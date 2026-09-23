from common import frame
SW = 44
TOP, BOT, L, R, RAD = 262, 662, 250, 774, 110
CX = 512
def rest_path(gap):
    # bubble outline minus the T crossbar segment on the top edge
    if gap:
        a, b = 370, 654
        return (f'M {a} {TOP} H {L+RAD} A {RAD} {RAD} 0 0 0 {L} {TOP+RAD} V {BOT-RAD} A {RAD} {RAD} 0 0 0 {L+RAD} {BOT} '
                f'H 372 L 348 772 L 462 {BOT} H {R-RAD} A {RAD} {RAD} 0 0 0 {R} {BOT-RAD} V {TOP+RAD} A {RAD} {RAD} 0 0 0 {R-RAD} {TOP} H {b}')
    return (f'M {L+RAD} {TOP} A {RAD} {RAD} 0 0 0 {L} {TOP+RAD} V {BOT-RAD} A {RAD} {RAD} 0 0 0 {L+RAD} {BOT} '
            f'H 372 L 348 772 L 462 {BOT} H {R-RAD} A {RAD} {RAD} 0 0 0 {R} {BOT-RAD} V {TOP+RAD} A {RAD} {RAD} 0 0 0 {R-RAD} {TOP} Z')
def bubble(bg_defs, bg, outline, bars, tcol, gap, rim_op=0.9):
    defs = bg_defs
    s = f'stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round" fill="none"'
    c = '<g filter="url(#soft)">'
    c += f'<path d="{rest_path(gap)}" stroke="{outline}" {s}/>'
    if gap:
        c += f'<path d="M 436 {TOP} H 588" stroke="{tcol}" {s}/>'
    # the stem: tallest bar, fused to the top edge
    c += f'<path d="M {CX} {TOP} V 598" stroke="{tcol}" {s}/>'
    mid = 468
    for dx, h in [(66, 196), (132, 128), (198, 64)]:
        for x in (CX - dx, CX + dx):
            c += f'<path d="M {x} {mid-h/2} V {mid+h/2}" stroke="{bars}" {s}/>'
    c += '</g>'
    return frame(defs, bg, c, rim="#ffffff", rim_op=rim_op)

light = '''<linearGradient id="bgL" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fbf8f3"/><stop offset="1" stop-color="#e7e0d6"/></linearGradient>
<linearGradient id="org" gradientUnits="userSpaceOnUse" x1="0" y1="240" x2="0" y2="790"><stop offset="0" stop-color="#ffa040"/><stop offset="1" stop-color="#e8531f"/></linearGradient>
<linearGradient id="deep" gradientUnits="userSpaceOnUse" x1="0" y1="240" x2="0" y2="620"><stop offset="0" stop-color="#e0561c"/><stop offset="1" stop-color="#b8380f"/></linearGradient>'''
dark = '''<linearGradient id="bgK" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#3a2a3f"/><stop offset="1" stop-color="#17121c"/></linearGradient>
<linearGradient id="org" gradientUnits="userSpaceOnUse" x1="0" y1="240" x2="0" y2="790"><stop offset="0" stop-color="#ffb35c"/><stop offset="1" stop-color="#f2702a"/></linearGradient>
<linearGradient id="cream" gradientUnits="userSpaceOnUse" x1="0" y1="240" x2="0" y2="620"><stop offset="0" stop-color="#fffaf0"/><stop offset="1" stop-color="#f1e3c8"/></linearGradient>'''
out = {
 'D1-joined':    bubble(light, 'url(#bgL)', 'url(#org)', 'url(#org)', 'url(#org)', False),
 'D2-split':     bubble(light, 'url(#bgL)', 'url(#org)', 'url(#org)', 'url(#org)', True),
 'D3-split-tone':bubble(light, 'url(#bgL)', 'url(#org)', 'url(#org)', 'url(#deep)', True),
 'D4-dark':      bubble(dark,  'url(#bgK)', 'url(#org)', 'url(#org)', 'url(#cream)', True, rim_op=0.35),
}
for k,v in out.items(): open(k+'.svg','w').write(v)
