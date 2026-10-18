"""Offline tests for layer/stray_tags.py and its hooks in the layer (gate F1).
No GPU, no server: a fake upstream returns the recorded answers
as a non-stream JSON body or as SSE deltas. The layer's code sandbox is stubbed (the tests run no code).

python tests/test_stray_tags.py
"""
import http.server
import json
import os
import random
import sys
import threading
import types
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for name in ("wasmtime", "sandbox"):
    sys.modules.setdefault(name, types.ModuleType(name))
sys.path.insert(0, os.path.join(ROOT, "layer"))
import bonsai_layer  # noqa: E402
import stray_tags  # noqa: E402
from stray_tags import strip_stray_tags, StrayTagStream, SseFilter  # noqa: E402

CLEAN = "\n".join("vault %d: %s" % (i + 1, c) for i, c in
                  enumerate(("8411", "8629", "8402", "9320", "4111", "4025", "9387", "8794")))
A20K = CLEAN + "\n</parameter>\n</function>\n</tool_call>"            # measured: 20k prompt, a tool block, thinking off
A64K = CLEAN + "\n</think>\n\nvault 1: 8411\nvault 2:"               # measured: 64k prompt, a tool block, thinking off

STRAY = [
    (A20K, CLEAN),
    (A64K, CLEAN),
    (CLEAN + "\n</tool_call>\n\n  \n", CLEAN),
    (CLEAN + " \r\n</function>\r\n</tool_call>\r\n", CLEAN),
    (CLEAN + "\n</tool_call>\n</think>\nvault 1: 8411", CLEAN),
    ("Done.\n  </think>  \nDone.\n</think>\nDone.", "Done."),
]
UNCHANGED = [
    CLEAN,
    "Red, yellow, and blue.",
    "Here is the call format:\n\n```xml\n<tool_call>\n<function=f>\n<parameter=x>\n1\n</parameter>\n</function>\n"
    "</tool_call>\n```",
    "Here it is:\n```xml\n<function>\n</function>\n```\nDone.",
    "The model closes its reasoning with </think> and then answers.",
    "Use </tool_call> at the end of a call.\n",
    "Example:\n```\nanswer\n</tool_call>",                                   # in an open fence
    "<function=search>\n<parameter=q>\ncats\n</parameter>\n</function>",     # an XML document (opening tags)
    "The XML:\n</function>\nmore text after it",                            # a closing tag followed by text
    "<think>\nplan\n</think>\n\nanswer",                                    # a think block the server did not parse
    "</think>\n\nanswer only",                                              # nothing before the tag
    "a\n</thinking>\nb",
    "line\n</tool_calls>",
    "",
    "x\n\n",
]


def stream_join(text, cuts):
    s, out, prev = StrayTagStream(), [], 0
    for c in list(cuts) + [len(text)]:
        out.append(s.feed(text[prev:c]))
        prev = c
    out.append(s.finish())
    return "".join(out), s.removed


def test_pure():
    for raw, want in STRAY:
        got, n = strip_stray_tags(raw)
        assert got == want and n == len(raw) - len(want), (raw, got)
    for raw in UNCHANGED:
        assert strip_stray_tags(raw) == (raw, 0), raw
    print("pure function: %d recorded / stray cases -> clean list, %d cases unchanged: ok" % (len(STRAY), len(UNCHANGED)))


def test_stream_every_boundary():
    rng = random.Random(1017)
    cases = [r for r, _ in STRAY] + UNCHANGED
    n_runs = 0
    for raw in cases:
        want, n = strip_stray_tags(raw)
        for i in range(len(raw) + 1):                       # two deltas, split at every character
            assert stream_join(raw, [i]) == (want, n), (raw, i)
            n_runs += 1
        assert stream_join(raw, range(1, len(raw))) == (want, n), raw   # one delta per character
        for _ in range(200):                                # random sizes, seeded
            cuts, p = [], 0
            while True:
                p += rng.randint(1, 9)
                if p >= len(raw):
                    break
                cuts.append(p)
            assert stream_join(raw, cuts) == (want, n), (raw, cuts)
            n_runs += 1
    print("streaming helper: %d cases, %d split runs (every boundary, 1-char, 200 seeded random): ok" % (len(cases), n_runs))


def test_stream_holds_little():
    s = StrayTagStream()
    assert s.feed("vault 1: 8411\nvault 2") == "vault 1: 8411\nvault 2"   # no line-start "<": nothing held
    assert s.feed(": 8629\n") == ": 8629"                                # the newline is held
    assert s.feed("</") == "" and s.feed("b>x") == "\n</b>x"              # not a stray tag: released
    s = StrayTagStream()
    assert s.feed(CLEAN + "\n</think>") == CLEAN and s.feed("\n\nvault 1") == "" and s.finish() == ""
    s = StrayTagStream()                                                  # a tool round: held text goes out unchanged
    assert s.feed("calling\n</tool_call>") == "calling" and s.flush_raw() == "\n</tool_call>" and s.feed("x") == "x"
    print("streaming helper hold-back and tool-round flush: ok")


def sse_payloads(text, size):
    ev = [{"id": "c1", "object": "chat.completion.chunk", "model": "m",
           "choices": [{"index": 0, "delta": {"role": "assistant", "content": None}, "finish_reason": None}]}]
    for i in range(0, len(text), size):
        ev.append({"id": "c1", "object": "chat.completion.chunk", "model": "m",
                   "choices": [{"index": 0, "delta": {"content": text[i:i + size]}, "finish_reason": None}]})
    ev.append({"id": "c1", "object": "chat.completion.chunk", "model": "m",
               "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
    return ev


def test_sse_filter():
    for raw in [A20K, A64K] + UNCHANGED[:4]:
        want, n = strip_stray_tags(raw)
        for size in (1, 2, 3, 7, 50):
            f, got, layer, finished = SseFilter(), [], None, False
            for ev in sse_payloads(raw, size):
                payload = json.dumps(ev).encode()
                held = f.s.sent < len(f.s.acc)
                before, cur = f.event(ev, payload)
                for p in before + ([cur] if cur is not None else []):
                    e = json.loads(p)
                    layer = e.get("layer") or layer
                    assert not finished, "no event after the finish event"
                    finished = e["choices"][0].get("finish_reason") is not None
                    got.append(e["choices"][0]["delta"].get("content") or "")
                c = ev["choices"][0]["delta"].get("content")
                if not held and ev["choices"][0]["finish_reason"] is None and c is None or (
                        not held and c and "\n" not in c and "<" not in c and not c[-1].isspace() and c[0] not in "/<"):
                    assert not before and cur is payload, "no held text: the same event bytes"
            assert "".join(got) == want, (raw, size, "".join(got))
            assert (layer or {}).get("stray_tags_removed", 0) == n, (layer, n)
    print("SSE filter (events, finish flush, byte-identical when clean): ok")


def test_response_bytes():
    body = json.dumps({"choices": [{"message": {"role": "assistant", "content": CLEAN}}]}).encode()
    assert stray_tags.filter_response_bytes(body)[0] is body
    calls = {"choices": [{"message": {"role": "assistant", "content": A20K,
                                      "tool_calls": [{"function": {"name": "f", "arguments": "{}"}}]}}]}
    body = json.dumps(calls).encode()
    assert stray_tags.filter_response_bytes(body)[0] is body, "a message with tool calls is never changed"
    out, n = stray_tags.filter_response_bytes(json.dumps({"choices": [{"message": {"content": A20K}}]}).encode())
    o = json.loads(out)
    assert n == 38 and o["choices"][0]["message"]["content"] == CLEAN and o["layer"] == {"stray_tags_removed": 38}
    print("non-stream body filter: ok")


# ---- end to end through the layer, with a fake llama-server ----

UPSTREAM = {"content": A20K, "tool_round": False}
SEEN = []


class Fake(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        SEEN.append(b)
        first_round = not any(m.get("role") == "tool" for m in b.get("messages") or [])
        tool = None
        if UPSTREAM["tool_round"] and first_round:
            name = bonsai_layer.TOOL_NAME if any(t["function"]["name"] == bonsai_layer.TOOL_NAME
                                                 for t in b.get("tools") or []) else b["tools"][0]["function"]["name"]
            tool = {"id": "call_1", "type": "function", "function": {"name": name, "arguments": '{"code": "print(1)"}'}}
            content = "Let me check.\n</tool_call>"
        else:
            content = UPSTREAM["content"]
        if not b.get("stream"):
            msg = {"role": "assistant", "content": content}
            if tool:
                msg["tool_calls"] = [tool]
            d = json.dumps({"id": "x", "object": "chat.completion", "model": "m",
                            "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if tool else "stop"}],
                            "usage": {"prompt_tokens": 5, "completion_tokens": 9, "total_tokens": 14}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(d)))
            self.end_headers()
            self.wfile.write(d)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        evs = sse_payloads(content, 3)
        if tool:
            evs[-1:] = [{"id": "c1", "object": "chat.completion.chunk", "model": "m",
                         "choices": [{"index": 0, "delta": {"tool_calls": [dict(tool, index=0)]}, "finish_reason": None}]},
                        {"id": "c1", "object": "chat.completion.chunk", "model": "m",
                         "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}]
        for ev in evs:
            self.wfile.write(b"data: " + json.dumps(ev, separators=(",", ":")).encode() + b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")


up = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=up.serve_forever, daemon=True).start()
P = bonsai_layer.Proxy
P.upstream, P.keepalive, P.slots = "http://127.0.0.1:%d" % up.server_address[1], 0.3, None
lay = http.server.ThreadingHTTPServer(("127.0.0.1", 0), P)
threading.Thread(target=lay.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:%d/v1/chat/completions" % lay.server_address[1]
CLIENT_TOOLS = [{"type": "function", "function": {"name": "lookup", "parameters": {"type": "object", "properties": {}}}}]


def call(stream, client_tools=False, **extra):
    body = {"messages": [{"role": "user", "content": "List the access codes of vaults 1 to 8. Then stop."}],
            "stream": stream, **extra}
    if client_tools:
        body["tools"] = CLIENT_TOOLS
    rq = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    raw = urllib.request.urlopen(rq, timeout=10).read()
    if not stream:
        o = json.loads(raw)
        m = o["choices"][0]["message"]
        return m.get("content"), (o.get("layer") or {}).get("stray_tags_removed"), bool(m.get("tool_calls")), raw
    text, removed, tools, finished = [], None, False, False
    for line in raw.decode().splitlines():
        if line.startswith("data: ") and line[6:] != "[DONE]":
            e = json.loads(line[6:])
            removed = (e.get("layer") or {}).get("stray_tags_removed") or removed
            for ch in e.get("choices") or []:
                c = (ch.get("delta") or {}).get("content") or ""
                assert not (c and finished), "content after the finish event"
                finished = finished or ch.get("finish_reason") in ("stop", "length")
                text.append(c)
                tools = tools or bool((ch.get("delta") or {}).get("tool_calls"))
    assert raw.rstrip().endswith(b"data: [DONE]"), raw[-200:]
    return "".join(text), removed, tools, raw


def test_end_to_end():
    UPSTREAM.update(content=A20K, tool_round=False)
    for stream in (False, True):
        for ct in (False, True):
            route = ("stream" if stream else "non-stream") + (" + client tools (pass-through)" if ct else " (interpreter)")
            SEEN.clear()
            text, removed, _, _ = call(stream, ct)
            assert text == CLEAN and removed == 38, (route, text, removed)
            assert all("strip_stray_tags" not in b for b in SEEN)
            SEEN.clear()
            text, removed, _, _ = call(stream, ct, strip_stray_tags=False)
            assert text == A20K and removed is None, (route, text)
            assert SEEN and all("strip_stray_tags" not in b for b in SEEN), "the key must not reach the server"
            print("end to end %s: clean list + stray_tags_removed 38; off -> unchanged: ok" % route)
    UPSTREAM.update(content=A64K)
    for stream in (False, True):
        text, removed, _, _ = call(stream)
        assert text == CLEAN and removed == len(A64K) - len(CLEAN), (stream, text, removed)
    UPSTREAM.update(content=CLEAN)
    for stream in (False, True):
        for ct in (False, True):
            text, removed, _, raw = call(stream, ct)
            assert text == CLEAN and removed is None and b"stray_tags_removed" not in raw, (stream, ct)
    UPSTREAM.update(content=A20K)
    P.keepalive = 0                                   # --keepalive 0: the line reader without the pump thread
    for ct in (False, True):
        text, removed, _, _ = call(True, ct)
        assert text == CLEAN and removed == 38, (ct, text)
    P.keepalive = 0.3
    UPSTREAM.update(content=CLEAN)
    _, _, _, raw_on = call(False, True)
    _, _, _, raw_off = call(False, True, strip_stray_tags=False)
    assert raw_on == raw_off, "pass-through of a clean answer: the same bytes with the filter on and off"
    print("end to end 64k answer -> clean list; clean answers unchanged (pass-through bytes identical): ok")


def test_end_to_end_tool_rounds():
    UPSTREAM.update(content=A20K, tool_round=True)
    # client tools: the round with the client's tool call keeps its content unchanged
    for stream in (False, True):
        text, removed, tools, _ = call(stream, True)
        assert tools and text == "Let me check.\n</tool_call>" and removed is None, (stream, text)
    # interpreter: the run_python round's text goes out unchanged, the final answer is filtered
    text, removed, _, _ = call(True)
    assert text == "Let me check.\n</tool_call>" + CLEAN and removed == 38, text
    text, removed, _, _ = call(False)
    assert text == CLEAN and removed == 38, text
    UPSTREAM.update(tool_round=False)
    print("end to end tool rounds: content of a round with tool calls unchanged, final answer filtered: ok")


def test_think_stop():
    UPSTREAM.update(content=CLEAN, tool_round=False)
    off = {"enable_thinking": False}
    for stream in (False, True):
        for ct in (False, True):
            SEEN.clear(); call(stream, ct, chat_template_kwargs=off)
            assert SEEN and all("\n</think>" in (b.get("stop") or []) for b in SEEN), (stream, ct, SEEN)
    SEEN.clear(); call(False, False, chat_template_kwargs=off, stop="END")
    assert SEEN[0]["stop"] == ["END", "\n</think>"], SEEN[0].get("stop")
    SEEN.clear(); call(False, False, chat_template_kwargs=off, stop=["A", "\n</think>"])
    assert SEEN[0]["stop"] == ["A", "\n</think>"], SEEN[0].get("stop")
    for extra in ({"chat_template_kwargs": {"enable_thinking": True}}, {}, {"chat_template_kwargs": off, "strip_stray_tags": False}):
        SEEN.clear(); call(False, False, **extra)
        assert all("stop" not in b for b in SEEN), (extra, SEEN)
    print("thinking off: stop at a stray </think> line (merged with the client's stop list); otherwise no stop added: ok")


if __name__ == "__main__":
    test_pure()
    test_stream_every_boundary()
    test_stream_holds_little()
    test_sse_filter()
    test_response_bytes()
    test_end_to_end()
    test_end_to_end_tool_rounds()
    test_think_stop()
    print("ALL OK")
