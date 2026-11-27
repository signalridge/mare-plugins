#!/usr/bin/env python3
"""A real RPC component consumer: native source positions, PNG bytes, updates and cancellation."""

import base64
import html
import json
import os
import select
import struct
import sys
import tempfile
import time
import zlib

from rpc_client import Client


def png_bytes(variant=False):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data))
        )

    width, height = (16, 32) if variant else (32, 16)
    color = [200, 30, 50, 255] if variant else [30, 180, 210, 255]
    rows = b"".join(b"\0" + bytes(color) * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def write_presenter(home):
    directory = os.path.join(home, "config", "plugins")
    os.makedirs(directory, exist_ok=True)
    encoded = base64.b64encode(png_bytes()).decode("ascii")
    other = base64.b64encode(png_bytes(True)).decode("ascii")
    with open(
        os.path.join(directory, "presentation-fixture.lua"), "w", encoding="utf-8"
    ) as stream:
        stream.write(
            "return {name='presentation-fixture',inject={'ui','session'},apply=function(ctx)\n"
            "ctx:on('ui/caps',function(c,ev) local p=mare.env('PRESENTATION_CAPS_REPORT'); if p then mare.fs.write(p,mare.json.encode({mode=mare.mode,caps=c})) end; return ev.next(c) end)\n"
            "ctx:on('turn/completed',function() local p=mare.env('PRESENTATION_SESSION_REPORT'); if p then mare.fs.write(p,mare.json.encode(ctx.session:info())) end end)\n"
            "local slow_done_tx, slow_done_rx = mare.task.channel()\n"
            "ctx.ui:markdown_presenter('drawing',{render=function(r)\n"
            "if r.source:find('rpc-cancel',1,true) then r.cancel:wait(); slow_done_tx:send(true) elseif r.source:find('slow-cancel',1,true) then r.cancel:wait() elseif r.source:find('fence',1,true) then slow_done_rx:recv() elseif r.source:find('slow',1,true) then mare.task.sleep(200) end\n"
            "return mare.ui.Lines({mare.ui.Code('viewport:'..r.width,'text'),\n"
            f"mare.ui.image{{bytes=mare.crypto.base64_decode((r.source:find('cancel',1,true)) and '{other}' or '{encoded}'),max_rows=8,max_cols=40}}}})\n"
            "end})\nend}\n"
        )


class Frontend(Client):
    def __init__(self, *args):
        super().__init__(*args)
        self.presentations = []
        self.session_id = None

    def dispatch(self, message):
        if message.get("method") == "ui.markdown_changed":
            self.presentations.append(message["params"])
            return None
        return super().dispatch(message)

    def settled(self, identity):
        result = self.call(
            "ui.get_markdown", {"session_id": self.session_id, "document_id": identity}
        )
        if result and not result["pending"]:
            return result
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.p.stdout], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                break
            self.dispatch(self.read())
            for note in reversed(self.presentations):
                if note.get("document_id") == identity and not note.get("pending"):
                    return self.call(
                        "ui.get_markdown",
                        {"session_id": self.session_id, "document_id": identity},
                    )
        raise AssertionError("presentation did not settle")


def rejected(client, method, params, code=None):
    try:
        client.call(method, params)
    except RuntimeError as exc:
        if code is not None:
            assert code in str(exc), exc
        return
    raise AssertionError(f"invalid {method} was accepted")


def component_html(node):
    kind = node.get("type")
    if kind == "image":
        assert "bytes" not in node and "path" not in node
        raw = base64.b64decode(node["data"], validate=True)
        assert raw == png_bytes()
        assert struct.unpack(">II", raw[16:24]) == (32, 16)
        return '<img alt="diagram" src="data:image/png;base64,' + node["data"] + '">'
    if kind == "lines":
        return "".join(component_html(child) for child in node["items"])
    if kind == "code":
        return "<pre>" + html.escape(node["code"]) + "</pre>"
    if kind == "presented_markdown":
        source, cursor, pieces = node["text"].encode("utf-8"), 0, []
        for block in node["blocks"]:
            start, end = block["start"], block["end"]
            assert cursor <= start < end <= len(source)
            pieces.append(
                "<pre>" + html.escape(source[cursor:start].decode("utf-8")) + "</pre>"
            )
            pieces.append(component_html(block["node"]))
            cursor = end
        pieces.append("<pre>" + html.escape(source[cursor:].decode("utf-8")) + "</pre>")
        return "".join(pieces)
    raise AssertionError(f"unsupported fixture component: {kind}")


def main():
    binary = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory() as temp:
        home, work = os.path.join(temp, "home"), os.path.join(temp, "work")
        os.makedirs(work)
        write_presenter(home)
        env = dict(os.environ, MARE_HOME=home)
        client = Frontend(
            [binary, "--rpc", "--no-session", "--yolo", "--model", "faux/echo"],
            env,
            work,
        )
        try:
            init = client.call("initialize", {"protocol_version": "3.0"})
            sid = init["session"]["session_id"]
            client.session_id = sid
            assert any(
                entry["language"] == "drawing"
                for entry in client.call("ui.list_markdown_presenters")["data"]
            )
            source = "前置\n\n> ~~~DRAWING info\n> same\n> ~~~\n\n```drawing\nsame\n```\n\nafter"
            result = client.call(
                "ui.render_markdown",
                {
                    "session_id": sid,
                    "document_id": "document",
                    "source": source,
                    "viewport": {"supports_images": True, "width": 50},
                },
            )
            assert result["source"] == source
            result = client.settled("document")
            assert result["enhanced"] and len(result["node"]["blocks"]) == 2
            document = component_html(result["node"])
            assert (
                document.count('<img alt="diagram"') == 2
                and "前置" in document
                and "after" in document
            )
            assert client.presentations and client.presentations[-1]["document_id"] == "document"
            assert "cancel" not in json.dumps(result) and "userdata" not in json.dumps(
                result
            )
            with open(
                os.path.join(temp, "frontend.html"), "w", encoding="utf-8"
            ) as stream:
                stream.write("<!doctype html><meta charset=utf-8>" + document)
            trace_dir = os.environ.get("PRESENTATION_TRACE_DIR")
            if trace_dir:
                os.makedirs(trace_dir, exist_ok=True)
                with open(
                    os.path.join(trace_dir, "frontend.html"), "w", encoding="utf-8"
                ) as stream:
                    stream.write("<!doctype html><meta charset=utf-8>" + document)
                with open(
                    os.path.join(trace_dir, "snapshot.json"), "w", encoding="utf-8"
                ) as stream:
                    json.dump(result, stream, ensure_ascii=False)
            client.call(
                "ui.render_markdown",
                {
                    "session_id": sid,
                    "document_id": "document",
                    "source": source,
                    "viewport": {"supports_images": True, "width": 30},
                },
            )
            resized = client.settled("document")
            assert resized["revision"] > result["revision"]
            before_ids = [
                block["node"]["items"][1]["image_id"]
                for block in result["node"]["blocks"]
            ]
            after_ids = [
                block["node"]["items"][1]["image_id"]
                for block in resized["node"]["blocks"]
            ]
            assert before_ids == after_ids, (
                "occurrence image identity must survive profile updates"
            )
            assert (
                resized["node"]["blocks"][0]["node"]["items"][0]["code"]
                == "viewport:30"
            )
            client.call(
                "ui.render_markdown",
                {
                    "session_id": sid,
                    "document_id": "plain",
                    "source": source,
                    "viewport": {"supports_images": False},
                },
            )
            plain = client.settled("plain")
            assert (
                plain["source"] == source
                and not plain["enhanced"]
                and plain["node"]["blocks"] == []
            )
            client.call(
                "ui.render_markdown",
                {
                    "session_id": sid,
                    "document_id": "open",
                    "source": "```drawing\nopen",
                    "viewport": {"supports_images": True},
                },
            )
            assert not client.settled("open")["enhanced"]
            client.call(
                "ui.render_markdown",
                {
                    "session_id": sid,
                    "document_id": "cancel",
                    "source": "```drawing\nrpc-cancel\n```",
                    "viewport": {"supports_images": True},
                },
            )
            assert client.call(
                "ui.cancel_markdown", {"session_id": sid, "document_id": "cancel"}
            ) == {}
            client.call(
                "ui.render_markdown",
                {
                    "session_id": sid,
                    "document_id": "fence-wait",
                    "source": "```drawing\nfence\n```",
                    "viewport": {"supports_images": True},
                },
            )
            client.settled("fence-wait")
            assert not client.settled("cancel")["enhanced"]
            assert client.call(
                "ui.delete_markdown", {"session_id": sid, "document_id": "cancel"}
            ) == {}
            rejected(
                client,
                "ui.get_markdown",
                {"session_id": sid, "document_id": "cancel"},
                code="ui.unknown_document",
            )
            rejected(
                client,
                "ui.render_markdown",
                {"session_id": sid, "document_id": "bad", "source": "x", "viewport": {"width": 0}},
            )
            rejected(
                client,
                "ui.render_markdown",
                {"session_id": sid, "document_id": "bad", "source": "x", "extra": True},
            )
            assert isinstance(client.call("shutdown"), dict)
            client.p.stdin.close()
            assert client.p.wait(timeout=20) == 0
        finally:
            if client.p.poll() is None:
                client.p.kill()
                client.p.wait(timeout=10)
    print(
        "presentation_client: native positions, PNG components, updates, resize, source fallback, cancellation passed"
    )


if __name__ == "__main__":
    main()
