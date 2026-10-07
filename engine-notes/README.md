# Engine notes

`mirai-delta/`: alesha-pro/llama.cpp-mirai-s (alesha-pro's reference fork for the model, squashed history, upstream base d834d44e6) as five
format-patches against that upstream commit, taken 2026-10-04. This is the material that was ported onto our engine:
the ggml types 90-93 with CPU and CUDA kernels, the loader and graph plumbing (rotation tensors, per-row scales, the
head auxiliary path, the split attention gate). Not taken from it: their GDN kernel, flash-attention vector changes
and server tweaks (ours cover the same ground). The port lives in `engine/` as three commits on top of the stack's
product commit (`git -C engine log c8b8993a6..`); `engine/` has the fork as remote `mirai` for future diffs.

Reference binary: the reference fork's own build, used for the profile and the greedy dumps in `receipts/mirai-port/`,
is kept outside the repo at `%TEMP%\mirai-build\bin` (rebuild from the `mirai` remote if it is gone).
