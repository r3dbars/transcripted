from common import frame
SW = 60
L, R, TOP, BOT, RAD = 236, 788, 246, 676, 110
CX, MID = 512, 450
A, B = L + RAD, R - RAD          # where the straight top edge starts/ends
CB = 80                          # crossbar half-length (centerline)
STEM_BOT = 585

def tail():
    return f'H 404 Q 396 748 350 804 Q 446 770 504 {BOT}'

def outline(split):
    if split:
        return (f'M {A} {TOP} A {RAD} {RAD} 0 0 0 {L} {TOP+RAD} V {BOT-RAD} A {RAD} {RAD} 0 0 0 {L+RAD} {BOT} '
                f'{tail()} H {R-RAD} A {RAD} {RAD} 0 0 0 {R} {BOT-RAD} V {TOP+RAD} A {RAD} {RAD} 0 0 0 {B} {TOP}')
    return (f'M {A} {TOP} A {RAD} {RAD} 0 0 0 {L} {TOP+RAD} V {BOT-RAD} A {RAD} {RAD} 0 0 0 {L+RAD} {BOT} '
            f'{tail()} H {R-RAD} A {RAD} {RAD} 0 0 0 {R} {BOT-RAD} V {TOP+RAD} A {RAD} {RAD} 0 0 0 {B} {TOP} Z')

BARS5 = [(92, 200), (184, 100)]
BARS3 = [(110, 190)]

DEFS = '''<linearGradient id="bgK" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#3b2b40"/><stop offset="1" stop-color="#151118"/></linearGradient>
<linearGradient id="bgN" x1="0" y1="0" x2="0.2" y2="1"><stop offset="0" stop-color="#2b2427"/><stop offset="1" stop-color="#0f0d0e"/></linearGradient>
<linearGradient id="org" gradientUnits="userSpaceOnUse" x1="0" y1="220" x2="0" y2="820"><stop offset="0" stop-color="#ffb65e"/><stop offset="1" stop-color="#f0692a"/></linearGradient>
<linearGradient id="coral" gradientUnits="userSpaceOnUse" x1="236" y1="220" x2="788" y2="820"><stop offset="0" stop-color="#ffc46b"/><stop offset="0.55" stop-color="#ff8a3d"/><stop offset="1" stop-color="#ef4f3a"/></linearGradient>
<linearGradient id="cream" gradientUnits="userSpaceOnUse" x1="0" y1="220" x2="0" y2="620"><stop offset="0" stop-color="#fffbf3"/><stop offset="1" stop-color="#f0e1c4"/></linearGradient>
<radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="512" cy="430" r="260"><stop offset="0" stop-color="#ff9a2e" stop-opacity="0.55"/><stop offset="1" stop-color="#ff9a2e" stop-opacity="0"/></radialGradient>
<filter id="tglow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="14" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>'''

def icon(bg='url(#bgK)', split=True, outline_c='url(#org)', bars_c='url(#org)', t_c='url(#cream)',
         bars=BARS5, glow=False, tglow=False):
    s = f'stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round" fill="none"'
    c = ''
    if glow:
        c += '<rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>'
    c += '<g filter="url(#soft)">'
    c += f'<path d="{outline(split)}" stroke="{outline_c}" {s}/>'
    for dx, h in bars:
        for x in (CX - dx, CX + dx):
            c += f'<path d="M {x} {MID-h/2} V {MID+h/2}" stroke="{bars_c}" {s}/>'
    t = ''
    if split:
        t += f'<path d="M {CX-CB} {TOP} H {CX+CB}" stroke="{t_c}" {s}/>'
    t += f'<path d="M {CX} {TOP} V {STEM_BOT}" stroke="{t_c}" {s}/>'
    c += f'<g filter="url(#tglow)">{t}</g>' if tglow else t
    c += '</g>'
    return frame(DEFS, bg, c, rim="#ffffff", rim_op=0.32)

V = {
 'V1': icon(split=False, t_c='url(#org)', glow=True),                                   # joined, all orange, soft glow (subtlest)
 'V2': icon(split=False, t_c='url(#cream)'),                                              # joined, cream stem
 'V3': icon(split=True),                                                                  # split, cream T (bold #4)
 'V4': icon(split=True, glow=True, tglow=True),                                           # split, cream T, glowing
 'V5': icon(split=False, outline_c='url(#cream)', bars_c='url(#cream)', t_c='url(#cream)', glow=True),  # joined, all cream, amber glow
 'V6': icon(split=True, outline_c='url(#org)', bars_c='url(#cream)', t_c='url(#cream)'),  # split, orange bubble, cream sound
 'V7': icon(split=False, t_c='url(#cream)', bars=BARS3, bg='url(#bgN)'),                   # joined, minimal 3 bars, near-black
 'V8': icon(split=True, outline_c='url(#coral)', bars_c='url(#coral)', t_c='url(#cream)', bg='url(#bgN)', tglow=True),  # split, sunset gradient
}
if __name__ == "__main__":
    for k, v in V.items():
        open("round3/" + k + ".svg", "w").write(v)
