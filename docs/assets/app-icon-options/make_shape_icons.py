# Round 5: shape variations of the joined bubble + waveform + hidden T (plum + orange)
import math
from common import frame

DEFS = '''<linearGradient id="bg" x1="0" y1="0" x2="0.25" y2="1"><stop offset="0" stop-color="#3b2b40"/><stop offset="1" stop-color="#17121b"/></linearGradient>
<linearGradient id="ink" gradientUnits="userSpaceOnUse" x1="0" y1="180" x2="0" y2="860"><stop offset="0" stop-color="#ffb45c"/><stop offset="1" stop-color="#f26b2b"/></linearGradient>
<filter id="lift" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#000" flood-opacity="0.18"/></filter>'''

def icon(w, h, r, sw, bw=None, n=2, gap=None, peak=0.78, falloff=0.55, tail='left', tail_len=0.30, stem_extra=0.0):
    bw = bw or sw
    gap = gap if gap is not None else max(22, sw * 0.5)
    tail_h = tail_len * h
    total = sw + h + tail_h                      # glyph height incl. stroke
    top = 520 - total / 2 + sw / 2
    L, R, TOP, BOT = 512 - w / 2, 512 + w / 2, top, top + h
    # tail on the bottom edge
    rl = max(L + r, L + 0.30 * w); rr = rl + 0.18 * w
    tip = (L + 0.21 * w, BOT + tail_h)
    c1 = (rl - 8, BOT + 0.55 * tail_h); c2 = (L + 0.38 * w, BOT + 0.72 * tail_h)
    if tail == 'right':
        m = lambda x: 1024 - x
        rl, rr = m(rr), m(rl); tip = (m(tip[0]), tip[1]); c1, c2 = (m(c2[0]), c2[1]), (m(c1[0]), c1[1])
    tailp = f'H {rl:.1f} Q {c1[0]:.1f} {c1[1]:.1f} {tip[0]:.1f} {tip[1]:.1f} Q {c2[0]:.1f} {c2[1]:.1f} {rr:.1f} {BOT:.1f}'
    d = (f'M {L+r:.1f} {TOP:.1f} A {r} {r} 0 0 0 {L:.1f} {TOP+r:.1f} V {BOT-r:.1f} A {r} {r} 0 0 0 {L+r:.1f} {BOT:.1f} '
         f'{tailp} H {R-r:.1f} A {r} {r} 0 0 0 {R:.1f} {BOT-r:.1f} V {TOP+r:.1f} A {r} {r} 0 0 0 {R-r:.1f} {TOP:.1f} Z')
    # waveform
    inner_top, inner_bot = TOP + sw / 2, BOT - sw / 2
    mid = (inner_top + inner_bot) / 2 - 0.03 * h
    stem_bot = inner_bot - gap - bw / 2 - stem_extra
    half_avail = w / 2 - sw / 2 - gap - bw / 2
    # a pill-shaped bubble has less room near its corners, keep bars inside the curve
    if r > h * 0.35:
        half_avail -= r * 0.28
    step = half_avail / n
    tallest = (stem_bot - mid) * 2 * peak
    bars = ''
    for i in range(1, n + 1):
        bh = max(bw * 0.2, tallest * (1 - falloff * (i - 1) / max(1, n - 1)) if n > 1 else tallest)
        for x in (512 - i * step, 512 + i * step):
            bars += f'<path d="M {x:.1f} {mid-bh/2:.1f} V {mid+bh/2:.1f}" stroke-width="{bw}"/>'
    stem = f'<path d="M 512 {TOP:.1f} V {stem_bot:.1f}" stroke-width="{bw}"/>'
    g = (f'<g stroke="url(#ink)" stroke-linecap="round" stroke-linejoin="round" fill="none" filter="url(#lift)">'
         f'<path d="{d}" stroke-width="{sw}"/>{stem}{bars}</g>')
    return frame(DEFS, 'url(#bg)', g, rim="#ffffff", rim_op=0.3)

VARIANTS = {
 'R1-thin':        dict(w=560, h=420, r=120, sw=34, n=3, falloff=0.6),
 'R2-fine-dense':  dict(w=520, h=380, r=110, sw=24, n=4, falloff=0.7, peak=0.82),
 'R3-medium':      dict(w=560, h=430, r=115, sw=46, n=2, falloff=0.5),
 'R4-small':       dict(w=430, h=330, r=95,  sw=40, n=2, falloff=0.5),
 'R5-heavy':       dict(w=540, h=420, r=120, sw=66, bw=54, n=2, falloff=0.5, peak=0.62),
 'R6-pill':        dict(w=600, h=400, r=200, sw=42, n=3, falloff=0.6, peak=0.8),
 'R7-square-thin-bars': dict(w=560, h=440, r=70, sw=52, bw=34, n=3, falloff=0.6),
 'R8-wide-right-tail':  dict(w=630, h=380, r=110, sw=40, n=3, falloff=0.6, tail='right'),
}
if __name__ == '__main__':
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    for k, v in VARIANTS.items():
        open(f'{out}/{k}.svg', 'w').write(icon(**v))
    print(list(VARIANTS))
