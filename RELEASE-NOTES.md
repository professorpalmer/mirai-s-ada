# mirai-s-ada, first release (bundle-20261006)

Mirai S 27B (Mirai Labs' Qwen3.8-27B-S, Qwen3.8-27B in their Mirai S trellis codec, in alesha-pro's GGUF conversion and llama.cpp port,
11.17 GB) served on an RTX 4070 12 GB with:

- the model's **full 262,144-token window at q8_0 KV** (tiered cache: ~44k positions in VRAM, the rest in pinned
  system RAM, bit-identical to an all-VRAM cache; alesha-pro's reference fork fits 64k at q8_0 on the same card),
- **MTP speculative decoding from the GGUF's own draft block at every depth** (outputs identical to drafting off):
  75.8 / 71.4 / 40.3 / 16.6 / 10.3 tok/s at 0 / 16k / 60k / 120k / 180k of context (the fork: 40 / 38 / 33.5 at 0 / 16k / 60k),
- **prefill 1,090 tok/s on a 16.8k-token prompt** (one int8 activation plane for the FFN matmuls of prompt tokens at
  KL 0.00028, a packed 1-bit attention mask, level-decode chunking; 2048 micro-batch mode 1,148),
- **harness-proofing**: apps that send `effort: "high"` or tiny output caps get answers instead of template errors,
- the optional **layer** (exact API cards, an API check that now flags names looked up on classes and fresh
  instances, a sandboxed Python tool).

Quality, measured with plans and gates frozen before results (`docs/REPORT.md`):

- HumanEval 164, greedy, tests executed in a sandbox: **158** at medium (budget 20k or 8k: identical), 158 at
  effort "low" for 0.71x the tokens, 154 thinking off.
- Long exact-work suite, 37 tasks, paired, same seeds: raw 18, behind the layer **28** (12 rescues, 2 losses).
  Coding family over two seed sets (24): raw 7, layer **12** at medium (tar 1 -> 5 of 8 is the API-check family;
  MIME 0 of 8 in both arms). At effort "low" (seeds 1-4): raw 6, layer 8 of 12; MIME raw 4 of 4.
- Recommended: defaults for chat and anything behind the layer; `reasoning_effort: "low"` for coding agents that
  run their own tools against the raw server (launch with `MIRAI_EFFORT_ALLOWED=low,medium`).

What did not work, kept in the record: overlapping the level decode behind the GEMM (the int8 GEMM already runs at
the card's tensor peak), a round-countdown note for tool loops (read and ignored), removing the layer's
"run it on the example" sentence (7 -> 4 of 12 without it: it stays), and every layer variant on the MIME task
(0 of 4 at every setting; only the raw server at effort "low" passes it, 4 of 4).

Install: unzip `mirai-s-bundle-win-x64.zip` into the repo, put the GGUF in `models\`, run `start-server.ps1`.
Binaries: sm_89 (RTX 40), CUDA 13 runtime included, NVIDIA driver only. Engine: `professorpalmer/llama.cpp-ada-mirai`
(PrismML's llama.cpp fork + the serving patches, also open as PrismML PRs #319-#323, + Mirai Labs' codec as alesha-pro ported it to ggml in
alesha-pro/llama.cpp-mirai-s and verified greedy token-for-token against it).

Credits: Mirai Labs (the model, its quantization and the Mirai S codec), Qwen (the base model, Qwen3.8-27B), alesha-pro
(GGUF conversion, the llama.cpp port of the codec, the reference fork), PrismML (the llama.cpp fork), sudoingX (planar
activations, batch-invariant mode, PrismML PR #218). Not affiliated with any of them.

## bundle-20261006b (same day)

- Engine f11c75618: a drafter graph that borrows the Mirai head (DFlash, DSpark) now finds the codec's tensors through
  the target model; the earlier binaries aborted at drafter load.
- `MIRAI_SPEC_TYPE=dflash`: ggml-org's DFlash drafter for Qwen3.8-27B at draft 3, +13% decode at depth 0 and +8.5% at
  16k with identical outputs, for ~590 MiB of VRAM; a mode, the MTP block stays the default (receipt:
  `receipts/mirai-port/dflash_probe.log`).

## bundle-20261006c (same day, evening)

- **VRAM line 45,312 -> 57,856 positions** on this card at the same 800 MiB margin, from two measured levers
  (`receipts/mirai-port/mtp_q4_probe.log`, `docs/REPORT.md` 6e): one transient CUDA pool for the target and draft
  contexts with a 256-token draft micro-batch (188 MiB; `MIRAI_SHARED_POOL=0` reverts), and `tooling/requant_mtp.py`,
  which writes a copy of the GGUF with only the MTP draft block at Q4_0 (204 MiB; the launcher prefers the copy when
  it is in `models\`). Greedy identity 3/3 in every arm and 5/5 on the restarted product, decode unchanged
  (76.5 / 71.9 tok/s at 0 / 16k), acceptance 77.7% vs 78.2%. Decode by depth on the new line: 76.6 / 72.6 / 61.7 / 19.5 / 11.4 tok/s at
  0 / 16k / 60k / 120k / 180k (68.8 at 32k, 66.4 at 48k); 60k was 40.3 when it sat past the line.
- The launcher accepts the 10.96 GB copy (its size guard was set for the 11.17 GB published file).
- Housekeeping found while packaging: the sandbox canary and the FFN-gate driver carried absolute paths from the
  development machine; `bench/lib.sh` now derives the repo root from its own location.
- Not changed: K/V stays q8_0 (a q4_0 cache is a knob until its quality on this model is measured); the MTP block
  stays the default drafter (DFlash remains the `MIRAI_SPEC_TYPE=dflash` mode).
- **The launcher supervises the server.** One 180k-token request ended llama-server with an assert-style fail-fast
  once on the new defaults and did not reproduce in four replays (`docs/REPORT.md` 6e). An aborted server is now
  restarted (`MIRAI_RESTARTS`, default 3 within ten minutes) and `MIRAI_STDERR_FILE` keeps its raw stderr so the
  next assert leaves its text; `tooling\stop.ps1` stops it without a restart.
- **Engine be00bbdc1**: alesha-pro's control-vector projection mode (`--cvec-mode project`, off unless passed; greedy
  identity against the fork's dump re-checked here 5/5 without the flag) plus a bounds guard on its per-layer flag.
- **Linux**: `start-server.sh` and the Ubuntu 22.04 / RTX 3090 check (build line, identity 5/5, decode by depth) from
  alesha-pro's pull request; the layer on Linux is not wired.
- **Removing refusals, optional**: alesha-pro's refusal-direction control vector and his measurements, in
  `docs/CONTROL-VECTOR.md` with a short README pointer; off unless the file is passed, not measured on the suite here.


## bundle-20261007 (fixes from the first user reports on the sister Bonsai serve)

- **Engine `9b28b6057`**: a JSON schema with an empty `anyOf` / `oneOf` / `type` list no longer fails the request with
  "failed to parse grammar"; the empty keyword is dropped and the rest of the schema converted (reported by Milor123
  against the Bonsai serve, which shares this code). Upstream llama.cpp rejects such schemas with a clear error since
  its September rewrite; the fork this engine is built on has not synced it yet.
- **Layer**: a response cut by the token limit is no longer run as a sandbox tool call (it is handed back with
  `finish_reason: length`); the "run the program on the example" sentence is only added when the request asks for
  code, so agents that offer run tools on every turn no longer get it on turns without a program.
- **Launcher**: warns when the GPU is already busy before the server starts. An app working on the card (found with
  KDE Connect) time-slices the GPU and costs MTP drafting about a third of its speed even when it uses no VRAM.

## bundle-20261008 (lookup drafting, keep-alive, clearer launcher messages)

Same model file. New engine binaries (`0aad5de56`, sm_89) and a new launcher and layer.

- **Lookup drafting, on by default.** A lookup drafter drafts text that is already in the context, up to 32 tokens
  at a time, in front of the model's own draft block. When the answer copies the context (file rewrites, edit calls,
  quoted logs), decode is much faster. On new text, the speed is the same. The output is the same in every arm we ran
  (`receipts/lookup_ab_mirai.jsonl`):

  | RTX 4070, tok/s | Before, 4k | Now, 4k | Before, 130k | Now, 130k |
  | --- | ---: | ---: | ---: | ---: |
  | Rewrite a 150-line file | 86.5 | 265.6 | 20.1 | 84.9 |
  | One edit tool call | 85.1 | 103.8 | 19.8 | 24.9 |
  | New text | 75.6 | 75.7 | 17.4 | 17.3 |

  At 130k, most of the cache is in system RAM and each step costs more, so one long accepted draft saves more.

  `MIRAI_LOOKUP=0` turns it off; `MIRAI_LOOKUP_N` sets the limit (32 is best for edit calls). Engine option:
  `--spec-lookup-n-max N`, a separate draft limit for the lookup drafters, so the draft block keeps its own small
  draft size. Idea credit: syv-ai/HyperQwen, which drafts out of the prompt for the same reason on vLLM.
- **SSE keep-alive in the layer.** While the server sends nothing (a long prefill), the layer sends a `: keep-alive`
  comment every 15 seconds, so proxies and tunnels do not close the stream. Clients ignore it.
- **Launcher messages.** At start, the launcher lists every `MIRAI_*`, `LLAMA_ARG_*` and `GGML_*` variable that is set
  in the window, and it says when drafting is off and why. It turns the engine's automatic fit off, because it sizes
  the VRAM itself (the "failed to fit params" warning is gone).
- **Linux build:** the quick start uses `-DCMAKE_CUDA_ARCHITECTURES=native` and lets cmake find CUDA (issue #3, from
  Gotoro).

## bundle-20261010 (system RAM sized at start, a faster verification step)

Same model file. New engine binaries (engine commit `f16e386f6`) and launcher.

- **System RAM sized at start (`ram` line).** The server's memory commit is the VRAM it holds (Windows charges that
  to the process too), the K/V past the VRAM line (~6.8 GB at 262k), the prompt cache (default limit 8 GiB; one entry
  for a 26k-token prompt is ~2 GB) and the checkpoints. With the old defaults, 7 sequential thinking requests with
  26k-token prompts took the server to **22.1 GB** on a 32 GB machine; on 16 GB the same engine stopped with
  "bad allocation" and then exited (a user report). Now: under 24 GB of RAM, a 1 GiB prompt cache and 8 checkpoints;
  under 48 GB, a 4 GiB cache (the 32 checkpoints stay: they make agent turns fast); 48 GB and more, unchanged. The
  same run: **17.8 GB**, 7/7 answers (`receipts/ram_ab_mirai.log`). The launcher gives a warning when much less memory is free than the server can
  use. `LLAMA_ARG_CACHE_RAM` / `LLAMA_ARG_CTX_CHECKPOINTS` set by hand win.
- **Draft verification steps slightly faster.** The conv-state concat of the gated delta net ran in a generic kernel
  (48 calls of 14.5 us per step). The engine's transpose kernel for this layout, before enabled only on GB10, now runs
  on every NVIDIA card: decode +0.7-1.2 %, the same text in 6/6 greedy answers.
- **Measured, not changed:** a CUPTI kernel trace of one decode step. 78 % of a 1-token step is the trellis mat-vec,
  which reads the weights at ~76 % of this card's memory bandwidth. The integer work of the trellis decode, not the
  memory, is probably the limit there.

## bundle-20261009 (the example check, checkpoints inside long messages, the free-VRAM line)

Same model file. New engine binaries (engine commit `75eaee882`), launcher and layer.

- **Example check in the layer, on by default.** When a coding request has a function stub with docstring examples,
  the layer runs the examples on the answer in the sandbox; if they fail, it sends one follow-up turn with the report.
  HumanEval through the layer at medium: 158 -> **160** of 164, none lost, for +23% completion tokens.
  `"example_check": false` per request or `--no-example-check` turns it off.
- **Checkpoints inside long messages, on by default.** A prompt that changes inside one long message (an edited tool
  result, a file sent again) was read again from the start. The server now also keeps a checkpoint every 8,192 tokens
  inside a message: at 32k, those requests took 4.5-6.6 s instead of 34.6-36.5 s, with the same text. It costs no VRAM
  and does not raise the server's limit of 32 checkpoints per slot (~150 MiB of system RAM each, which a long session
  already fills); long prompts that need no restore take about 1 s longer. `MIRAI_CKPT_EVERY=0` turns it off.
- **The launcher shows the free VRAM at start** (`vram` line) and gives a warning when other programs hold much of it.
  The VRAM line is set from the free VRAM at start, so a low line now has a visible cause.
- **Layer:** the run-on-the-example sentence is decided from the first user message only. Before, a later message with
  a code block could add it to the first message in the middle of a conversation, so the server read the prompt again
  from there.
- **Launcher fix:** on Windows PowerShell 5.1 with Python on PATH but without the `wasmtime` package, the probe for the
  optional layer stopped the launcher before the server started. The probe now runs only when the layer's runtime is
  present and cannot stop the launcher; the layer turns off with its `layer  off:` line as intended.
- **`llama-perplexity` fixed:** the copy in bundle-20261008d was older than its library and stopped at an assertion.
- Measured, not changed: q4_0 K/V costs this model far more than q8_0 (top token flipped on 1 position in 34, single
  tokens far off; docs/REPORT.md 6f), so K/V stays q8_0.

## bundle-20261008d (the shared CUDA pool, made safe)

Same model file, launcher and layer. New engine binaries (engine commit `8ebd8348d`; the change is in `ggml-cuda.dll`).

- **The shared CUDA pool is safe now.** The launcher turns on one CUDA memory pool for the main and the MTP draft
  context (`MIRAI_SHARED_POOL`, 188 MiB less VRAM, so about 5k more positions in VRAM). The two contexts run on two
  CUDA streams, and a block freed by one stream could be used by the other before the first was done with it. That is
  a race: it depends on timing. On the sister Bonsai serve, an RTX 2060 SUPER got 1-token answers to fresh long
  prompts because of it (fresh 60k prompts: 18 of 18). Now each graph waits for the other stream's last graph, so the
  two streams cannot reuse each other's blocks too early (the same RTX 2060 SUPER: 0 of 18, same speed).
- **On the RTX 4070 we did not see the race with Mirai S**: fresh prompts of 20k to 100k, two rounds, gave normal
  answers with the pool on and off (20 of 20) and with this engine and the pool on (10 of 10), at the same speed
  (100k prompt: 141-142 s in every arm; `receipts/pool_ab_mirai.log`). A slower card could hit it; this engine
  removes the risk and keeps the 188 MiB.
- `MIRAI_SHARED_POOL=0` turns the pool off, as before; at the engine level, `GGML_CUDA_SHARED_POOL=0` now also means
  off (before, any value turned it on).

## bundle-20261008c (agent requests with many tools)

Same model file, launcher and layer. New engine binaries (engine commit `6f2d47e3e`; the change is in `llama.dll`).

- **Many tools cost no decode speed.** With speculative decoding, the server copies the sampler on each draft step,
  so that it can go back when the draft is rejected. With tools, the sampler holds the tool-call grammar. The grammar
  copy found each stack entry with a search over every element of every grammar rule, so a long tool list (an agent
  with several MCP servers) made each draft step slower. Now each entry is found with a binary search over the rule
  start addresses. The copy is the same; only the search is faster. Requests without tools do not change.

  | RTX 4070, Mirai S, 107 tools (106.7k characters of tool definitions), about 63k tokens | Before | Now |
  | --- | ---: | ---: |
  | Code-like answer, server-default sampling | 40.4 tok/s | 49.2 tok/s |
  | Plan-like answer, server-default sampling | 36.7 tok/s | 45.0 tok/s |
  | Code-like answer, greedy | 48.4 tok/s | 53.6 tok/s |
  | Plan-like answer, greedy | 38.4 tok/s | 46.9 tok/s |
  | A request with three tool calls (the grammar is active) | 59.6 tok/s | 70.4 tok/s |

  Each pair has the same token count and the same draft acceptance, and the tool-call request gives the same calls
  with the same hash (`receipts/tools_ab_mirai.log`). The same change is patch 0042 of the sister Bonsai serve, and it
  is offered upstream as ggml-org/llama.cpp #30172.

## bundle-20261008b (prefill past the VRAM line)

Same model file, launcher and layer. New engine binaries (engine commit `8381d3a45`; the change is in `ggml-cuda.dll`).

- **Prefill past the VRAM line, without the fixed extra cost.** The first ~58k positions of the cache are in VRAM
  (the display on the integrated GPU), and the rest are in system RAM. Before, prefill became slower at once when the
  prompt passed that line: each prefill micro-batch wrote its new K/V rows to system RAM in small pieces over PCIe.
  Now the rows are written to VRAM first and then copied to system RAM as whole 16-byte stores, and the system-RAM
  rows of the next attention layer are copied on a second CUDA stream while the layers before it compute. Greedy
  output does not change, and decode does not change.

  | RTX 4070, Mirai S, prefill | Before | Now |
  | --- | ---: | ---: |
  | Cost per prompt token, prompt chunks past the line (58k to 130k) | 2.27-3.10 ms | 1.53-2.26 ms |
  | One 100k prompt (cumulative) | 596 tok/s | 722 tok/s |
  | One 130k prompt (cumulative; time to first token) | 509 tok/s (254 s) | 639 tok/s (202 s) |
  | VRAM line pinned at 16k, one 40k prompt | 765 tok/s | 964 tok/s |

  Decode at 130k: 18.4 and 18.5 tok/s. Greedy text: 7 of 7 prompts identical (`receipts/tier_ab_mirai.jsonl`;
  the same patch is patch 0041 of the sister Bonsai serve).

- **Each KV cache has its own staging buffers.** Before, the MTP draft context and the main context shared them, and
  the draft context runs on its own CUDA stream. With the VRAM line pinned below the draft context's size (about
  20.7k cells, `MIRAI_KV_VRAM_CELLS`), one context could overwrite the other's rows: at a 16k line, the old engine
  gave broken text (answers of 2 to 17 tokens) on prompts of 30k. The automatic line is above that size.

`GGML_CUDA_KV_TIER_REDIRECT=0` and `GGML_CUDA_KV_TIER_PREFETCH=0` turn the two parts off.
