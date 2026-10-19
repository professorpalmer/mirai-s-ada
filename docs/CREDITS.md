# Credits

## Who made what

| Contribution | By |
| --- | --- |
| The model [`Qwen3.8-27B-S-experimental`](https://huggingface.co/trymirai/Qwen3.8-27B-S-experimental), the Mirai S trellis codec and the vLLM plugin with the original CUDA kernels | [Mirai Labs](https://trymirai.com) |
| The base model [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) and the vision encoder | Qwen (Alibaba) |
| The GGUF conversion, [`Qwen3.8-27B-S-mirai-GGUF`](https://huggingface.co/alesha-pro/Qwen3.8-27B-S-mirai-GGUF). The trellis codes are copied bit for bit. | [alesha-pro](https://github.com/alesha-pro) |
| The port of the Mirai S codec to llama.cpp and ggml (types 90-93, CPU and CUDA kernels), in the reference fork [`llama.cpp-mirai-s`](https://github.com/alesha-pro/llama.cpp-mirai-s). This serve started from that fork and checks its outputs against it. | alesha-pro |
| The refusal-direction control vector and the `--cvec-mode project` engine mode (refer to [Remove refusals](setup/README.md#remove-refusals-optional-from-alesha-pro) and [CONTROL-VECTOR.md](research/CONTROL-VECTOR.md)) | alesha-pro |
| The Linux launcher `start-server.sh`, the Linux quick start and the Linux check on an RTX 3090 with its measurements (refer to [Quick start (Linux)](setup/README.md#quick-start-linux-from-alesha-pro) and [the Linux numbers](speed/README.md#linux-rtx-3090-measured-by-alesha-pro)) | alesha-pro |
| The AppWorld runs of Mirai's vLLM plugin and the BF16 reference ([qwen38-27b-bench-4x3090](https://github.com/alesha-pro/qwen38-27b-bench-4x3090/tree/main/agentic-v1)) | alesha-pro |
| The llama.cpp fork that the engine uses | [PrismML](https://github.com/PrismML-Eng/llama.cpp) |
| The planar activation layout and the batch-invariant mode ([PrismML PR #218](https://github.com/PrismML-Eng/llama.cpp/pull/218), in the engine with the original authorship) | [sudoingX](https://github.com/sudoingX) |
| llama.cpp and ggml | the ggml authors ([ggml-org](https://github.com/ggml-org/llama.cpp)) |
| The optional DFlash drafter, [`ggml-org/Qwen3.8-27B-GGUF`](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF) | ggml-org |
| The idea to draft out of the prompt (lookup drafting) and the SSE keep-alive ([HYPERQWEN.md](research/HYPERQWEN.md)) | [syv-ai/HyperQwen](https://github.com/syv-ai/HyperQwen) |
| The tiered KV cache, drafting at every depth, harness-proofing, the prefill work, the launcher for Windows, the layer, the suite and the measurements | Cary Palmer (this repository) |

The layer and the suite were first written for
[`professorpalmer/bonsai-ada-surgery`](https://github.com/professorpalmer/bonsai-ada-surgery) by the same author
(`layer/ORIGIN.md`, `suite/ORIGIN.md`).

## Thanks

- Gotoro proposed the `CMAKE_CUDA_ARCHITECTURES=native` Linux build and checked it on Arch Linux (issue #3).
- Milor123 reported the JSON schema with an empty `anyOf` / `oneOf` / `type` list (fixed in bundle-20261007).

## Licenses and attribution

- This repository (launcher, tooling, layer, suite, documents, receipts): MIT, Cary Palmer.
- The engine (`engine/`): llama.cpp is MIT (the ggml authors). The PrismML fork and the alesha-pro fork are also MIT.
  The engine tree keeps their notices. The Mirai S codec is the work of Mirai Labs. The ggml and CUDA kernels for the
  codec in the engine come from the port by alesha-pro. The commit history and `engine/README.md` record this
  attribution.
- This repository does not redistribute the model weights. The model is
  [`trymirai/Qwen3.8-27B-S-experimental`](https://huggingface.co/trymirai/Qwen3.8-27B-S-experimental) from Mirai Labs,
  a quantization of Qwen3.8-27B from Alibaba. `Qwen3.8-27B-S-mirai-GGUF` is the community conversion of that model by
  alesha-pro. Its license is on its Hugging Face card (Apache 2.0, the same as Qwen3.8). Download the GGUF from there
  and keep its notices.
- This project has no affiliation with Mirai Labs, alesha-pro, PrismML, sudoingX or the Qwen team of Alibaba. They do
  not endorse or sponsor this project.
