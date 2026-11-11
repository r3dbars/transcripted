import pathlib, re, sys
# Fixed candidate check names and numeric counts only; never raw assertion values.
source = pathlib.Path('scripts/entrypoints/check.sh').read_text()
full = source.split('    full)\n',1)[1].split('    hardware)\n',1)[0]
allowed = set(re.findall(r'step "([^"]+)"', full))
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
for line in text.splitlines():
    row = re.fullmatch(r"(PASS|FAIL|SKIP)\s+([0-9]+s|-)\s+(.+)", line)
    if row and row[3] in allowed:
        print(f'{row[1]} {row[2]} {row[3]}')
    elif line in ('RESULT: PASS', 'RESULT: FAIL'):
        print(line)
    else:
        row = re.search(r'Executed (\d+) tests?, with (\d+) failures?', line)
        if row: print(f'Executed {int(row[1])} tests, with {int(row[2])} failures')
