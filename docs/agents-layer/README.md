# The layer and agent use

![Agent work on the RTX 4070 12 GB. AppWorld, 168 tasks, task goals: this serve 88.7 % (scenario 73.2), Mirai's vLLM plugin on 4x RTX 3090 89.9 % and BF16 95.8 % (alesha-pro). Before and now: an edited tool result at 32k 36.5 / 34.6 to 6.6 / 4.5 s, file rewrites at 130k 20.1 to 84.9 tok/s and short 86.5 to 265.6, 107 tools 36.7 to 45.0 tok/s, three tool calls 59.6 to 70.4, edit calls rejected 0 of 91, effort "high" from a template error to an answer](img/agentic.png)

This page has four parts:

- [The layer](#the-layer): API cards, the API check, the sandboxed Python tool, the example check.
- [For agents and apps](#for-agents-and-apps): what to send.
- [Agent results](#agent-results): AppWorld and the server changes for agent work.
- [Saved conversations](SAVED_CONVERSATIONS.md): long conversations saved to disk and restored in seconds.

## The layer

`start-server.ps1` puts a small server-side layer in front of `llama-server` on the same port (`:8080`). Clients
change nothing. `llama-server` itself listens on `127.0.0.1:18080`. The layer comes from the layer of an earlier serve
on the same engine, with the changes of this project (`layer/ORIGIN.md`). It does these things:

- **API cards.** For Python coding requests, it adds the exact API of the modules involved to the first user message.
- **API check.** It checks code that the model wrote in earlier tool calls for names and keyword arguments that do not
  exist, and notes them on the tool result. Since E18 it also flags names looked up on a class or called on a fresh
  stdlib instance.
- **Sandboxed Python tool.** For requests that bring no tools of their own, the model gets a `run_python` tool. It
  runs in CPython on WASI (no host files, network or processes). The user's text is available to the program as
  `input.txt`. Requests with client tools pass through.
- **Example check** (on by default since bundle-20261009). When a coding request has a function stub with docstring
  examples, the layer runs the examples on the answer in the sandbox. If they fail, it sends one follow-up turn with
  the report. HumanEval through the layer at medium: 158 -> **160** of 164, none lost, +23 % completion tokens.
- **Clean answers.** It removes stray closing tags after an answer (bundle-20261017c) and stops a thinking-off request
  at a stray `</think>` line (bundle-20261017d).
- **Replies cut at `max_tokens`** (bundle-20261019b): when the model had started to write its answer into the Python
  tool, the layer asks once more without the tool, so the reply has text. Such a reply can use up to two times
  `max_tokens`.
- **SSE keep-alive.** While the server sends nothing (a long prefill), the layer sends a `: keep-alive` comment every
  15 seconds.
- **Key check.** It rejects requests with a wrong API key before any work starts.

Enable it one time with `layer\fetch_runtime.ps1`. The script downloads the checksummed WASI Python and runs the
isolation canaries. It needs Python 3 on PATH. Without the runtime, the plain server starts. `MIRAI_LAYER=0` turns the
layer off. On Linux, the layer is not connected or tested.

Per request: `"code_interpreter": true|false`, `"api_cards": false`, `"api_lint": false`, `"input_file": false`,
`"example_check": false`, `"strip_stray_tags": false`, `"prefill_only": true` (read and save a prompt, see
[saved conversations](SAVED_CONVERSATIONS.md)).

Measured on Mirai S (paired, same seeds): the 37-task suite went from 18 to 28 (12 rescues, 2 losses); on the
reference fork from 13 to 30 (17 rescues, 0 losses). Details: [quality](../quality/README.md#the-long-exact-work-suite).

## For agents and apps

- Chat, coding answers and all requests through the layer: use the defaults (medium reasoning, 20k thinking budget).
- Coding agents that run their own tools against the raw server (`127.0.0.1:18080`), or the layer with
  `"api_cards": false`: send `reasoning_effort: "low"`, and start the server with `MIRAI_EFFORT_ALLOWED=low,medium`.
- Tool-heavy agents that need speed more than depth: send `chat_template_kwargs: {"enable_thinking": false}` in each
  request.
- **Harness-proofing.** Apps that send `effort: "high"` (Cline, Kilo, Open WebUI) get answers, not a template error:
  the server changes effort words that are not on the allow-list to medium, and the server log records the change.
  Apps with a small output cap (256-4096 tokens) and thinking on: the server raises the cap to the thinking budget.
  `MIRAI_HARNESS_PROOF=0` turns this off.
- Long sessions: set `MIRAI_SLOT_SAVE_PATH` ([saved conversations](SAVED_CONVERSATIONS.md)).

More: [recommended settings](../setup/README.md#recommended-settings).

## Agent results

**AppWorld** test_normal, all 168 tasks, the simplified ReAct code agent (temperature 1.0, seed 100, 50-step cap), raw
Mirai S on the server of bundle-20261009 (medium effort, 20k thinking budget, harness-proofing), one RTX 4070 12 GB
(`receipts/mirai-port/appworld.log`, 2026-10-09):

| | task goal completion | scenario goal completion | by difficulty 1 / 2 / 3 |
| --- | ---: | ---: | --- |
| this serve, one RTX 4070 12 GB | **88.7** | **73.2** | 100.0 / 87.5 / 79.4 |
| alesha-pro, Mirai's vLLM plugin, 4x RTX 3090 | 89.9 | 75.0 | 96.5 / 89.6 / 84.1 |
| alesha-pro, BF16 reference | 95.8 | 91.1 | 100.0 / 97.9 / 90.5 |

The 12 GB serve matches the vLLM run within noise (1.2 points is about 2 of 168 tasks, one seed each). alesha-pro's
numbers: [qwen38-27b-bench-4x3090, agentic-v1](https://github.com/alesha-pro/qwen38-27b-bench-4x3090/tree/main/agentic-v1).

**Server changes for agent work.** Each pair gives the same output.

| | Before | Now | Source |
| --- | ---: | ---: | --- |
| a prompt that changes inside one long message (an edited tool result), 32k, the two requests that read again | 36.5 / 34.6 s | 6.6 / 4.5 s | `receipts/mirai-port/ckpt_ab.jsonl`, bundle-20261009 |
| rewrite a 150-line file, decode, short prompt / 130k | 86.5 / 20.1 tok/s | 265.6 / 84.9 tok/s | `receipts/lookup_ab_mirai.jsonl`, bundle-20261008 |
| one edit tool call, short prompt / 130k | 85.1 / 19.8 tok/s | 103.8 / 24.9 tok/s | same |
| new text, short prompt / 130k | 75.6 / 17.4 tok/s | 75.7 / 17.3 tok/s | same |
| 107 tools at about 63k tokens, plan-like answer | 36.7 tok/s | 45.0 tok/s | `receipts/tools_ab_mirai.log`, bundle-20261008c |
| a request with three tool calls | 59.6 tok/s | 70.4 tok/s | same |
| apps that send `effort: "high"` | template error | answered (changed to medium) | bundle-20261006 |

The full table of the 107-tool run, with greedy arms: [release notes](../../RELEASE-NOTES.md), bundle-20261008c.

**Edit calls.** An agent's `edit` tool needs old text that matches the file exactly. 120 requests on 40 windows of
CPython stdlib files, temperature 1.0, thinking on: 91 edit calls, **0 rejected** (90 placed exactly as asked). The
other 29 requests read the file again first ([REPORT.md](../research/REPORT.md) 6h, 2026-10-09).

![Saved conversations on the RTX 4070 12 GB: after a restart, a 64k conversation is back in 0.8 + 0.4 s (re-read 73 s), 128k in 1.6 + 0.6 s (195 s), 245k in 9.0 + 1.6 s (524 s); a 128k document through the layer answers in 6.7 s (199 s cold). A full save of a 174k conversation took 227 s, a delta 0.2-0.6 s; the mean wait per turn in a 30-turn session went from 74 s to 23 s](img/saved.png)

Details: [saved conversations](SAVED_CONVERSATIONS.md).
