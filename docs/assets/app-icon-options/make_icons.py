from common import frame
icons = {}

# A: Wave -> Text. Dark plum like today, waveform bars flow into text lines.
defs = '''<linearGradient id="bgA" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#3a2a3f"/><stop offset="1" stop-color="#17121c"/></linearGradient>
<radialGradient id="glowA" cx="0.47" cy="0.5" r="0.3"><stop offset="0" stop-color="#ff9a2e" stop-opacity="0.75"/><stop offset="1" stop-color="#ff9a2e" stop-opacity="0"/></radialGradient>
<linearGradient id="cream" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fffaf0"/><stop offset="1" stop-color="#f1e3c8"/></linearGradient>
<linearGradient id="amber" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffd08a"/><stop offset="1" stop-color="#ff9e3d"/></linearGradient>'''
bars = [(262,150),(342,300),(422,210)]
c = '<rect x="100" y="100" width="824" height="824" fill="url(#glowA)"/><g filter="url(#soft)" transform="translate(517 512) scale(1.2) translate(-517 -512)">'
for x,h in bars:
    c += f'<rect x="{x}" y="{512-h/2}" width="52" height="{h}" rx="26" fill="url(#amber)"/>'
for y,w in [(402,262),(486,222),(570,262),(654,160)]:
    pass
for y,w in [(420,264),(512,214),(604,172)]:
    c += f'<rect x="508" y="{y-26}" width="{w}" height="52" rx="26" fill="url(#cream)"/>'
c += '</g>'
icons['A-wave-to-text'] = frame(defs, 'url(#bgA)', c)

# B: Page. Warm amber tile, white page with folded corner; top line is a waveform, rest are text.
defs = '''<linearGradient id="bgB" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffb347"/><stop offset="1" stop-color="#f26b1d"/></linearGradient>
<linearGradient id="page" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#f6efe6"/></linearGradient>'''
c = '<g filter="url(#soft)"><path d="M300 230 H620 L724 334 V762 Q724 794 692 794 H332 Q300 794 300 762 V262 Q300 230 332 230 Z" fill="url(#page)"/>'
c += '<path d="M620 230 V310 Q620 334 644 334 H724 Z" fill="#e9dccb"/></g>'
wave = [30,62,40,96,58,120,70,44,84,36]
for i,h in enumerate(wave):
    x = 356 + i*30
    c += f'<rect x="{x}" y="{395-h/2}" width="16" height="{h}" rx="8" fill="#f07a24"/>'
for y,w in [(520,312),(588,312),(656,230),(724,0)]:
    if w: c += f'<rect x="356" y="{y-15}" width="{w}" height="30" rx="15" fill="#3a2f2a" opacity="0.82"/>'
icons['B-page'] = frame(defs, 'url(#bgB)', c)

# C: Mic of lines. Teal/blue tile, white mic capsule whose grille slots are text lines.
defs = '''<linearGradient id="bgC" x1="0" y1="0" x2="0.4" y2="1"><stop offset="0" stop-color="#2fd0c3"/><stop offset="1" stop-color="#1363c7"/></linearGradient>'''
c = '<g filter="url(#soft)"><rect x="372" y="200" width="280" height="450" rx="140" fill="#ffffff"/>'
c += '<path d="M292 520 Q292 736 512 736 Q732 736 732 520" fill="none" stroke="#ffffff" stroke-width="44" stroke-linecap="round"/>'
c += '<rect x="490" y="736" width="44" height="72" fill="#fff"/><rect x="392" y="790" width="240" height="44" rx="22" fill="#fff"/></g>'
for y,w in [(330,150),(396,184),(462,184),(528,120)]:
    c += f'<rect x="420" y="{y-17}" width="{w}" height="34" rx="17" fill="#1a6fcf"/>'
icons['C-mic-of-lines'] = frame(defs, 'url(#bgC)', c)

# D: Speech bubble. Light cream glass tile, orange bubble with waveform inside.
defs = '''<linearGradient id="bgD" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbf8f3"/><stop offset="1" stop-color="#e7e0d6"/></linearGradient>
<linearGradient id="bub" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#ff9f43"/><stop offset="1" stop-color="#e8531f"/></linearGradient>'''
c = '<g filter="url(#soft)"><path d="M300 250 H724 Q800 250 800 326 V602 Q800 678 724 678 H470 L340 790 L362 678 H300 Q224 678 224 602 V326 Q224 250 300 250 Z" fill="url(#bub)"/></g>'
wave = [70,150,230,120,190,90]
for i,h in enumerate(wave):
    x = 326 + i*68
    c += f'<rect x="{x}" y="{464-h/2}" width="40" height="{h}" rx="20" fill="#fffaf2"/>'
icons['D-speech-bubble'] = frame(defs, 'url(#bgD)', c, rim="#ffffff", rim_op=0.9)

for k,v in icons.items():
    open(f'{k}.svg','w').write(v)
print(list(icons))
