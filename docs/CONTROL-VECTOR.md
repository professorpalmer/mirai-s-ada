# Removing refusals at run time: alesha-pro's control vector (optional, off by default)

Written by [alesha-pro](https://github.com/alesha-pro), the author of the GGUF conversion, its ggml codec and the
reference fork this serve was built from (the model itself is Mirai Labs' Qwen3.8-27B-S),
and contributed in [pull request #1](https://github.com/professorpalmer/mirai-s-ada/pull/1) together with the
engine's projection mode (`--cvec-mode project`,
[llama.cpp-ada-mirai#1](https://github.com/professorpalmer/llama.cpp-ada-mirai/pull/1)). The measurements below are
alesha-pro's, on an RTX 3090 under Ubuntu 22.04; the method and the per-run counts are in
[`receipts/ubuntu-3090/`](../receipts/ubuntu-3090/). Nothing changes unless you pass the file.

What this repository has and has not checked: the engine change is merged, and greedy identity against the fork's
dump is unchanged without the flag (5/5 on the RTX 4070). The long exact-work suite and HumanEval have **not** been
run with the vector on either card; the quality cost known so far is alesha-pro's KL (0.019 on prose, 0.009 on code)
and five agent tasks. It is a documented mode, not a default and not a measured-quality claim. What the model
writes with the vector on is the user's responsibility.

Mirai S refuses like its base model. The weights are trellis codes, so the usual abliteration (editing the matrices)
cannot be written back. alesha-pro measured the refusal direction on the quantized model itself and published it as a
1.3 MB control vector next to the weights; the engine removes it from the residual stream after every layer at run
time (`h -= (h.v) v`, `--cvec-mode project`). Nothing changes unless you pass the file.

```bash
hf download alesha-pro/Qwen3.8-27B-S-mirai-GGUF Qwen3.8-27B-S-mirai-refusal-direction.gguf --local-dir models
MIRAI_CVEC=models/Qwen3.8-27B-S-mirai-refusal-direction.gguf ./start-server.sh
```

On any platform it is two more arguments on the `llama-server` line:
`--control-vector-scaled models/Qwen3.8-27B-S-mirai-refusal-direction.gguf:1.0 --cvec-mode project`
(`start-server.ps1` does not pass them yet; `start-server.sh` does, via `MIRAI_CVEC`). The reference fork `alesha-pro/llama.cpp-mirai-s` takes the same two arguments.

Measured by alesha-pro on this serve (Ubuntu, RTX 3090, the template's system block in every prompt;
`receipts/ubuntu-3090/abliteration.md` has the method, `refusal-counts.jsonl` one line per run).
A refusal is a regex on the start of the answer, greedy unless marked sampled:

| | without the vector | with the vector |
| --- | ---: | ---: |
| 64 harmful instructions (AdvBench, not used for the direction), thinking off | 64 refused | **0** |
| 82 held-out behaviours (JailbreakBench, non-AdvBench rows), thinking off | 78 | **0** |
| 24 harmful instructions, thinking on | 23 | **1** |
| 10-prompt probe, sampled, thinking off / on | 10 / 8 | **0 / 0** |
| 32 ordinary instructions refused | 0 | 0 |
| KL to the model without the vector, prose / code | | 0.019 / 0.009 |
| same top token as without the vector, prose / code | | 94.0% / 97.1% |
| decode tok/s on short prompts, thinking off / on (MTP acceptance) | 69.9 / 67.4 (71% / 65%) | 69.7 / 67.2 (70% / 66%) |
| decode at 60k / 120k / 180k | 27.9 / 9.5 / 5.8 | 27.8 / 9.4 / 5.9 |
| 5 agent coding tasks through a harness, original tests | | 5 of 5 (one on a second run: the first hit its 10 minute cap) |

Tool calls, the three effort words and an image request (encoder on the CPU, `MIRAI_MMPROJ`) were checked with the
vector on. Limits: the counts are a regex over 10 to 82 prompts, not a human read; the direction was measured with this
repo's template and with the GGUF's own, with and without a system message, thinking on and off, and a very different
system prompt may leave more refusals; quality with the vector was checked by KL and the agent tasks, not by the suite.
What the model writes with the vector on is the user's responsibility.

