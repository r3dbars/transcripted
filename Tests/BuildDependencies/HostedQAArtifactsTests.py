#!/usr/bin/env python3
"""Offline fixture/evidence guards; never invoke Swift or touch account state."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('setup', Path(__file__).resolve().parents[2] / 'scripts/ci/prepare-hosted-qa-artifacts.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


def report(rows):
    values = [dict(check=check, status=status, target='PRIVATE_CANARY', detail='PRIVATE_CANARY') for check, status in rows]
    return json.dumps(dict(results=values, summary={key: sum(row['status'] == status for row in values)
                      for key, status in [('passed', 'PASS'), ('failed', 'FAIL'), ('warnings', 'WARN')]}))


class HostedQAArtifactsTests(unittest.TestCase):
    def test_missing_layout_proof(self):
        value = setup.bounded_report(report([(key, 'FAIL') for key in setup.MISSING]))
        setup.require_missing(value, 1)
        self.assertNotIn('PRIVATE_CANARY', json.dumps(value))

    def test_additional_failure_cannot_be_excused_as_missing_layout(self):
        value = setup.bounded_report(report([(key, 'FAIL') for key in setup.MISSING | {'health/macos-version'}]))
        with self.assertRaises(setup.UnsafeEvidence):
            setup.require_missing(value, 1)

    def test_unknown_check_is_rejected_without_echo(self):
        with self.assertRaises(setup.UnsafeEvidence) as error:
            setup.bounded_report(report([('PRIVATE_CANARY', 'FAIL')]))
        self.assertNotIn('PRIVATE_CANARY', str(error.exception))

    def test_malformed_summary_is_rejected(self):
        value = json.loads(report([('health/meetings-dir', 'FAIL')]))
        value['summary']['failed'] = 0
        with self.assertRaises(setup.UnsafeEvidence):
            setup.bounded_report(json.dumps(value))

    def test_missing_json_and_unknown_status_are_rejected(self):
        for value in ['PRIVATE_CANARY', report([('health/meetings-dir', 'PRIVATE_CANARY')])]:
            with self.assertRaises(setup.UnsafeEvidence):
                setup.bounded_report(value)

    def test_ambiguous_reports_and_non_scalar_fields_are_rejected(self):
        valid = report([('health/meetings-dir', 'FAIL')])
        cases = [valid + valid]
        for field in ['check', 'status']:
            value = json.loads(valid)
            value['results'][0][field] = ['PRIVATE_CANARY']
            cases.append(json.dumps(value))
        value = json.loads(valid)
        value['summary']['failed'] = True
        cases.append(json.dumps(value))
        for raw in cases:
            with self.assertRaises(setup.UnsafeEvidence):
                setup.bounded_report(raw)

    def test_empty_directory_is_not_positive_proof(self):
        value = setup.bounded_report(report([('health/meetings-dir', 'PASS')]))
        with self.assertRaises(setup.UnsafeEvidence):
            setup.require_seeded(value, 0)

    def test_complete_synthetic_positive_proof(self):
        keys = ['health/meetings-dir', 'health/state-dir', 'health/logs-dir', 'database/speakers-integrity',
                'database/stats-integrity', 'logs/jsonl-valid'] + ['transcript/yaml-present'] * 3
        value = setup.bounded_report(report([(key, 'PASS') for key in keys]))
        setup.require_seeded(value, 0)
        with self.assertRaises(setup.UnsafeEvidence):
            setup.require_seeded(value, 1)

    def test_account_guard_blocks_before_any_filesystem_mutation(self):
        with patch.dict(setup.os.environ, {'RUNNER_ENVIRONMENT': 'self-hosted'}):
            with self.assertRaises(setup.UnsafeEvidence):
                setup.hosted_paths()

    def test_seed_copies_complete_layout_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); fixtures = root / 'fixtures'; fixtures.mkdir()
            (fixtures / 'Logs').mkdir()
            for name in ['Call_a.md', 'Call_b.md', 'Call_c.md', 'speakers.sqlite', 'stats.sqlite', 'Logs/app.jsonl']:
                (fixtures / name).write_text('synthetic ' + name)
            destination = root / 'destination'
            setup.seed_layout(fixtures, destination)
            self.assertEqual(len(list((destination / 'captures/meetings').glob('*.md'))), 3)
            self.assertEqual((destination / 'state/stats.sqlite').read_bytes(), (fixtures / 'stats.sqlite').read_bytes())
            self.assertEqual((destination / 'logs/app.jsonl').read_bytes(), (fixtures / 'Logs/app.jsonl').read_bytes())
            with self.assertRaises(setup.UnsafeEvidence):
                setup.seed_layout(fixtures, destination)

    def test_missing_fixture_and_symlink_destination_fail_before_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); destination = root / 'destination'
            with self.assertRaises(setup.UnsafeEvidence):
                setup.seed_layout(root, destination)
            self.assertFalse(destination.exists())
            destination.symlink_to(root / 'absent')
            with self.assertRaises(setup.UnsafeEvidence):
                setup.seed_layout(root, destination)


if __name__ == '__main__':
    unittest.main()
