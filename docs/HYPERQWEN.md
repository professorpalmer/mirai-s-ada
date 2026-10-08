# What we took from HyperQwen, and what we measured (2026-10-08)

[syv-ai/HyperQwen](https://github.com/syv-ai/HyperQwen) serves Qwen-family models with the same attention shape as
Mirai S (24 query heads, 4 KV heads, head size 256) on vLLM. We read its list of speed techniques and tested each one
that applies to this engine and this card (RTX 4070 12 GB). Decisions follow the measurement, not the idea.

| HyperQwen technique | What we did | Result on Mirai S | Decision |
| --- | --- | --- | --- |
| Draft from the prompt (copy text that is already in the context) | Lookup drafter in front of the MTP draft block, with its own draft limit (`--spec-lookup-n-max`) | Rewrite a 150-line file: 86.5 -> 265.6 tok/s at 4k, 20.1 -> 84.9 at 130k. One edit call: 85.1 -> 103.8, 19.8 -> 24.9. New text: unchanged. Same output (`receipts/lookup_ab_mirai.jsonl`) | Shipped, on by default (`bundle-20261008`) |
| SSE keep-alive | A `: keep-alive` comment every 15 s while the server is silent (layer) | Long prefills no longer drop through proxies and tunnels | Shipped |
| Int8 activations for the prefill matmuls | Already in this serve: one int8 plane for the FFN matmuls of prompt tokens | +18% prefill at KL 0.00028 (`docs/PREFILL.md`) | Already in |
| Int8 score step in prefill attention | Built and measured on the same attention kernel (q8_0 K, head 256) in the sister serve | Kernel 12% faster (about +6% prefill at depth); KL 0.000314, above the gate of 0.00017 (the cost of the q8_0 cache itself) | Stopped |
| Smaller draft head | Already in this serve: the MTP block requantized to Q4_0 (`tooling/requant_mtp.py`) | About 200 MiB of VRAM back, outputs identical | Already in |
| Calibrated 40k-token draft vocabulary | Not built. A smaller draft head removes about the same bytes per draft token and gave +3% at short context and nothing at depth | Expected 1-3% at short context | Not worth the engine change on this card |
| 4-bit / 2-bit KV cache for the long window | The tiered cache gives the full window at q8_0 | - | Not adopted (q8_0 stays) |
| Batch mode against single-user mode | This serve is one slot, one user | - | Not applicable |

What the measurements found on the way: prefill by depth showed a fixed extra cost once a prompt passes the tiered
cache's VRAM line. Its cause was the writes of the new K/V rows to system RAM in small pieces over PCIe. The fix is in
`bundle-20261008b`: the rows go to VRAM first and then to system RAM in whole blocks, and the next layer's RAM rows are
copied while the layers before it compute. A 130k prompt: 509 -> 639 tok/s (time to first token 254 -> 202 s), a 100k
prompt 596 -> 722, same output (`receipts/tier_ab_mirai.jsonl`). The same release gives each KV cache its own staging
buffers; before, a VRAM line pinned below the draft context's size gave broken text.
