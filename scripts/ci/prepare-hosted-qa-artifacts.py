#!/usr/bin/env python3
"""Seed disposable hosted QA state with the candidate's synthetic fixture generator.

Never runs on the owner's account. Raw validator output stays on the runner;
only fixed check identifiers, statuses and counts enter receipts.
"""
import argparse
import collections
import json
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import sys

KNOWN_CHECKS = frozenset("""
database/speakers-callcount-positive
database/speakers-confidence-range
database/speakers-embedding-size
database/speakers-exists
database/speakers-integrity
database/speakers-name-source
database/speakers-no-null-embeddings
database/speakers-open
database/speakers-permissions
database/speakers-schema
database/speakers-valid-uuids
database/speakers-wal-mode
database/stats-exists
database/stats-integrity
database/stats-open
database/stats-permissions
database/stats-positive-durations
database/stats-schema-daily
database/stats-schema-recordings
database/stats-valid-dates
dictation/body-nonempty
dictation/capture-type
dictation/date-present
dictation/dir-readable
dictation/entry-ids
dictation/files-exist
dictation/readable
dictation/yaml-present
health/disk-space
health/logs-dir
health/macos-version
health/meetings-dir
health/no-crashes
health/state-dir
logs/file-exists
logs/jsonl-entry-count
logs/jsonl-error-rate
logs/jsonl-required-keys
logs/jsonl-valid
logs/jsonl-valid-levels
logs/jsonl-valid-subsystems
logs/not-empty
logs/readable
transcript/body-has-sections
transcript/dir-readable
transcript/files-exist
transcript/legacy-sidecar-optional
transcript/legacy-sidecar-present
transcript/permissions
transcript/readable
transcript/yaml-capture-quality
transcript/yaml-count-mic_utterances
transcript/yaml-count-system_utterances
transcript/yaml-count-total_word_count
transcript/yaml-engine-diarize
transcript/yaml-engine-stt
transcript/yaml-present
transcript/yaml-required-keys
transcript/yaml-sources
writing/accepted-words
writing/capture-type
writing/date-present
writing/dir-readable
writing/entries-parse
writing/entries-present
writing/filename-date
writing/format-version
writing/readable
writing/yaml-present
""".split())
MISSING = {'health/meetings-dir', 'transcript/dir-readable'}


class UnsafeEvidence(Exception):
    pass


def bounded_report(text):
    if len(text) > 4_000_000:
        raise UnsafeEvidence('Validator report exceeds bound.')
    decoder = json.JSONDecoder()
    report = None
    index = 0
    while index < len(text):
        if text[index] != '{':
            index += 1
            continue
        try:
            candidate, consumed = decoder.raw_decode(text[index:])
        except ValueError:
            index += 1
            continue
        index += consumed
        if isinstance(candidate, dict) and 'results' in candidate and 'summary' in candidate:
            if report is not None:
                raise UnsafeEvidence('Multiple validator reports are ambiguous.')
            report = candidate
    if not report or not isinstance(report['results'], list) or not 1 <= len(report['results']) <= 2000:
        raise UnsafeEvidence('Validator report is missing or malformed.')
    counts = collections.Counter()
    checks = collections.Counter()
    for row in report['results']:
        if (not isinstance(row, dict) or not isinstance(row.get('check'), str)
                or not isinstance(row.get('status'), str) or row['check'] not in KNOWN_CHECKS
                or row.get('status') not in {'PASS', 'WARN', 'FAIL'}):
            raise UnsafeEvidence('Validator result contains an unknown check or status.')
        counts[row['status']] += 1
        checks[(row['check'], row['status'])] += 1
    summary = {'passed': counts['PASS'], 'failed': counts['FAIL'], 'warnings': counts['WARN']}
    if (not isinstance(report['summary'], dict)
            or any(type(value) is not int for value in report['summary'].values())
            or report['summary'] != summary):
        raise UnsafeEvidence('Validator summary does not match results.')
    return {'summary': summary, 'checks': [dict(check=key[0], status=key[1], count=count)
            for key, count in sorted(checks.items())]}


def require_missing(report, code):
    failed = {row['check'] for row in report['checks'] if row['status'] == 'FAIL'}
    if code != 1 or failed != MISSING or report['summary']['failed'] != 2:
        raise UnsafeEvidence('Fresh-runner failure differs from the missing-meetings hypothesis.')


def require_seeded(report, code):
    passed = {row['check']: row['count'] for row in report['checks'] if row['status'] == 'PASS'}
    required = {'health/meetings-dir', 'health/state-dir', 'health/logs-dir',
                'database/speakers-integrity', 'database/stats-integrity', 'logs/jsonl-valid'}
    if (code != 0 or report['summary']['failed'] or not required <= passed.keys()
            or passed.get('transcript/yaml-present') != 3):
        raise UnsafeEvidence('Synthetic default layout did not validate completely.')


def absent(path):
    if path.exists() or path.is_symlink():
        raise UnsafeEvidence('Refusing to overwrite an existing fixture or application path.')


def seed_layout(fixtures, destination):
    absent(destination)
    transcripts = sorted(fixtures.glob('Call_*.md'))
    sources = transcripts + [fixtures / 'speakers.sqlite', fixtures / 'stats.sqlite', fixtures / 'Logs/app.jsonl']
    if len(transcripts) != 3 or any(not p.is_file() or p.is_symlink() for p in sources):
        raise UnsafeEvidence('Generated fixture layout is incomplete or unsafe.')
    destination.mkdir(parents=True, mode=0o700)
    for folder in ['captures/meetings', 'captures/dictations', 'captures/writing', 'state', 'logs']:
        (destination / folder).mkdir(parents=True, mode=0o700)
    for source in transcripts:
        shutil.copy2(source, destination / 'captures/meetings' / source.name)
    for name in ['speakers.sqlite', 'stats.sqlite']:
        shutil.copy2(fixtures / name, destination / 'state' / name)
    shutil.copy2(fixtures / 'Logs/app.jsonl', destination / 'logs/app.jsonl')


def hosted_paths():
    account = pwd.getpwuid(os.getuid())
    if (os.getuid() == 0 or os.getuid() != os.geteuid()
            or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or os.environ.get('GITHUB_ACTIONS') != 'true'
            or platform.system() != 'Darwin' or platform.machine() != 'arm64'
            or account.pw_name != 'runner' or account.pw_dir != '/Users/runner'
            or Path.home() != Path(account.pw_dir)):
        raise UnsafeEvidence('Fixture setup requires the disposable hosted runner account.')
    if any(os.environ.get(key) for key in ['TRANSCRIPTED_DATA_DIR', 'TRANSCRIPTED_MEETINGS_DIR',
            'TRANSCRIPTED_DICTATIONS_DIR', 'TRANSCRIPTED_WRITING_DIR']):
        raise UnsafeEvidence('Capture overrides would invalidate default-path evidence.')
    home = Path(account.pw_dir)
    destination = home / 'Library/Application Support/Transcripted'
    for path in [destination, home / 'Documents/Transcripted',
                 home / 'Library/Application Support/Draft']:
        absent(path)
    for ancestor in destination.parents:
        if ancestor.is_symlink():
            raise UnsafeEvidence('Application path has a symlink ancestor.')
    temporary = Path(os.environ['RUNNER_TEMP'])
    if not temporary.is_absolute() or not temporary.is_dir():
        raise UnsafeEvidence('Runner temporary directory is unavailable.')
    return destination, temporary


def prepare(candidate):
    destination, temporary = hosted_paths()
    candidate = candidate.resolve(strict=True)
    source_sha = os.environ['SOURCE_SHA']
    actual = subprocess.check_output(['git', '-C', str(candidate), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != source_sha:
        raise UnsafeEvidence('Candidate identity differs from the requested source.')
    workflow_sha = os.environ['WORKFLOW_SHA']
    harness = Path(__file__).resolve().parents[2]
    actual_workflow = subprocess.check_output(['git', '-C', str(harness), 'rev-parse', 'HEAD'], text=True).strip()
    if actual_workflow != workflow_sha:
        raise UnsafeEvidence('Harness identity differs from the workflow.')
    evidence = temporary / 'qa-artifact-setup'
    absent(evidence)
    evidence.mkdir(mode=0o700)
    qa = ['swift', 'run', '--package-path', str(candidate / 'Tools/TranscriptedQA'), 'transcripted-qa']
    receipt = {'source_sha': source_sha, 'workflow_sha': workflow_sha, 'proof': 'Synthetic default artifact layout on a fresh hosted account',
               'original_run_failure_cause': 'unrecovered; original raw step log was not retained', 'complete': False}
    output = temporary / 'qa-artifact-setup-receipt.json'

    def run(arguments, name):
        with (evidence / (name + '.log')).open('w') as log:
            result = subprocess.run(qa + arguments, cwd=candidate, stdout=log, stderr=subprocess.STDOUT)
        return result.returncode, (evidence / (name + '.log')).read_text()

    try:
        code, raw = run(['validate-all', '--format', 'json'], 'missing')
        receipt['missing_layout'] = bounded_report(raw)
        output.write_text(json.dumps(receipt, indent=2) + '\n')
        require_missing(receipt['missing_layout'], code)
        fixtures = evidence / 'generated'
        absent(fixtures)  # generate-fixtures deletes an existing --output directory.
        code, _ = run(['generate-fixtures', '--output', str(fixtures)], 'generate')
        if code:
            raise UnsafeEvidence('Candidate fixture generator failed.')
        seed_layout(fixtures, destination)
        code, raw = run(['validate-all', '--format', 'json'], 'seeded')
        receipt['seeded_layout'] = bounded_report(raw)
        require_seeded(receipt['seeded_layout'], code)
        receipt['complete'] = True
    finally:
        output.write_text(json.dumps(receipt, indent=2) + '\n')
    print('Synthetic default artifacts validated; original-run cause remains unrecovered.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate-root', type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.candidate_root)
    except (UnsafeEvidence, OSError, ValueError, KeyError, subprocess.SubprocessError):
        # Never echo exception values containing private paths or subprocess output.
        raise SystemExit('Hosted QA artifact setup failed; inspect bounded receipt if available.')


if __name__ == '__main__':
    main()
