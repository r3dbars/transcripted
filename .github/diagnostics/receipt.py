"""Record only bounded step IDs, status, exit codes, and test counts."""
import csv, json, os, pathlib, re
p = pathlib.Path
expected = {'00-preflight','01-build','02-fast-tests','03-e2e-smoke','04-slow-pasteback-smoke','10-integration-smoke','11-core-swift-test','12-qa-cli-tests','13-qa-round-trip','14-qa-stress-small','15-imported-audio-smoke','21-qa-validate-all','30-audio-synthetic','60-release-health','62-posthog-product-tasks'}
rows = []; seen = set()
path = p(os.environ['RUNNER_TEMP']) / 'full-qa-bench/local-vm/results.tsv'
for row in csv.reader(path.read_text().splitlines(), delimiter='\t'):
    assert len(row) == 6 and row[0] in expected and row[0] not in seen
    assert row[2] in {'PASS','FAIL','WARN','SKIP'}
    assert all(re.fullmatch(r'[0-9]{1,9}', row[i]) for i in (3,4))
    seen.add(row[0]); rows.append(dict(step=row[0],status=row[2],exit=int(row[3]),seconds=int(row[4])))
counts = {}
for log in p('diagnostic-proof').glob('*.raw'):
    counts[log.stem] = [dict(tests=int(n), failures=int(f)) for n,f in re.findall(r'Executed (\d+) tests?, with (\d+) failures?', log.read_text(errors='replace'))][-40:]
receipt = dict(source_sha='e66e3e4fb7c4e73e5a6825a8f66458425ca12d16', workflow_sha=os.environ['GITHUB_SHA'], run_id=os.environ['GITHUB_RUN_ID'], proof='Local ephemeral macOS 26 Actions VM, not hosted proof', bench_steps=rows, all_expected_bench_steps=seen==expected,  test_count_summaries=counts, unknown=['real hardware','host microphone/system audio/clipboard','release/upgrade','live services'])
p('diagnostic-proof/coverage.json').write_text(json.dumps(receipt,indent=2))
assert seen == expected, 'Incomplete bench step receipt'
