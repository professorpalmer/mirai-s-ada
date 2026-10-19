# Result cards

Each card is one HTML file in this directory. The numbers of a card are in one `DATA` object at the top of its file.
Each number has a comment that names its source (a receipt, a release note or a research record). The small print
of each card gives the bundle and the date.

To change a number:

1. Edit the `DATA` object of the card.
2. Run `bench\render_cards.ps1` (all cards) or `bench\render_cards.ps1 decode` (the cards whose name matches).
3. Look at the new PNGs. Commit them with the HTML.

The script uses headless Edge (or Chrome) at 1200 x 675 CSS pixels and device scale 2 (2400 x 1350 PNG):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bench\render_cards.ps1
```

| Card | Source | PNG |
| --- | --- | --- |
| scorecard | `scorecard.html` | `docs/img/scorecard.png` |
| decode by depth | `decode.html` | `docs/speed/img/decode.png` |
| prompt reading | `prefill.html` | `docs/speed/img/prefill.png` |
| quality | `quality.html` | `docs/quality/img/quality.png` |
| agent work | `agentic.html` | `docs/agents-layer/img/agentic.png` |
| saved conversations | `saved.html` | `docs/agents-layer/img/saved.png` |

`card.css` and `card.js` hold the shared style and drawing code. They hold no numbers. A value of `null` in `DATA`
prints "not measured".

Rules for a number on a card:

- Take it from a receipt or a document in this repository. Do not estimate it.
- Use the newest measurement of the default configuration. Write the bundle and the date in the small print.
- If no run measured it, the card says "not measured".
- Do not compare numbers from different prompt sets in one chart without a note in the small print.

`legacy/` keeps the cards that the README used before 2026-10-19. The script does not render them.
