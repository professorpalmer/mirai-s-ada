# Research records and receipts

Each record below has its plan, its gates and its results. Numbers are from one RTX 4070 12 GB unless the record says
otherwise. The current results are in the topic pages: [speed](../speed/README.md), [quality](../quality/README.md),
[agents-layer](../agents-layer/README.md).

| Record | What |
| --- | --- |
| [REPORT.md](REPORT.md) | the full record, newest at the bottom: the port, MTP drafting, the tiered cache, the layer runs (ML1-ML2f, E18-E24), K/V precision, checkpoints, the example check, AppWorld, the kernel timeline |
| [PREFILL.md](PREFILL.md) | where the prefill time goes, the ceiling of the card, the plan and what each step gave |
| [ROADMAP.md](ROADMAP.md) | the open items on this card and the measurement that would prove each one |
| [HYPERQWEN.md](HYPERQWEN.md) | speed techniques from syv-ai/HyperQwen: what we tested and what we decided (2026-10-08) |
| [CONTROL-VECTOR.md](CONTROL-VECTOR.md) | alesha-pro's refusal-direction control vector: method, measurements, limits |

## Receipts

| Path | What |
| --- | --- |
| `receipts/mirai-port/` | probe logs, profiles, greedy dumps of the reference fork, the AppWorld log, the HumanEval log, K/V KL |
| `receipts/ubuntu-3090/` | alesha-pro's Linux check on an RTX 3090 and the control-vector measurements |
| `receipts/lookup_ab_mirai.jsonl` | lookup drafting A/B (bundle-20261008) |
| `receipts/tier_ab_mirai.jsonl` | prefill past the VRAM line A/B (bundle-20261008b) |
| `receipts/tools_ab_mirai.log` | 107 tools A/B (bundle-20261008c) |
| `receipts/pool_ab_mirai.log` | the shared CUDA pool A/B (bundle-20261008d) |
| `receipts/ram_ab_mirai.log` | system RAM sizing A/B (bundle-20261010) |
| `bench/<run>/` | the scoreboard and results of each suite run and HumanEval arm |

How to repeat the measurements: [quality](../quality/README.md#measure-it-yourself). What each bundle changed:
[RELEASE-NOTES.md](../../RELEASE-NOTES.md).
