# Decode and prefill by depth on Ubuntu (RTX 3090, 12 GB recipe)

`llama-server` with the README flags, 262,144 window, q8_0 K/V, 44,000 positions in VRAM, MTP draft 2 / tail 2,
`-b 2048 -ub 1024`, packed mask, `GGML_MIRAI_PREFILL_PLANES=ffn`. Each row is one cold request: a document of the
given length and a request for 10 bullet points, thinking off, greedy, 256 output tokens. Speeds are the server's own
timings; prefill is the average over the whole prompt. VRAM is `nvidia-smi` memory.used of the card minus what was
there before the start.

| prompt tokens | decode tok/s, no vector | decode tok/s, vector | prefill tok/s, no vector | prefill tok/s, vector |
| ---: | ---: | ---: | ---: | ---: |
| 8,095 | 66.9 | 63.0 | 1,124 | 1,130 |
| 60,096 | 27.9 | 27.8 | 667 | 743 |
| 120,096 | 9.5 | 9.4 | 409 | 489 |
| 180,097 | 5.8 | 5.9 | 330 | 393 |

The vector run also had the image encoder loaded on the CPU and ran while the other card was idle; the no-vector run
shared the box with an agent run on the second card, which is the likely source of its lower prefill.

VRAM: 11,533 MiB at load through `start-server.sh` (11,551 through a hand-written command line), 11,719 MiB peak
without the vector, 11,721 MiB peak with it. Host RAM holds the tail of the cache as in the README.

Short prompts (12 ordinary instructions, 400 output tokens, greedy, `start-server.sh`): 69.9 tok/s thinking off and
67.4 on without the vector (draft acceptance 71.5% and 64.8%); 69.7 and 67.2 with it (69.7% and 65.6%).

Against the RTX 4070 numbers of the README (40.3 / 16.6 / 10.3 tok/s at 60k / 120k / 180k) this box is slower past
the VRAM line. The cards sit on PCIe 3.0 here, and the tail is read over PCIe on every step; that is the likely
reason. It was not isolated.
