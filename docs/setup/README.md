# Set up and run Mirai S on a 12 GB card

This page tells you how to start the server, which settings to use, and what limits the card has.

- [What you get](#what-you-get)
- [Quick start (Windows, NVIDIA)](#quick-start-windows-nvidia)
- [Quick start (Linux, from alesha-pro)](#quick-start-linux-from-alesha-pro)
- [Remove refusals (optional, from alesha-pro)](#remove-refusals-optional-from-alesha-pro)
- [Recommended settings](#recommended-settings)
- [Settings (environment variables)](KNOBS.md)
- [Get more positions into VRAM](#get-more-positions-into-vram)
- [Why the VRAM line is where it is](#why-the-vram-line-is-where-it-is)
- [Known limits and issues](#known-limits-and-issues)

## What you get

[Mirai S](https://huggingface.co/trymirai/Qwen3.8-27B-S-experimental) is a version of Qwen3.8-27B from
[Mirai Labs](https://trymirai.com). Mirai Labs compressed the model with their trellis codec to approximately 2.4 bits
of information for each weight. alesha-pro converted the model to
[GGUF](https://huggingface.co/alesha-pro/Qwen3.8-27B-S-mirai-GGUF) (11.17 GB) and ported the Mirai S codec to
llama.cpp.

This serve adds these items:

- The **full 262,144-token trained window with a q8_0 KV cache**.
- **MTP speculative decoding at every depth**. The draft block is in the GGUF.
- **Harness-proofing** for apps that send `effort: "high"` or very small output caps.
- An optional **server-side layer**: exact API cards, an API check and a sandboxed Python tool
  ([agents-layer](../agents-layer/README.md)).
- **Lookup drafting** in front of the draft block (on by default): text that is already in the context is drafted up
  to 32 tokens at a time. File rewrites are 3 to 4 times faster (130k: 20.1 -> 84.9 tok/s), new text is unchanged, and
  so is the output.
- **Prefill past the VRAM line without a fixed extra cost**: new K/V rows go to VRAM first and then to system RAM in
  whole blocks. A 130k prompt: 509 -> 639 tok/s.
- **Many tools cost no decode speed** (bundle-20261008c): the server copied the tool-call grammar with a slow
  search on each draft step. 107 tools at 63k: 36.7 -> 45.0 tok/s on a plan-like answer, 59.6 -> 70.4 on a request
  with three tool calls, same output.
- **Saved conversations** (bundle-20261017b): with `MIRAI_SLOT_SAVE_PATH` set, the layer saves the K/V cache of
  each long prompt to disk (the VRAM part, the system-RAM part and the draft block's state). After a restart it loads
  it back and reads only the new turn: a 245k-token conversation is back in ~10 s instead of a 524 s re-read, and a
  128k document answers in 6.7 s after a restart (199 s cold). The answers are the same as without the restart
  ([saved conversations](../agents-layer/SAVED_CONVERSATIONS.md)).
- **Replay rollback** (on by default since bundle-20261019b): the draft keeps one recurrent state, not one snapshot
  for each draft token. On the RTX 4070 the VRAM line goes from 58,624 to 67,840 positions. The output does not change.
- What we took from [syv-ai/HyperQwen](https://github.com/syv-ai/HyperQwen) and what we measured:
  [HYPERQWEN.md](../research/HYPERQWEN.md).

The weights are the same as the published weights. Before all other measurements, this project checked each kernel
against alesha-pro's reference fork, greedy and token for token. This repository does not replace the work of Mirai
Labs or alesha-pro. It is a serving layer on that work: it adds the cache, the drafting, the server flags and the
measurements that a 12 GB card needs. Who made what: [CREDITS.md](../CREDITS.md).

## Quick start (Windows, NVIDIA)

1. Download `mirai-s-bundle-win-x64.zip` from [Releases](https://github.com/professorpalmer/mirai-s-ada/releases).
   Unzip it into this repository. It fills `bin\`. You can also build the binaries (refer to
   [Build from source (Windows)](../build/README.md#build-from-source-windows)).
   The binaries contain sm_89 machine code (RTX 40). They need only the NVIDIA driver.
2. Download `Qwen3.8-27B-S-mirai.gguf` from [alesha-pro on Hugging Face](https://huggingface.co/alesha-pro/Qwen3.8-27B-S-mirai-GGUF).
   Put it in `models\`. The MTP draft block is in that file. This project does not graft a draft block.
3. Optional: make a copy of the GGUF with a smaller draft block. This step takes approximately two minutes on the CPU.
   It needs `numpy` and the `engine` submodule, or `pip install gguf`.

   ```powershell
   python tooling\requant_mtp.py models\Qwen3.8-27B-S-mirai.gguf models\Qwen3.8-27B-S-mirai-mtpq4.gguf
   ```

   The script requantizes only the MTP draft block, from Q8_0 to Q4_0. All other tensors stay byte-identical. When
   the copy is present, the launcher uses it. The copy gives 204 MiB more K/V in VRAM (approximately 6k positions).
   The outputs are identical by construction, because speculation is exact. The draft acceptance is 77.7% against
   78.2% (`receipts/mirai-port/mtp_q4_probe.log`).
4. Optional, one time: run `layer\fetch_runtime.ps1`. The script downloads the sandbox runtime (CPython 3.12 on WASI,
   with checksums) and runs its isolation canaries. Without the runtime, the plain server starts.
5. Start the server:

   ```powershell
   .\start-server.ps1
   ```

   The server gives an OpenAI-compatible API on `http://<host>:8080/v1`. The bearer key is in
   `artifacts\api_key.txt`. The launcher makes this file on the first run.

   The launcher reads the free VRAM. It keeps a safety margin below the point where Windows demotes the memory of a
   background process. Then it puts as many positions of the 262k cache in VRAM as possible. The launcher prints the
   line that it chose. On this card with the display on the iGPU and the Q4 draft-block copy:

   | Bundle | Positions in VRAM | Source |
   | --- | ---: | --- |
   | bundle-20261019b (replay rollback on, the default) | 67,840 | [release notes](../../RELEASE-NOTES.md) |
   | bundle-20261016 to bundle-20261019 (replay rollback off) | 58,624 | release notes |
   | bundle-20261006c | 57,856 (approximately 51k with the published file) | `receipts/mirai-port/decode_by_depth.log`; the 51k value: the README of that bundle |

Upgrade from an older bundle: [docs/build](../build/README.md#upgrading).

## Quick start (Linux, from alesha-pro)

alesha-pro wrote the Linux launcher, `start-server.sh`. alesha-pro also checked this procedure on Ubuntu 22.04 with an
RTX 3090, the CUDA 12.8 toolkit, gcc 11.4 and cmake 3.22 (`receipts/ubuntu-3090/`).

```bash
git clone --recurse-submodules https://github.com/professorpalmer/mirai-s-ada && cd mirai-s-ada
cmake -S engine -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DLLAMA_CURL=OFF -DCMAKE_CUDA_ARCHITECTURES=native
cmake --build build -j --target llama-server            # approximately 4 min on 32 threads
hf download alesha-pro/Qwen3.8-27B-S-mirai-GGUF --local-dir models
MIRAI_KV_VRAM_CELLS=44000 ./start-server.sh             # raw server on http://127.0.0.1:8080/v1
```

- CMake finds the CUDA toolkit by itself. If the configure step finds an old `nvcc` or fails, add the paths of a
  CUDA 12 or 13 toolkit: `-DCUDAToolkit_ROOT=/usr/local/cuda -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc`. On the
  Ubuntu test computer, an older system `nvcc` was first on the PATH, and the configure step needed these paths.
- With a system cuBLAS 11, the int8 GEMM of the prompt path uses a tile that is approximately half as fast.
- `CMAKE_CUDA_ARCHITECTURES=native` compiles for the GPU in the computer. It needs cmake 3.24 or later and a GPU
  that the driver can see when you configure. With an older cmake, use the number for your GPU: 75 for RTX 20, 86
  for RTX 30, 89 for RTX 40, 120 for RTX 50. Without a value, an older cmake compiles the kernels for all
  generations. That build took 17 minutes on the test computer.
- The name "ada" comes from the RTX 4070 (Ada) where we measured the engine. The engine also runs on RTX 20, 30
  and 50 cards. Proposed by Gotoro (issue #3), checked on Arch Linux with cmake 4.4.4.
- As a last check, a fresh clone of this branch was built with these steps and served through `start-server.sh`.

`start-server.sh` starts only the raw server. It uses the same flags and environment as `start-server.ps1`. It does
not start the layer, and it does not calculate the VRAM line. Set `MIRAI_KV_VRAM_CELLS` for your card. The
[settings table](KNOBS.md) applies. The script also reads `MIRAI_HOST`, `MIRAI_API_KEY`,
`MIRAI_MMPROJ` (images, with the encoder on the CPU) and `MIRAI_CVEC` (refer to
[Remove refusals](#remove-refusals-optional-from-alesha-pro)).

alesha-pro's measurements on Linux (RTX 3090): [docs/speed](../speed/README.md#linux-rtx-3090-measured-by-alesha-pro).

### The serving flags as one command line

These flags give the Linux measurements. Any build of the engine can use them:

```bash
llama-server -m Qwen3.8-27B-S-mirai.gguf -ngl 99 -fa on -c 262144 -np 1 -ctk q8_0 -ctv q8_0 --kv-vram-cells 44000 \
  -b 2048 -ub 1024 --kq-mask-packed \
  --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-n-max-tail 2 --spec-draft-window 16384 -ctkd q8_0 -ctvd q8_0 \
  --reasoning-effort-allow medium --reasoning-max-tokens-floor 24576 --reasoning-budget 20480 --backend-sampling \
  --chat-template-file templates/bonsai-template.jinja --chat-template-kwargs '{"reasoning_effort":"medium"}' --jinja
```

The environment also has `GGML_CUDA_BATCH_INVARIANT=1` and `GGML_MIRAI_PREFILL_PLANES=ffn`. `start-server.sh` sets
both.

## Remove refusals (optional, from alesha-pro)

alesha-pro measured the refusal direction of the quantized model. alesha-pro published this direction as a 1.3 MB
control vector next to the weights. The engine can remove the direction from the residual stream at run time with
`--cvec-mode project`. alesha-pro also wrote this engine mode.

1. Download the vector:

   ```bash
   hf download alesha-pro/Qwen3.8-27B-S-mirai-GGUF Qwen3.8-27B-S-mirai-refusal-direction.gguf --local-dir models
   ```

2. Add two arguments to the `llama-server` command line:

   ```bash
   --control-vector-scaled models/Qwen3.8-27B-S-mirai-refusal-direction.gguf:1.0 --cvec-mode project
   ```

   On Linux, you can set `MIRAI_CVEC` instead:
   `MIRAI_CVEC=models/Qwen3.8-27B-S-mirai-refusal-direction.gguf ./start-server.sh`. `start-server.ps1` does not
   pass these arguments yet.

[CONTROL-VECTOR.md](../research/CONTROL-VECTOR.md) has the measurements, the method and the caveats of alesha-pro. It
also tells what this repository checked and did not check with the vector. The vector is off if you do not give the
file. This project did not measure the vector on the suite.

## Recommended settings

- **Chat, coding answers and all requests through the layer**: use the defaults (medium reasoning, 20k thinking
  budget, layer on).
- **Coding agents that run their own tools** (Cline, Kilo, OpenHands-style loops against `127.0.0.1:18080`, or the
  layer with `"api_cards": false`): send `reasoning_effort: "low"`. Start the server with
  `MIRAI_EFFORT_ALLOWED=low,medium`, so that the server accepts that value. On the coding family of the suite, raw,
  with the same seeds, the result went from 4 to 6 of 12. The MIME task went from 0 to 4 of 4. HumanEval stayed at
  158/164. The cost is longer tool loops (+31% completion tokens).
- **Sessions that stay below approximately 28k tokens and need the fastest decode**: set `MIRAI_SPEC_TYPE=dflash`.
  Put the Q4_0 DFlash drafter from `ggml-org/Qwen3.8-27B-GGUF` in `models\`. Results (E22, three runs): 86 / 78
  tok/s at 0 / 16k, against 76 / 72 with the MTP block. The greedy outputs are identical, and the acceptance is 70% at
  draft 3. Drafts of 4 or more are slower. The drafter uses approximately 17k of the approximately 58k positions in
  VRAM (measured before replay rollback). For this reason, the default keeps the MTP block for long agent sessions.
- **Tool-heavy agents that need speed more than depth**: send `chat_template_kwargs: {"enable_thinking": false}` in
  each request (HumanEval 154/164 at 0.19x the tokens).
- **Long-context work past the VRAM line**: `MIRAI_CTK=q3_0` (bundle-20261016 or newer) puts 2.9x the positions in
  VRAM. It is an option, not the default ([quality](../quality/README.md#kv-cache-precision)).

All settings: [KNOBS.md](KNOBS.md).

## Get more positions into VRAM

Each GB of VRAM that the desktop does not use gives approximately 30k more q8_0 positions at full speed. To get this
VRAM:

1. Connect the display to the integrated graphics of the CPU.
2. In Windows, open **Settings > System > Display > Graphics**. Set the GPU-accelerated apps to the integrated
   graphics.

The launcher margin then decreases from 1300 MiB to 800 MiB headless.

## Why the VRAM line is where it is

These numbers are from bundle-20261006c (line approximately 58k positions). Replay rollback (bundle-20261019b) changed
the snapshot item. The other items stay the same.

- Mirai keeps 8,016 MiB of weights in VRAM. With the published file, it keeps 8,220 MiB, because the MTP draft block
  at Q8_0 is 204 MiB larger than the Q4_0 copy.
- Drafting keeps one 150 MiB snapshot of the recurrent state for each unit of rollback depth. At the default draft of
  2, that is two snapshots. With replay rollback on, the engine keeps one state and the inputs of the last draft
  tokens: 164 MiB in place of 449 MiB at draft 2 (RELEASE-NOTES.md bundle-20261019).
- The draft context uses approximately 480 MiB when it shares the transient pool.
- Each q8_0 position uses 34,816 bytes. Thus each 100 MiB holds approximately 3k positions.

Past the line, each step reads the host tail over PCIe. In that range, drafting gives 2.2x the speed of no drafting.
`MIRAI_SPEC=0` moves the line to approximately 80k positions. But below the line, you then lose the 1.85x gain from
drafting ([REPORT.md](../research/REPORT.md), sections 5b and 6e).

## Known limits and issues

- **12 GB is the minimum.** 8.2 GB of weights stay in VRAM. This model does not fit on an 8 GB card, and the launcher
  does not try.
- **Past the VRAM line, the PCIe speed limits the decode.** The line is at 67,840 positions on a 12 GB card with the
  display on the iGPU (bundle-20261019b; approximately 58k before replay rollback). The launcher calculates that a
  16 GB card moves the line to approximately 180k. This project did not measure that.
- **Prefill is at the int8 limit of the card.** The trellis level decode and the int8 GEMM run at 191-233 TOPS of the
  233 TOPS dense peak. Approximately 1.1k tok/s on a 16.8k prompt is the speed of this card with these weights. An
  overlap of the level decode behind the GEMM gave 0 to -2.5% ([PREFILL.md](../research/PREFILL.md)). Each of the
  remaining options gives only a few percent.
- **The K/V cache stays at q8_0.** A q4_0 cache (`MIRAI_CTK=q4_0`) puts approximately two times the positions in
  VRAM, but on this model it changes the top token on 1 position in 34 (KL 0.0243 vs 0.0005 for q8_0;
  [REPORT.md](../research/REPORT.md) 6f). It is a knob and not a default, and it is not recommended. For long
  context, use the q3_0 option (above).
- **System RAM: 32 GB recommended.** The server's memory commit is the VRAM it holds (Windows charges that to the
  process too, ~12 GB), the K/V past the VRAM line (~6.8 GB of pinned RAM at 262k), the prompt cache and the
  checkpoints. The launcher sizes the last two from the RAM (`ram` line): under 24 GB, a 1 GiB prompt cache and 8
  checkpoints; under 48 GB, a 4 GiB cache. With 16 GB, also enlarge the page file or use `MIRAI_CTX=131072`, or the
  server can stop with "bad allocation".
- **One slot** (`-np 1`). The reference fork also requires one slot for this model.
- **Two launchers.** `start-server.ps1` (Windows) calculates the VRAM line and starts the layer. `start-server.sh`
  (Linux) starts the raw server with the line that you give. On Linux, the layer is not connected or tested.
- **The server changes effort words that are not on the allow-list to medium.** This is intentional
  (harness-proofing). Agents that need "low" must start the server with `MIRAI_EFFORT_ALLOWED=low,medium`. The server
  does not silently accept or reject the effort of a request. It maps the effort, and the server log records the
  change.
- **By default, prompt numerics use one plane for the FFN matmuls.** The KL against the exact path is 0.00028, the
  top-token agreement is 99.2%, and no suite pair changed. `MIRAI_PREFILL_PLANES=2` gives the exact path at -18%
  prefill.
- **Library-heavy coding tasks stay difficult for the model.** The MIME task of the suite passes only raw at effort
  "low". The API check of the layer decreases invented names. It does not remove the limits of the model.
- **Sampled runs are deterministic for an identical request and seed.** With cache reuse, a late divergence occurs
  rarely: one time in twelve traces of 70k characters. Treat small paired differences as noise
  ([REPORT.md](../research/REPORT.md), determinism probe).
- **One abort occurred one time and did not occur again.** On the evening of 10-06, a 180k-token request stopped
  llama-server with an assert-style fail-fast. Then four runs were clean: the same request, the same sequence of
  requests, and the bare server at 120k and 180k ([REPORT.md](../research/REPORT.md) 6e). Now the launcher monitors
  the server:
  - It restarts an aborted server, up to `MIRAI_RESTARTS` times (default 3) in ten minutes.
  - It writes the event to its output.
  - With `MIRAI_STDERR_FILE=logs\product.stderr`, it keeps the raw stderr of the server. An assert prints its text
    there.
- To report an issue, attach the configuration block that the launcher prints and `logs\product.log`. If you set
  `MIRAI_STDERR_FILE`, also attach `logs\product.stderr`.
