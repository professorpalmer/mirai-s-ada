# Mirai: a draft of 4 past the VRAM line, with replay rollback (2026-10-19)

Plan written before the runs.

## Question

Past the VRAM line a decode step is PCIe-bound, so extra verify columns are nearly free. Before replay, each draft
token past the line cost a 150 MiB rollback snapshot, so `MIRAI_SPEC_DEEP` stayed at 2 (the launcher comment: 4 "buys
+20 % past it"). With replay on (the default since bundle-20261019b) a token costs ~8 MiB, so 4 past the line costs
~16 MiB more. Bonsai on 8 GB (AD1 / AD2, bonsai-ada-surgery docs/research/adaptive-mtp-20261019): a deeper draft past
the line gave +15-58 % at 128k. Is `MIRAI_SPEC_DEEP=4` faster on Mirai now?

## Setup

RTX 4070 12 GB, a clean unzip of mirai-s-bundle-win-x64-20261019b (replay on by default), layer off, the launcher's own
VRAM line (it includes the per-token cost). Arms: **d2** (the default, `MIRAI_SPEC_DEEP=2`) and **d4**
(`MIRAI_SPEC_DEEP=4`). Requests: the R2 set (story / code / quote, greedy and temperature 0.8, 300 tokens, thinking off)
at 4k, 64k, 128k and 200k; one server per arm.

## Gates (declared before the runs)

| Gate | Condition |
|---|---|
| G1 | 128k and 200k: the mean of the story / code / quote means is at least 8 % above d2 at both depths |
| G2 | 4k (below the line, the same draft size): no prompt type more than 5 % below d2 (a noise check) |
| G3 | 0 CUDA errors; every request answers; free VRAM at or above 100 MiB during the requests |

G1-G3 pass: the next Mirai bundle sets `MIRAI_SPEC_DEEP` to 4 with replay on. Any fail: 2 stays.

Amendment (2026-10-19 16:00, after the run started, before any result): G2 widened from 2 % to 5 %. Reason: the
Bonsai AD3 run of the same day showed up to 5 % run-to-run noise per prompt type with the same draft size and this
request set (bonsai-ada-surgery docs/research/adaptive-mtp-20261019, AD3). G1 (8 %) is above that noise and stays.

Deviation (2026-10-19 17:33): the run was paused after arm d2 (24 records, 0 CUDA errors, no spill, lowest free VRAM
358 MiB), because each request reads its whole prompt (128k: ~285 s, 200k: ~595 s), so the two arms take ~3.5 h, and
the Bonsai 8 GB release (higher priority) waited on the GPU. Arm d4 runs alone after the release (the same root,
requests and log). The two arms are then about 2 h apart on the same machine; the gates stay as declared.

## Result (2026-10-19 19:51)

d2 15:54-17:33, d4 18:13-19:51 (the d4 arm ran alone after the pause; the line was 67,840 for d2 and 67,328 for d4:
the two extra replay tokens). Decode tok/s, the mean of greedy and temperature 0.8:

| depth | story d2 | story d4 | code d2 | code d4 | quote d2 | quote d4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 4k | 56.4 | 55.2 (-2.1 %) | 62.8 | 63.0 (+0.3 %) | 90.9 | 92.1 (+1.4 %) |
| 64k | 43.9 | 39.8 (-9.5 %) | 55.0 | 59.6 (+8.3 %) | 71.2 | 83.2 (+16.9 %) |
| 128k | 13.2 | 13.3 (+0.2 %) | 15.9 | 19.2 (+20.7 %) | 22.0 | 28.3 (+28.5 %) |
| 200k | 6.4 | 7.0 (+9.0 %) | 8.4 | 10.3 (+22.6 %) | 10.3 | 13.7 (+33.2 %) |

- G1 PASS: the mean of the three means is +18.8 % at 128k and +23.5 % at 200k (+8 % required at both).
- G2 PASS: at 4k the worst prompt type is -2.1 % (-5 % allowed).
- G3 PASS: 0 CUDA errors, no spill line, 24 / 24 requests per arm answered, lowest free VRAM 358 MiB (d2) / 408 MiB (d4).
- Note: 64k is below the line in both arms (the same draft size), and story still differs by -9.5 %: the run-to-run
  noise of single requests is larger here than the 5 % seen on Bonsai (AD3). The gated gains are above it.
- Verdict: **the next Mirai bundle sets `MIRAI_SPEC_DEEP=4` when replay rollback is on.**
