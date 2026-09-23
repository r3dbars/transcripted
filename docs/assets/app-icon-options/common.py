# shared squircle frame helpers
BODY = 'x="100" y="100" width="824" height="824" rx="186"'
def frame(defs, bg_fill, content, rim="#ffffff", rim_op=0.35):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
<filter id="drop" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity="0.35"/></filter>
<filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#000" flood-opacity="0.28"/></filter>
<linearGradient id="rim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{rim}" stop-opacity="{rim_op}"/><stop offset="0.5" stop-color="{rim}" stop-opacity="0.04"/><stop offset="1" stop-color="{rim}" stop-opacity="{rim_op*0.7}"/></linearGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.16"/><stop offset="0.45" stop-color="#fff" stop-opacity="0"/></linearGradient>
<clipPath id="body"><rect {BODY}/></clipPath>
{defs}
</defs>
<rect {BODY} fill="{bg_fill}" filter="url(#drop)"/>
<g clip-path="url(#body)">{content}</g>
<rect {BODY} fill="url(#sheen)"/>
<rect x="104" y="104" width="816" height="816" rx="182" fill="none" stroke="url(#rim)" stroke-width="8"/>
</svg>'''
