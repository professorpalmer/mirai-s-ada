# Mirai S 27B on a 12 GB card: the full 262k window, drafting at every depth, and the layer

[Mirai S](https://huggingface.co/alesha-pro/Qwen3.8-27B-S-mirai-GGUF) (Qwen3.8-27B-S, trellis codes, ~2.4 bits of
information per weight, 11.17 GB) served on an **RTX 4070 12 GB** with the **full 262,144-token trained window at q8_0
KV cache**, MTP speculative decoding from the GGUF's own draft block at every depth, harness-proofing for the apps
that send `effort: "high"` or tiny output caps, and an optional server-side layer (exact API cards, an API check, a
sandboxed Python tool). Same weights as published; every kernel checked greedy token-for-token against the model's
own llama.cpp fork before anything else was measured. This is a serving layer on top of alesha-pro's work, not a
replacement for it: the codec, the model and the reference fork are theirs; the cache, drafting, server flags and
measurements here are what a 12 GB card adds around them.

| RTX 4070 12 GB, served, one slot | alesha-pro's reference fork (`llama.cpp-mirai-s`, the starting point) | this serve |
| --- | ---: | ---: |
| context window with q8_0 KV | 64k (11.0 GB) | **262,144** (tiered: ~58k positions in VRAM, the rest in pinned RAM) |
| decode, tok/s, at 0 / 16k / 60k / 120k / 180k | 40.0 / 38.1 / 33.5 (60k) / - / - | **76.6 / 72.6 / 61.7 / 19.5 / 11.4** (60k is inside the VRAM line since 10-06 evening; 40.3 before) |
| prefill, 16.8k-token prompt | ~1,000 | **1,090** (2048 micro-batch mode: 1,148) |
| speculative decoding | none | MTP draft at every depth, outputs identical to drafting off |
| HumanEval 164, greedy, tests executed in a sandbox | | **158** at medium or at effort "low"; 154 thinking off |
| long exact-work suite, 37 tasks, raw / behind the layer | 13 / 30 (on the reference fork) | **18 / 28** (12 rescues, 2 losses); coding family over two seed sets 7 / **12** of 24, at effort "low" 6 / 8 of 12 |
| apps that send `effort: "high"` | template error on every request | answered (normalized to medium) |

Receipts for every row are in `receipts/mirai-port/` and `bench/`; how each number was obtained, and what did not
work, is in `docs/REPORT.md` and `docs/PREFILL.md`. Numbers are from 2026-10-05/06 (decode by depth: 10-06 evening, `receipts/mirai-port/decode_by_depth.log`), GDDR6X at stock clocks, display on
the CPU's integrated GPU (see "Getting more positions into VRAM").

![Built so the agent loop finishes: window, depth, effort words, output caps, forced close, API check, sandboxed Python, effort low](docs/img/agentic.png)

## Quick start (Windows, NVIDIA)

1. Download `mirai-s-bundle-win-x64.zip` from [Releases](../../releases) and unzip into this repo (it fills `bin\`),
   or build it (below). The binaries carry sm_89 machine code (RTX 40) and need only the NVIDIA driver.
2. Put `Qwen3.8-27B-S-mirai.gguf` from [alesha-pro on Hugging Face](https://huggingface.co/alesha-pro/Qwen3.8-27B-S-mirai-GGUF)
   in `models\`. The MTP draft block ships inside that file; nothing is grafted.
   Optional, two minutes on the CPU (needs `numpy` and the `engine` submodule, or `pip install gguf`):

   ```powershell
   python tooling\requant_mtp.py models\Qwen3.8-27B-S-mirai.gguf models\Qwen3.8-27B-S-mirai-mtpq4.gguf
   ```

   writes a copy with only the MTP draft block requantized Q8_0 -> Q4_0 (every other tensor byte-identical). The
   launcher prefers that copy when it is present: 204 MiB more K/V in VRAM (~6k positions), outputs identical by
   construction (speculation is exact), draft acceptance 77.7% vs 78.2% (`receipts/mirai-port/mtp_q4_probe.log`).
3. Optional, once: `layer\fetch_runtime.ps1` downloads the sandbox runtime (CPython 3.12 on WASI, checksummed) and runs
   its isolation canaries. Without it the plain server starts.
4. Serve:

   ```powershell
   .\start-server.ps1
   ```

   OpenAI-compatible API on `http://<host>:8080/v1`, bearer key in `artifacts\api_key.txt` (created on first run).
   The launcher reads free VRAM, keeps a safety margin below the point where Windows demotes a background process's
   memory, and puts as many positions of the 262k cache in VRAM as fit (57,856 headless on this card with the
   Q4 draft-block copy, ~51k with the published file). It prints the line it chose.

![Speed: the full 262k window and drafting at every depth on the same card](docs/img/speed.png)
![Quality: the same model answers more, with the layer and the right settings](docs/img/quality.png)

## Recommended settings

- **Chat, coding answers, anything behind the layer**: the defaults (medium reasoning, 20k thinking budget, layer on).
- **Coding agents that run their own tools** (Cline, Kilo, OpenHands-style loops against `127.0.0.1:18080`, or the
  layer with `"api_cards": false`): send `reasoning_effort: "low"`, and launch with `MIRAI_EFFORT_ALLOWED=low,medium`
  so the server lets it through. Measured on the suite's coding family, raw: 4 -> 6 of 12 at the same seeds, the MIME
  task 0 -> 4 of 4, HumanEval unchanged at 158/164; the cost is longer tool loops (+31% completion tokens).
- **Sessions that stay under ~28k tokens and want the fastest decode**: `MIRAI_SPEC_TYPE=dflash` with the Q4_0
  DFlash drafter from `ggml-org/Qwen3.8-27B-GGUF` in `models\`. Measured (E22, three runs): 86 / 78 tok/s at 0 / 16k
  against 76 / 72 with the MTP block, greedy outputs identical, acceptance 70% at draft 3; drafts of 4 or more lose.
  It costs ~17k of the ~58k positions in VRAM, which is why the default keeps the MTP block for long agent sessions.
- **Tool-heavy agents that want speed over depth**: `chat_template_kwargs: {"enable_thinking": false}` per request
  (HumanEval 154/164 at 0.19x the tokens).

## Knobs (environment variables)

| Variable | Default | |
| --- | --- | --- |
| `MIRAI_CTX` | 262144 | context window |
| `MIRAI_CTK` | q8_0 | K/V cache type |
| `MIRAI_TIER` | 1 | 0 = all-VRAM cache (then a 64k window) |
| `MIRAI_KV_VRAM_CELLS` | auto | pin the VRAM line |
| `MIRAI_VRAM_MARGIN` | 800 headless / 1300 with the display on this card | MiB kept free below the demotion point |
| `MIRAI_SPEC` / `MIRAI_SPEC_DEEP` | 2 / 2 (3 with dflash) | draft size, and past the VRAM line |
| `MIRAI_SPEC_TYPE` / `MIRAI_DRAFTER` | mtp / `models\dflash-Qwen3.8-27B-Q4_0.gguf` | `dflash` drafts with ggml-org's DFlash drafter instead of the GGUF's MTP block: +13% decode at depth 0, +8.5% at 16k, outputs identical, ~590 MiB more VRAM (~17k fewer positions in VRAM). Download the drafter from `ggml-org/Qwen3.8-27B-GGUF` into `models\` |
| `MIRAI_DRAFT_WINDOW` | 16384 | rows the draft block keeps |
| `MIRAI_EFFORT` / `MIRAI_EFFORT_ALLOWED` | medium / medium | server default effort; effort words the template sees (others become medium) |
| `MIRAI_THINK` / `MIRAI_THINK_BUDGET` | 1 / 20480 | thinking on; tokens before a forced close |
| `MIRAI_HARNESS_PROOF` | 1 | 0 = pass effort words and output caps through unchanged |
| `MIRAI_PREFILL_PLANES` | ffn | prompt-token numerics: `ffn` (one int8 plane for the FFN matmuls, +18% prefill, KL 0.00028), `2` exact, `1` one plane everywhere |
| `MIRAI_KQ_MASK_PACKED` / `MIRAI_UBATCH` | 1 / 1024 | 1-bit attention mask; micro-batch (2048 = +5.6% prefill for ~570 MiB of VRAM) |
| `MIRAI_LEVELS_MIB` | 128 | level-decode chunk footprint for long prompts |
| `MIRAI_SHARED_POOL` | 1 | one transient CUDA pool for the target and draft contexts, 256-token draft micro-batch: 188 MiB of VRAM back (~5.7k positions), outputs, decode and acceptance unchanged (E23); 0 reverts |
| `MIRAI_LAYER` | 1 | 0 = no layer |
| `MIRAI_STDERR_FILE` / `MIRAI_RESTARTS` | none / 3 | keep the server's raw stderr in this file (assert text); restarts after an abort before the launcher gives up |
| `MIRAI_PORT`, `MIRAI_MODEL`, `MIRAI_LOG_FILE` | 8080, auto, none | model: `models\Qwen3.8-27B-S-mirai-mtpq4.gguf` when present, else the published file |

### Getting more positions into VRAM

Every GB of VRAM the desktop does not use is ~30k more q8_0 positions at full speed. Run the display from the CPU's
integrated graphics and set GPU-accelerated apps to it in Windows **Settings > System > Display > Graphics**; the
launcher's margin drops from 1300 to 800 MiB headless.

### Why the VRAM line is ~58k and not more

Mirai keeps 8,016 MiB of weights resident (8,220 with the published file: its MTP draft block at Q8_0 is 204 MiB
more than the Q4_0 copy); drafting keeps one 150 MiB snapshot of the recurrent state per unit of rollback depth (two
at the default draft 2) plus ~480 MiB for the draft context once it shares the transient pool. Each q8_0 position is
34,816 bytes, so every 100 MiB is ~3k positions. Past the line every step reads the host tail over PCIe; drafting
there is worth 2.2x over no drafting. `MIRAI_SPEC=0` moves the line to ~80k positions at the cost of the 1.85x below
it (`docs/REPORT.md`, sections 5b and 6e).

## Known limits and issues

- **12 GB is the floor.** 8.2 GB of weights stay resident; this model does not fit an 8 GB card, and the launcher
  does not try.
- **Past the VRAM line decode is PCIe-bound** (~58k positions on a 12 GB card with the display on the iGPU; see the
  decode table). A 16 GB card moves the line to ~180k by the launcher's arithmetic; not measured here.
- **Prefill sits at the card's int8 ceiling.** The trellis level decode plus the int8 GEMM run at 191-233 TOPS of the
  233 dense peak; ~1.1k tok/s on a 16.8k prompt is what this card does with these weights, and overlapping the level
  decode behind the GEMM measured 0 to -2.5% (`docs/PREFILL.md`). The remaining levers are each a few percent.
- **K/V stays q8_0.** A q4_0 cache (`MIRAI_CTK=q4_0`) would put about twice the positions in VRAM; its quality cost
  on this model is not measured here, so it is a knob, not a default.
- **Host RAM**: the full 262k cache keeps ~7 GB of K/V in pinned system RAM; the box needs that much free.
- **One slot** (`-np 1`), as the reference fork also requires for this model.
- **Two launchers.** `start-server.ps1` (Windows) sizes the VRAM line and starts the layer. `start-server.sh` (Linux)
  starts the raw server with the line you give it; the layer in front of it on Linux is not wired or tested.
- **Effort words outside the allow-list are normalized to medium** by design (harness-proofing). Agents that want
  "low" need `MIRAI_EFFORT_ALLOWED=low,medium` at launch; a request's effort is never silently honored or rejected,
  it is mapped, and the server log says so.
- **Prompt numerics are one-plane for the FFN matmuls by default** (KL 0.00028 against exact, top-token agreement
  99.2%, no suite pair moved). `MIRAI_PREFILL_PLANES=2` gives the exact path at -18% prefill.
- **Library-heavy coding tasks remain hard for the model** (the suite's MIME task passes only raw at effort "low");
  the layer's API check reduces invented names, it does not remove the model's limits.
- **Sampled runs are deterministic for an identical request and seed**, with rare late divergence under cache
  reuse (one in twelve 70k-character traces); treat small paired deltas as noise (`docs/REPORT.md`, determinism probe).
- **One abort seen, not reproduced.** On 10-06 evening a 180k-token request ended llama-server with an assert-style
  fail-fast once; the same request, the same sequence of requests and the bare server at 120k/180k then ran clean
  four times (`docs/REPORT.md` 6e). The launcher now supervises the server: an aborted server is restarted (up to
  `MIRAI_RESTARTS`, default 3, within ten minutes), the event is written to the launcher's output, and with
  `MIRAI_STDERR_FILE=logs\product.stderr` the server's raw stderr (where an assert prints) is kept.
- Report issues with the launcher's printed configuration block, `logs\product.log` and, if you set it,
  `logs\product.stderr`.

## What is here

| path | what |
| --- | --- |
| `engine/` | submodule: [`professorpalmer/llama.cpp-ada-mirai`](https://github.com/professorpalmer/llama.cpp-ada-mirai). PrismML's llama.cpp fork with the serving patches (tiered KV cache, draft window and tail, reasoning flags, batch-invariant kernels, op timing) and Mirai's codec ported on top (ggml types 90-93, CPU and CUDA kernels, rotation and scale tensors, split attention gate, graph hook), plus the prefill work done here (one-plane FFN prompt numerics, packed 1-bit KQ mask, level-decode chunking). |
| `start-server.ps1` | the launcher: sizes the VRAM line from measured fixed costs, starts the layer in front of llama-server. |
| `start-server.sh` | Linux (from alesha-pro): the raw server with the same flags; optional images (`MIRAI_MMPROJ`) and a control vector (`MIRAI_CVEC`, projected out of the residual stream). |
| `tooling/` | `build_engine.bat` (Ninja + pip CUDA 13, sm_89), `install_bin.ps1`, `serve.ps1` / `stop.ps1` (hidden test server, log and PID files). |
| `layer/`, `suite/` | the layer and the long exact-work suite, from [`bonsai-ada-surgery`](https://github.com/professorpalmer/bonsai-ada-surgery) with the changes made here (`layer/ORIGIN.md`). |
| `bench/` | the measurement scripts and every run's scoreboard and results (`ML1`..`ML2f`, `E18`..`E21`, HumanEval arms). |
| `receipts/` | small text receipts cited by the docs: profiles, greedy dumps from the model's fork, probe logs; `ubuntu-3090/` is alesha-pro's Linux check (RTX 3090). |
| `templates/bonsai-template.jinja` | the chat template used for every measurement (reasoning_effort, thinking on/off). |
| `docs/REPORT.md`, `docs/PREFILL.md`, `docs/ROADMAP.md` | what was found, the prefill investigation, what is left. |

## Build from source

Windows without the CUDA toolkit (VS 2022 Build Tools C++ workload + NVIDIA's pip wheels):

```powershell
python -m pip install cmake ninja nvidia-cuda-nvcc nvidia-cuda-runtime nvidia-cublas nvidia-cuda-nvrtc
git clone --recurse-submodules https://github.com/professorpalmer/mirai-s-ada
cd mirai-s-ada
tooling\build_engine.bat llama-server      # ~30 min first time
tooling\install_bin.ps1                      # copies the result into bin\ next to the CUDA runtime DLLs
```

Linux (checked on Ubuntu 22.04, RTX 3090, CUDA 12.8 toolkit, gcc 11.4, cmake 3.22; `receipts/ubuntu-3090/`):

```bash
git clone --recurse-submodules https://github.com/professorpalmer/mirai-s-ada && cd mirai-s-ada
cmake -S engine -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DLLAMA_CURL=OFF \
  -DCUDAToolkit_ROOT=/usr/local/cuda -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCMAKE_CUDA_ARCHITECTURES=86
cmake --build build -j --target llama-server            # about 4 min on 32 threads
hf download alesha-pro/Qwen3.8-27B-S-mirai-GGUF --local-dir models
MIRAI_KV_VRAM_CELLS=44000 ./start-server.sh             # raw server on http://127.0.0.1:8080/v1
```

Point both CUDA paths at a CUDA 12 or 13 toolkit. On this box an older system `nvcc` was first on the PATH and the
configure step failed without the compiler path; with a system cuBLAS 11 the int8 GEMM of the prompt path runs on a
tile about half as fast. `CMAKE_CUDA_ARCHITECTURES` is your GPU generation (86 = RTX 30, 89 = RTX 40); without it an
older cmake builds the kernels for every generation, which took 17 minutes here. A fresh clone of this branch was built that way
and served through `start-server.sh` as a last check.
`start-server.sh` is the raw server only: the same flags and environment as `start-server.ps1`, no layer, no automatic
sizing of the VRAM line (set `MIRAI_KV_VRAM_CELLS` for your card). The knobs table above applies; it also reads
`MIRAI_HOST`, `MIRAI_API_KEY`, `MIRAI_MMPROJ` (images, encoder on the CPU) and `MIRAI_CVEC` (below).

Measured by alesha-pro on that Ubuntu box with the 12 GB recipe of 10-06 morning (44,000 positions in VRAM, the
published GGUF, the card at 300 W, PCIe 3.0 x16; `receipts/ubuntu-3090/`):

| | Ubuntu 22.04, RTX 3090 |
| --- | ---: |
| greedy identity against the reference dumps, thinking off | 5 of 5 |
| thinking on (the 300-token reference is a prefix of the output) | 5 of 5 |
| VRAM at load / peak over a 180k-token prompt | 11,533 / 11,719 MiB |
| decode, tok/s, at 8k / 60k / 120k / 180k | 66.9 / 27.9 / 9.5 / 5.8 |
| prefill, 8k-token prompt | 1,124 tok/s |
| MTP draft acceptance, thinking off / on | 71% / 65% |

Past the VRAM line this box is slower than the RTX 4070 (27.9 against the 4070's 40.3 tok/s at 60k when its line
was also 44-45k; the 4070 now holds 60k inside the line, see the table at the top). The tail is read over PCIe 3.0
here; that is the likely reason and it was not isolated.

The flags behind the numbers are one `llama-server` command line:

```bash
llama-server -m Qwen3.8-27B-S-mirai.gguf -ngl 99 -fa on -c 262144 -np 1 -ctk q8_0 -ctv q8_0 --kv-vram-cells 44000 \
  -b 2048 -ub 1024 --kq-mask-packed \
  --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-n-max-tail 2 --spec-draft-window 16384 -ctkd q8_0 -ctvd q8_0 \
  --reasoning-effort-allow medium --reasoning-max-tokens-floor 24576 --reasoning-budget 20480 --backend-sampling \
  --chat-template-file templates/bonsai-template.jinja --chat-template-kwargs '{"reasoning_effort":"medium"}' --jinja
```

with `GGML_CUDA_BATCH_INVARIANT=1` and `GGML_MIRAI_PREFILL_PLANES=ffn` in the environment (`start-server.sh` sets both).

## Measure it yourself

```powershell
python bench\compare_servers.py --base http://127.0.0.1:18080 --against receipts\mirai-port\stock-greedy-nothink.json   # greedy identity vs the model's fork
bash bench\product_smoke.sh                                   # identity, layer round trip, decode by depth
bash bench\prefill_probe.sh                                   # prefill by prompt length
python suite\run_suite.py --base http://127.0.0.1:18080 --base-b http://127.0.0.1:8080 --out suite-out   # the paired suite
python bench\humaneval_wasi.py --arm medium                    # HumanEval 164, sandbox-scored
python bench\determinism_probe.py                             # same request and seed, seven conditions
```

## Licenses and attribution

- This repository (launcher, tooling, layer, suite, docs, receipts): MIT, Cary Palmer.
- The engine (`engine/`): llama.cpp is MIT (the ggml authors); PrismML's fork and alesha-pro's fork are MIT; their
  notices are preserved in the engine tree. The Mirai codec kernels are alesha-pro's work, ported with attribution in
  the commit history and `engine/README.md`.
- The model weights are not redistributed here. `Qwen3.8-27B-S-mirai-GGUF` is published by alesha-pro under the
  license on its Hugging Face card (Qwen3.8 itself is Apache 2.0); download it from there and keep its notices.
- Nothing here is affiliated with, endorsed by or sponsored by alesha-pro, PrismML or Alibaba's Qwen team.

## Credits

alesha-pro for the model, its codec and the llama.cpp fork it ships with, and for the refusal vector, the projection
mode and the Linux check. PrismML for the llama.cpp fork the engine
is built on. sudoingX for the planar activation layout and batch-invariant mode in that fork. MIT for everything here;
the weights are their authors'. Not affiliated with alesha-pro or PrismML.
