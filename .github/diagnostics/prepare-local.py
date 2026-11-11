"""Local-VM adapter: reuse reviewed fixture functions without spoofing hosted identity."""
import importlib.util, json, os, pathlib, pwd, runpy, subprocess
p = pathlib.Path
spec = importlib.util.spec_from_file_location('setup', '../reviewed-harness/scripts/ci/prepare-hosted-qa-artifacts.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
guard = runpy.run_path('scripts/ops/native-smoke-isolation.py')
assert guard['in_throwaway_ci_vm']() and guard['allowed'](**guard['current_state']())
assert os.environ['RUNNER_ENVIRONMENT'] == 'self-hosted'
a = pwd.getpwuid(os.getuid())
assert os.getuid() != 0 and os.getuid() == os.geteuid() == os.stat('/dev/console').st_uid
assert p.home() == p(a.pw_dir)
assert 'admin' not in subprocess.check_output(['id', '-Gn'], text=True).split()
assert not any(os.environ.get(k) for k in ['TRANSCRIPTED_DATA_DIR', 'TRANSCRIPTED_MEETINGS_DIR', 'TRANSCRIPTED_DICTATIONS_DIR', 'TRANSCRIPTED_WRITING_DIR'])
dest = p.home() / 'Library/Application Support/Transcripted'
for path in [dest, p.home() / 'Documents/Transcripted', p.home() / 'Library/Application Support/Draft']:
    m.absent(path)
assert not any(x.is_symlink() for x in dest.parents)
evidence = p(os.environ['RUNNER_TEMP']) / 'local-qa-artifact-setup'
m.absent(evidence); evidence.mkdir(mode=0o700)
receipt = {'proof': 'Synthetic defaults in genuine ephemeral local Actions VM', 'complete': False, 'harness_sha': '8a38235eef00816a79daa1324387a21ef880204d'}
qa = ['swift', 'run', '--package-path', 'Tools/TranscriptedQA', 'transcripted-qa']
def run(args, name):
    with (evidence / (name + '.log')).open('w') as f:
        r = subprocess.run(qa + args, stdout=f, stderr=subprocess.STDOUT)
    return r.returncode, (evidence / (name + '.log')).read_text()
try:
    code, raw = run(['validate-all', '--format', 'json'], 'missing')
    receipt['missing_layout'] = m.bounded_report(raw); m.require_missing(receipt['missing_layout'], code)
    fixtures = evidence / 'generated'; m.absent(fixtures)
    code, _ = run(['generate-fixtures', '--output', str(fixtures)], 'generate')
    assert code == 0
    m.seed_layout(fixtures, dest)
    code, raw = run(['validate-all', '--format', 'json'], 'seeded')
    receipt['seeded_layout'] = m.bounded_report(raw); m.require_seeded(receipt['seeded_layout'], code)
    receipt['complete'] = True
finally:
    p('diagnostic-proof/fixture-receipt.json').write_text(json.dumps(receipt, indent=2))
