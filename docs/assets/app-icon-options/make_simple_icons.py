# Round 4: simplified #1 (joined outline, one color), in several color schemes
from common import frame
SW = 62
L, R, TOP, BOT, RAD = 236, 788, 246, 676, 110
CX, MID, STEM_BOT = 512, 450, 585
OUTLINE = (f'M {L+RAD} {TOP} A {RAD} {RAD} 0 0 0 {L} {TOP+RAD} V {BOT-RAD} A {RAD} {RAD} 0 0 0 {L+RAD} {BOT} '
           f'H 404 Q 396 748 350 804 Q 446 770 504 {BOT} H {R-RAD} A {RAD} {RAD} 0 0 0 {R} {BOT-RAD} '
           f'V {TOP+RAD} A {RAD} {RAD} 0 0 0 {R-RAD} {TOP} Z')
BARS = [(96, 196), (190, 92)]

def icon(bg_top, bg_bot, ink_top, ink_bot, rim_op=0.3):
    defs = f'''<linearGradient id="bg" x1="0" y1="0" x2="0.25" y2="1"><stop offset="0" stop-color="{bg_top}"/><stop offset="1" stop-color="{bg_bot}"/></linearGradient>
<linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="0" y1="215" x2="0" y2="835"><stop offset="0" stop-color="{ink_top}"/><stop offset="1" stop-color="{ink_bot}"/></linearGradient>
<filter id="lift" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#000" flood-opacity="0.18"/></filter>'''
    s = f'stroke="url(#ink)" stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round" fill="none"'
    d = OUTLINE + f' M {CX} {TOP} V {STEM_BOT}'
    for dx, h in BARS:
        for x in (CX - dx, CX + dx):
            d += f' M {x} {MID-h/2} V {MID+h/2}'
    return frame(defs, 'url(#bg)', f'<path d="{d}" {s} filter="url(#lift)"/>', rim="#ffffff", rim_op=rim_op)

SCHEMES = {
 'S1-plum-orange':   ('#3b2b40', '#17121b', '#ffb45c', '#f26b2b'),
 'S2-black-orange':  ('#2a2626', '#0c0b0b', '#ffa94d', '#ff6a2b'),
 'S3-orange-white':  ('#ffa24a', '#ec5a22', '#ffffff', '#fff3e6'),
 'S4-plum-cream':    ('#3b2b40', '#17121b', '#fffaf0', '#efdcbc'),
 'S5-navy-amber':    ('#22324f', '#0c1424', '#ffd27a', '#ffa13d'),
 'S6-black-white':   ('#2c2c2e', '#0b0b0c', '#ffffff', '#e4e4e8'),
 'S7-cream-orange':  ('#fdfaf5', '#ebe3d8', '#ff9a45', '#ec5a22'),
 'S8-violet-white':  ('#8a6cff', '#4b2fd1', '#ffffff', '#efeaff'),
}
for k, (a, b, c, d) in SCHEMES.items():
    light = k in ('S3-orange-white', 'S7-cream-orange', 'S8-violet-white')
    open('round4/' + k + '.svg', 'w').write(icon(a, b, c, d, rim_op=0.7 if light else 0.3))
print(list(SCHEMES))
