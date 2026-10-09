# Mirai S on a 12 GB card: report

Running notes, newest at the bottom. Method: paired runs, frozen plans and gates in `DECISIONS.md`, receipts in
`receipts/`. Numbers are from this RTX 4070 12 GB unless marked as someone else's.

## 1. The model

`alesha-pro/Qwen3.8-27B-S-mirai-GGUF` (sha256 5aa4365c...), 11.17 GB: alesha-pro's GGUF conversion of Mirai Labs'
`Qwen3.8-27B-S` (trymirai; a trellis quantization of Alibaba's Qwen3.8-27B). Its weights are in four trellis-coded
ggml types (`MS_V4T8`, `MS_V2T4`, `MS_V2T6`, `MS_I3`, ids 90-93 in the engine), about 2.4 bits of information per
weight; model-wide rotation tensors (`mirai.rot.*`), a head auxiliary tensor (`mirai.head_aux`), a split attention
gate, and the MTP draft block (`blk.64`) in Q8_0 inside the same file.

## 2. The starting point: alesha-pro's reference fork on this card

Mirai's own fork (`alesha-pro/llama.cpp-mirai-s`, upstream d834d44e6), 64k q8 window, 11.0 GB: decode 40.0 / 39.6 /
38.1 / 36.1 / 33.5 tok/s at depth 0 / 4k / 16k / 32k / 60k; prefill ~1000 tok/s at 4k falling to 600 at 60k. No
tiered KV, no speculative decoding, no reasoning budget (`receipts/mirai-port/profile-stock-fork-q8-64k.txt`).

## 3. The port

Mirai's codec (39 files, +3.2k lines over upstream) was merged onto our engine at the pinned product commit of the serving stack
(PrismML llama.cpp + 36 serve patches), not the other way round: eleven hand merges, their GDN / flash-attention /
server changes not taken because ours cover the same ground. One missed CUDA `supports_op` case first put all 417
Mirai tensors in system RAM; fixed, the whole model sits on the GPU at the stock footprint.

Verification: greedy, token-for-token against the reference fork's dumped outputs on five prompts, thinking off (200
tokens) and on (300 tokens): identical on all ten. Speed, plain 64k q8 window: 41.1 / 38.9 / 37.2 / 34.4 tok/s at
0 / 16k / 32k / 60k, +3% over the reference fork from our attention and GDN kernels; nothing Mirai-specific was tuned.

## 4. MTP speculation, and the prefill collapse that was really a VRAM budget

Drafting on the GGUF's Q8_0 MTP block with the stack's recipe (draft 2, q8 draft KV, 16k draft window, tail 4,
backend sampling): outputs identical to the stock dump 5/5, **73.9 tok/s at depth 0** (1.8x). Prompt processing
collapsed to ~50 tok/s against ~930 plain.

The probe (`receipts/mirai-port/prefill_probe.log`): no MTP flag combination mattered (51 tok/s with any of them at
`-b 1024 -ub 1024`), the product batch `-b 2048 -ub 512` gave 746, and the per-op GPU table
(`op-timing-mtp-ub1024.txt`) charged 44 of the 47 s to the trellis matmuls at 1024 columns, the same ops that run
the whole prompt in 2.6 s without MTP. The accounting (`vram-accounting-mtp-64k.txt`) explains it: Mirai keeps
8,220 MiB of weights resident (its 2.4 GB F16 token embedding stays in host RAM), the 64k q8 KV takes 2,176 MiB, the
recurrent state 449, the compute buffer 406, and the MTP draft context another 440; the engine's own fit check at
launch reported 11,691 MiB projected against 10,656 free. Windows demotes the newest allocations to system memory and
prefill is where the big GEMMs touch them. Confirmation: the identical configuration at a 32k window prefills at
887 tok/s with the same draft acceptance (`one_probe.log`, V1). ub512 only slips under the demotion line.

What this means for Mirai S on 12 GB: the resident weights leave about 1.1-1.4 GB for KV in VRAM once the draft
and compute buffers are counted. The tiered KV cache is therefore not only the way to the 262k
window; it is what makes MTP fit at all. The product recipe is built on that budget (section 5, feature tests A/B/C).

## 5. The serving stack on Mirai S: feature tests A, B, C

All on the engine built in this repo, `-b 2048 -ub 512`, q8_0 K/V, greedy identity against the reference fork's dump
checked first in every arm (5/5 each time). `receipts/mirai-port/feature_tests.log`.

| arm | window | VRAM at load | decode tok/s by depth |
| --- | --- | ---: | --- |
| plain (reference) | 64k all-VRAM | 10.7 GB | 41.1 / 38.9 / 37.2 / 34.4 at 0 / 16k / 32k / 60k |
| A: MTP draft 2 | 64k all-VRAM | 11.7 GB | **76.9 / 72.4 / 68.5 / 65.4** (1.85x throughout) |
| B: tiered KV, 32k cells in VRAM | 262,144 | 10.1 GB | 41.0 / 37.2 / **14.6 / 6.2** at 0 / 32k / 60k / 120k |
| C: B + MTP (tail draft 4) | 262,144 | 11.3 GB | **77.0 / 67.9 / 38.7 / 19.5 / 12.6** at 0 / 32k / 60k / 120k / 180k |

The arithmetic behind B: a q8_0 K/V cell for this architecture is 34,816 bytes (16 attention layers, K+V, 4 heads x
256). Mirai keeps 8,220 MiB of weights resident, so the line sits
positions, Mirai's sits at ~32k with drafting (~70k without); past it every step reads the host tail over PCIe (27k
rows, 0.9 GB, at 60k; 87k rows, 3 GB, at 120k), which is B's 14.6 and 6.2. The tail draft in C turns that into 2.65x:
a PCIe-bound step reads the tail once per verify batch, so the extra draft columns cost almost nothing. 38.7 tok/s at
60k in the 262k window is above the plain 64k window's 34.4 at the same depth.

Measured fixed VRAM cost against idle free VRAM (what the launcher's auto-sizing uses): 8,220 MiB without drafting,
9,434 MiB with the MTP draft context. The draft context's 1,214 MiB is the largest leftover on this card: its K/V is
44 MiB; the rest is a second context's compute buffer and pools.

Product defaults (`start-server.ps1`): arm C plus harness-proofing and the layer. `MIRAI_SPEC=0` is the long-context
mode (line at ~70k, no drafting).

### 5b. Where the draft's VRAM really was, and the tail-draft trade (night of 10-04/05)

With a pool-growth log in the engine and `-lv 5` launches (`receipts/mirai-port/vram_split.log`), the MTP draft
context costs 175 MiB (K/V 43, compute 118, pool 14); sharing the transient pool between the two contexts and
halving the draft's micro-batch return 74 MiB together (identity 5/5, decode unchanged) and stay env options under
the 150 MiB gate. The number that mattered is the recurrent-state buffer: 149.6 MiB without speculation, and one
full snapshot per unit of rollback depth with it (449 MiB at draft 2, 748 at the tail draft 4), because a partly
accepted draft has to roll the GDN state back. Each unit is ~4.5k K/V positions.

The tail draft past the VRAM line, measured at 31,488 cells (`tail_draft.log`): tail 2 / 3 / 4 = 32.2 / 37.0 /
38.8 tok/s at 60k and 15.1 / 17.8 / 19.3 at 120k, against 14.6 / 6.2 with no draft, for 449 / 598 / 748 MiB of
snapshots. The product takes tail 2: drafting then costs only the two snapshots it needs below the line, and the
300 MiB returned move the line up ~9k positions where decode is ~70 instead of ~35; past the line it gives up 17%.
With the launcher's fixed-cost model corrected to 8,220 + 150 x depth + 664 MiB (the second context's full cost,
measured), the serve sizes the line to 39,424 positions at the 1,000 MiB margin and measures 75.6 / 71.3 / 37.0 /
16.1 / 10.1 tok/s at 0 / 16k / 60k / 120k / 180k, identity 5/5, the layer's tool round correct
(`product_smoke.log`, 02:11). One launch in between ran with a wrong constant (50,688 cells, ~550 MiB headroom);
its receipts are kept and marked as over budget, not cited.

## 6. The layer in front of Mirai S (ML1, on the reference fork)

The suite paired, 74 runs, raw vs behind the layer with shipped defaults:

| | Mirai S raw | Mirai S + layer |
| --- | ---: | ---: |
| suite, 37 items | 13 | **30** |
| rescues / losses | | 17 / 0 |
| tokens | 488k | 381k (0.78x) |

The layer's three levers (exact API cards, the sandboxed tool with the user's text as a file, the verify sentence)
are model-agnostic: the same families move for the same reasons on both models, workspace passes through
byte-identical on both, and no pair got worse. Cross-model totals are not a ranking (Mirai's fork has no reasoning
budget, so its raw arm can think to the cap without answering); the within-model pairs are the result. Scoreboard
and traces: `bench/ML1/`. Card: `docs/img/mirai-layer.png`.

## 6b. The layer on the product serve (ML2)

Same 37 items and seeds as ML1, paired raw vs layer on this engine with the product defaults (262k tiered window,
MTP, reasoning budget 20,480 with forced close, harness-proofing), 74 runs in 3.5 h:

| | raw | layer | rescues / losses | tokens |
| --- | ---: | ---: | --- | ---: |
| ML1 (reference fork, no reasoning budget) | 13/37 | 30/37 | 17 / 0 | 488k -> 381k |
| ML2 (this serve) | **16/37** | **29/37** | **13 / 0** | 486k -> 377k |

Per family on this serve: coding 3 -> 6 of 12 (tar 0 -> 2, ZIP 3 -> 4, MIME 0 -> 0), computation 5 -> 15 of 15,
workspace 8 -> 8 of 10 (byte-identical passthrough). The raw arm's +3 over ML1 is the serve, not the model: the
forced close turns runs that thought to the cap into answers. The layer's levers stack the same way on both serves.
Served receipt over the run's 525 requests (`receipts/mirai-port/served-ml2.md`): decode median 74.4 tok/s,
prompt median 700 tok/s, draft acceptance 83.5% pooled over 710k drafted tokens.

### 6c. ML2b: the same suite on the prefill work of 10-05

The suite was re-paired on the serve as it stands after the prefill day (one-plane FFN activations for prompt
tokens, packed 1-bit mask, 1024 micro-batch, VRAM line 44,288), same items and seeds, 74 runs in 3.6 h
(`bench/ML2b`, `receipts/mirai-port/ml2-vs-ml2b.md`):

| | raw | layer | rescues / losses | tokens |
| --- | ---: | ---: | --- | ---: |
| ML2 (10-04 defaults) | 16/37 | 29/37 | 13 / 0 | 486k -> 377k |
| ML2b (10-05 defaults) | **18/37** | **28/37** | **12 / 2** | 508k -> 394k |

Per family (raw / layer): coding 4 / 3 of 12, computation 4 / 15 of 15, workspace 10 / 10 of 10. Against ML2 the
layer total is within the pre-declared band (within 3), computation and workspace reproduce ML2 (11 of the 15
computation traces token-identical, the workspace pairs byte-identical), and the raw arm gained 2. The layer's
coding arm lost 3 (two tar seeds and one ZIP seed went pass -> fail), which is also where the run's 2 within-run
losses sit; the failed traces are the test-harness loop seen before, on the long tool-looped prompts that the
one-plane path touches. The pre-registered rule keeps the one-plane default; the coding-only control on the exact
two-plane numerics (`bench/ML2c-coding`, 24 runs) came back layer 4/12, raw 3/12, with six runs moving three each
way against ML2b, so the coding swing is seed noise on long tool-looped prompts and not the prefill numerics
(DECISIONS 2026-10-05 18:15). Served
receipt over the run's 481 requests (`served-ml2b.md`): decode median 73.9 tok/s, prompt median 911 tok/s (700 in
ML2), acceptance 82.8% pooled.

## 6d. Night of 10-05/06: the layer's coding gaps, effort "low", and what the suite can resolve

Five runs on the product serve (`DECISIONS.md` 2026-10-05 21:10 through 2026-10-06 07:15), all plans and gates frozen
before results:

| run | what | result |
| --- | --- | --- |
| E18 | the API check now flags names looked up on a class or called on a fresh stdlib instance (`EmailMessage.from_bytes`, the most repeated MIME mistake, was never flagged before); MIME requests get the `email`, `email.policy`, `email.parser` cards | layer coding 4/12 -> **7/12** (tar 1 -> 3, ZIP 3 -> 4), MIME 0/4 -> 0/4: the pre-registered MIME gate missed, the change kept on no-regression grounds, no MIME claim |
| E19 | a round-countdown note on tool results from the 8th round | 7/12, identical to E18; the model reads the note ("1 response remains... I need to wrap this up") and spends the last response on a tool call anyway; off |
| ML2e-low | coding + computation, both arms, effort "low" (server allow-list verified on the process) | raw 8 -> **12**/27 (MIME 0 -> 4/4), layer 18 -> **23**/27 (coding 3 -> 8 with E18 riding along; computation 15/15 both); tokens +31% raw, +13% layer; medium stays the default, "low" for raw coding agents |
| E20 | MIME at low through the layer with cards off, then lint only | 0/4, then 2/4 (raw 4/4): the cards are not the cause alone; the finish sentence accounts for part; the full-layer prompt makes the first response 2.6x longer on this item (23,382 vs 8,948 tokens) |
| ML2f | second seed set (5-8) for the coding family at medium | layer 5/12, raw 3/12: over both seed sets layer **12/24**, raw 7/24 (tar 1 -> 5 of 8, ZIP 6 -> 7, MIME 0 -> 0) |
| E21 | the finish sentence on Mirai S (coding x12 at medium without it; MIME x4 at low without it, cards on) | 4/12 vs 7/12 with it: the sentence helps here and stays; MIME 0/4 either way at every setting except raw at low (4/4) |
| determinism probe | same request and seed, seven cache/sampling conditions, the layer path, and E18 vs E19 first turns | identical in every condition; 11 of 12 suite first turns byte-identical; one late divergence 35k characters into a 75k response. 4-seed deltas of 1 to 2 are noise; the paired design stands |

ML2d-low (meant as the "low" run) was a medium replay because the launcher's harness-proofing normalized the effort
word; it reproduced ML2b on 54 of 54 runs and is kept as that receipt. Lesson applied: a runner flag the server can
normalize is checked against the server's own setting before a run.

## 6e. 10-06: the prefill ceiling, DFlash drafting, and two free VRAM levers (E22, E23)

**Where prefill stops on this card** (`docs/PREFILL.md`, DECISIONS 2026-10-05 18:30 / 18:45, 20:30). With the one-plane
FFN prompt numerics, the packed mask and the 128 MiB level chunk, the 16.8k prompt prefills at 1,090 tok/s. The per-op
table says where the time goes: trellis level decode 51%, GDN 11%, flash attention 11%, the activation quantizer 9%.
The int8 GEMM itself runs at 191-233 TOPS against the card's 233 dense peak, so a two-stream pipeline that decodes the
next chunk's levels behind the current GEMM (`GGML_MIRAI_PIPELINE=1`) measured 0 to -2.5%: there is no idle tensor time
to hide work in. The 2048 micro-batch is +5.6% prefill (1,148) for 567 MiB of activation buffers (~16k positions), kept
as a mode (`MIRAI_UBATCH=2048`). What is left is a few percent each (the quantizer's 127-register kernel, the decode
write path); the ceiling for these weights on this card is ~1.1k tok/s.

**E22, DFlash drafting** (`receipts/mirai-port/dflash_probe.log`; test server at the product flags, 40,960 cells, greedy
identity against the no-draft dump). ggml-org's DFlash drafter for Qwen3.8-27B borrows the target's output head, which on
Mirai is a trellis tensor; the graph hook had to learn to find the codec's tensors through the target model (engine
f11c75618), without which every drafter arm aborted at load.

| arm | identity | tok/s at 0 / 16k | pooled acceptance (mean draft) | VRAM at load |
| --- | --- | ---: | ---: | ---: |
| MTP block, draft 2 (default) | 3/3 | 76.2 / 71.8 | 78% (2.5) | 11,339 |
| DFlash Q4_0, draft 3 (three runs agree within 1%) | 3/3 | 86.3 / 77.9 | 70% (3.0) | 11,925 |
| DFlash draft 2 | 3/3 | 73.0 / 69.7 | 78% (2.6) | 11,919 |
| DFlash draft 4 / 5 | 3/3 | 84.6 / 57.1 and 77.9 / 55.2 | 61% / 54% | 11,931 / 11,935 |
| DFlash Q8_0 drafter, draft 5 | 3/3 | 43.1 / 35.2 | 55% | 11,941 |
| DFlash draft 7 | did not load (VRAM) | | | |

Draft 3 is the knee: +13% at depth 0 and +8.5% at 16k with identical outputs. Longer drafts lose acceptance faster
than they add tokens, and each unit of draft depth adds a 150 MiB recurrent-state snapshot, which is why draft 4+
collapse at 16k and draft 7 does not load. Placing the drafter's layers on the GPU (`-ngld 99`) and the 16k draft window
changed nothing: the drafter is small, its file's bulk is embeddings and a head the loader never uses. The cost is 586
MiB at equal cells, ~17k fewer positions on the VRAM line. Pre-declared gate (1.10x at 16k, or equal speed with more
positions): missed at 1.085x. Shipped as `MIRAI_SPEC_TYPE=dflash` for sessions that stay under the smaller line; the
MTP block stays the default for agents.

**E23, two free VRAM levers** (`receipts/mirai-port/mtp_q4_probe.log`; same harness):

| arm | VRAM at load | identity | tok/s at 0 / 16k | pooled acceptance |
| --- | ---: | --- | ---: | ---: |
| BASE: published file, pool off | 11,339 | 3/3 | 77.0 / 72.4 | 78.2% |
| POOL: `GGML_CUDA_SHARED_POOL=1`, draft micro-batch 256 | 11,151 (-188) | 3/3 | 77.0 / 72.4 | 78.4% |
| POOLQ4: POOL + the MTP block at Q4_0 (`tooling/requant_mtp.py`) | 10,947 (-392) | 3/3 | 77.9 / 73.7 | 77.7% |

The requantized copy rewrites the GGUF by hand (its trellis tensor types are private to this fork and unknown to
`gguf-py`): the 8 tensors of `blk.64.*` go Q8_0 -> Q4_0, everything else is copied byte for byte, 212 MB smaller.
Speculation is exact, so the model's outputs cannot change and did not (3/3 in every arm); the draft's acceptance moved
by half a point. Both levers are now defaults: the launcher credits 188 MiB for the pool and uses the 8,016 MiB weight
term when the Q4 copy is present. The product restarted at 57,856 positions in VRAM (from 45,312) at the same 800 MiB
margin, 11,487 MiB at load (the previous product start: 11,459), identity 5/5 against the fork's dump, the layer's tool
round correct, 76.5 / 71.9 tok/s at 0 / 16k (`product_smoke.log` 15:26). Decode by depth on the new line
(`decode_by_depth.log`): 76.6 / 72.6 / 68.8 / 66.4 / 61.7 / 19.5 / 11.4 tok/s at 0 / 16k / 32k /
48k / 60k / 120k / 180k; 60k is inside the line now (40.3 before), past it the PCIe tail is unchanged. The 800 MiB
margin soak on the new line is in `margin_soak.log` (same day).

**E24, one abort.** The first decode-by-depth receipt on the new line ended at 180k: the request's connection was
reset and llama-server was gone (Windows Application log: ucrtbase fail-fast 0xc0000409, the signature of an assert
or `std::terminate`; the server's log was overwritten by the next restart before the text was read). It did not
reproduce: the bare server at 120k then 180k, twice (19.6 / 11.5 tok/s), and the product with the exact request
sequence 0 through 180k (11.4 tok/s at 180k), `deep_crash_probe.log`, `deep_seq_probe.log`. The only difference
left was the traffic before the sequence (the smoke's identity prompts and tool round). Mitigation shipped instead
of a cause: the launcher restarts an aborted server and can keep its raw stderr (`MIRAI_STDERR_FILE`), so the next
occurrence leaves its assert text; `stop.ps1` writes a flag first so an intended stop is not restarted (both
verified: a killed server was back in 12 s, a stop stayed stopped).

Not changed, by decision: the K/V cache stays q8_0. A q4_0 cache would double the positions in VRAM; the earlier
KL-by-position receipt on this stack (1 flipped top token in 48 at depth for q4_0 against 1 in 160 for q8_0) is not
a measurement on this model, so q4_0 is a knob until it is.

### 6f. 10-09: K/V precision on Mirai S (receipts/mirai-port/kv_kl.log)

KL divergence by token against the same model with f16 K/V: wikitext-2 test, 16,384-token chunks x 4, so every
scored token sits at 8k-16k depth (`llama-perplexity --kl-divergence`).

| K / V | Mean KL vs f16 | Top token the same | Max KL on one token | PPL vs f16 |
| --- | ---: | ---: | ---: | ---: |
| q8_0 / q8_0 | 0.00050 | 99.64% | 1.46 | +0.24% |
| q4_0 / q4_0 | 0.0243 | 97.10% | 22.6 | +0.9% |

q4_0 would fit about 2.3 times the positions in VRAM (the line from ~58k to ~130k), but on this model it flips the
top token on 1 position in 34 and puts single tokens far off (KL 22.6). K/V stays q8_0, and MIRAI_CTK=q4_0 is not
recommended.

### 6g. 10-09: context checkpoints inside long messages (receipts/mirai-port/ckpt_ab.log)

Mirai S is a hybrid model: the server keeps checkpoints of the recurrent state only at user-message starts and at
the prompt end, so a prompt that changes inside one long message (an edited tool result, a file sent again) is read
again from the start. Engine 75eaee882 adds `--checkpoint-every-nt N` (`LLAMA_ARG_CHECKPOINT_EVERY_NT`): a checkpoint
every N tokens inside a message as well. 11 requests at 32k on one server (one long filler; only the end of that one
message changes), layer off:

| | N = 0 | N = 8192 |
| --- | ---: | ---: |
| the two requests that read the prompt again | 36.5 / 34.6 s | 6.6 / 4.5 s |
| mean of the requests after the first | 15.0 s | 9.6 s |
| text | | 11 of 11 identical |
| decode | | same |
| llama-server private memory | 17.8 GB | 18.5 GB |

Requests that need no restore are about 1 s slower with it (the checkpoint copies), and each checkpoint holds the
recurrent state in system RAM (~150 MiB). The server's limit stays 32 checkpoints per slot, which a long session
already fills with checkpoints at the ends of requests, so the worst-case RAM does not change. On by default since the
launcher of 10-09 evening; `MIRAI_CKPT_EVERY=0` turns it off.

### 6h. 10-09: the example check in the layer, and exact copies in edit calls

When a coding request has a function stub with docstring examples, the layer now runs those examples on the answer
in the sandbox; if they fail, it sends one follow-up turn with the doctest report and returns the second answer.
HumanEval 164 through the layer at medium, greedy (the two arms differ only where the follow-up was sent):

| | layer | layer + example check |
| --- | ---: | ---: |
| HumanEval 164 | 158 | **160** (HumanEval/59 and /162 fixed, none lost) |
| completion tokens | 162,920 | 200,988 (+23%) |

On by default; `"example_check": false` per request or `--no-example-check` turns it off.

Edit calls (an agent's `edit` tool, whose old text must match the file exactly): 120 requests on 40 windows of CPython
stdlib files, temperature 1.0, thinking on. 91 edit calls, **0 rejected** (90 placed exactly as asked); the other 29
requests read the file again first. A repair step for near-miss edit calls has nothing to fix here, so the layer has
none.

### 6i. 10-09: AppWorld on this serve (receipts/mirai-port/appworld.log)

AppWorld test_normal, all 168 tasks, the simplified ReAct code agent (temperature 1.0, seed 100, 50-step cap), raw
Mirai S on the product server (`:18080`: medium effort, 20k thinking budget, harness-proofing), one RTX 4070 12 GB:

| | task goal completion | scenario goal completion | by difficulty 1 / 2 / 3 |
| --- | ---: | ---: | --- |
| this serve, one RTX 4070 12 GB | **88.7** | **73.2** | 100.0 / 87.5 / 79.4 |
| alesha-pro, Mirai's vLLM plugin, 4x RTX 3090 | 89.9 | 75.0 | 96.5 / 89.6 / 84.1 |
| alesha-pro, BF16 reference | 95.8 | 91.1 | 100.0 / 97.9 / 90.5 |

The 12 GB serve matches the vLLM run within noise (1.2 points is about 2 of 168 tasks, one seed each). alesha-pro's
numbers: [qwen38-27b-bench-4x3090, agentic-v1](https://github.com/alesha-pro/qwen38-27b-bench-4x3090/tree/main/agentic-v1).

## 7. Open

1. Decode past ~58k positions is PCIe-bound (section 5b). The honest levers left are a 16 GB card (~180k positions by
   the launcher's arithmetic, not measured), `MIRAI_SPEC=0` for ~80k positions without drafting, or a q4_0 cache once
   its quality on this model is measured (KL by position and the suite, not before).
2. Prefill is at the card's int8 ceiling (section 6e); the quantizer kernel and the decode write path are worth a few
   percent each.
3. Quality beyond the suite: AIME and MMLU-Pro have not been run on this serve (AppWorld: 6i). The suite's library-heavy
   coding items remain model-limited (MIME passes only raw at effort "low").
4. Model-side: the MTP block's acceptance (78% at draft 2; DFlash 70% at draft 3). An on-policy draft head trained on
   this model's own outputs is the one lever that would move decode below the line; that is a change to the model (Mirai Labs' checkpoint, alesha-pro's GGUF), not to this serve.
5. Whether any of the codec's kernels as ported (trellis decode, the head's aux path) leave speed on the
   table at batch 1: the op table says the level decode is half of prefill, and it is already at the tensor peak when
   it feeds the GEMM.
