# Origin

Vendored from the Bonsai serve repo (`professorpalmer/bonsai-ada-surgery`, commit 3628b6a, the state tagged
`bundle-20261004`) on 2026-10-04: `bonsai_layer.py`, `apicards.py`, `apicards_v2.py`, `apilint.py`, `sandbox_path.py`,
`fetch_runtime.ps1`, `wasi-python/`. The layer is model-agnostic by design and measured so (Bonsai: suite 17 -> 28/29 of
37; Mirai S: 13 -> 30 of 37, docs/REPORT.md). Changes for Mirai are made here and, when they are generic, offered back
to the Bonsai repo as plain patches. Nothing Mirai-specific goes the other way.

The env var the launcher uses for the key check is still `BONSAI_LAYER_KEY` (the module's name); renaming it is
cosmetic and not done.

2026-10-05 (E18, DECISIONS 21:10): diverges from the Bonsai copy in two places, measured here first: apilint reports
names looked up on a class or called on a fresh stdlib instance that the class does not have (with idiom hints), and
apicards triggers email, email.policy and email.parser on MIME requests, orders the task family before the generic
helpers and caps at 6 cards. To be offered back to the public layer with its own measurement if the MIME family moves.

2026-10-17 (layer cache): ported from the Bonsai repo `slot_cache.py` and its hooks in
`bonsai_layer.py` from commits 8689a2a (#157, saved conversations on disk) and bad2d9a (#159, read ahead with
`"prefill_only": true`), plus their tests as `tests/test_slot_cache.py`. The hooks are the same as in Bonsai; the
Mirai changes above stay as they are. The module still reads `BONSAI_SLOT_SAVE_PATH`; the launcher sets it from
`MIRAI_SLOT_SAVE_PATH` for the layer process only. Off when `MIRAI_SLOT_SAVE_PATH` is not set.

2026-10-17 (stray closing tags): `stray_tags.py` and its hooks in `bonsai_layer.py` remove stray closing tags
(`</think>`, `</parameter>`, `</function>`, `</tool_call>`) that the model can print after an answer when the
prompt has a tool block, thinking is off and the prompt is long. Only answers without tool calls, never inside a code
fence; `"strip_stray_tags": false` turns it off for a request. Generic, to be offered back to the Bonsai layer.

2026-11-20 (bundle-20261120, layer fixes measured on this engine):
- Background saves after the answer: when the server reports `slot_save_async` (engine with the background save), the
  layer sends `"async": true`, releases its lock at once, and indexes the save in a thread when the server reports the
  write done (`/slots/0?action=save_status`). A failed or lost write leaves no index entry. `BONSAI_SLOT_SAVE_ASYNC=0`
  turns it off. Temp names are unique per save.
- Delta parent fix: after a background save the layer's `held` tokens become the saved tokens when no request came in
  between, so the next turn's save is a delta of it (without the fix every later save was full).
- `--no-interpreter` (Proxy.interpreter): the run_python offer can be turned off (default on, as before). Known
  limit: when a turn's last round runs without the tool block (a cut retry at max_tokens, or the final round), the
  slot holds a prompt without the tool block and the next turn's prompt has it, so the next save is a full save.
