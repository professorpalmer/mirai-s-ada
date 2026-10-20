# Quality: what the runtime controls, measured

![Quality on the RTX 4070 12 GB, q8_0 K/V. HumanEval 164 at medium: raw 159, through the layer 161. Effort low / thinking off: raw 158 / 154, layer with thinking off 153. Exact-work suite 37 tasks: raw 18, layer 28. Coding family 7 to 12 of 24, computation family 4 to 15 of 15. q8_0 against f16: same top token 99.64 %, KL 0.00050. q3_0: copies 20/20 and lookups 24/24 at 245k (raw), HumanEval 156 and workspace tasks 6/10 through the layer (q8_0: 161, 10/10). AIME and MMLU-Pro: not measured](img/quality.png)

All runs on one RTX 4070 12 GB. Plans and gates were frozen before the results. Tests are executed: HumanEval runs
each answer in a sandbox, and the suite checks the exact output of each task.

- [HumanEval 164](#humaneval-164)
- [The long exact-work suite](#the-long-exact-work-suite)
- [K/V cache precision](#kv-cache-precision)
- [Prompt numerics](#prompt-numerics)
- [Determinism](#determinism)
- [Not measured](#not-measured)
- [Measure it yourself](#measure-it-yourself)

## HumanEval 164

Greedy, tests run in a sandbox (`bench/humaneval_wasi.py`).

| Setting | Result | Source |
| --- | ---: | --- |
| medium, 20k thinking budget (the default) | 158 | `bench/humaneval/H0-medium-20k` (2026-10-05/06) |
| medium, 8k budget | 158 | `bench/humaneval/H1-medium-8k` |
| effort "low" (0.71x the tokens) | 158 | `bench/humaneval/H2-low-20k` |
| thinking off (0.19x the tokens) | 154 | `bench/humaneval/H3-off` |
| medium, bundle-20261013 (graph change) | 158, identical answers on all 164 | release notes, bundle-20261013 |
| medium, bundle-20261014 (long prefill on tensor cores) | **159** (the five fails are a subset of the old six) | release notes, bundle-20261014 |
| through the layer, medium | 158 | `receipts/mirai-port/humaneval.log` L0 (bundle-20261009) |
| through the layer, medium, example check on (the default) | **160** (HumanEval/59 and /162 fixed, none lost, +23 % completion tokens) | `receipts/mirai-port/humaneval.log` L1 (bundle-20261009) |
| through the layer, medium, bundle-20261019c (replay, a draft of 4 past the line) | **161** | [`receipts/kvq3`](../../receipts/kvq3/README.md) (2026-10-19) |
| through the layer, thinking off | 153, with and without the stray-tag filter | release notes, bundle-20261017c / 20261017d |
| `MIRAI_CTK=q3_0` | 157 (q8_0: 158) | release notes, bundle-20261016 |
| `MIRAI_CTK=q3_0`, through the layer, bundle-20261019c | 156 (q8_0: 161; lost /32, /108, /118, /120, /150) | [`receipts/kvq3`](../../receipts/kvq3/README.md) |

The bundle-20261014 change alters the float order of one prefill step, so long answers can differ in wording.

## The long exact-work suite

37 tasks in three families (coding, computation, workspace), paired runs with the same seeds, raw server against the
layer ([agents-layer](../agents-layer/README.md#the-layer)). Scoreboards: `bench/<run>/scoreboard.md`.

| Run | Raw | Layer | Rescues / losses | Tokens |
| --- | ---: | ---: | --- | ---: |
| ML1 (reference fork, no reasoning budget) | 13/37 | 30/37 | 17 / 0 | 488k -> 381k |
| ML2 (this serve, 10-04 defaults) | 16/37 | 29/37 | 13 / 0 | 486k -> 377k |
| ML2b (this serve, 10-05 defaults) | **18/37** | **28/37** | 12 / 2 | 508k -> 394k |

- Per family on ML2b (raw / layer): coding 4 / 3 of 12, computation 4 / 15 of 15, workspace 10 / 10 of 10.
- The coding family over two seed sets (E18 + ML2f, 24 runs): raw 7, layer **12** (tar 1 -> 5 of 8, ZIP 6 -> 7,
  MIME 0 -> 0).
- At effort "low" (ML2e-low, seeds 1-4): raw coding 4 -> 6 of 12, layer 8 of 12; the MIME task raw 0 -> 4 of 4.
- What did not work: a round-countdown note for tool loops (E19: read and ignored), and the layer without its "run it
  on the example" sentence (E21: 7 -> 4 of 12, so the sentence stays). Every layer variant failed the MIME task.

The full record: [REPORT.md](../research/REPORT.md) sections 6 to 6d.

## K/V cache precision

KL divergence by token against the same model with an f16 K/V cache. wikitext-2 test, 16,384-token chunks x 4, so
every scored token is at 8k-16k depth (`receipts/mirai-port/kv_kl.log`, 2026-10-09):

| K / V | Mean KL vs f16 | Top token the same | Max KL on one token | PPL vs f16 |
| --- | ---: | ---: | ---: | ---: |
| q8_0 / q8_0 (the default) | 0.00050 | 99.64% | 1.46 | +0.24% |
| q4_0 / q4_0 | 0.0243 | 97.10% | 22.6 | +0.9% |

q4_0 would fit about 2.3 times the positions in VRAM, but on this model it flips the top token on 1 position in 34
and puts single tokens far off. K/V stays q8_0, and `MIRAI_CTK=q4_0` is not recommended.

**The q3_0 option** (`MIRAI_CTK=q3_0`, bundle-20261016). Against the q8_0 default: exact code copies 20/20 and fact
lookups 24/24 at 245k (the same), HumanEval 157 (q8_0: 158), perplexity +0.87 % at 2k context. Its per-token
divergence from an f16 cache is higher than q8_0's. On bundle-20261019c through the layer
([receipts/kvq3](../../receipts/kvq3/README.md)): HumanEval 156 against 161, the 37-item suite 26 against 27, but
workspace tasks (multi-step tool work) 6 of 10 against 10 of 10. Thus it is an option for long-context work, not the default.
Speed: [docs/speed](../speed/README.md#the-long-context-option-q3_0).

## Prompt numerics

By default, prompt tokens use one int8 plane for the FFN matmuls (`MIRAI_PREFILL_PLANES=ffn`): +18 % prefill, KL
0.00028 against the exact path, top-token agreement 99.2 %, and no suite pair changed. `MIRAI_PREFILL_PLANES=2` gives
the exact path at -18 % prefill. Details: [PREFILL.md](../research/PREFILL.md).

## Determinism

The same request and seed gave identical output in seven cache and sampling conditions, through the layer too. 11 of
12 suite first turns were byte-identical. One late divergence occurred 35k characters into a 75k response. Treat
4-seed differences of 1 to 2 as noise (`bench/determinism_probe.py`, [REPORT.md](../research/REPORT.md) 6d).

## Not measured

- AIME and MMLU-Pro were not run on this serve ([REPORT.md](../research/REPORT.md) section 7).
- The suite and HumanEval were not run with the refusal-removal vector
  ([CONTROL-VECTOR.md](../research/CONTROL-VECTOR.md)).

Agent results (AppWorld, tool calls, edit calls): [agents-layer](../agents-layer/README.md#agent-results).

## Measure it yourself

Run these commands to repeat the measurements:

```powershell
python bench\compare_servers.py --base http://127.0.0.1:18080 --against receipts\mirai-port\stock-greedy-nothink.json   # greedy identity against alesha-pro's reference fork
bash bench\product_smoke.sh                                   # identity, layer round trip, decode by depth
bash bench\prefill_probe.sh                                   # prefill by prompt length
python suite\run_suite.py --base http://127.0.0.1:18080 --base-b http://127.0.0.1:8080 --out suite-out   # the paired suite
python bench\humaneval_wasi.py --arm medium                    # HumanEval 164, scored in a sandbox
python bench\determinism_probe.py                             # same request and seed, seven conditions
```

To measure decode by depth, do not ask the same prompts at several depths on one server from the deepest to the
shortest. Lookup drafting learns from the earlier answers, and the later (shorter) depths then show speeds that are
too high. Restart the server for each depth, or use a different prompt at each depth.
