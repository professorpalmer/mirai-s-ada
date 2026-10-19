# Settings (environment variables)

Set these variables in the window before you run `start-server.ps1`. `start-server.sh` reads the same variables, but
it does not start the layer and it does not calculate the VRAM line. At start, the launcher prints every `MIRAI_*`,
`LLAMA_ARG_*` and `GGML_*` variable that is set in the window.

| Variable | Default | Function |
| --- | --- | --- |
| `MIRAI_CTX` | 262144 | context window |
| `MIRAI_CTK` / `MIRAI_CTV` | q8_0 / same as K | K/V cache type. `q3_0` (bundle-20261016 or newer): 2.9x the context in VRAM, decode at 245k 9.6 -> 36.9 tok/s on an RTX 4070, copies and lookups at 245k the same as q8_0, HumanEval 157 (q8_0 158); a long-context option, not the default. `MIRAI_CTV` sets V separately (mixed pairs need `GGML_CUDA_FA_ALL_QUANTS`) |
| `MIRAI_TIER` | 1 | 0 = all-VRAM cache (then a 64k window) |
| `MIRAI_KV_VRAM_CELLS` | auto | sets a fixed VRAM line |
| `MIRAI_SPARSE` | 0 | 1 = sparse reads past the VRAM line: each decode step reads the system-RAM K/V pages with the highest score bound (at least 12,288 positions or 1/8 of the RAM part, plus the last 1,024) and skips the rest. 192k decode 11.7 -> 16.2-17.0 tok/s on an RTX 4070, exact copies and fact lookups at 160k-245k the same as the full read; the bounds take about 166 MiB of VRAM (a line about 5k positions shorter). Engine bundle-20261014 or newer |
| `MIRAI_MMPROJ` / `MIRAI_MMPROJ_GPU` | none / 0 | vision projector (a file in `models\` or a full path; the Qwen3.8-27B projector, or `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`, the same encoder). Default: the encoder on the CPU, no VRAM. `MIRAI_MMPROJ_GPU=1`: on the card, counted in the VRAM line. bundle-20261015 or newer |
| `MIRAI_VRAM_MARGIN` | 800 headless, 1300 with the display on this card | MiB that stay free below the demotion point |
| `MIRAI_SPEC` / `MIRAI_SPEC_DEEP` | 2 / 4 with replay rollback (the Windows default), 2 / 2 without it (`start-server.sh`, `MIRAI_RS_REPLAY=0`); 3 with dflash | draft size, and draft size past the VRAM line |
| `MIRAI_SPEC_TYPE` / `MIRAI_DRAFTER` | mtp / `models\dflash-Qwen3.8-27B-Q4_0.gguf` | `dflash` drafts with the DFlash drafter of ggml-org, not with the MTP block of the GGUF: +13% decode at depth 0, +8.5% at 16k, outputs identical, approximately 590 MiB more VRAM (approximately 17k fewer positions in VRAM). Download the drafter from `ggml-org/Qwen3.8-27B-GGUF` into `models\` |
| `MIRAI_DRAFT_WINDOW` | 16384 | rows that the draft block keeps |
| `MIRAI_LOOKUP` / `MIRAI_LOOKUP_N` | ngram-mod / 32 | lookup drafter in front of the draft block: it drafts text that is already in the context (file rewrites, edit calls, quoted logs), up to N tokens at a time; the draft block drafts when it finds no match. 0 = off. Not used with `dflash` |
| `MIRAI_SPEC_ARGS` | none | more drafter flags, passed to the server as they are |
| `MIRAI_EFFORT` / `MIRAI_EFFORT_ALLOWED` | medium / medium | default effort of the server; effort words that the template gets (the server changes other words to medium) |
| `MIRAI_THINK` / `MIRAI_THINK_BUDGET` | 1 / 20480 | thinking on; tokens before a forced close |
| `MIRAI_HARNESS_PROOF` | 1 | 0 = do not change effort words and output caps |
| `MIRAI_PREFILL_PLANES` | ffn | numerics for prompt tokens: `ffn` (one int8 plane for the FFN matmuls, +18% prefill, KL 0.00028), `2` exact, `1` one plane for all matmuls |
| `MIRAI_KQ_MASK_PACKED` / `MIRAI_UBATCH` | 1 / 1024 | 1-bit attention mask; micro-batch (2048 = +5.6% prefill for approximately 570 MiB of VRAM) |
| `MIRAI_LEVELS_MIB` | 128 | memory size of the level-decode chunk for long prompts |
| `MIRAI_SHARED_POOL` | 1 | one transient CUDA pool for the target and draft contexts, with a 256-token draft micro-batch: gives back 188 MiB of VRAM (approximately 5.7k positions); outputs, decode and acceptance do not change (E23); 0 disables it |
| `MIRAI_RS_REPLAY` | 1 | replay rollback (bundle-20261019 or newer; on by default since bundle-20261019b): the draft keeps one recurrent state and the inputs of the last draft tokens, not one 150 MiB snapshot for each draft token. 285 MiB more K/V in VRAM (RTX 4070: line 58,624 -> 67,840), output byte-identical, decode +7 % / +14 % / +6 % at 64k / 128k / 200k. 0 = off |
| `MIRAI_CKPT_EVERY` | 8192 | checkpoints inside long messages (bundle-20261009 or newer): a prompt that changes inside one long message (an edited tool result) restores the nearest checkpoint, not the start. At 32k: 34.6-36.5 s -> 4.5-6.6 s, the same text. 0 = only at user messages and prompt ends |
| `LLAMA_ARG_CACHE_RAM` / `LLAMA_ARG_CTX_CHECKPOINTS` | from the RAM (`ram` line) | prompt-cache limit in MiB and checkpoints per slot; set by hand, they replace the launcher's sizing |
| `MIRAI_SLOT_SAVE_PATH` | none | a folder for saved conversations (bundle-20261017 or newer). With the layer on (bundle-20261017b): automatic. The layer saves prompts of 16k+ tokens there and restores them after a restart, so the next request reads only its new tokens (128k: 6.7 s after a restart, against 199 s cold). It removes its own `lc-` files past 20 GB, oldest first. A request with `"prefill_only": true` reads and saves a prompt ahead of the real request. Without the layer: `POST /slots/0?action=save` with `{"filename": "name.bin"}` and `action=restore` (those files are not removed). A file is approximately 34 KB per position at q8_0 (8.3 GB at 245k) |
| `MIRAI_SLOT_CACHE_AFTER` | off | `1`: saved conversations save after the answer, not before the request (bundle-20261018, opt-in). It works when the next turn renders the answer with the same tokens (thinking off, or a client that sends the reasoning back); the layer tests this per conversation and falls back. The answer does not wait for the save, but a turn sent right after a slow save waits for it. `GET /layer/slot-cache` says `busy` while a save runs. Since bundle-20261018b every save (this one and the default save before the request) writes only the tokens since the last save of the conversation (a delta; a full save every 8) |
| `MIRAI_LAYER` | 1 | 0 = no layer |
| `MIRAI_STDERR_FILE` / `MIRAI_RESTARTS` | none / 3 | file that keeps the raw stderr of the server (assert text); number of restarts after an abort before the launcher stops |
| `MIRAI_PORT`, `MIRAI_MODEL`, `MIRAI_LOG_FILE` | 8080, auto, none | model: `models\Qwen3.8-27B-S-mirai-mtpq4.gguf` if present, else the published file |

Back to [setup](README.md).
