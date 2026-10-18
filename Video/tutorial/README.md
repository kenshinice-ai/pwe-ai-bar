# Tutorial video

A 56-second film of PWE AI Bar, and a silent 8-second loop of its three verdicts for the product page.
Vertical 1080 × 1920, Chinese and English narration, one edit for both.

Status, 2026-10-18: not posted, and not planned. Lee chose an image post instead for 1.6.6–1.6.8
(`Video/cards/`, posted to LinkedIn 2026-10-18). The film was last rebuilt on 2026-10-16 for 1.6.5, with a
`projects` take — the trophy page's by-project section, cropped, project names hidden — after the cost take.
It does not show the Codex resets, the prepaid balance or the Max credit.
The page loop is unchanged. (2026-10-10: Lee reviewed the first cut; it was never posted.)

The pipeline is the one in `07 TOOLS/PWE Loan Bar/Video/tutorial` (its README explains the script
files, the edit list, the narration tools and the compositor). What is specific to this film:

## It is cut from stills, and the app drew every one

PWE AI Bar is a readout. Nothing on it moves unless a quota moves, and a quota state cannot be waited
for. So nothing here is a screen recording. `tools/stills.sh` has the app draw each picture with its
own renderers and turns each into a four-second take:

| Take | Drawn by | From |
|---|---|---|
| `panel`, `cost`, `settings` | `--panel` | This Mac's real data at that moment. Lee agreed to his real usage being shown (2026-10-09). |
| `projects` | `--panel -trophyRange week` | The same real data over seven days, cropped to the by-project section. Project names render as "Project A, B, C": folder names are often clients' names. |
| `makes`, `close`, `short` | `--endurance` | Sample figures. The app itself prints that they are synthetic. |

The line under the picture says which it is, on every frame (`tags` in the script, `tag` on each step).

> ⚠️ Run `tools/stills.sh` only when the panel shows what the film should show. The `panel` take is
> whatever the app reads at that moment. The first cut was drawn after the Claude Code login had expired,
> so its panel showed no Claude quota under narration about reading Claude Code. It was drawn again on
> 2026-10-10, with the login live.

## What is here

| File | What it is |
|---|---|
| `script.en.json`, `script.zh.json` | Narration, captions, title, end card, and the tags. |
| `edit.json` | The edit: one held still per step, with a spotlight where a part of the panel is the subject. |
| `loop.json`, `script.loop.en.json`, `script.loop.zh.json` | The page loop: the three verdicts in turn. |
| `film.json` | The label, the icon, and each take's size, width in points and corner radius. |
| `tools/stills.sh` | Has the app draw the stills in one language and makes the takes. |
| `tools/build.py` and the rest | As in the Loan Bar film. `winrec.swift` is not used here. |
| `build/` | A link to `~/Movies/PWE Films/ai-bar`. Not in git, not in iCloud. |

## Rebuild

1. Run `tools/stills.sh en`, then `tools/stills.sh zh-Hans`.
   Success: six lines `  <take>-<lang>  <width>,<height>` for each.
2. If a take's size changed, correct `size` and `points` in `film.json`.
3. Copy the licensed music to `build/music.wav` (see the Loan Bar README).
4. Run `python3 tools/build.py script.en.json`, then the same with `script.zh.json`.
   Success: the last line is the path `build/tutorial-<lang>.mp4`.
5. Run `python3 tools/build.py script.loop.en.json --edit loop.json --layout loop --silent --name loop-en` (and `zh`).
   Success: the last line is the path `build/loop-<lang>.mp4`.

To change the narration, follow "Change the narration" in the Loan Bar README. Read every `heard`
line: this voice turned "makes it" into "mix it" and "login" into "logging" on the first pass.
