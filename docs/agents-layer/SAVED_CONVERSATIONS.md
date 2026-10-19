# Saved conversations

![Saved conversations on the RTX 4070 12 GB: after a restart, a 64k conversation is back in 0.8 + 0.4 s (re-read 73 s), 128k in 1.6 + 0.6 s (195 s), 245k in 9.0 + 1.6 s (524 s); a 128k document through the layer answers in 6.7 s (199 s cold). A full save of a 174k conversation took 227 s, a delta 0.2-0.6 s; the mean wait per turn in a 30-turn session went from 74 s to 23 s](img/saved.png)

A long conversation costs minutes to read again after a server restart. With a saved state, the server loads the
cache from disk and reads only the new turn. The answers are the same as without the restart.

## Setup

1. Set `MIRAI_SLOT_SAVE_PATH` to a folder with free space (a file is approximately 34 KB per position at q8_0, 8.3 GB
   at 245k). The launcher makes a relative folder absolute.
2. Start the server with the layer on (the default): `.\start-server.ps1`.

With the layer on (bundle-20261017b or newer), the saves are automatic:

- The layer saves each prompt of 16k+ tokens, and again when it grows by 8k.
- After a server restart, it restores the longest saved prefix before the request. The request then reads only its
  new tokens.
- The files are named `lc-<hash>`. The layer removes its own files past 20 GB, oldest first, and no other file.
- **Read ahead:** a chat request with `"prefill_only": true` reads the prompt and saves it. It answers with a short
  JSON object, not text. Send it when a big file is attached, before the question.
- With the cache off, the answers of the layer do not change (greedy hashes identical).

Without the layer (bundle-20261017 or newer): `POST /slots/0?action=save` with `{"filename": "name.bin"}` writes the
K/V state of the conversation (both tiers). A second file, `name.bin.draft`, holds the state of the draft block.
`action=restore` reads both back. The server does not remove these files: delete old files yourself. Without the
`.draft` file the restore still works and the server prints a warning; the draft block then reads the conversation
again.

## Numbers

RTX 4070, 262k window, q8_0 cache, bundle-20261017 ([release notes](../../RELEASE-NOTES.md)):

| Conversation | Restore + new turn | Read it again | File |
| --- | --- | --- | --- |
| 64k | 0.8 + 0.4 s | 73 s | 2.3 GB |
| 128k | 1.6 + 0.6 s | 195 s | 4.5 GB |
| 245k | 9.0 + 1.6 s | 524 s | 8.3 GB |

The next turn reads only its new tokens (a 5.5k-token turn at 128k: 13.3 s, in memory 13.2 s).

Through the layer (bundle-20261017b): a 128k document asked after a restart answers in **6.7 s** (restore 2.2 s, 39
new tokens), against 199 s cold, with the same answer.

With replay rollback on (bundle-20261019b) these runs were not repeated.

## Delta saves (bundle-20261018b and newer)

A save writes only the tokens since the last save of the conversation (a delta), not the whole conversation.

- A restore loads the last full save and then each delta.
- After 8 deltas, the next full save waits until the layer has been idle for 30 s (`BONSAI_SLOT_CACHE_IDLE`,
  bundle-20261018c). Until then the chain grows, and a restore costs ~1 s more per delta. After 32 deltas
  (`BONSAI_SLOT_CACHE_CHAIN_MAX`), the full save happens in any case.
- Each delta also holds the fixed recurrent state of the model (~150 MiB).
- A chain restore (a full save + 4 deltas) gives the same answer, the same tokens read and the same cached tokens as a
  full-file restore, at 20k and 174k tokens.

Why it matters: a full save of a long conversation is ~6 GB. On a drive that cannot keep its write speed, one full
save took 227 s for a 174k-token conversation; a delta took 0.2-0.6 s. In a 30-turn session with restarts and pauses
of 20 s, the default save waited 23 s per turn on average with delta saves, and 74 s with full saves
(bundle-20261018c).

## Save after the answer (opt-in)

`MIRAI_SLOT_CACHE_AFTER=1` (bundle-20261018 or newer, with `MIRAI_SLOT_SAVE_PATH` and the layer):

- The layer saves a long conversation after the answer, not before the request. The answer does not wait for the
  save, but a turn sent right after a slow save waits for it. `GET /layer/slot-cache` says `busy` while a save runs.
- It works when the next turn renders the answer with the same tokens: thinking off, or a client that sends the
  reasoning back. The layer tests this for each conversation. The last save must be a token prefix of the new prompt.
  After 2 failures in a row it tries again only every 4th turn and uses the save before the request.
- Since bundle-20261018d, the layer saves after every answer of a long conversation, as a delta. Sessions that share
  their start each keep their own saves (up to 4 for each start).
- A save that would remove another conversation's save used in the last 10 minutes is skipped
  (`BONSAI_SLOT_CACHE_PROTECT`, seconds; 0 = off).

Since bundle-20261018 a speculative draft also stops at the end of the answer. Before, the lookup drafter could
continue a draft past `<|im_end|>`, and the next turn could not reuse the state after the answer. On a 20k-token
conversation of 10 turns, the next turn now reuses the whole state on 9 of 9 turns.

Settings: [KNOBS.md](../setup/KNOBS.md) (`MIRAI_SLOT_SAVE_PATH`, `MIRAI_SLOT_CACHE_AFTER`). Back to
[agents-layer](README.md).
