# App icon options

Mockups for a new Transcripted app icon (user feedback: the app icon doesn't match the website).

- `A-wave-to-text.svg` — sound bars turning into text lines (recommended)
- `B-page.svg` — a page with a waveform heading and text lines
- `C-mic-of-lines.svg` — a mic whose grille is text lines
- `D-speech-bubble.svg` — a speech bubble with a waveform

`options-light.png` shows each option next to today's icon at 256, 64, 32 and 16 px.

Regenerate: `python3 make_icons.py` (writes the SVGs), then
`NODE_PATH=$(npm root -g) node render.js *.svg` (Playwright + Chromium) for 1024 px PNGs.

## Round 2: outlined speech bubble with a hidden T

Justin picked the speech bubble. These redraw it as an outline, with the waveform
peaking in the middle; the tallest bar meets the top edge so the two form a "T".

- `D1-joined.svg` — the top edge is one unbroken line
- `D2-split.svg` — small gaps set the T's crossbar apart from the rest of the outline (recommended)
- `D3-split-tone.svg` — like D2, with the T a shade darker
- `D4-dark.svg` — like D2 on today's dark tile, with a cream T

`bubble-light.png` compares them at 256, 64, 32 and 16 px. Regenerate with `python3 make_bubble_icons.py`.

## Round 3: bolder dark versions

Justin liked the dark tile (4), the split T (2) and the subtle joined edge (1). Round 3 makes
the bubble bigger and bolder with fewer bars, a thicker line and a curved tail, on the dark tile.
Eight variations live in `round3/`, compared in `round3/dark8-dark.png`. `V3` (split, cream T)
is recommended and is what `Resources/Transcripted.icns` uses. Regenerate with
`python3 make_bold_icons.py`.
