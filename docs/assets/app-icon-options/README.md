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

## Round 4: simplified #1 in eight colors

Justin picked round 3's #1 (joined edge, one color) and asked for it simpler and in a few colors.
Round 4 draws the whole mark as one flat path (no glow, no second color) and tries it in eight
color schemes, compared in `round4/simple8-light.png`. `S1-plum-orange` is recommended and is what
`Resources/Transcripted.icns` uses. Regenerate with `python3 make_simple_icons.py`.

## Round 5: shape variations

Same idea as round 4 (joined bubble, waveform, hidden T, plum + orange), varying the bubble's
size and shape, the line weight, and the number of bars. Eight takes in `round5/`, compared in
`round5/shapes8-dark.png`. `R6-pill` was recommended
uses. Regenerate with `python3 make_shape_icons.py round5`.

## Round 6: polished

Round 5 still looked flat. Round 6 rebuilds the icon with Apple's smoothed-corner tile shape,
soft top lighting, a warm glow behind the mark, a glossy rounded "tube" for the bubble (specular
highlight on top, shade underneath), light dithering against gradient banding, and a tail that
curls out of the bubble's corner. Four takes in `round6/`. `P1-glossy` is recommended and is what
`Resources/Transcripted.icns` uses. Regenerate with `python3 make_polished_icons.py` (writes SVGs
into the working directory).

## Round 7: the app's own colors

Justin tried Sunset (round 3, V8) and then turned down orange and black for both the icon and the
site. Round 7 keeps the Sunset shape (split top edge, hidden T) but draws it in the app's own tokens
from `Sources/UI/Shared/LibraryTokens.swift`: off-white `#F7F7F5` / graphite `#1D1D1F`, dark
`#232325` / `#1A1A1B`, and the one capture-green accent (`#1F8A66` light, `#2EBD8C` dark) for the T.
Four takes in `round7/`. `G1-paper-green-T` is what `Resources/Transcripted.icns` uses for now.
`website/site-mockup.html` shows transcripted.app in the same colors.

## Round 8: wider T, light and dark, no green

Justin asked for a wider top on the T, a dark option, and an accent other than green. The T's
crossbar is now 110 px each side (was 80), and the outline's top ends now start on the corner arcs so
the gaps stay the same. `round8/` has blue, indigo, red and no-accent versions, each on a light and a
dark tile.

**Chosen:** no accent. `H-mono-light` (graphite bubble on an off-white tile) is the app icon in
`Resources/Transcripted.icns`, and `H-mono-dark` (white bubble on a graphite tile) is the dark option.
The website mockups in `website/` use the same black and white with no accent.
