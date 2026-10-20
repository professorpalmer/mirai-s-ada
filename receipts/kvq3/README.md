# Mirai: q3_0 K/V as the default? (2026-10-19, overnight)

Plan written before the runs.

## Question

`MIRAI_CTK=q3_0` (since bundle-20261016) puts 2.9x the positions in VRAM (167,680 against 58,624 for q8_0 at the
time) and decodes 2.8-3.8x faster at 128k-245k (61.6 / 51.3 / 36.9 against 21.7 / 12.9 / 9.6 tok/s). Its task checks
then: exact code copies 20 / 20 and fact lookups 24 / 24 at 245k (the same as q8_0), HumanEval 157 (q8_0 158),
perplexity +0.87 % at 2k. It stayed opt-in because its per-token divergence from an f16 cache is higher than q8_0's.
Bonsai's 12 GB preset made the same kind of switch (q8_0 -> q4_0) after task-level gates. Does q3_0 hold on the agent
and coding work, so that it can be Mirai's default?

## Setup

RTX 4070 12 GB, the bundle-20261019c zip root (replay on, tail 4), the layer on (as shipped), thinking at medium.
Arms in this order: **q8** (the default) and **q3** (`MIRAI_CTK=q3_0`), one server per arm.

1. HumanEval 164 at medium through the layer (`bench/humaneval_wasi.py --arm medium --max-tokens 24576`), as the
   release regression runs it.
2. The suite's frozen plan, 37 items (the ML1 / ML2 seeds), through the layer only (`suite/run_suite.py --base :8080`).

## Gates (declared before the runs)

| Gate | Condition |
|---|---|
| Q1 | HumanEval 164: q3 >= q8 - 2 |
| Q2 | the suite: q3 >= q8 - 2 items |
| Q3 | carried from bundle-20261016: 245k copies 20 / 20 and lookups 24 / 24 with q3_0 |
| Q4 | 0 CUDA errors; no spill line; every request answered |

Q1-Q4 pass: the next Mirai bundle sets q3_0 as the default K/V type (`MIRAI_CTK=q8_0` keeps the previous one). Any
fail: q8_0 stays the default; q3_0 stays the long-context option.

## Result (2026-10-19 20:05-23:34, `kvq3.log`)

| | q8 (default) | q3 (`MIRAI_CTK=q3_0`) |
| --- | ---: | ---: |
| VRAM line (positions) | 67,328 | 188,416 |
| Q1 HumanEval 164, medium, through the layer | 161 | **156** |
| Q2 suite, 37 items, through the layer | 27 | 26 |
| - coding (12) | 3 | 5 |
| - computation (15) | 14 | 15 |
| - workspace (10) | 10 | **6** |
| completion tokens (suite) | 370,215 | 364,643 |
| Q4 CUDA errors / spill | 0 / 0 | 0 / 0 |

- Q1 FAIL: 156 against 161 (-5; at most -2). q3 lost HumanEval/32, /108, /118, /120, /150 and won none.
- Q2 pass on the total (26 against 27), but the split is not neutral: workspace (multi-step tool work) 10 -> 6.
- Verdict: **q8_0 stays the Mirai default.** q3_0 stays the long-context option (`MIRAI_CTK=q3_0`), with its cost now
  measured on code and tool work, not only on lookups. Receipts: `scoreboard_*.md`, `results_*.jsonl`, `humaneval_*.json`.
