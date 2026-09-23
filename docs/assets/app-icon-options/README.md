# App icon options

Mockups for a new Transcripted app icon (user feedback: the app icon doesn't match the website).

- `A-wave-to-text.svg` — sound bars turning into text lines (recommended)
- `B-page.svg` — a page with a waveform heading and text lines
- `C-mic-of-lines.svg` — a mic whose grille is text lines
- `D-speech-bubble.svg` — a speech bubble with a waveform

`options-light.png` shows each option next to today's icon at 256, 64, 32 and 16 px.

Regenerate: `python3 make_icons.py` (writes the SVGs), then
`NODE_PATH=$(npm root -g) node render.js *.svg` (Playwright + Chromium) for 1024 px PNGs.
