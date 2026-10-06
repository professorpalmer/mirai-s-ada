# Leftovers on this card, and what would prove each one

Status 2026-10-06 evening: items 1 (the pool and the draft micro-batch are defaults since E23, 188 MiB; the MTP
block's Q4_0 copy adds 204 MiB; the tail draft is 2), 2 (800 MiB headless adopted after the soaks), 3 (HumanEval
grid: medium or low 158, thinking off 154; "low" recommended for raw coding agents) and 4 (acceptance measured: 78% at
draft 2, DFlash 70% at draft 3; no on-policy head exists for this model) are closed in `docs/REPORT.md`. Items 5, 6
and 7 stand; item 5 is now the gate for ever shipping a q4_0 cache.

The stance: every number in `README.md` is a record, not a ceiling. Each item below names the translation layer it
lives in, the expected gain, and the paired measurement that gates it. Nothing ships on expectation.
Ordered by expected value per hour on the RTX 4070 12 GB. Updated 2026-10-04 23:00.

## 1. The recurrent rollback snapshots (speculation; 150 MiB = ~4.5k VRAM positions per unit of rollback depth)

Measured 2026-10-05 (DECISIONS 01:31): the MTP draft context itself costs 175 MiB (K/V 43, compute 118, pool 14);
sharing the pool and shrinking its micro-batch return 74 MiB together (identity 5/5, decode unchanged), under the
150 MiB gate, so `GGML_CUDA_SHARED_POOL=1` and `LLAMA_MTP_DRAFT_UBATCH=N` stay env options. The cost is elsewhere:
with speculation the hybrid memory keeps one full snapshot of the recurrent state (149.6 MiB on this model) per
draft position so a partially accepted draft can roll back: 449 MiB at draft 2, 748 MiB with the tail draft 4.
Levers, in order of cost to try: (a) the tail draft size past the line (`bench/tail_draft.sh`: positions bought
vs decode lost; a product decision with both numbers stated); (b) snapshot only the layers' state that the GDN
update actually changes per token (it changes all of it: no gain expected, verify once); (c) rollback by recompute
from one snapshot (a GDN-only pass over the accepted tokens; costs per step, probably a loss); (d) smaller
rollback depth below the line with a checkpoint fallback for the rare deeper rollback (the server has that path).
Gate as always: identity 5/5, decode by depth, VRAM at load, and the launcher's fixed cost re-measured.

## 2. The VRAM margin on Mirai (launcher; expected: +6k positions per 200 MiB)

1,000 MiB headless comes from the stack's earlier soaks (2026-09-27). Mirai's step pattern differs (bigger weights, smaller
cache). Proof: a 10-minute soak at 4k / 16k / 32k with the margin at 800 and 600, watching for demotion (decode
falling off a cliff, as the probe showed). Gate: no demotion at 800 over the soak on two runs; 600 is expected to
fail as it did there.

## 3. Reasoning budget and effort on Mirai (recipe; expected: quality, not speed)

Medium with a 20,480 budget and the forced close were tuned on the stack's previous model. On Mirai the
suite smoke shows raw runs thinking to the cap on hard items. Proof: HumanEval 164 on the inner port at medium /
low / off and budgets 8k / 20k / 32k (the same grid as before), then the suite's computation family at the two best
settings. Gate: a setting exceeds medium/20k by >= 3 HumanEval and does not lose a suite pair.

## 4. MTP acceptance (model-side; expected: +10-15% decode below the line, more above it)

Acceptance 73% at draft 2 with the GGUF's own head. On the stack's previous model an on-policy head over a teacher graft gave
+4.3 pp. Proof: acceptance by task family at draft 2/3/4 (receipt), then, if a better head exists or can be trained
on this model's own outputs (sudoingX's tools, the same recipe), the same identity + decode-by-depth arms as C.

## 5. K/V precision by position on this model (cache; expected: nothing to gain in VRAM, a quality receipt)

Measured before on this stack: q8_0 K/V flips 1 top token in 160 at depth vs 1 in 48 for q4_0 (KL by position). Mirai's attention layers are
the same shape; the receipt should be re-made here before anyone cites the 262k window as "lossless enough". A q4_0
cache would double the positions in VRAM (18,432 B per cell) at a measured quality cost; that trade is the user's,
once measured.

## 6. The F16 token embedding (2.4 GB in host RAM; expected: prefill, not VRAM)

Every prompt token's embedding row is gathered on the CPU and uploaded. At 933 tok/s plain prefill this is not the
bottleneck; measure its share with the op table at 2k / 16k prompts before touching it.

## 7. Beyond serving: our own quantization of this family

Everything above keeps the weights as published. The next class of leftover is the quantization itself: Mirai's
trellis codes sit at ~2.4 bits of information. What a 12 GB card wants is a 27B-class
model whose resident weights leave room for a long cache AND a draft head, i.e. a ~2 bpw codec with Mirai-class
quality. Prerequisites before any of this is more than a note: the teacher weights (Qwen3.8-27B), a calibration set
that is not the suite, a KL-by-position harness against the teacher (exists on this stack), and a quantizer we can run
(the Mirai codec's encoder is not public; PrismML's is). This is a project, not a leftover; it starts with the
harness, not with weights.
