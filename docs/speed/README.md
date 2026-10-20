# Speed: decode by depth and prompt reading

![Decode by context depth on the RTX 4070 12 GB, replay rollback on, the mean of story / code / quote prompts: 70.1 / 60.9 / 20.3 / 10.3 tok/s at 4k / 64k / 128k / 200k with a draft of 4 past the VRAM line (the default since bundle-20261019c, line 67,328), 70.0 / 56.7 / 17.0 / 8.4 with a draft of 2 (line 67,840). The MIRAI_CTK=q3_0 option, bundle-20261016: 61.6 / 51.3 / 36.9 tok/s at 128k / 192k / 245k against 21.7 / 12.9 / 9.6 for q8_0 in the same run](img/decode.png)

On one RTX 4070 12 GB the server decodes through the whole 262,144-token window. The first 67,328 positions of the
cache are in VRAM (bundle-20261019c and newer, display on the iGPU). Past that line, each step reads the rest of the cache from
system RAM over PCIe, and decode becomes slower.

- [Decode by depth](#decode-by-depth)
- [Prompt reading (prefill)](#prompt-reading-prefill)
- [The first comparison with the reference fork](#the-first-comparison-with-the-reference-fork)
- [Linux, RTX 3090, measured by alesha-pro](#linux-rtx-3090-measured-by-alesha-pro)
- [Ideas tested](#ideas-tested)

## Setup

Use the defaults: [Quick start](../setup/README.md#quick-start-windows-nvidia). For more positions in VRAM, put the
display on the CPU's integrated graphics ([how](../setup/README.md#get-more-positions-into-vram)).

## Decode by depth

### The default (bundle-20261019c and newer)

RTX 4070 12 GB, q8_0 K/V, MTP and lookup drafting, replay rollback on. Decode of a 300-token answer, tok/s, the mean
of the story / code / quote means (greedy and temperature 0.8), one server per arm
([receipts/tail4](../../receipts/tail4/README.md), 2026-10-19):

| depth | 4k | 64k | 128k | 200k |
| --- | ---: | ---: | ---: | ---: |
| a draft of 4 past the VRAM line (the default since bundle-20261019c), line 67,328 | 70.1 | 60.9 | 20.3 | 10.3 |
| a draft of 2 past the line (bundle-20261019b), line 67,840 | 70.0 | 56.7 | 17.0 | 8.4 |

By prompt type at 200k (draft of 4): story 7.0, code 10.3, quote 13.7. Single requests vary by up to 9.5 % from run to
run ([receipts/tail4](../../receipts/tail4/README.md#result-2026-10-19-1951)).

Replay rollback itself (bundle-20261019, a story prompt, a draft of 2): 62.8 / 48.2 / 17.9 / 9.1 tok/s on (line
67,840) against 62.9 / 44.9 / 15.8 / 8.5 off (line 58,624) ([release notes](../../RELEASE-NOTES.md)).

The text is the same with and without replay rollback (12 of 12 requests at 4k and 32k, 4 of 4 at 4k to 200k). A
30-minute soak with it on ran 14 requests up to 200k with 0 errors. The release notes do not give the order of the
depths in this run, and this repository has no receipt file for it.

### The long-context option: q3_0

`MIRAI_CTK=q3_0` (bundle-20261016 or newer) is a 3.5-bit K/V cache. On the RTX 4070 with a 262k window, the VRAM line
goes from 58,624 to 167,680 positions. In the same run (bundle-20261016, before replay rollback):

| depth | 128k | 192k | 245k |
| --- | ---: | ---: | ---: |
| q8_0 (the default) | 21.7 | 12.9 | 9.6 |
| q3_0 | 61.6 | 51.3 | 36.9 |

The two tables come from different runs with different prompts. Do not compare numbers across the two tables. The
quality of q3_0: [quality](../quality/README.md#kv-cache-precision).

### Changes past the VRAM line

| Bundle | Change | Measured (RTX 4070) |
| --- | --- | --- |
| bundle-20261013 | CUDA graphs off for the steps that read the system-RAM part, so the K/V prefetch runs | mean decode 32k 65.7 -> 66.9, 128k 16.1 -> 18.8, 192k 10.5 -> 11.6 tok/s; HumanEval answers identical on all 164 |
| bundle-20261014 | `MIRAI_SPARSE=1` (opt-in): sparse reads of the system-RAM pages with the highest score bound | mean decode at 192k 11.7 -> 16.2-17.0 tok/s, 128k about +20 %; exact copies and fact lookups (66 items at 160k / 200k / 245k) the same as the full read; the line about 5k positions shorter |
| bundle-20261019b | replay rollback on by default | story prompt: 128k 15.8 -> 17.9, 200k 8.5 -> 9.1 tok/s |
| bundle-20261019c | a draft of 4 past the VRAM line (was 2) | mean of three prompt types: 128k +18.8 %, 200k +23.5 % ([receipts/tail4](../../receipts/tail4/README.md)) |

Source: [release notes](../../RELEASE-NOTES.md).

### The record of 2026-10-06 (bundle-20261006c)

`receipts/mirai-port/decode_by_depth.log`, `bench/depth_receipt.sh` (`bench/quick_tps.py`: mean of a code, a prose
and a bash prompt, 400-token greedy answers, MTP drafting, no lookup drafting yet). Line 57,856 positions. The run
went from 0 to 180k on one server:

| depth | 0 | 16k | 32k | 48k | 60k | 120k | 180k |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| decode (tok/s) | 76.6 | 72.6 | 68.8 | 66.4 | 61.7 | 19.5 | 11.4 |

Use this table only for the history. The bundles after it added lookup drafting, the graph change, the q3_0 option and
replay rollback, and the newer runs use a different prompt.

## Prompt reading (prefill)

![Prompt reading on the RTX 4070 12 GB: a 16.8k prompt at 1,090 tok/s (2048 mode 1,148; the reference fork ~1,000), cold reads with replay rollback on: 64k at 912 tok/s (first token after 70 s), 128k at 678 tok/s (189 s), 200k at 527 tok/s (381 s). Reading a whole conversation again takes 73 s at 64k, 195 s at 128k and 524 s at 245k](img/prefill.png)

| Prompt | tok/s | Source |
| --- | ---: | --- |
| 16.8k tokens, the default (micro-batch 1024) | 1,090 | `receipts/mirai-port/levels_chunk.log`, 2026-10-05 |
| 16.8k tokens, `MIRAI_UBATCH=2048` (approximately 570 MiB more VRAM) | 1,148 | `receipts/mirai-port/ub2048_probe.log`, 2026-10-05 |
| 4k tokens, cold, replay rollback on | 1,120, first token after 3.5 s | `receipts/replay/m34.jsonl`, 2026-10-19 |
| 64k tokens, cold, replay rollback on | 912, first token after 70 s | `receipts/replay/m34.jsonl`, 2026-10-19 |
| 128k tokens, cold, replay rollback on | 678, first token after 189 s | `receipts/replay/m34.jsonl`, 2026-10-19 |
| 200k tokens, cold, replay rollback on | 527, first token after 381 s | `receipts/replay/m34.jsonl`, 2026-10-19 |
| the reference fork, 16.8k tokens | approximately 1,000 | [PREFILL.md](../research/PREFILL.md) |

bundle-20261014 added the chunked gated-delta-net prefill on tensor cores: code prefill +3.5 % at 128k and 192k.
The cold reads come from the replay check of engine 1ee7f9766 (the bundle-20261019b engine): one request per depth,
`cache_prompt: false`. With replay rollback off, the same file gives 64k-200k within 0.3 % and 4k at 1,184 tok/s
(one request per depth, so the 4k difference can be noise).

Time to read a whole conversation again, without a saved state (bundle-20261017, q8_0 cache): 73 s at 64k, 195 s at
128k, 524 s at 245k. A saved conversation skips this read: [saved conversations](../agents-layer/SAVED_CONVERSATIONS.md).

Why prefill stops near 1.1k tok/s on this card: [PREFILL.md](../research/PREFILL.md) and
[REPORT.md](../research/REPORT.md) section 6e.

## The first comparison with the reference fork

This table is from the first release and the bundles up to bundle-20261017. It compares alesha-pro's reference fork
with this serve. Both ran on the same RTX 4070 12 GB with one slot. The current numbers are in the sections above.

| RTX 4070 12 GB, served, one slot | alesha-pro's reference fork (`llama.cpp-mirai-s`, the starting point) | this serve |
| --- | ---: | ---: |
| context window with q8_0 KV | 64k (11.0 GB) | **262,144** (tiered: approximately 58k positions in VRAM, the remainder in pinned RAM) |
| decode, tok/s, at 0 / 16k / 60k / 120k / 180k | 40.0 / 38.1 / 33.5 (60k) / - / - | **76.6 / 72.6 / 61.7 / 19.5 / 11.4** (60k is inside the VRAM line since the evening of 10-06; before that, 40.3). Past the VRAM line +10-17 % since bundle-20261013 (128k 16.1 -> 18.8, 192k 10.5 -> 11.6, both arms at stock clocks); with `MIRAI_SPARSE=1` (bundle-20261014) 192k 11.7 -> 16.2-17.0 |
| prefill, 16.8k-token prompt | approximately 1,000 | **1,090** (2048 micro-batch mode: 1,148) |
| prefill, 130k-token prompt (cumulative) | - (64k window) | **639** (since bundle-20261008b; before: 509) |
| decode when the answer copies the context (rewrite a 150-line file), tok/s, at 4k / 130k | - | **265.6 / 84.9** (lookup drafting in front of the MTP draft, since bundle-20261008; before: 86.5 / 20.1. New text: 75.7 / 17.3, the same as before. Same output) |
| speculative decoding | none | MTP draft at every depth, outputs identical to drafting off |
| HumanEval 164, greedy, tests run in a sandbox | | **158** at medium or at effort "low"; 154 with thinking off; **160** through the layer with the example check (since bundle-20261009) |
| long exact-work suite, 37 tasks, raw / through the layer | 13 / 30 (on the reference fork) | **18 / 28** (12 rescues, 2 losses); coding family over two seed sets 7 / **12** of 24, at effort "low" 6 / 8 of 12 |
| AppWorld test_normal, 168 tasks, ReAct code agent (task / scenario goal completion) | | **88.7 / 73.2** on this one 12 GB card; alesha-pro measured 89.9 / 75.0 on Mirai's vLLM plugin (4x RTX 3090), BF16 95.8 / 91.1 |
| apps that send `effort: "high"` | template error on each request | answered (changed to medium) |
| a 245k-token conversation after a server restart (restore + next turn) | - (not measured; 64k window) | **10.5 s** (restore 9.0 s + 1.6 s; a re-read takes 524 s), since bundle-20261017b |
| a 128k-token document asked after a restart, through the layer | - (not measured; 64k window) | **6.7 s** (199 s cold), automatic with `MIRAI_SLOT_SAVE_PATH`, since bundle-20261017b |

The receipts for each row are in `receipts/mirai-port/` and `bench/`. [REPORT.md](../research/REPORT.md) and
[PREFILL.md](../research/PREFILL.md) tell how this project got each number and what did not work. The numbers are from
2026-10-05 and 2026-10-06. The decode-by-depth numbers are from the evening of 10-06
(`receipts/mirai-port/decode_by_depth.log`). The GDDR6X memory was at stock clocks. The display was on the integrated
GPU of the CPU (refer to [Get more positions into VRAM](../setup/README.md#get-more-positions-into-vram)).

## Linux, RTX 3090, measured by alesha-pro

alesha-pro measured these results on the Ubuntu computer with the 12 GB recipe of the morning of 10-06. The recipe
used 44,000 positions in VRAM and the published GGUF. The card was at 300 W on PCIe 3.0 x16
(`receipts/ubuntu-3090/`).

| | Ubuntu 22.04, RTX 3090 |
| --- | ---: |
| greedy identity against the reference dumps, thinking off | 5 of 5 |
| thinking on (the 300-token reference is a prefix of the output) | 5 of 5 |
| VRAM at load / peak over a 180k-token prompt | 11,533 / 11,719 MiB |
| decode, tok/s, at 8k / 60k / 120k / 180k | 66.9 / 27.9 / 9.5 / 5.8 |
| prefill, 8k-token prompt | 1,124 tok/s |
| MTP draft acceptance, thinking off / on | 71% / 65% |

Past the VRAM line, this computer is slower than the RTX 4070. At 60k, it decoded 27.9 tok/s. The RTX 4070 decoded
40.3 tok/s at 60k when its line was also at 44-45k. Now the RTX 4070 keeps 60k inside the line. This computer reads
the tail over PCIe 3.0. That is the probable cause, but this project did not isolate it.

These numbers come from one `llama-server` command line:
[the serving flags](../setup/README.md#the-serving-flags-as-one-command-line).

## Ideas tested

| Page | What |
| --- | --- |
| [HYPERQWEN.md](../research/HYPERQWEN.md) | speed techniques from syv-ai/HyperQwen: what we tested and what we decided (2026-10-08) |
| [PREFILL.md](../research/PREFILL.md) | where the prefill time goes, the ceiling of the card, the plan |
| [REPORT.md](../research/REPORT.md) | the full record: MTP, the tiered cache, DFlash, VRAM levers, the kernel timeline |

Measure it yourself: [quality](../quality/README.md#measure-it-yourself).
