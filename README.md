# Mirai S 27B on a 12 GB card: the full 262k window, drafting at every depth, and the layer

![Scorecard, RTX 4070 12 GB, bundle-20261019d defaults: 262,144-token window with a q8_0 K/V cache, 67,328 positions in VRAM, decode 70.1 / 60.9 / 20.3 / 10.3 tok/s at 4k / 64k / 128k / 200k (mean of three prompt types), a 16.8k prompt read at 1,090 tok/s, HumanEval 161 of 164 through the layer, AppWorld 88.7 %, a 245k conversation back in 9.0 + 1.6 s after a restart. The reference fork on the same card: a 64k window, 39.6 tok/s at 4k, 33.5 at 60k](docs/img/scorecard.png)

This repository serves [Mirai S 27B](https://huggingface.co/trymirai/Qwen3.8-27B-S-experimental) from Mirai Labs on one
RTX 4070 with 12 GB of VRAM. The model file is alesha-pro's
[GGUF conversion](https://huggingface.co/alesha-pro/Qwen3.8-27B-S-mirai-GGUF). The weights are not changed.
The serve gives the full 262,144-token window with a q8_0 K/V cache, MTP drafting at every depth, and an optional
layer for agents. It runs on Windows (the launcher and the release zip) and on Linux (`start-server.sh`).

## Index

| Directory | What |
| --- | --- |
| [docs/setup](docs/setup/README.md) | quick start (Windows and Linux), recommended settings, settings, the VRAM line, known limits |
| [docs/speed](docs/speed/README.md) | decode by context depth, prompt reading, the first comparison with the reference fork |
| [docs/quality](docs/quality/README.md) | HumanEval, the exact-work suite, K/V precision, measure it yourself |
| [docs/agents-layer](docs/agents-layer/README.md) | the layer, agent results, saved conversations |
| [docs/build](docs/build/README.md) | build from source, what is in this repository, release notes and upgrading |
| [docs/research](docs/research/README.md) | the report, the prefill study, the open items, the receipts |
| [docs/cards](docs/cards/README.md) | the card sources: each card keeps its numbers in one place |
| [docs/CREDITS.md](docs/CREDITS.md) | who made what, licenses and attribution |
