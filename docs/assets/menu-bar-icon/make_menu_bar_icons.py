#!/usr/bin/env python3
"""Menu bar glyphs for Transcripted: the app icon's bubble + hidden T as a one-color template.

Geometry is the app icon's own (docs/assets/app-icon-options/round8/H-mono-light.svg, 1024 design
units). Arcs are written as cubic Beziers so this file and Sources/UI/MenuBar/MenuBarGlyph.swift
draw the exact same curves. Keep the numbers in the two files in sync.

    python3 make_menu_bar_icons.py      # writes idle.svg, dictating.svg, meeting.svg + preview.html
"""
import math

SW = 60                                   # stroke width (same as the app icon)
L, R, TOP, BOT, RAD = 236, 788, 246, 676, 110
CX, MID = 512, 450
CB = 110                                  # T crossbar half-length
GAP = 26                                  # gap between the crossbar and the rest of the outline
STEM_BOT = 585
SIDE_BARS = [(138, 200)]                   # (offset from centre, height); the icon's outer pair is
                                          # dropped because it smears at menu bar size, and the
                                          # remaining pair sits halfway between the stem and the wall
DOT_C, DOT_R, DOT_RING = (744, 757), 84, 44   # meeting "recording" dot and the clear ring around it
# Glyph bounds incl. stroke: x 206..818, y 216..834 -> a 640-unit square centred on the mark.
BOX_X, BOX_Y, BOX = 192, 205, 640


def arc(c, r, a0, a1):
    """Cubic Bezier for a circular arc from angle a0 to a1 (radians, y-down, any direction)."""
    k = 4 / 3 * math.tan((a1 - a0) / 4)
    p0 = (c[0] + r * math.cos(a0), c[1] + r * math.sin(a0))
    p3 = (c[0] + r * math.cos(a1), c[1] + r * math.sin(a1))
    p1 = (p0[0] - k * r * math.sin(a0), p0[1] + k * r * math.cos(a0))
    p2 = (p3[0] + k * r * math.sin(a1), p3[1] - k * r * math.cos(a1))
    return p0, p1, p2, p3


def f(p):
    return f'{p[0]:.2f} {p[1]:.2f}'


def outline_d():
    # The outline starts and ends on the top corner arcs, leaving a gap on each side of the crossbar.
    x_end = CX - CB - SW - GAP
    th = math.asin(((L + RAD) - x_end) / RAD)          # angle from straight up
    tl_c, bl_c, br_c, tr_c = (L + RAD, TOP + RAD), (L + RAD, BOT - RAD), (R - RAD, BOT - RAD), (R - RAD, TOP + RAD)
    up = -math.pi / 2
    segs = []
    p0, p1, p2, p3 = arc(tl_c, RAD, up - th, -math.pi)
    d = f'M {f(p0)} C {f(p1)} {f(p2)} {f(p3)} L {L} {BOT-RAD} '
    _, p1, p2, p3 = arc(bl_c, RAD, math.pi, math.pi / 2)
    d += f'C {f(p1)} {f(p2)} {f(p3)} '
    d += f'L 404 {BOT} Q 396 748 350 804 Q 446 770 504 {BOT} L {R-RAD} {BOT} '
    _, p1, p2, p3 = arc(br_c, RAD, math.pi / 2, 0)
    d += f'C {f(p1)} {f(p2)} {f(p3)} L {R} {TOP+RAD} '
    _, p1, p2, p3 = arc(tr_c, RAD, 0, up + th)
    d += f'C {f(p1)} {f(p2)} {f(p3)}'
    return d


def body_d():
    # Closed silhouette of the bubble (for the filled "recording" states).
    tl_c, bl_c, br_c, tr_c = (L + RAD, TOP + RAD), (L + RAD, BOT - RAD), (R - RAD, BOT - RAD), (R - RAD, TOP + RAD)
    d = f'M {L+RAD} {TOP} '
    for c, a0, a1, nxt in [(tl_c, -math.pi / 2, -math.pi, f'L {L} {BOT-RAD} '),
                           (bl_c, math.pi, math.pi / 2, f'L 404 {BOT} Q 396 748 350 804 Q 446 770 504 {BOT} L {R-RAD} {BOT} '),
                           (br_c, math.pi / 2, 0, f'L {R} {TOP+RAD} '),
                           (tr_c, 0, -math.pi / 2, 'Z')]:
        _, p1, p2, p3 = arc(c, RAD, a0, a1)
        d += f'C {f(p1)} {f(p2)} {f(p3)} {nxt}'
    return d


def bars():
    out = [f'M {CX} {TOP} V {STEM_BOT}']
    for dx, h in SIDE_BARS:
        for x in (CX - dx, CX + dx):
            out.append(f'M {x} {MID-h/2} V {MID+h/2}')
    return out


S = f'stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round"'


def svg(state, ink='#000', size=None):
    size_attr = f' width="{size}" height="{size}"' if size else ''
    if state == 'idle':
        body = (f'<g stroke="{ink}" fill="none" {S}><path d="{outline_d()}"/>'
                f'<path d="M {CX-CB} {TOP} H {CX+CB}"/>' + ''.join(f'<path d="{b}"/>' for b in bars()) + '</g>')
    else:
        # Filled bubble with the stem and side bars knocked out. The stem starts under the top edge
        # so the solid top edge reads as the T's crossbar.
        cut = [f'M {CX} {TOP+SW} V {STEM_BOT}'] + bars()[1:]
        mask = (f'<mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
                f'<rect width="1024" height="1024" fill="#fff"/>'
                f'<g stroke="#000" fill="none" {S}>' + ''.join(f'<path d="{b}"/>' for b in cut) + '</g>')
        if state == 'meeting':
            mask += f'<circle cx="{DOT_C[0]}" cy="{DOT_C[1]}" r="{DOT_R+DOT_RING}" fill="#000"/>'
        mask += '</mask>'
        body = (f'<defs>{mask}</defs><path d="{body_d()}" fill="{ink}" stroke="{ink}" {S} mask="url(#m)"/>')
        if state == 'meeting':
            body += f'<circle cx="{DOT_C[0]}" cy="{DOT_C[1]}" r="{DOT_R}" fill="{ink}"/>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg"{size_attr} viewBox="{BOX_X} {BOX_Y} {BOX} {BOX}">'
            f'{body}</svg>')


if __name__ == '__main__':
    for st in ('idle', 'dictating', 'meeting'):
        open(f'{st}.svg', 'w').write(svg(st))
    print('wrote idle.svg dictating.svg meeting.svg')
