"""Actual RPC user commands/model tools/storage restart and native durable inbox receipts."""
import datetime as dt
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

binary,cwd=sys.argv[1:]
process=None
messages=[]
responses=None
serial=0
errors=[]

def launch(resume=None):
    global process,responses,serial,messages,errors
    responses=queue.Queue();serial=0;messages=[];errors=[]
    args=[binary,"-C",cwd,"--rpc","--yolo"]
    if resume: args.extend(["--resume",resume])
    process=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True, encoding="utf-8")
    def reader():
        for line in process.stdout:
            item=json.loads(line);messages.append(item);responses.put(item)
    def stderr():
        for line in process.stderr: errors.append(line)
    threading.Thread(target=reader,daemon=True).start();threading.Thread(target=stderr,daemon=True).start()
    rpc("initialize",{"protocol_version":"3.0","capabilities":{"ui":True}})

def rpc(method,params=None):
    global serial
    serial+=1
    process.stdin.write(json.dumps({"jsonrpc":"2.0","id":serial,"method":method,"params":params or {}})+"\n");process.stdin.flush()
    deadline=time.monotonic()+30
    while time.monotonic()<deadline:
        try: item=responses.get(timeout=.5)
        except queue.Empty:
            assert process.poll() is None,"".join(errors)
            continue
        if item.get("id")==serial:
            assert "error" not in item,item
            return item.get("result")
    raise AssertionError((method,"".join(errors)))

def command(action,value=None):
    text="/schedule "+action
    if value is not None: text+=" "+(json.dumps(value) if isinstance(value,dict) else value)
    return rpc("commands.run",{"line":text})

def sid():
    return rpc("status.get")["session"]["session_id"]
def busy():
    return bool(rpc("agent.get", {"session_id": sid()}).get("busy"))
def session_messages():
    return rpc("agent.list_messages", {"session_id": sid()})["data"]
def prompt_wait(text):
    s = sid()
    started = rpc("agent.prompt", {"session_id": s, "input": text})
    return rpc("agent.wait", {"session_id": s, "turn_id": started["turn_id"]})
def snapshot():
    result=rpc("state.snapshot",{"namespace":"schedule.tasks"})
    assert result["status"]=="ok",result
    return result["snapshot"]

def tasks():
    snap=snapshot();return snap["value"]["tasks"] if snap["exists"] else []

def task(title): return next(t for t in tasks() if t["record"]["title"]==title)
def wait(predicate,seconds=15):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.1)
    raise AssertionError((tasks(),"".join(errors)))
def ui(): return "\n".join(m["params"].get("text","") for m in messages if m.get("method")=="ui.notify")
def create(title,timing,prompt="Check independently"):
    command("create",{"title":title,"prompt":prompt,"timing":timing,"target":{"kind":"session","session_id":target}})
    return task(title)
def stop():
    rpc("shutdown");process.wait(timeout=10);assert process.returncode==0,"".join(errors)

try:
    launch()
    initial=prompt_wait("MODEL_DEFINE")
    assert not initial.get("error"),(initial,errors,messages)
    model=task("MODEL_SAVED");assert model["status"]=="paused",model
    target=model["target"]["session_id"]
    command("view",model["record"]["id"])
    command("history",model["record"]["id"])
    assert "MODEL_SAVED" in ui() and '"records":[]' in ui(),ui()
    rpc("commands.run",{"line":"/domain-checks"})
    assert "DOMAIN_LIFETIME_CHECKS_PASSED" in ui(),ui()
    now=dt.datetime.now(dt.timezone.utc)
    at=(now+dt.timedelta(hours=2)).isoformat(timespec="milliseconds").replace("+00:00","Z")
    recurrence="DTSTART:"+(now+dt.timedelta(hours=2)).strftime("%Y%m%dT%H%M%SZ")+"\nRRULE:FREQ=DAILY;COUNT=2"
    variants=[("after",{"kind":"after","after_seconds":7200}),("at",{"kind":"at","at":at}),
              ("every",{"kind":"every","every_seconds":60}),("daily",{"kind":"daily","daily":{"time":"13:17:03.123","time_zone":"Asia/Tokyo"}}),
              ("weekly",{"kind":"weekly","weekly":{"time":"13:17:03.123","time_zone":"UTC","weekdays":[1,3,5]}}),
              ("cron",{"kind":"cron","cron":{"expression":"*/15 * * * 1-5","time_zone":"America/New_York"}}),("rrule",{"kind":"rrule","rrule":recurrence})]
    for name,timing in variants:
        row=create("TYPE_"+name,timing);assert row["record"]["kind"]==name
        command("pause",row["record"]["id"])
    assert len(tasks())==8
    before=task("TYPE_every");scheduled=before["record"]["scheduled_at"];anchor=before["pattern"]["anchor_ms"]
    command("edit",{"id":before["record"]["id"],"action":"update","expected_updated_at":before["updated_at"],"patch":{"title":"TYPE_every","prompt":"Changed description"}})
    changed=task("TYPE_every");assert changed["record"]["scheduled_at"]==scheduled and changed["pattern"]["anchor_ms"]==anchor
    command("edit",{"id":changed["record"]["id"],"action":"update","expected_updated_at":before["updated_at"],"patch":{"title":"WRONG"}})
    assert not any(t["record"]["title"]=="WRONG" for t in tasks()) and "schedule_conflict" in ui()
    count=len(tasks())
    command("create",{"title":"INVALID","prompt":"none","timing":{"kind":"after","after_seconds":1,"every_seconds":60},"target":{"kind":"session","session_id":target}})
    command("create",{"title":"NO_CHILD_FALLBACK","prompt":"none","timing":{"kind":"after","after_seconds":1},"target":{"kind":"new_once"}})
    assert len(tasks())==count and "target_runtime_unavailable" in ui()
    stop();launch(target)
    assert len(tasks())==8 and all(t["status"]=="paused" for t in tasks())
    rpc("commands.run",{"line":"/domain-capabilities"})
    cap=[l for l in ui().splitlines() if l.startswith("DOMAIN_CAPABILITY agent.enqueue=")]
    assert cap and cap[-1].endswith("=true"),(ui(),"".join(errors))
    rpc("commands.run",{"line":"/plan"})
    prompt_wait("COMMIT_PLAN_ON")
    held=create("PLAN_HOLD",{"kind":"after","after_seconds":1},"PLAN_HELD_PROMPT")
    time.sleep(2.2)
    assert "last_delivery" not in task("PLAN_HOLD")
    rpc("commands.run",{"line":"/plan off"})
    wait(lambda: task("PLAN_HOLD")["status"]=="ended");wait(lambda: not busy())
    race=create("PLAN_RESERVE_RACE",{"kind":"after","after_seconds":1},"PLAN_RESERVATION_PROMPT")
    wait(lambda: "PLAN_RESERVE_RACE_BLOCKED" in ui())
    assert "last_delivery" not in task("PLAN_RESERVE_RACE")
    rpc("commands.run",{"line":"/plan off"})
    wait(lambda: task("PLAN_RESERVE_RACE")["status"]=="ended");wait(lambda: not busy())
    late=create("PLAN_LATE",{"kind":"after","after_seconds":1},"PLAN_LATE_RACE")
    wait(lambda: "PLAN_LATE_RACE_BLOCKED" in ui());wait(lambda: not busy())
    late_receipt=task("PLAN_LATE")["last_delivery"]
    # agent/input-ready prevents canonical B persistence while in Plan mode; entry stays queued.
    assert not any(m.get("input_id")==late_receipt["input_id"] for m in session_messages())
    assert not any("PLAN_LATE_RACE" in json.loads(line)["user"] for line in Path(os.environ["DOMAIN_MODEL_LOG"]).read_text(encoding="utf-8").splitlines())
    rpc("commands.run",{"line":"/plan off"})
    wait(lambda: any("PLAN_LATE_RACE" in json.loads(line)["user"] for line in Path(os.environ["DOMAIN_MODEL_LOG"]).read_text(encoding="utf-8").splitlines()))
    wait(lambda: not busy())
    assert len(task("PLAN_LATE")["delivery_history"]["records"])==1
    assert sum(m.get("input_id")==late_receipt["input_id"] for m in session_messages())==1
    due=create("DUE_ACTUAL",{"kind":"after","after_seconds":1},"DELIVERED_BY_NATIVE_INBOX")
    wait(lambda: task("DUE_ACTUAL")["status"]=="ended")
    wait(lambda: not busy())
    delivered=task("DUE_ACTUAL");receipt=delivered["last_delivery"]
    actual=session_messages()
    assert any(m.get("input_id")==receipt["input_id"] and m.get("source")=="schedule" for m in actual),actual
    assert len(delivered["delivery_history"]["records"])==1
    command("history",delivered["record"]["id"]);assert receipt["input_id"] in ui()
    manual=create("MANUAL",{"kind":"after","after_seconds":7200})
    command("run",manual["record"]["id"]);wait(lambda: "last_delivery" in task("MANUAL"))
    assert task("MANUAL")["record"]["scheduled_at"]==manual["record"]["scheduled_at"]
    command("run",manual["record"]["id"]);assert len(task("MANUAL")["delivery_history"]["records"])==1
    command("pause",manual["record"]["id"])
    wait(lambda: not busy())
    raced=create("CONCURRENT_RUN",{"kind":"after","after_seconds":7200})
    rpc("commands.run",{"line":"/domain-race "+raced["record"]["id"]})
    wait(lambda: "last_delivery" in task("CONCURRENT_RUN"));wait(lambda: not busy())
    assert len(task("CONCURRENT_RUN")["delivery_history"]["records"])==1
    race_input=task("CONCURRENT_RUN")["last_delivery"]["input_id"]
    wait(lambda: any(m.get("input_id")==race_input for m in session_messages()))
    wait(lambda: not busy())
    assert sum(m.get("input_id")==race_input for m in session_messages())==1
    command("pause",raced["record"]["id"])
    failure=create("MODEL_ERROR",{"kind":"after","after_seconds":1},"DELIVERY_ERROR")
    wait(lambda: "last_delivery" in task("MODEL_ERROR"));wait(lambda: not busy())
    assert task("MODEL_ERROR")["status"]=="ended" and len(task("MODEL_ERROR")["delivery_history"]["records"])==1
    cancel=create("MODEL_CANCEL",{"kind":"after","after_seconds":1},"DELIVERY_CANCEL")
    wait(lambda: any("DOMAIN_CANCEL_STARTED" in json.dumps(m) for m in messages))
    rpc("agent.cancel",{"session_id":sid()});wait(lambda: not busy())
    assert len(task("MODEL_CANCEL")["delivery_history"]["records"])==1
    # External /schedule commands queue non-waking [SCHEDULE CHANGE] notices without waking an idle turn
    # and self-actor model tool creates (MODEL_SAVED) do not emit self-notices.
    prompt_wait("NOTICE_CHECK")
    log_rows=[json.loads(line) for line in Path(os.environ["DOMAIN_MODEL_LOG"]).read_text(encoding="utf-8").splitlines()]
    notice_row=next(r for r in reversed(log_rows) if "NOTICE_CHECK" in r["user"])
    joined_notices="\n".join(notice_row.get("notifications",[]))
    assert "[SCHEDULE CHANGE]" in joined_notices and "schedule_title_json" in joined_notices,notice_row
    assert "MODEL_SAVED" not in joined_notices,joined_notices
    # Same-target recurring batching: two rrule tasks with matching DTSTART fire in one [SCHEDULE REMINDER BATCH]
    batch_dt=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(seconds=3)).strftime("%Y%m%dT%H%M%SZ")
    batch_rrule="DTSTART:"+batch_dt+"\nRRULE:FREQ=DAILY;COUNT=2"
    create("BATCH_1",{"kind":"rrule","rrule":batch_rrule},"BATCH_PROMPT_1")
    create("BATCH_2",{"kind":"rrule","rrule":batch_rrule},"BATCH_PROMPT_2")
    wait(lambda: "last_delivery" in task("BATCH_1") and "last_delivery" in task("BATCH_2"),seconds=15)
    wait(lambda: not busy(),seconds=15)
    assert task("BATCH_1")["last_delivery"]["input_id"]==task("BATCH_2")["last_delivery"]["input_id"]
    log_rows=[json.loads(line) for line in Path(os.environ["DOMAIN_MODEL_LOG"]).read_text(encoding="utf-8").splitlines()]
    assert any("[SCHEDULE REMINDER BATCH]" in r["user"] and "BATCH_PROMPT_1" in r["user"] and "BATCH_PROMPT_2" in r["user"] for r in log_rows),log_rows
    command("pause",task("BATCH_1")["record"]["id"])
    command("pause",task("BATCH_2")["record"]["id"])
    # Unknown ACK reconciliation across restart against real core queued()/messages()/entries()/persist_error()
    rec_abs=create("RECONCILE_ABSENT",{"kind":"after","after_seconds":7200},"NEVER_DUE")
    snap_unk=snapshot()
    unk_val=snap_unk["value"]
    for item in unk_val["tasks"]:
        if item["record"]["id"]==rec_abs["record"]["id"]:
            item["reservation"]={
                "id":"unk-absent-1","owner":"crashed-instance","phase":"unknown",
                "prompt":item["record"]["prompt"],"pattern":item["pattern"],"timing":item["timing"],
                "target":item["target"],"manual":False,"scheduled_at":item["record"]["scheduled_at"],
                "occurrence_at":item["record"]["scheduled_at"],"reserved_at":item["created_at"],
            }
            item["revision"]=item["revision"]+1
    assert rpc("state.compare_exchange",{"namespace":"schedule.tasks","expected_revision":snap_unk["revision"],"value":unk_val})["status"]=="ok"
    stop();launch(target)
    wait(lambda: "reservation" not in task("RECONCILE_ABSENT"),seconds=15)
    assert "last_delivery" not in task("RECONCILE_ABSENT")
    command("pause",task("RECONCILE_ABSENT")["record"]["id"])
    command("delete-inactive");assert not any(t["status"]=="ended" for t in tasks())
    preserved=snapshot();expected_count=len(preserved["value"]["tasks"])
    bad=rpc("state.compare_exchange",{"namespace":"schedule.tasks","expected_revision":preserved["revision"],"value":{"version":999,"tasks":[]}})
    assert bad["status"]=="ok"
    command("list");assert "storage_corrupt" in ui() or "storage_unavailable" in ui()
    latest=snapshot();assert latest["value"]["version"]==999
    restored=rpc("state.compare_exchange",{"namespace":"schedule.tasks","expected_revision":latest["revision"],"value":preserved["value"]});assert restored["status"]=="ok"
    stop();launch(target);command("list");assert len(tasks())==expected_count
    stop()
finally:
    if process is not None and process.poll() is None:
        process.terminate();process.wait(timeout=10)
