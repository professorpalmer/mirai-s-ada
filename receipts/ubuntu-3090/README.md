# Ubuntu 22.04, RTX 3090: the Linux check and the abliterated serve

2026-10-06, alesha-pro. One RTX 3090 (24 GB, power limit 300 W, PCIe 3.0 x16) held to the 12 GB recipe of this repo
(`--kv-vram-cells 44000`), EPYC 7642, 128 GB RAM, Ubuntu 22.04.5, kernel 5.15, driver 610.43.02, CUDA 12.8 toolkit,
gcc 11.4, cmake 3.22. Engine: `llama.cpp-ada-mirai` at 78c6a2ac7 plus the `--cvec-mode` commit, built for sm_86.
Model: `Qwen3.8-27B-S-mirai.gguf`, sha256 5aa4365c... (equal to the Hugging Face LFS object).

| file | what |
| --- | --- |
| `identity.log` | `bench/compare_servers.py` against `receipts/mirai-port/stock-greedy-*.json`, server started by `start-server.sh` without a vector. Thinking off: SAME 5 of 5. Thinking on: the server raises small output caps, so it writes past the 300-token reference; the reference is a prefix of the output in all 5 (the reported divergence is at its end). |
| `decode-by-depth.md` | VRAM at load and peak, decode and prefill at 8k / 60k / 120k / 180k, without and with the vector. |
| `abliteration.md` | how the direction was measured, the refusal counts, KL, draft acceptance, the agent tasks. |
| `refusal-counts.jsonl` | one line per run: label, prompt set, thinking, refused, empty. Counts only; the answers are not kept here. |

The vector: `Qwen3.8-27B-S-mirai-refusal-direction.gguf` in `alesha-pro/Qwen3.8-27B-S-mirai-GGUF`, 1,293,184 bytes,
sha256 3f3432d09822864e0bcb4aff27f52ef58424fa92734e352a6abe67c2b570d879.
