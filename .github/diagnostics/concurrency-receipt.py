"""Only source-relative compiler diagnostics and numeric counters may leave VM."""
import json, os, pathlib, re
out = {}
for role in ['head','base']:
    log=(pathlib.Path(os.environ['RUNNER_TEMP'])/'private-diagnostic-logs'/f'{role}-concurrency-census.log').read_text(errors='replace')
    matches=re.findall(r'(Sources/[A-Za-z0-9_+./-]+\.swift):(\d+):(\d+): warning: ([^\n]+)',log)
    # Concurrency warning messages describe source types, not captured runtime data.
    diagnostics=sorted(set((p,int(l),int(c),m) for p,l,c,m in matches if any(k in m.lower() for k in ['sendable','actor','concurrency','concurrent','isolated','async','data race'])))
    assert len(diagnostics)<200
    out[role]={'counts':json.loads(pathlib.Path(f'diagnostic-proof/{role}-counts.json').read_text()),'diagnostics':[{'file':p,'line':l,'column':c,'warning':m[:1500]} for p,l,c,m in diagnostics]}
pathlib.Path('diagnostic-proof/concurrency.json').write_text(json.dumps(out,indent=2))
