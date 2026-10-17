"""Filter for stray closing tags at the end of an answer.

Measured problem: with a tool block in the prompt, thinking off and a long document, the model ends a correct answer
with the closing tags of the tool-call format ("</parameter>", "</function>", "</tool_call>") or with "</think>", and
then starts the answer again until max_tokens. The server leaves this text in message.content.

Rules, only for the content of a response (or a round) that has no parsed tool calls:
  1. Remove a trailing run of lines that each are exactly one of the stray tags (whitespace around it is permitted),
     when only such lines or whitespace follow to the end. The whitespace before the run goes too.
  2. Cut the content at the first line that starts with "</think>": that line, all text after it and the whitespace
     before it go.
Guards (then the text stays as it is):
  - the tag is in a ``` code fence (an odd count of fences before it);
  - the text before the tag has an opening tag of the same name ("<function=x>", "<think>"): it is a document, not a
    stray tag;
  - rule 2 only: the text before the "</think>" line is empty or whitespace (the cut would remove all of the answer).

strip_stray_tags() is the reference. StrayTagStream gives the same final text when the content arrives in deltas
that are split at any character: it holds back a line that can still become a stray tag and the whitespace before
it, and it releases that text when the line cannot be a stray tag. SseFilter applies StrayTagStream to the events of
an SSE chat stream.
"""
import json
import re

TAGS = ("</parameter>", "</function>", "</tool_call>", "</think>")
FENCE = "```"
_THINK_LINE = re.compile(r"^[ \t]*</think>", re.M)


def _in_fence(text, pos):
    return text.count(FENCE, 0, pos) % 2 == 1


def _opened(prefix, names):
    """True when prefix has an opening tag for one of the names ("<function=x>", "<think>", "<parameter name=...>")."""
    return any(re.search("<" + re.escape(n) + r"[\s>=]", prefix) for n in names)


def _think_cut(text, start=0):
    """Rule 2: the start of the first line at or after start (a line start) where the content is cut, or -1."""
    for m in _THINK_LINE.finditer(text, start):
        p = m.start()
        if text[:p].strip() and not _in_fence(text, p) and not _opened(text[:p], ("think",)):
            return p
    return -1


def _tail_run(text):
    """Rule 1: the start of the trailing run of stray-tag lines, or -1."""
    end, run, names = len(text), -1, set()
    while True:
        start = text.rfind("\n", 0, end) + 1
        line = text[start:end].strip()
        if line in TAGS:
            run = start
            names.add(line[2:-1])
        elif line:
            break
        if start == 0:
            break
        end = start - 1
    if run < 0 or _in_fence(text, run) or _opened(text[:run], names):
        return -1
    return run


def strip_stray_tags(text):
    """Apply rules 1 and 2. Returns (text, count of removed characters). The result is always a prefix of text."""
    if not isinstance(text, str) or "</" not in text:
        return text, 0
    out = text
    p = _think_cut(out)
    if p >= 0:
        out = out[:p].rstrip()
    p = _tail_run(out)
    if p >= 0:
        out = out[:p].rstrip()
    return out, len(text) - len(out)


def _maybe_tag_line(line):
    """True when this incomplete line can still become a stray-tag line (or a line that starts with "</think>")."""
    t = line.strip()
    return not t or any(tag.startswith(t) for tag in TAGS)


class StrayTagStream:
    """Streamed form of strip_stray_tags. feed() returns the text to send now; finish() returns the rest at the end of
    the content. The joined output is the same as strip_stray_tags() of the joined input, for any split."""

    def __init__(self):
        self.acc = ""        # all content so far
        self.sent = 0        # characters of acc already given out (always a prefix of the final text)
        self.scan = 0        # the line start from which rule 2 is not checked yet
        self.cut = False     # rule 2 applied: the rest of the content goes
        self.done = False    # finish() or flush_raw() was called: the text passes unchanged
        self.removed = 0

    def feed(self, delta):
        if self.done:
            return delta
        self.acc += delta
        if self.cut:
            return ""
        p = _think_cut(self.acc, self.scan)
        self.scan = self.acc.rfind("\n") + 1
        if p >= 0:
            self.cut = True
            return self._release(len(strip_stray_tags(self.acc)[0]))
        return self._release(self._safe_end())

    def finish(self):
        """The end of the content: the rest of the filtered text."""
        if self.done:
            return ""
        self.done = True
        final = strip_stray_tags(self.acc)[0]
        if len(final) < self.sent:   # not expected; then keep the text of the client complete
            return self._release(len(self.acc))
        self.removed = len(self.acc) - len(final)
        return self._release(len(final))

    def flush_raw(self):
        """The round has tool calls: give out the held text unchanged and stop the filter."""
        self.done = True
        self.removed = 0
        return self._release(len(self.acc))

    def _release(self, end):
        out = self.acc[self.sent:end] if end > self.sent else ""
        self.sent = max(self.sent, end)
        return out

    def _safe_end(self):
        """The end of the text that no later delta can remove: before a trailing block of lines that are (or can
        become) stray-tag lines or whitespace, and before the whitespace in front of that block."""
        a = self.acc
        b = a.rfind("\n") + 1
        if not _maybe_tag_line(a[b:]):
            b = len(a)
        else:
            while b > 0:
                s = a.rfind("\n", 0, b - 1) + 1
                line = a[s:b - 1].strip()
                if line and line not in TAGS:
                    break
                b = s
        while b > 0 and a[b - 1].isspace():
            b -= 1
        return b


class SseFilter:
    """StrayTagStream on the content deltas of one SSE chat stream (one choice). The event payloads are JSON bytes
    without the "data: " prefix. An event that the filter does not change is given back as the same object."""

    META = ("id", "object", "created", "model", "system_fingerprint")

    def __init__(self):
        self.s = StrayTagStream()
        self.tpl = {"object": "chat.completion.chunk"}
        self.idx = 0

    @property
    def removed(self):
        return self.s.removed

    def _content_event(self, text, layer=None):
        ev = dict(self.tpl, choices=[{"index": self.idx, "delta": {"content": text}, "finish_reason": None}])
        if layer:
            ev["layer"] = layer
        return json.dumps(ev, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    def tools(self, ev=None):
        """Tool calls in this round: payloads to send now (the held content, unchanged); the filter stops."""
        if self.s.done:
            return []
        tail = self.s.flush_raw()
        return [self._content_event(tail)] if tail else []

    def event(self, ev, raw):
        """Returns (payloads to send before this event, this event's payload or None to drop it)."""
        chs = ev.get("choices") if isinstance(ev, dict) else None
        if self.s.done or not (isinstance(chs, list) and len(chs) == 1 and isinstance(chs[0], dict)):
            return [], raw
        for k in self.META:
            if k in ev:
                self.tpl[k] = ev[k]
        ch = chs[0]
        self.idx = ch.get("index", 0)
        delta = ch.get("delta") if isinstance(ch.get("delta"), dict) else {}
        fin = ch.get("finish_reason")
        if delta.get("tool_calls") or fin == "tool_calls":
            return self.tools(), raw
        c = delta.get("content")
        out = self.s.feed(c) if isinstance(c, str) else None
        if fin:
            # the end of the content: the held text goes out in one event BEFORE the finish event
            text = (out or "") + self.s.finish()
            layer = {"stray_tags_removed": self.s.removed} if self.s.removed else None
            if text == (c or "") and layer is None:
                return [], raw
            before = [self._content_event(text)] if text else []
            d2 = dict(delta)
            if isinstance(c, str):
                d2["content"] = ""
            ev2 = dict(ev, choices=[dict(ch, delta=d2)])
            if layer:
                ev2["layer"] = layer
            return before, json.dumps(ev2, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if out == c:
            return [], raw
        if (out == "" and set(delta) <= {"content"} and ch.get("logprobs") is None
                and set(ev) <= set(self.META) | {"choices"}):
            return [], None   # held content only: nothing to send
        ev2 = dict(ev, choices=[dict(ch, delta=dict(delta, content=out))])
        return [], json.dumps(ev2, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    def close(self):
        """The stream ended without a finish event: payloads with the rest of the content."""
        if self.s.done:
            return []
        tail = self.s.finish()
        layer = {"stray_tags_removed": self.s.removed} if self.s.removed else None
        return [self._content_event(tail, layer)] if (tail or layer) else []


def filter_message(msg):
    """Apply the rules in place to an assistant message without tool calls. Returns the count of removed characters."""
    if not isinstance(msg, dict) or msg.get("tool_calls") or not isinstance(msg.get("content"), str):
        return 0
    msg["content"], n = strip_stray_tags(msg["content"])
    return n


def filter_response_bytes(data):
    """A non-stream chat completion from the server, with the rules applied to its choices without tool calls.
    Returns (bytes, removed). The bytes are the same object when nothing is removed or the body is not JSON."""
    try:
        resp = json.loads(data)
        n = sum(filter_message(c.get("message")) for c in resp.get("choices") or [] if isinstance(c, dict))
    except Exception:
        return data, 0
    if not n:
        return data, 0
    layer = resp.get("layer") if isinstance(resp.get("layer"), dict) else {}
    resp["layer"] = dict(layer, stray_tags_removed=n)
    return json.dumps(resp).encode(), n
