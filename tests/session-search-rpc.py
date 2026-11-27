"""Real RPC contract against policy-bound search primitives; no model calls."""

import gzip
import json
import os
import subprocess
import sys
import time
from pathlib import Path

work, source = sys.argv[1:]
proc = subprocess.Popen(
    [os.environ["MARE_BIN"], "-C", work, "--yolo", "--rpc"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",
)
next_id = 0


pending = {}


def send(method, params):
    global next_id
    next_id += 1
    request_id = next_id
    proc.stdin.write(
        json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        )
        + "\n"
    )
    proc.stdin.flush()
    return request_id


def take(request_id):
    if request_id in pending:
        return pending.pop(request_id)
    while True:
        line = proc.stdout.readline()
        if not line:
            raise AssertionError(proc.stderr.read())
        msg = json.loads(line)
        if msg.get("id") == request_id:
            return msg
        if "id" in msg:
            pending[msg["id"]] = msg


MASKED = "internal error (details are in the log)"


def error_text(msg):
    err = msg["error"]
    assert not (err["message"] == MASKED and (err.get("data") or {}).get("code") == "internal"), msg
    return err["message"]


def call(method, params):
    return take(send(method, params))


def result(method, params):
    msg = call(method, params)
    assert "error" not in msg, msg
    return msg["result"]


try:
    result("initialize", {"protocol_version": "3.0"})
    revoke = call("query.call", {"operation": "contract.unregister", "arguments": {}})
    assert "error" in revoke and "ephemeral-read-only" in error_text(revoke), (
        revoke
    )
    providers = result("query.list_providers", {})["data"]
    assert any(p["name"] == "persisted-sessions" for p in providers), providers
    assert any(p["name"] == "live-sessions" for p in providers), providers
    echo = result(
        "query.call",
        {
            "operation": "contract.echo",
            "arguments": {"value": "public query", "first": True},
        },
    )
    echo_cursor = echo["next_cursor"]
    assert (
        echo["value"] == "public query"
        and echo["provider"] == "contract-provider"
        and echo_cursor
    ), echo
    result("commands.run", {"line": "/reload session-search-probe"})
    old_cursor = call(
        "query.call",
        {"operation": "contract.echo", "arguments": {"cursor": echo_cursor}},
    )
    assert (
        "error" in old_cursor and "QUERY_STALE_CURSOR" in error_text(old_cursor)
    ), old_cursor
    slow = send("query.call", {"operation": "contract.slow", "arguments": {}})
    for _ in range(100):
        if result("query.call", {"operation": "contract.status", "arguments": {}})[
            "started"
        ]:
            break
    else:
        raise AssertionError("slow provider never entered its cancellable wait")
    result("commands.run", {"line": "/query-unregister"})
    cancelled = take(slow)
    assert "error" in cancelled and any(
        code in error_text(cancelled)
        for code in ("QUERY_PROVIDER_CHANGED", "QUERY_CANCELLED")
    ), cancelled
    assert not any(
        p["name"] == "contract-provider" for p in result("query.list_providers", {})["data"]
    )
    opaque = call("query.call", {"operation": "contract.opaque", "arguments": {}})
    assert (
        "error" in opaque
        and "QUERY_CAPABILITY_UNAVAILABLE" in error_text(opaque)
    ), opaque
    assert not result(
        "query.call", {"operation": "contract.opaque-status", "arguments": {}}
    )["called"]
    forbidden = Path(work) / "query-must-not-write.txt"
    for operation, arguments in [
        ("contract.write", {"path": str(forbidden)}),
        ("contract.network", {"url": "http://127.0.0.1:9/no-network"}),
    ]:
        blocked = call("query.call", {"operation": operation, "arguments": arguments})
        assert "error" in blocked and any(
            marker in error_text(blocked)
            for marker in ("ephemeral-read-only", "denied")
        ), blocked
    confined = call(
        "query.call",
        {"operation": "contract.process", "arguments": {"path": str(forbidden)}},
    )
    assert "error" in confined or confined["result"]["code"] != 0, confined
    assert not forbidden.exists()
    invalid = call("session.get_item", {"item_id": 3})
    assert invalid["error"]["code"] == -32602, invalid
    first = result(
        "session.search",
        {"query": "secret needle", "filters": {"session_ids": ["history-one"]}},
    )
    assert len(first["data"]) == 1 and first["data"][0]["session_id"] == "history-one", (
        first
    )
    assert first["data"][0].get("item_id") and "event_id" not in first["data"][0], first
    first_item = result(
        "session.get_item",
        {
            "session_id": "history-one",
            "item_id": first["data"][0]["item_id"],
            "before": 1,
        },
    )
    assert first_item["item"]["item_id"] == first["data"][0]["item_id"], first_item
    first_query = result(
        "query.call",
        {
            "operation": "session.search",
            "arguments": {"query": "secret needle", "filters": {"session_ids": ["history-one"]}},
        },
    )
    assert len(first_query["data"]) == 1 and first_query["data"][0]["event_id"], first_query
    event = result(
        "query.call",
        {
            "operation": "session.read",
            "arguments": {"event_id": first_query["data"][0]["event_id"], "before": 1},
        },
    )
    assert event["event"]["message"]["content"][0]["text"] == "secret needle 世界", (
        event
    )
    assert event["seq"] == 125 and len(event["neighbors"]) == 1
    live = call(
        "query.call",
        {
            "operation": "session.search",
            "provider": "persisted-sessions",
            "arguments": {"query": "needle", "filters": {"availability": ["live"]}},
        },
    )
    assert (
        "error" in live and "QUERY_CAPABILITY_UNAVAILABLE" in error_text(live)
    ), live
    archived = result(
        "session.search",
        {
            "query": "secret needle",
            "filters": {
                "session_ids": ["history-one", "history-archived"],
                "archived": True,
            },
        },
    )
    assert [h["session_id"] for h in archived["data"]] == ["history-archived"], archived
    current = result(
        "session.search",
        {
            "query": "secret needle",
            "filters": {
                "session_ids": ["history-one", "history-archived"],
                "archived": False,
            },
        },
    )
    assert [h["session_id"] for h in current["data"]] == ["history-one"], current
    generic = result(
        "query.call",
        {
            "operation": "session.events",
            "arguments": {
                "session_id": "history-one",
                "query": "secret needle",
                "event_filters": {"seq_from": 3, "seq_to": 5},
            },
        },
    )
    assert len(generic["data"]) == 3, generic
    assert generic["data"][0]["position"]["seq"] == 5
    events = result(
        "session.search_items", {"session_id": "history-one", "query": "secret needle"}
    )
    assert len(events["data"]) == 20 and events["next_cursor"], events
    item = result(
        "session.get_item",
        {
            "session_id": "history-one",
            "item_id": events["data"][0]["item_id"],
            "before": 1,
        },
    )
    assert item["item"]["item_id"] == events["data"][0]["item_id"], item
    assert item["seq"] == 125 and len(item["neighbors"]) == 1, item
    page = result(
        "session.search_items",
        {
            "session_id": "history-one",
            "query": "secret needle",
            "cursor": events["next_cursor"],
        },
    )
    assert len(page["data"]) == 20 and page.get("next_cursor"), page
    total = 40
    while page.get("next_cursor"):
        page = result(
            "session.search_items",
            {
                "session_id": "history-one",
                "query": "secret needle",
                "cursor": page["next_cursor"],
            },
        )
        total += len(page["data"])
    assert total == 125, total
    hidden = call(
        "session.search_items", {"session_id": "hidden", "query": "secret needle"}
    )
    assert "error" in hidden and (
        "session unavailable" in error_text(hidden)
        or (hidden["error"].get("data") or {}).get("code") == "unavailable"
    ), hidden
    # An append changes generation; old positions must never read a different event.
    with Path(source).open("a") as f:
        f.write(
            json.dumps(
                {
                    "type": "message",
                    "entry_id": "appended",
                    "message": {"role": "user", "content": "later"},
                }
            )
            + "\n"
        )
    stale = call(
        "session.search_items",
        {
            "session_id": "history-one",
            "query": "secret needle",
            "cursor": events["next_cursor"],
        },
    )
    assert "error" in stale and (
        "stale history cursor" in error_text(stale)
        or (stale["error"].get("data") or {}).get("code") == "stale_session"
    ), stale
    stale = call(
        "query.call",
        {
            "operation": "session.read",
            "arguments": {"event_id": first_query["data"][0]["event_id"]},
        },
    )
    assert "error" in stale and (
        "stale history event" in error_text(stale)
        or (stale["error"].get("data") or {}).get("code") == "stale_session"
    ), stale
    resumed = result("session.load", {"session_id": "history-tools"})
    assert resumed["session_id"] == "history-tools", resumed
    forked = result("session.fork", {"session_id": "history-tools"})
    assert forked["session_id"] != "history-tools", forked
    family = result(
        "query.call",
        {"operation": "session.trace", "arguments": {"session_id": forked["session_id"]}},
    )
    assert (
        family["target"]["session_id"] == forked["session_id"]
        and family["ancestors"][0]["session_id"] == "history-tools"
    ), family
    descendants = result(
        "query.call",
        {"operation": "session.trace", "arguments": {"session_id": "history-tools"}},
    )
    assert any(
        node["session"]["session_id"] == forked["session_id"]
        for node in descendants["descendants"]
    ), descendants
    result("session.load", {"session_id": "history-tools"})
    result("commands.run", {"line": "/history-child"})
    child = json.loads(Path(os.environ["HISTORY_CHILD_REPORT"]).read_text(encoding="utf-8"))
    assert not child.get("error") and "世界" in json.dumps(
        child["messages"], ensure_ascii=False
    ), child
    captured = [
        json.loads(line)
        for line in Path(os.environ["HISTORY_CAPTURE"]).read_text(encoding="utf-8").splitlines()
    ]
    assert captured[-1]["mode"] == "child", captured[-1]
    # the child's own session in its VM (agent:activity()), not the parent's; its transcript
    # identity (what the parent's trace lists) is what the parent observed when it spawned it -
    # whether the two agree is session-search-child-identity.py's check
    first_child_id = captured[-1]["caller_id"]
    assert first_child_id and first_child_id != "history-tools", captured[-1]
    child_transcript = child["parent_observed"]["child_session_id"]
    family = result(
        "query.call",
        {"operation": "session.trace", "arguments": {"session_id": "history-tools"}},
    )
    assert len(family["descendants"]) >= 2, family
    assert any(
        n["session"]["session_id"] == child_transcript
        for n in family["descendants"]
    ), family
    result("commands.run", {"line": "/history-deny-file"})
    result("commands.run", {"line": "/history-child"})
    child = json.loads(Path(os.environ["HISTORY_CHILD_REPORT"]).read_text(encoding="utf-8"))
    assert not child.get("error") and "世界" not in json.dumps(
        child["messages"], ensure_ascii=False
    ), child
    assert "QUERY_" in json.dumps(child["messages"]), child
    newer = [
        json.loads(line)
        for line in Path(os.environ["HISTORY_CAPTURE"]).read_text(encoding="utf-8").splitlines()
    ][-1]
    assert newer["caller_id"] not in (first_child_id, "history-tools"), newer
    result("commands.run", {"line": "/history-full"})
    result("commands.run", {"line": "/history-deny-children"})
    restricted = result(
        "query.call",
        {"operation": "session.trace", "arguments": {"session_id": "history-tools"}},
    )
    assert child_transcript not in json.dumps(restricted), restricted
    assert len(restricted["descendants"]) == 1, restricted
    result("commands.run", {"line": "/history-deny-current"})
    boundary = result(
        "query.call",
        {"operation": "session.trace", "arguments": {"session_id": forked["session_id"]}},
    )
    assert boundary["parent_boundary"] and "history-tools" not in json.dumps(
        boundary
    ), boundary
    result("commands.run", {"line": "/history-full"})
    # Active live-sessions provider returns live active session & excludes persisted-only for live
    live_active = result(
        "query.call",
        {
            "operation": "session.search",
            "arguments": {
                "query": "secret needle",
                "filters": {"availability": ["live"]},
            },
        },
    )
    assert live_active["coverage"]["live"] is True, live_active
    assert any(
        h["session_id"] == "history-tools" and h["availability"] == "live"
        for h in live_active["data"]
    ), live_active
    assert all(h["session_id"] != "history-one" for h in live_active["data"]), (
        live_active
    )
    result("commands.run", {"line": "/archive"})
    native_archive = result(
        "query.call",
        {
            "operation": "session.search",
            "arguments": {
                "query": "secret needle",
                "filters": {"session_ids": ["history-tools"], "archived": True},
            },
        },
    )
    assert (
        len(native_archive["data"]) == 1
        and native_archive["data"][0]["session_id"] == "history-tools"
    ), native_archive
    assert native_archive["data"][0]["rank"]["match_count"] > 1, native_archive
    not_archived = result(
        "session.search",
        {
            "query": "secret needle",
            "filters": {"session_ids": ["history-tools"], "archived": False},
        },
    )
    assert not not_archived["data"], not_archived

    # Surface projection, event_trace, >64 KiB chunked read, title search + updatedAt sort,
    # compressed .jsonl.gz rollout, and >32 MiB multi-file corpus tail scan.
    sessions_dir = Path(source).parent
    seed_cwd = json.loads(Path(source).read_text(encoding="utf-8").splitlines()[0])["cwd"]
    huge_payload = "H" * 70_000
    surf_file = sessions_dir / "rpc-surface.jsonl"
    gz_file = sessions_dir / "z-rpc-tail.jsonl.gz"
    bulk_files = []
    try:
        surf_rows = [
            {
                "type": "session",
                "version": 3,
                "session_id": "rpc-surface",
                "cwd": seed_cwd,
                "created_at_ms": 1000,
            },
            {
                "type": "message",
                "entry_id": "u1",
                "created_at_ms": 1010,
                "message": {"role": "user", "content": "shadowed surf needle"},
            },
            {
                "type": "message",
                "entry_id": "a1",
                "parent_entry_id": "u1",
                "created_at_ms": 1020,
                "message": {
                    "role": "assistant",
                    "tool_calls": [{"id": "tc1", "name": "read"}],
                    "content": "calling tool",
                },
            },
            {
                "type": "message",
                "entry_id": "t1",
                "parent_entry_id": "a1",
                "created_at_ms": 1030,
                "message": {
                    "role": "tool_result",
                    "tool_call_id": "tc1",
                    "content": "tool out",
                },
            },
            {
                "type": "message",
                "entry_id": "ab1",
                "parent_entry_id": "u1",
                "created_at_ms": 1040,
                "message": {"role": "user", "content": "abandoned surf needle"},
            },
            {"type": "leaf", "target_entry_id": "t1"},
            {
                "type": "compaction",
                "entry_id": "cmp1",
                "parent_entry_id": "t1",
                "created_at_ms": 1050,
                "summary": "compacted surf",
            },
            {
                "type": "branch_summary",
                "entry_id": "bs1",
                "parent_entry_id": "cmp1",
                "from_entry_id": "ab1",
                "created_at_ms": 1060,
                "summary": "branch summary surf",
            },
            {
                "type": "message",
                "entry_id": "u2",
                "parent_entry_id": "bs1",
                "created_at_ms": 2000,
                "message": {
                    "role": "user",
                    "content": f"current surf needle {huge_payload}",
                },
            },
            {"type": "name", "name": "Surface Alpha"},
        ]
        surf_file.write_text(
            "".join(json.dumps(r) + "\n" for r in surf_rows), encoding="utf-8"
        )
        shadowed_hits = result(
            "query.call",
            {
                "operation": "session.events",
                "arguments": {
                    "session_id": "rpc-surface",
                    "query": "surf needle",
                    "event_filters": {"surfaces": ["shadowed"]},
                },
            },
        )
        assert [h["position"]["seq"] for h in shadowed_hits["data"]] == [1], (
            shadowed_hits
        )
        assert shadowed_hits["data"][0]["surface"] == "shadowed", shadowed_hits
        log_only_hits = result(
            "query.call",
            {
                "operation": "session.events",
                "arguments": {
                    "session_id": "rpc-surface",
                    "query": "surf needle",
                    "event_filters": {"surfaces": ["log_only"]},
                },
            },
        )
        assert [h["position"]["seq"] for h in log_only_hits["data"]] == [4], (
            log_only_hits
        )
        ev_trace = result(
            "query.call",
            {
                "operation": "session.event_trace",
                "arguments": {"session_id": "rpc-surface", "seq": 3},
            },
        )
        assert (
            ev_trace["surface"] == "shadowed"
            and ev_trace["replaced_by"] == 6
            and ev_trace["source_event_seqs"] == [2]
            and ev_trace["derived_event_seqs"] == [6]
        ), ev_trace
        current_hits = result(
            "query.call",
            {
                "operation": "session.events",
                "arguments": {
                    "session_id": "rpc-surface",
                    "query": "current surf needle",
                    "event_filters": {"surfaces": ["current"]},
                },
            },
        )
        big_eid = current_hits["data"][0]["event_id"]
        inline_err = call(
            "query.call",
            {"operation": "session.read", "arguments": {"event_id": big_eid}},
        )
        assert "error" in inline_err and "QUERY_EVENT_TOO_LARGE" in error_text(inline_err), (
            inline_err
        )
        assembled = []
        offset = 0
        while True:
            part = result(
                "query.call",
                {
                    "operation": "session.read",
                    "arguments": {
                        "event_id": big_eid,
                        "offset": offset,
                        "max_bytes": 65536,
                    },
                },
            )
            assembled.append(part["chunk"])
            if not part.get("next_offset"):
                break
            offset = part["next_offset"]
        assert huge_payload in json.loads("".join(assembled))["message"]["content"]

        # Compressed .jsonl.gz + title_query + updated_at sort + >32 MiB corpus
        gz_rows = [
            {
                "type": "session",
                "version": 3,
                "session_id": "z-rpc-tail",
                "cwd": seed_cwd,
                "created_at_ms": 500,
            },
            {"type": "name", "name": "Surface Beta"},
            {
                "type": "message",
                "entry_id": "g1",
                "created_at_ms": 5000,
                "message": {"role": "assistant", "content": "rpc_tail_gz_needle"},
            },
        ]
        gz_file.write_bytes(
            gzip.compress("".join(json.dumps(r) + "\n" for r in gz_rows).encode("utf-8"))
        )
        title_desc = result(
            "query.call",
            {
                "operation": "session.search",
                "arguments": {
                    "title_query": "Surface",
                    "sort_key": "updated_at_ms",
                    "sort_direction": "desc",
                },
            },
        )
        assert [h["session_id"] for h in title_desc["data"]] == [
            "z-rpc-tail",
            "rpc-surface",
            "surface-e2e",
        ], title_desc
        title_asc = result(
            "query.call",
            {
                "operation": "session.search",
                "arguments": {
                    "title_query": "Surface",
                    "sort_key": "updated_at_ms",
                    "sort_direction": "asc",
                },
            },
        )
        assert [h["session_id"] for h in title_asc["data"]] == [
            "surface-e2e",
            "rpc-surface",
            "z-rpc-tail",
        ], title_asc

        filler_line = (
            json.dumps(
                {
                    "type": "message",
                    "entry_id": "f",
                    "created_at_ms": 100,
                    "message": {"role": "assistant", "content": "B" * 600_000},
                }
            )
            + "\n"
        )
        for idx in range(6):
            bf = sessions_dir / f"00-bulk-{idx}.jsonl"
            hdr = (
                json.dumps(
                    {
                        "type": "session",
                        "version": 3,
                        "session_id": f"rpc-bulk-{idx}",
                        "cwd": seed_cwd,
                        "created_at_ms": 100 + idx,
                    }
                )
                + "\n"
            )
            bf.write_text(hdr + filler_line * 10, encoding="utf-8")
            bulk_files.append(bf)
        cursor = None
        tail_hits = []
        while True:
            args_bulk = {"query": "rpc_tail_gz_needle"}
            if cursor:
                args_bulk["cursor"] = cursor
            page_bulk = result(
                "query.call", {"operation": "session.search", "arguments": args_bulk}
            )
            tail_hits.extend(page_bulk["data"])
            cursor = page_bulk.get("next_cursor")
            if not cursor:
                break
        assert [h["session_id"] for h in tail_hits] == ["z-rpc-tail"], tail_hits
    finally:
        surf_file.unlink(missing_ok=True)
        gz_file.unlink(missing_ok=True)
        for bf in bulk_files:
            bf.unlink(missing_ok=True)

    result("commands.run", {"line": "/history-deny"})
    denied = call("session.search", {"query": "secret needle"})
    assert "error" in denied and (
        "sandbox" in error_text(denied)
        or (denied["error"].get("data") or {}).get("code") == "denied"
    ), denied
    result("shutdown", {})
finally:
    proc.stdin.close()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
assert proc.returncode == 0
