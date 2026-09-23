# Round 6: polished speech bubble icon. Squircle tile, layered light, glossy tube glyph.
import math

def squircle(x0=100, y0=100, w=824, h=824, R=185, sm=0.6):
    """Rounded square with smoothed (continuous) corners, like Apple's icon shape."""
    p = (1 + sm) * R
    arc = 90 * (1 - sm)
    Ls = math.sin(math.radians(arc / 2)) * R * math.sqrt(2)
    alpha = (90 - arc) / 2
    p34 = R * math.tan(math.radians(alpha / 2))
    beta = 45 * sm
    c = p34 * math.cos(math.radians(beta))
    d = c * math.tan(math.radians(beta))
    b = (p - Ls - c - d) / 3
    a = 2 * b
    f = lambda v: f'{v:.3f}'
    return (f'M {f(x0+w-p)} {f(y0)} '
            f'c {f(a)} 0 {f(a+b)} 0 {f(a+b+c)} {f(d)} a {R} {R} 0 0 1 {f(Ls)} {f(Ls)} c {f(d)} {f(c)} {f(d)} {f(b+c)} {f(d)} {f(a+b+c)} '
            f'L {f(x0+w)} {f(y0+h-p)} '
            f'c 0 {f(a)} 0 {f(a+b)} {f(-d)} {f(a+b+c)} a {R} {R} 0 0 1 {f(-Ls)} {f(Ls)} c {f(-c)} {f(d)} {f(-(b+c))} {f(d)} {f(-(a+b+c))} {f(d)} '
            f'L {f(x0+p)} {f(y0+h)} '
            f'c {f(-a)} 0 {f(-(a+b))} 0 {f(-(a+b+c))} {f(-d)} a {R} {R} 0 0 1 {f(-Ls)} {f(-Ls)} c {f(-d)} {f(-c)} {f(-d)} {f(-(b+c))} {f(-d)} {f(-(a+b+c))} '
            f'L {f(x0)} {f(y0+p)} '
            f'c 0 {f(-a)} 0 {f(-(a+b))} {f(d)} {f(-(a+b+c))} a {R} {R} 0 0 1 {f(Ls)} {f(-Ls)} c {f(c)} {f(-d)} {f(b+c)} {f(-d)} {f(a+b+c)} {f(-d)} Z')

TILE = squircle()
TILE_IN = squircle(x0=101.5, y0=101.5, w=821, h=821, R=183.5)

def bubble(L, R, TOP, BOT, r, tail):
    if tail == 'corner':
        # iMessage-style tail curling out of the bottom-left corner
        return (f'M {L+r} {TOP} A {r} {r} 0 0 0 {L} {TOP+r} V {BOT-r*0.55} '
                f'C {L} {BOT-r*0.1} {L-r*0.12} {BOT+r*0.32} {L-r*0.34} {BOT+r*0.52} '
                f'C {L+r*0.2} {BOT+r*0.5} {L+r*0.55} {BOT+r*0.2} {L+r*0.8} {BOT} '
                f'H {R-r} A {r} {r} 0 0 0 {R} {BOT-r} V {TOP+r} A {r} {r} 0 0 0 {R-r} {TOP} Z')
    # classic tail dropping from the bottom edge
    w = R - L; h = BOT - TOP
    x1 = L + 0.26 * w; x2 = L + 0.44 * w; tip = (L + 0.16 * w, BOT + 0.27 * h)
    return (f'M {L+r} {TOP} A {r} {r} 0 0 0 {L} {TOP+r} V {BOT-r} A {r} {r} 0 0 0 {L+r} {BOT} H {x1} '
            f'C {x1+6} {BOT+0.10*h} {tip[0]+34} {tip[1]-18} {tip[0]} {tip[1]} '
            f'C {tip[0]+70} {tip[1]-8} {x2-40} {BOT+0.08*h} {x2} {BOT} '
            f'H {R-r} A {r} {r} 0 0 0 {R} {BOT-r} V {TOP+r} A {r} {r} 0 0 0 {R-r} {TOP} Z')

def icon(p):
    L, R, TOP, BOT, r, sw = p['L'], p['R'], p['TOP'], p['BOT'], p['r'], p['sw']
    bw = p.get('bw', sw)
    d = bubble(L, R, TOP, BOT, r, p.get('tail', 'classic'))
    inner_top, inner_bot = TOP + sw / 2, BOT - sw / 2
    mid = (inner_top + inner_bot) / 2 - 4
    stem_bot = inner_bot - p.get('gap', 30) - bw / 2
    d += f' M 512 {TOP} V {stem_bot}'
    # optical spacing: outer bars sit a touch closer so the group reads evenly inside the curve
    for dx, hh in p['bars']:
        for x in (512 - dx, 512 + dx):
            d += f' M {x} {mid-hh/2:.1f} V {mid+hh/2:.1f}'
    ink0, ink1, ink2 = p['ink']
    bg0, bg1, bg2 = p['bg']
    glow = p.get('glow', '#ff7a2e')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="{bg0}"/><stop offset="0.55" stop-color="{bg1}"/><stop offset="1" stop-color="{bg2}"/></linearGradient>
  <radialGradient id="topLight" cx="512" cy="60" r="620" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
  <radialGradient id="warm" cx="512" cy="520" r="360" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="{glow}" stop-opacity="{p.get('warm', 0.22)}"/><stop offset="1" stop-color="{glow}" stop-opacity="0"/></radialGradient>
  <linearGradient id="rim" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.34"/><stop offset="0.3" stop-color="#ffffff" stop-opacity="0.06"/>
    <stop offset="0.8" stop-color="#ffffff" stop-opacity="0.02"/><stop offset="1" stop-color="#ffffff" stop-opacity="0.12"/></linearGradient>
  <linearGradient id="ink" x1="0" y1="{TOP-40}" x2="0" y2="{BOT+140}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="{ink0}"/><stop offset="0.5" stop-color="{ink1}"/><stop offset="1" stop-color="{ink2}"/></linearGradient>
  <clipPath id="tile"><path d="{TILE}"/></clipPath>
  <filter id="tileShadow" x="-15%" y="-15%" width="130%" height="135%">
    <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.32"/>
    <feDropShadow dx="0" dy="2" stdDeviation="2" flood-color="#000" flood-opacity="0.25"/></filter>
  <filter id="noise" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" stitchTiles="stitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 0.05 0"/></filter>
  <filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="26"/></filter>
  <filter id="drop" x="-20%" y="-20%" width="140%" height="150%"><feGaussianBlur stdDeviation="10"/></filter>
  <filter id="glass" x="-10%" y="-10%" width="120%" height="120%" color-interpolation-filters="sRGB">
    <feGaussianBlur in="SourceAlpha" stdDeviation="{sw*0.16:.1f}" result="b"/>
    <feSpecularLighting in="b" surfaceScale="{sw*0.09:.1f}" specularConstant="0.95" specularExponent="34" lighting-color="#fff6ea" result="spec">
      <feDistantLight azimuth="265" elevation="58"/></feSpecularLighting>
    <feComposite in="spec" in2="SourceAlpha" operator="in" result="specIn"/>
    <feComponentTransfer in="specIn" result="specSoft"><feFuncA type="linear" slope="{p.get('gloss', 0.55)}"/></feComponentTransfer>
    <feOffset in="SourceAlpha" dy="-{sw*0.14:.1f}" result="up"/>
    <feComposite in="SourceAlpha" in2="up" operator="out" result="lowerEdge"/>
    <feGaussianBlur in="lowerEdge" stdDeviation="{sw*0.08:.1f}" result="lowerSoft"/>
    <feFlood flood-color="{p.get('shade', '#8a2410')}" flood-opacity="0.5"/>
    <feComposite in2="lowerSoft" operator="in"/>
    <feComposite in2="SourceAlpha" operator="in" result="shade"/>
    <feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="shade"/><feMergeNode in="specSoft"/></feMerge>
  </filter>
</defs>
<path d="{TILE}" fill="url(#bg)" filter="url(#tileShadow)"/>
<g clip-path="url(#tile)">
  <rect x="100" y="100" width="824" height="824" fill="url(#topLight)"/>
  <rect x="100" y="100" width="824" height="824" fill="url(#warm)"/>
  <rect x="100" y="100" width="824" height="824" filter="url(#noise)" opacity="0.6"/>
  <g transform="translate({p.get('dx', 9)} {p.get('dy', 28)})">
  <path d="{d}" fill="none" stroke="{glow}" stroke-opacity="{p.get('glowOp', 0.45)}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round" filter="url(#glow)"/>
  <path d="{d}" fill="none" stroke="#000" stroke-opacity="0.35" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round" transform="translate(0 12)" filter="url(#drop)"/>
  <path d="{d}" fill="none" stroke="url(#ink)" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round" filter="url(#glass)"/>
  </g>
</g>
<path d="{TILE_IN}" fill="none" stroke="url(#rim)" stroke-width="3"/>
</svg>'''

PLUM = ('#44304e', '#211727', '#110c15')
INK = ('#ffc774', '#ff8b37', '#ef5328')
BARS = [(92, 196), (178, 104)]
V = {
 'P1-glossy':  dict(L=258, R=790, TOP=262, BOT=636, r=124, sw=52, tail='corner', bars=BARS, bg=PLUM, ink=INK, gloss=0.38, glowOp=0.3, warm=0.16),
 'P2-pill':    dict(L=250, R=796, TOP=268, BOT=640, r=186, sw=50, tail='corner', bars=[(88, 196), (172, 112)], bg=PLUM, ink=INK, gloss=0.38, glowOp=0.3, warm=0.16),
 'P3-matte':   dict(L=258, R=790, TOP=262, BOT=636, r=124, sw=52, tail='corner', bars=BARS, bg=PLUM, ink=('#ffb866', '#ff8a3a', '#f0602c'), gloss=0.16, glowOp=0.12, warm=0.08),
 'P4-ember':   dict(L=258, R=790, TOP=262, BOT=636, r=124, sw=52, tail='corner', bars=BARS,
                    bg=('#322b2e', '#151113', '#090808'), ink=('#ffdca0', '#ff9a45', '#ff5a2a'), gloss=0.42, glowOp=0.5, warm=0.26),
}
for k, v in V.items():
    open(k + '.svg', 'w').write(icon(v))
print(list(V))
