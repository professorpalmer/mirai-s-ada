# Prefill on Mirai S: where the time goes, what the card allows, and the plan

Status 2026-10-05 morning. Product prefill is ~750-790 tok/s at the shipped batch (`-b 2048 -ub 512`), 933 at
`-ub 1024` without drafting; alesha-pro's reference fork does ~1,000 at 64k. A 100k-token prompt is two minutes
before the first token. That is not a long-context product, so this is the next engineering line.

## 1. Measured: where a healthy prefill spends its GPU time

Per-op table over a 16.8k-token prompt at the product configuration (`receipts/mirai-port/op-timing-prefill-ub512.txt`,
779 tok/s, within the VRAM budget):

| op (512 columns) | share |
| --- | ---: |
| trellis matmul, `ms_v4t8` | 37.5% |
| trellis matmul, `ms_v2t6` | 21.9% |
| gated delta net (the 48 recurrent layers' chunked scan) | 7.6% |
| flash attention (16 layers) | 7.1% |
| activation quantization (rotation + trellis codes) | 6.8% |
| trellis matmul, `ms_v2t4` | 2.3% |
| everything else (swiglu, norms, adds, copies, the MTP catch-up) | ~17% |

So 62% is the three trellis matmul types. From the micro-batch comparison (P0 at 1024 vs the product at 512) the
cost splits into a fixed part per micro-batch of ~200 ms and a per-token part of ~0.87 ms; the asymptote of the
current path is ~1,150 tok/s however large the batch.

## 2. Why: how the prefill matmul works (engine/ggml/src/ggml-cuda/mirai-s.cu, `launch_mul_mat`)

- Activations are rotated (Hadamard, `mirai.rot.*`) and quantized per token into **two int8 planes** (a coarse
  plane and a residual plane with their own scales, `stats`): effectively 16-bit activations.
- For 1 token the trellis weights are decoded on the fly (`gemv`); up to `MMA_TOKENS` a tensor-core kernel decodes
  tiles in registers (`mma`); past that, the "long input" path decodes **every weight to an int8 level buffer once
  per micro-batch** (`levels`, in 32 MiB chunks), runs a cuBLASLt int8 GEMM of the levels against **both planes**
  (`2 x tokens` columns), and combines the two products (`prefill_output`).
- Cost per micro-batch: a full decode of ~27B trellis parameters (the fixed ~200 ms) plus two int8 GEMMs over 27B
  parameters x tokens (the per-token 0.87 ms). The second plane is why the per-token part is twice an int8 GEMM.

## 3. The ceiling on this card

A 27B dense model costs 2 x 27B operations per token. The RTX 4070's dense int8 tensor rate is ~233 TOPS, fp16
~184 TFLOPS. At 60% of peak (what cuBLASLt reaches on these shapes) a one-plane int8 GEMM gives ~1.9-2.0k tok/s
for the matmuls alone; with the other 38% of the graph untouched, ~1.5-1.7k tok/s end to end. That is the honest
"way better": about 2x, not 10x. Beyond it is sparsity or not recomputing (prompt cache reuse for repeated
prefixes, which the server already does for agents that resend the same context; the layer keeps `cache_prompt` on).

## 3b. Why a bigger micro-batch costs K/V positions here: the attention mask

`bench/prefill_tiers.sh` (2026-10-05, `receipts/mirai-port/prefill_tiers.log`): micro-batch 512 -> 797-804 tok/s
with a 395 MiB compute buffer (11,324 MiB at load); 1024 -> 905-912 tok/s with 790 MiB (11,838); 2048 -> 1,580 MiB,
11,900 at load, and the prompt crawls at 48 tok/s: demotion again. The 128 MiB decode chunk (`GGML_MIRAI_LEVELS_MIB`)
at 1024 adds its workspace on top and also demotes (115 tok/s), so it is untestable at this line; it would need
~100 MiB of budget first. The step is the attention mask: an f16 tensor of `n_kv x n_tokens`
(`src/llama-graph.cpp`, `kq_mask`), reserved for the worst case, i.e. the full 262,144-cell window: 256 MiB per 512
tokens of micro-batch, 1 GiB at 2048. In a 64k window the same micro-batch of 1024 costs 406 MiB total, which is how
the tiered arms were misread as "tiered costs compute". Every 395 MiB is ~12k K/V positions, so +13% prefill for
-12k positions is not the product's trade; a compact mask (one bit, or one byte, per cell x token, expanded in the
flash-attention kernel's mask load) would make the 2048 micro-batch free and is the lever here. the earlier 262k
serve pays the same mask.

## 3c. Status 2026-10-05 11:00

Shipped in the launcher: the ffn one-plane prefill numerics (KL 0.00028 / 99.19%, computation family unchanged;
+18%) and the packed mask with a 1024 micro-batch (identity 3/3 on long prompts, compute 395 -> 310 MiB, +14%).
Expected together ~1,050 tok/s at the product configuration against 790 yesterday; the receipt follows the soak.
Still open from the plan: the level-decode kernel (fixed ~100 ms per micro-batch), the int32 combine (~40 ms,
memory-bound), the ~155 MiB per 512 tokens of non-mask activation state that keeps 2048 over budget, and the
remaining 38% (GDN scan, attention, quantizer).

**16:15, the level-decode chunk.** Sweeping `GGML_MIRAI_LEVELS_MIB` at the product configuration (16.8k prompt,
`receipts/mirai-port/levels_chunk.log`): 8 / 16 / 24 / 32 / 64 / 128 / 256 MiB = 936 / 956 / 1016 / 1046 / 1090 /
1103 / 1098 tok/s. Monotonic up to 128 and flat after, so the "fit the chunk in L2" idea was wrong: the cost is the
number and shape of the per-chunk GEMMs, not the level read-back. 64 MiB is the product default (+4%, +48 MiB of
VRAM, about 1,400 positions off the line; `MIRAI_LEVELS_MIB`). The in-register tensor-core path for the whole
micro-batch (`GGML_MIRAI_MMA_TOKENS=1024`, no level materialization, re-decodes per tile) measured 760 tok/s, 28%
below the two-plane GEMM path, so it stays the under-384-token path.

**18:30 to 20:00, what the GEMM leaves.** The cuBLASLt int8 GEMM measures 191-233 TOPS against the 4070's 233
dense peak (phase receipt of 09:46), so the GEMM is done, and an attempt to hide the level decode and the combine
behind it on side streams bought nothing (identity 3/3, prefill 0 to -2.5%: the GEMM occupies every SM;
`GGML_MIRAI_PIPELINE=1` keeps the code for other cards). The clean op table at the product configuration
(`receipts/mirai-port/op-timing-prod1024-ffn-packed.txt`) puts a 1024-token micro-batch at ~870 ms: trellis matmuls
51% (GEMM ~36%, decode ~12%, combine ~5%), gated delta net 11%, flash attention 11%, the activation quantizer 9%,
elementwise ~18%. Ceiling on this card with this codec: ~2.8x if everything but the GEMM were free; the levers that
remain are each a few percent.

*The quantizer (9%)*: `transform<1024, 17>` (the FFN down-projection input, K = 17,408) compiles to 127 registers
and 40.6 KB of shared memory at 512 threads, which is one block per SM (16 warps, 25% occupancy) with two
`__syncthreads` per rotated column, 34 per token; `transform<1024, 5>` sits at 51 registers and two blocks per SM.
The op averages ~0.31 ms per call against a bandwidth floor of 0.04-0.14 ms. The fix that keeps the numerics
bit-identical: two passes (rotation for the max, then rotation again for the quantization, same butterfly order), so
`out[ORDER][PER]` leaves the registers, with the per-column shared-memory transposes batched eight columns at a time
through the `staged` buffer in pass one and three at a time through a 12 KB scratch in pass two: ~18 syncs and two
blocks per SM instead of 34 and one. Expected: the K = 17,408 call ~2x, the op -25-30%, prefill +2-3%. Deferred
behind the micro-batch and the decode-side work for that reason.

*The 2048 micro-batch*: halves the decode and combine share per token for ~310 MiB of compute buffer (~9,300 q8_0
positions off the VRAM line); `bench/ub2048_probe.sh`, budgeted in the launcher as `MIRAI_UBATCH=2048`.

*The decode write path (12%)*: `levels` writes one 16-byte store per lane per packet across 32 rows, so a warp's
store instruction touches 32 half-used sectors; a shared-memory transpose to row-contiguous 512-byte stores is the
candidate, bounded by the 27 GB of int8 the GEMM must read back anyway (54 ms per micro-batch at 504 GB/s against
~200 ms measured for the decode phase).

## 4. Plan, in order of cost, each with its gate

1. **Config (today, `bench/prefill_tiers.sh`)**: DONE, see 3b: 1024 gives +13% for 395 MiB, 2048 and the larger
   decode chunk demote the card at this line. Which made the packed mask the enabler.
1b. **Packed (1-bit) attention mask** (engine, `--kq-mask-packed`, DECISIONS 11:10): the KQ mask becomes
   `GGML_TYPE_I32` with 32 cells per word for flash-attention micro-batches of 32+ tokens; the cache fills bits with
   the same predicate, the CPU attention reads bits, and in CUDA the tensor-core kernel reads them natively (the
   negative word stride carries the flag through the tile functions, the mask loader expands bits into its f16
   shared-memory tile, the KV-max scan tests words for zero); the vec and tile kernels get an f16 copy expanded per
   op. Reserved mask memory at 262k: 256 MiB per 512 tokens of micro-batch -> 16 MiB, so the 2048 micro-batch costs
   64 MiB of mask instead of 1 GiB, and at 512 about 240 MiB return to the line (~7k positions). Gate: identity on
   long prompts (0.6k / 2.4k / 9k tokens) against the f16 mask at 512 and 2048, compute buffer and VRAM at load,
   prefill at 2048, then the margin soak at the new line before the launcher's constants move.
2. **Level decode once per layer per prompt, not per micro-batch** (engine): the fixed 200 ms is the decode of all
   weights, repeated for every 512-token micro-batch of the same prompt. Keeping decoded int8 levels is 27 GB (no),
   but a larger effective micro-batch inside the op is the same thing: process the whole batch (`-b`) per weight
   chunk rather than per `-ub` slice. The server already feeds 2048-token batches; the split into 512 ubatches is
   the memory module's. Expected: the fixed cost amortized 4x. Gate: identity, VRAM, prefill by prompt length.
3. **One-plane int8 activations for the prefill GEMM only** (engine, numerics change). DONE as an opt-in mode
   (`GGML_MIRAI_PREFILL_PLANES=1`, DECISIONS 09:50): prefill 787-796 -> 992-993 tok/s (+26%) at mean KL 0.00075,
   median 0.00028, top-token agreement 98.86% (1 flip in 88) on 16k calibration tokens; the control run shows the
   harness floor is nil. The pre-registered bar for default adoption was KL <= 0.001 (met) and agreement >= 99.0%
   (missed by 0.14 pp), so it is a mode, not the default. The FFN-only variant (`=ffn`, both planes kept for the
   attention projections whose K/V persist): 939 tok/s (+18%) at KL 0.00028, median 0.00013, agreement 99.19%,
   which clears both thresholds; the suite's computation family on that setting is the remaining half of its gate
   (`bench/run_ffn_gate.sh`). The measurement also recalibrates the accounting: the two-plane GEMM was ~41% of
   prefill; the per-micro-batch level decode and plane/output kernels are the other ~21% of the "trellis matmul"
   share (per-phase timing: `GGML_MIRAI_TIMING=1`, `bench/prefill_phase_timing.sh`).
4. **Level decode kernel throughput** (engine): 27B parameters in ~200 ms is 135 G/s; the decode-time `gemv` path
   streams the same codes at memory speed. Expected: the fixed cost down to ~80 ms. Gate: identity (the levels are
   deterministic), prefill at 512.
5. **The other 38%**: GDN chunked scan at prompt width, attention at 512 queries, the quantizer's rotation. Each is
   a profile-then-kernel item; none is worth touching before 1-4.

What it would add up to, if every expectation holds: ~1.6-1.8k tok/s, a 100k prompt in about a minute instead of
two, with decode and the window unchanged. What it will not do: pass the card's dense ceiling. The first-token wait
on very long prompts is a property of 27B parameters on a 4070; the lever past this plan is caching, not kernels.
