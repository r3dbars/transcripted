# Menu bar icon

The menu bar glyph is the app icon's outlined speech bubble with the hidden "T", drawn as a
one-color template image so macOS tints it for light and dark menu bars.

- `idle.svg`: the outline mark, used when nothing is recording
- `dictating.svg`: the same bubble filled in, with the waveform cut out
- `meeting.svg`: the filled bubble plus a small recording dot

At menu bar size the app icon's outer pair of bars smears into the wall, so the glyph keeps the
T's stem and one pair of side bars, halfway between the stem and the wall.

`Sources/UI/MenuBar/MenuBarGlyph.swift` draws the same shapes in code. Keep the numbers in
`make_menu_bar_icons.py` and that file in sync.

Regenerate: `python3 make_menu_bar_icons.py`, then
`NODE_PATH=$(npm root -g) node render_preview.js` for `preview@2x.png` / `preview@1x.png`.
