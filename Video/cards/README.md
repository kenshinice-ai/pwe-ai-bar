# Feature cards

Three 1080 × 1350 cards for a LinkedIn image post about 1.6.6 to 1.6.8, in English, with the post's text.
Status, 2026-10-18: posted to LinkedIn on Lee's go, three images and `post.en.txt`:
https://www.linkedin.com/feed/update/urn:li:activity:7517439146496311296/
They replace a new film shot (Lee, 2026-10-18). The tutorial film itself was never posted.

| Card | Shows | From |
|---|---|---|
| `max-credit` | The Max plan's dollar credit | This Mac's real data (`--panel`) |
| `codex-reset` | Codex's free reset and its expiry | This Mac's real data (`--panel`) |
| `prepaid` | Claude's prepaid balance and an expiring promotional credit | Sample figures (`--stress`); the card says so |

## Redraw

1. Have the installed app draw the panels. Success: `panel-standard-dark.png` is 680 px wide; `stress-panel-dark.png` exists.
   ```bash
   APP="/Applications/PWE AI Bar.app/Contents/MacOS/PWEAIBar"
   "$APP" --panel /tmp/cards/live -language en
   "$APP" --stress /tmp/cards/stress -language en
   ```
2. Check that `crop` and `spot` in `cards.json` still frame the right lines in those renders.
3. Run `python3 Video/cards/cards.py /tmp/cards/live /tmp/cards/stress ~/Movies/PWE\ Films/ai-bar/cards-<version>`.
   Success: three paths printed, one per card.

> ⚠️ Look at every card before posting. A ring around the wrong line is worse than no card.
> The ring positions are pixel rows in the render, so they move when the panel gains or loses a line.

`post.en.txt` is the text that goes with them. Its figures are the ones on cards 1 and 2 (2026-10-18).
