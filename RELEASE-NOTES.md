# mirai-s-ada, first release (bundle-20261006)

> Upgrade steps and the build: [docs/build](docs/build/README.md#upgrading). All documents: [README.md](README.md).

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

Quality, measured with plans and gates frozen before results (`docs/research/REPORT.md`):

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
  (`receipts/mirai-port/mtp_q4_probe.log`, `docs/research/REPORT.md` 6e): one transient CUDA pool for the target and draft
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
  once on the new defaults and did not reproduce in four replays (`docs/research/REPORT.md` 6e). An aborted server is now
  restarted (`MIRAI_RESTARTS`, default 3 within ten minutes) and `MIRAI_STDERR_FILE` keeps its raw stderr so the
  next assert leaves its text; `tooling\stop.ps1` stops it without a restart.
- **Engine be00bbdc1**: alesha-pro's control-vector projection mode (`--cvec-mode project`, off unless passed; greedy
  identity against the fork's dump re-checked here 5/5 without the flag) plus a bounds guard on its per-layer flag.
- **Linux**: `start-server.sh` and the Ubuntu 22.04 / RTX 3090 check (build line, identity 5/5, decode by depth) from
  alesha-pro's pull request; the layer on Linux is not wired.
- **Removing refusals, optional**: alesha-pro's refusal-direction control vector and his measurements, in
  `docs/research/CONTROL-VECTOR.md` with a short README pointer; off unless the file is passed, not measured on the suite here.


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

## bundle-20261019b (replay rollback on by default; replies cut at max_tokens are no longer empty)

Same model file and engine (`1ee7f9766`).

- **Replay rollback is on by default** (`MIRAI_RS_REPLAY=0` turns it off). The same text as without it; 285 MiB more
  KV cache in VRAM (on the RTX 4070 the VRAM line goes from 58,624 to 67,840 positions; decode +7 % / +14 % / +6 % at
  64k / 128k / 200k). A 30-minute soak with it on ran 14 requests up to 200k with 0 errors.
- **Fix: empty replies.** Through the layer, a reply that `max_tokens` cut could come back with empty content: the
  model had started writing its answer into the layer's Python tool, and the layer never shows a half-written tool
  call. The layer now asks once more without its tool, so the reply has text. Such a reply can use up to twice
  `max_tokens` of generation.
- Checks on the zip: listed in the release receipt.

## bundle-20261019 (replay rollback, opt-in: MIRAI_RS_REPLAY=1)

Same model file. New engine binaries (`1ee7f9766` = `cc1c1391b` + replay rollback) and launcher.

- **What it does:** speculative decoding on the model's 48 recurrent (gated delta net) layers keeps a 150 MiB snapshot
  of the recurrent state per draft token, so that rejected draft tokens can be undone (draft 2: 449 MiB). With
  `MIRAI_RS_REPLAY=1` the engine keeps one state and the inputs of the last draft tokens instead, and replays the
  accepted ones at the next step (164 MiB). The launcher gives the freed VRAM to the KV cache: on the RTX 4070 the
  VRAM line goes from 58,624 to 67,840 positions.
- **The same text:** with replay on, the output is byte-identical to replay off (12 of 12 requests at 4k and 32k, 4 of
  4 at 4k to 200k; the same draft counts).
- **Measured (RTX 4070, decode of a 300-token answer):** 62.9 / 44.9 / 15.8 / 8.5 tok/s at 4k / 64k / 128k / 200k
  without replay, 62.8 / 48.2 / 17.9 / 9.1 with it (+7 % / +14 % / +6 % from 64k on); a 30-minute soak with replay on
  ran 14 requests up to 200k with 0 errors and at least 366 MiB of VRAM free.
- Off by default in this bundle; the next bundle turns it on.
- Checks on the zip: listed in the release receipt.

## bundle-20261018d (with the save after the answer on: a save after every answer)

Same model file and engine (`cc1c1391b`). Only the layer changes.

- **With `MIRAI_SLOT_CACHE_AFTER=1`:** the layer saves after every answer of a long conversation, as a delta. The next
  turn restores exactly the state after the last answer and reads only the new turn, also when several conversations
  take turns. The test is exact: the last save must be a token prefix of the new prompt.
  - Sessions that share their start each keep their own saves (up to 4 per start).
  - A template that rewrites every answer fails the test; after 2 failures in a row the layer tries again only every
    4th turn and uses the save before the request.
  - Under budget pressure a full save replaces a long chain of deltas.
  - A save that would evict another conversation's save used in the last 10 minutes is skipped
    (`BONSAI_SLOT_CACHE_PROTECT`, seconds; 0 = off).
- **Default (`MIRAI_SLOT_CACHE_AFTER` unset):** unchanged (the save before the request), except a review fix: removing
  a chain never leaves a delta without its parent.
- Checks on the zip: only the layer and notes changed; the bundle smoke test 5/5 the same; a saved conversation
  restored after a restart; the default launcher makes deltas; with the save after the answer on, a save after each
  answer and two interleaved conversations each restore their own last save; 0 CUDA errors.

## bundle-20261018c (the full save of a long conversation waits for idle time)

Same model file and engine (`cc1c1391b`). Only the layer changes.

- **Before:** after 8 deltas, the next save was a full save of the whole conversation, written right after an answer.
  On a slow drive it can take minutes (~6 GB for a long Mirai conversation), and a turn sent then waited for it.
- **Now:** after 8 deltas, the full save runs when the layer has been idle for 30 s (`BONSAI_SLOT_CACHE_IDLE`).
  - Until then the chain grows. A restore costs ~1 s more per delta.
  - After 32 deltas (`BONSAI_SLOT_CACHE_CHAIN_MAX`), the full save happens in any case.
- **Measured:** in a 30-turn session with restarts and pauses of 20 s, no full save landed on a turn any more.
  - With delta saves for both kinds of save, the default (save before the request) waits 23 s per turn on average.
  - With full saves (bundle-20261018) it waited 74 s.
- Checks on the zip:
  - only the layer file changed;
  - the bundle smoke test 5/5 the same;
  - a saved conversation restored after a restart;
  - the default launcher makes deltas;
  - an idle full save after a long chain;
  - 0 CUDA errors.

## bundle-20261018b (delta saves: a save writes only what is new)

Same model file. Engine `cc1c1391b` (`5f93f07c0` + delta slot saves). Layer: delta saves.

- **A save of a conversation now writes only the tokens since the last save** (a delta), not the whole conversation.
  - A restore loads the last full save and then each delta.
  - Every 8 deltas the next save is a full save again.
  - This works for both kinds of save: the save before the request (the default) and the opt-in save after the answer.
- **Why it matters:** a full save of a long Mirai conversation is ~6 GB. On a drive that cannot keep its write speed, one
  full save took 227 s for a 174k-token conversation in our test; a delta took 0.2-0.6 s.
- **Exact:** a chain restore (a full save + 4 deltas) gives the same answer, the same tokens read and the same cached
  tokens as a full-file restore, at 20k and 174k tokens.
- Each delta also holds the model's fixed recurrent state (~150 MiB).
- `MIRAI_SLOT_CACHE_AFTER=1` (save after the answer) stays opt-in: in our test, the turn after the forced full save
  waited for it.
- Checks on the zip:
  - the bundle smoke test 5/5 the same;
  - the one-token repro 10/10;
  - a saved conversation restored after a restart;
  - a chain restore equal to a full restore;
  - the default launcher makes deltas;
  - 0 CUDA errors.

## bundle-20261018 (the next turn reuses the state after the answer)

Same model file. Engine `5f93f07c0` (`41aa200a0` + one server change). Layer: one opt-in setting.

- **A speculative draft stops at the end of the answer.** In a long conversation, the lookup drafter could continue
  a draft past `<|im_end|>`, because the history makes the next `<|im_start|>` line easy to predict. The server
  accepted those tokens into the conversation state, so the next turn could not reuse the state after the answer. It
  read the answer again from an older checkpoint. Now the draft stops at the end token.
  - Measured on a 20k-token conversation, 10 turns: the next turn reuses the whole state on 9 of 9 turns.
  - The server no longer checks draft tokens after the end of an answer.
- **Opt-in: save after the answer** (`MIRAI_SLOT_CACHE_AFTER=1`, with `MIRAI_SLOT_SAVE_PATH` and the layer).
  - The layer saves a long conversation after the answer, not before the request, so the answer does not wait for
    the save.
  - It works when the next turn renders the answer with the same tokens: thinking off, or a client that sends the
    reasoning back. The layer tests this per conversation and keeps the save before the request when the test fails.
  - On the sister Bonsai serve (RTX 4070, a 30-turn session with restarts): restart turns -56 %, the session -12 %,
    the same answers. But a turn sent right after a slow save waits for it, so it is not the default.
- Checks on the zip: the bundle smoke test 5/5 the same; the one-token repro 10/10; a saved conversation restored
  after a restart; the opt-in setting turns on through the launcher and saves after the answer; 0 CUDA errors.

## bundle-20261017d (no answer written twice with thinking off)

Same model file and engine (`41aa200a0`). Only the layer changes.

- **A request with thinking off now stops at a stray `</think>` line.** With thinking off the template has already
  closed the think block, so such a line is always stray. Before, the model could write its answer a second time up
  to `max_tokens` after it (bundle-20261017c removed that text, but the tokens were still spent). Now the layer adds
  `"
</think>"` to the request's `stop` list (merged with the client's own list). Measured: the 64k case ends with
  finish `stop` instead of `length`; HumanEval 164 through the layer, thinking off: 153, the same, no task changed.

## bundle-20261017c (clean answers with tools and thinking off)

Same model file and engine (`41aa200a0`). Only the layer changes.

- **Stray closing tags are removed.** With a tool block in the prompt (the layer's `run_python` tool, or a client's
  own tools), thinking off and a long prompt, the model could end a correct answer with `</parameter></function>
  </tool_call>` (20k) or `</think>` and then the answer again (64k). The layer now removes such a trailing run of
  closing tags, and cuts at a stray `</think>` line, in streamed and non-streamed answers without tool calls (never
  inside a code fence). Measured: the 20k and 64k cases give the clean answer; HumanEval 164 through the layer,
  thinking off: 153 with and without the filter, no task changed; greedy answers of other requests unchanged.
  `"strip_stray_tags": false` turns it off for a request.

## bundle-20261017b (saved conversations, automatic with the layer)

Same model file and engine (`41aa200a0`). Only the layer and the launcher change.

- **With the layer on and `MIRAI_SLOT_SAVE_PATH` set, saved conversations are automatic.** The layer saves each
  prompt of 16k+ tokens (and again when it grows by 8k) and, after a server restart, restores the longest saved
  prefix before the request, so the request reads only its new tokens. RTX 4070, default recipe: a 128k document
  asked after a restart answers in **6.7 s** (restore 2.2 s, 39 new tokens), against 199 s cold, with the same
  answer. Files are named `lc-<hash>`; the layer removes its own files past 20 GB, oldest first, and no other file.
- **Read ahead:** a chat request with `"prefill_only": true` reads the prompt and saves it, and answers with a short
  JSON object instead of text. Send it when a big file is attached, before the question.
- With the cache off, the layer's answers are unchanged (greedy hashes identical).

## bundle-20261017 (saved conversations)

Same model file. New engine binaries (engine commit `41aa200a0`). The default does not change.

- **`MIRAI_SLOT_SAVE_PATH=<folder>`: save a conversation, and continue it after a restart without a new read.**
  `POST /slots/0?action=save` with `{"filename": "name.bin"}` writes the K/V state of the conversation (both tiers)
  and, in a second file `name.bin.draft`, the state of the draft block. `action=restore` reads both back. The next
  turn then reads only its new tokens (a 5.5k-token turn at 128k: 13.3 s, in memory 13.2 s). RTX 4070, 262k window, q8_0
  cache:

  | Conversation | Restore + new turn | Read it again | File |
  | --- | --- | --- | --- |
  | 64k | 0.8 + 0.4 s | 73 s | 2.3 GB |
  | 128k | 1.6 + 0.6 s | 195 s | 4.5 GB |
  | 245k | 9.0 + 1.6 s | 524 s | 8.3 GB |

  The answers after a restore are identical to the answers without a restart. Without the `.draft` file the
  restore still works and the server prints a warning; the draft block then reads the conversation again. A
  relative folder is made absolute by the launcher. The server does not remove files: delete old files yourself.
- **The CUDA pool grows safely.** A pool growth that fails for a moment under Windows (seen on an 8 GB card after a
  restore) is undone and tried again, with a message, in place of a crash. `GGML_CUDA_POOL_RESERVE_MIB=n` reserves
  the pool at start.

## bundle-20261016 (a long-context cache option: q3_0)

Same model file. New engine binaries (engine commit `70b9db679`). The default does not change.

- **`MIRAI_CTK=q3_0`: 2.9x the context in VRAM, decode at depth 2.6-3.8x.** A 3.5-bit K/V cache (the q3_0 type from
  the Bonsai serve). RTX 4070, 262k window: the VRAM line goes from 58,624 to 167,680 positions, and decode at 128k /
  192k / 245k goes from 21.7 / 12.9 / 9.6 to **61.6 / 51.3 / 36.9 tok/s**. Quality, against the q8_0 default: exact
  code copies 20/20 and fact lookups 24/24 at 245k (the same), HumanEval 164 157 (q8_0: 158), perplexity +0.87 % at
  2k context. Its per-token divergence from an f16 cache is higher than q8_0's, so it is an option for long-context
  work, not the default. `MIRAI_CTV` sets the V type separately (a mixed pair needs an engine built with
  `GGML_CUDA_FA_ALL_QUANTS`).
- **Faster K/V tile loads** in the tensor-core attention kernel (bit-identical output for q8_0, the default).

## bundle-20261015 (images on Windows, images from agent tools)

Same model file. New engine binaries (engine commit `de2104665`).

- **Images on Windows: `MIRAI_MMPROJ`.** `start-server.ps1` now loads a vision projector (before, only `start-server.sh`
  did). The encoder runs on the CPU by default and takes no VRAM from the cache; `MIRAI_MMPROJ_GPU=1` puts it on the
  card and counts it in the VRAM line. The Qwen3.8-27B projector works, and so does PrismML's
  `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` (the same vision encoder): a test image was read correctly with both the
  Responses and the chat API.
- **Images from agent tools on the Responses API.** A harness on `/v1/responses` whose tool returned a screenshot got
  HTTP 400 ("Output of tool call should be 'Input text'"), and every later request in that session failed. The engine
  now takes the upstream fix (ggml-org/llama.cpp `4098fdc922`); the image reaches the model like an image in a user
  message.

## bundle-20261014 (sparse reads past the VRAM line, faster long prefill)

Same model file. New engine binaries (engine commit `784986b41`).

- **Sparse host-tail reads, opt-in: `MIRAI_SPARSE=1`.** Past the VRAM line, a decode step normally reads every K/V
  row in system RAM over PCIe. With sparse reads, each attention op reads the RAM pages whose stored int8 bounds give
  the highest possible score for the current query (at least 12,288 positions or 1/8 of the RAM part, plus the last
  1,024 positions) and skips the rest. RTX 4070, 262k window: mean decode at 192k **11.7 -> 16.2-17.0 tok/s**, 128k
  about +20 %. Exact code copies and fact lookups (66 items at 160k / 200k / 245k) gave the same answers as the full
  read. A thinner budget (1/16 of the RAM part) was faster (20.9 tok/s at 192k) but got one digit of one fact wrong at
  245k, so the launcher uses 1/8. The bounds take about 166 MiB of VRAM, so the VRAM line is about 5k positions
  shorter; that is why it is off by default. The launcher prints a `sparse host-tail reads` line when it is on.
- **Long prefill on tensor cores** (the chunked gated-delta-net prefill of ggml-org/llama.cpp#29353): code prefill
  +3.5 % at 128k and 192k. The float order of that step changes, so long answers can differ in wording: HumanEval 164
  greedy 159 (bundle-20261013: 158), the five fails are a subset of the old six.
- Also in the engine (all off by default): a partial staging buffer and in-place reads for small attention ops
  (`GGML_CUDA_KV_TIER_STAGING_FRAC`, `GGML_CUDA_KV_TIER_STAGE_MIN_Q`), an f16 K/V path for long prefill
  (`GGML_CUDA_FA_PREFILL_F16`), chunked flash attention for prefill at depth (`GGML_CUDA_FA_CHUNK`), and the
  ADD + RMS_NORM + MUL fusion.

## bundle-20261013 (decode past the VRAM line, build on any Windows machine)

Same model file. New engine binaries (engine commit `cd4e9d8dd`).

- **Decode past the VRAM line +10-17 %.** CUDA graphs kept the K/V prefetch for the part of the cache in system RAM
  from running: the prefetch only runs when a step is not replayed from a graph. The engine now turns graphs off for
  the steps whose attention reads that part, and keeps them on below the line. Mean decode, the same card and clocks
  in both arms: 32k 65.7 -> 66.9, 128k 16.1 -> 18.8, 192k 10.5 -> 11.6 tok/s. The same text: HumanEval 164 greedy gave
  identical answers on all 164 prompts with and without the change. `GGML_CUDA_KV_TIER_GRAPHS=1` keeps the old
  behaviour. The server log has one line that says which mode the server uses.
- **Build on any Windows machine** (issue #4): `tooling/build_engine.bat` finds Visual Studio with vswhere and the CUDA
  toolkit, cmake and ninja from the Python pip packages (`tooling/find_toolchain.py`), and builds for the local GPU by
  default (`MIRAI_CUDA_ARCH`). It makes the cuBLAS import libraries when the CUDA 13 wheel has none;
  `tooling/install_bin.ps1` also copies the CUDA runtime DLLs.

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
  tokens far off; docs/research/REPORT.md 6f), so K/V stays q8_0.

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
