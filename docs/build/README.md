# Build, install and upgrade

| You have | Do this | Section |
| --- | --- | --- |
| Windows, an RTX 40 card | download the release zip, add the model, run `start-server.ps1` | [Quick start (Windows)](../setup/README.md#quick-start-windows-nvidia) |
| Windows, another NVIDIA card, or you want to build | build the engine with `tooling\build_engine.bat` | [Build from source (Windows)](#build-from-source-windows) |
| Linux, NVIDIA driver + CUDA toolkit | build `llama-server` with cmake, run `start-server.sh` | [Quick start (Linux)](../setup/README.md#quick-start-linux-from-alesha-pro) |
| an older bundle of this repository | `git pull`, unzip the newest zip over it | [Upgrading](#upgrading) |

## Build from source (Windows)

You need Visual Studio 2022 or its Build Tools (any edition: Build Tools, Community, Professional or Enterprise) with
the "Desktop development with C++" workload, Python, and the NVIDIA pip wheels. You do not need the CUDA toolkit. For
Linux, refer to [Quick start (Linux)](../setup/README.md#quick-start-linux-from-alesha-pro).

```powershell
python -m pip install cmake ninja nvidia-cuda-nvcc nvidia-cuda-runtime nvidia-cublas nvidia-cuda-nvrtc nvidia-cuda-cccl
git clone --recurse-submodules https://github.com/professorpalmer/mirai-s-ada
cd mirai-s-ada
tooling\build_engine.bat llama-server      # approximately 30 min the first time
tooling\install_bin.ps1                      # copies the result and the CUDA runtime DLLs into bin\
```

- `build_engine.bat` finds Visual Studio with `vswhere.exe`, and the CUDA toolkit, cmake and ninja from the pip
  packages of the `python` on PATH (`tooling\find_toolchain.py`). It builds for the GPU in the machine
  (`MIRAI_CUDA_ARCH=native`). To build for other cards, set a list first, for example
  `set MIRAI_CUDA_ARCH=75-real;86-real;89-real`. `MIRAI_JOBS` (default 6) sets the parallel compile jobs.
- The CUDA 13 cuBLAS wheel has no `cublas.lib` / `cublasLt.lib`. `build_engine.bat` makes them from the DLLs the first
  time (`dumpbin` + `lib`, in `nvidia\cu13\lib\x64`).

### Troubleshooting

| Message | Cause | Fix |
| --- | --- | --- |
| `CUDA error: no kernel image is available for execution on the device` | the engine was built for another GPU architecture | set `MIRAI_CUDA_ARCH` (or leave it at `native` on the card that runs it), delete `build\`, build again |
| `llama-server exited with code -1073741515` (`0xC0000135`) | the CUDA runtime DLLs are not next to `llama-server.exe` | run `tooling\install_bin.ps1` again; it copies `cublas64_13.dll`, `cublasLt64_13.dll`, `cudart64_13.dll`, `nvJitLink_130_0.dll` and `nvvm64_40_0.dll` from the pip wheels |
| CMake: `CUDA::cudart includes non-existent path ...\include\cccl` | the CUB/Thrust headers are missing | `python -m pip install nvidia-cuda-cccl` |
| CMake: `ggml-cuda links to: CUDA::cublas but the target was not found` | no cuBLAS import libraries | run `tooling\build_engine.bat` from a fresh window; if it still fails, `python tooling\find_toolchain.py implibs` after `vcvars64.bat` shows the error |

## Upgrading

1. Stop the server (`tooling\stop.ps1`, or close the launcher window).
2. Run `git pull` in this repository. This updates the launcher, the layer and the documents.
3. Download the newest `mirai-s-bundle-win-x64.zip` from
   [Releases](https://github.com/professorpalmer/mirai-s-ada/releases). Unzip it into this repository. It replaces
   `bin\`.
4. Start the server again with `.\start-server.ps1`. The launcher prints the settings that it uses.

All bundles so far use the same model file. What each bundle changed, newest first:
[RELEASE-NOTES.md](../../RELEASE-NOTES.md).

## What is in this repository

| Path | Contents |
| --- | --- |
| `engine/` | Submodule: [`professorpalmer/llama.cpp-ada-mirai`](https://github.com/professorpalmer/llama.cpp-ada-mirai). A llama.cpp fork (its origin: [CREDITS.md](../CREDITS.md)) with these additions: the serving patches (tiered KV cache, draft window and tail, reasoning flags, batch-invariant kernels, op timing); the Mirai S codec as alesha-pro ported it to ggml (ggml types 90-93, CPU and CUDA kernels, rotation and scale tensors, split attention gate, graph hook); the prefill work of this project (one-plane FFN prompt numerics, packed 1-bit KQ mask, level-decode chunks). |
| `engine-notes/` | `mirai-delta/`: alesha-pro's reference fork as five format-patches against its upstream commit, the material that was ported onto the engine. |
| `start-server.ps1` | The Windows launcher. It calculates the VRAM line from measured fixed costs and starts the layer in front of llama-server. |
| `start-server.sh` | The Linux launcher, from alesha-pro. It starts the raw server with the same flags. Optional: images (`MIRAI_MMPROJ`) and the refusal-direction vector (`MIRAI_CVEC`, [CONTROL-VECTOR.md](../research/CONTROL-VECTOR.md)). |
| `tooling/` | `build_engine.bat` (Ninja + pip CUDA 13, the GPU of the build machine), `install_bin.ps1`, `find_toolchain.py`, `requant_mtp.py` (the Q4_0 draft-block copy), `serve.ps1` / `stop.ps1` (hidden test server, log and PID files). |
| `layer/`, `suite/` | The layer and the long exact-work suite, with the changes of this project (`layer/ORIGIN.md`, `suite/ORIGIN.md`). |
| `tests/` | Tests of the layer (saved conversations, save after the answer, stray tags, replies cut at `max_tokens`). |
| `bench/` | The measurement scripts, the scoreboard and results of each run (`ML1`..`ML2f`, `E18`..`E21`, HumanEval arms), and `render_cards.ps1` (the result cards). |
| `receipts/` | Small text receipts that the documents refer to: profiles, greedy dumps from alesha-pro's reference fork, probe logs. `ubuntu-3090/` is the Linux check of alesha-pro (RTX 3090). |
| `templates/bonsai-template.jinja` | The chat template for all measurements (reasoning_effort, thinking on/off). |
| `docs/` | These documents. Index: [README.md](../../README.md). |
