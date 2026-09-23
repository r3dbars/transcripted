# Round 7: the Sunset shape redrawn in the app's own colors (LibraryTokens / OverlayTokens):
# graphite + off-white neutrals, one capture-green accent, no orange.
import bold, polish
SW = bold.SW
S = f'stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round" fill="none"'

def icon(tile_top, tile_bot, ink, accent, rim_op, shadow_op=0.18):
    bars = ''.join(f'<path d="M {x} {bold.MID-h/2} V {bold.MID+h/2}"/>' for dx, h in bold.BARS5 for x in (bold.CX-dx, bold.CX+dx))
    glyph = (f'<g stroke="{ink}" {S}><path d="{bold.outline(True)}"/>{bars}</g>'
             f'<g stroke="{accent}" {S}><path d="M {bold.CX-bold.CB} {bold.TOP} H {bold.CX+bold.CB}"/><path d="M {bold.CX} {bold.TOP} V {bold.STEM_BOT}"/></g>')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{tile_top}"/><stop offset="1" stop-color="{tile_bot}"/></linearGradient>
  <linearGradient id="rim" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff" stop-opacity="{rim_op}"/><stop offset="0.4" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="{rim_op*0.3:.3f}"/></linearGradient>
  <clipPath id="tile"><path d="{polish.TILE}"/></clipPath>
  <filter id="tileShadow" x="-15%" y="-15%" width="130%" height="135%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.28"/><feDropShadow dx="0" dy="2" stdDeviation="2" flood-color="#000" flood-opacity="0.2"/></filter>
  <filter id="lift" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000" flood-opacity="{shadow_op}"/></filter>
</defs>
<path d="{polish.TILE}" fill="url(#bg)" filter="url(#tileShadow)"/>
<g clip-path="url(#tile)"><g filter="url(#lift)" transform="translate(512 528) scale(0.84) translate(-512 -512)">{glyph}</g></g>
<path d="{polish.TILE_IN}" fill="none" stroke="url(#rim)" stroke-width="3"/>
</svg>'''

V = {
 'G1-paper-green-T':    icon('#fbfbf9', '#e9e9e6', '#1d1d1f', '#1f8a66', 0.9, 0.10),
 'G2-graphite-green-T': icon('#303033', '#1a1a1b', '#f5f5f3', '#2ebd8c', 0.28, 0.35),
 'G3-paper-all-green':  icon('#fbfbf9', '#e9e9e6', '#1f8a66', '#1f8a66', 0.9, 0.10),
 'G4-graphite-mono':    icon('#303033', '#1a1a1b', '#f5f5f3', '#f5f5f3', 0.28, 0.35),
}
for k, v in V.items():
    open(k + '.svg', 'w').write(v)
print(list(V))
