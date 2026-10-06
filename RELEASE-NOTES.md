# mirai-s-ada, first release (bundle-20261006)

Mirai S 27B (alesha-pro's Qwen3.8-27B-S trellis GGUF, 11.17 GB) served on an RTX 4070 12 GB with:

- the model's **full 262,144-token window at q8_0 KV** (tiered cache: ~44k positions in VRAM, the rest in pinned
  system RAM, bit-identical to an all-VRAM cache; the model's own fork fits 64k at q8_0 on the same card),
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
(PrismML's llama.cpp fork + the serving patches, also open as PrismML PRs #319-#323, + the Mirai codec ported from
alesha-pro/llama.cpp-mirai-s and verified greedy token-for-token against it).

Credits: alesha-pro (model, codec, fork), PrismML (the llama.cpp fork), sudoingX (planar activations, batch-invariant
mode). Not affiliated with either.

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

