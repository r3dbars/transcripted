# Round 8: wide-T bubble, light + dark tiles, non-green accents for the T
import make_appcolor_icons as ac
ACCENTS = {  # name: (on light tile, on dark tile)
  'blue':   ('#2563eb', '#4c8dff'),
  'indigo': ('#5b4fe0', '#8b82ff'),
  'red':    ('#dc3a3a', '#ff5f5f'),
  'mono':   ('#1d1d1f', '#f5f5f3'),
}
names = []
for a, (lt, dk) in ACCENTS.items():
    for mode in ('light', 'dark'):
        if mode == 'light':
            svg = ac.icon('#fbfbf9', '#e9e9e6', '#1d1d1f', lt, 0.9, 0.10)
        else:
            svg = ac.icon('#303033', '#1a1a1b', '#f5f5f3', dk, 0.28, 0.35)
        n = f'H-{a}-{mode}'
        open("round8/" + n + ".svg", "w").write(svg); names.append(n)
print(' '.join(n + '.svg' for n in names))
