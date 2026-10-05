#!/usr/bin/env python3
"""Offline fixture/evidence guards; never invoke Swift or touch account state."""
import ctypes
import ctypes.util
import importlib.util
import json
from pathlib import Path
import shutil
import stat
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
                'database/stats-integrity', 'database/speakers-wal-mode', 'database/speakers-schema',
                'database/stats-schema-recordings', 'database/stats-schema-daily', 'logs/jsonl-valid'] + ['transcript/yaml-present'] * 3
        value = setup.bounded_report(report([(key, 'PASS') for key in keys]))
        setup.require_seeded(value, 0)
        downgraded = setup.bounded_report(report([(key, 'WARN' if key == 'database/speakers-wal-mode' else 'PASS') for key in keys]))
        with self.assertRaises(setup.UnsafeEvidence):
            setup.require_seeded(downgraded, 0)
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
            for name in ['Call_a.md', 'Call_b.md', 'Call_c.md', 'speakers.sqlite', 'speakers.sqlite-wal', 'speakers.sqlite-shm',
                         'stats.sqlite', 'stats.sqlite-wal', 'stats.sqlite-shm', 'Logs/app.jsonl']:
                (fixtures / name).write_text('synthetic ' + name)
            destination = root / 'destination'
            setup.seed_layout(fixtures, destination)
            self.assertEqual(len(list((destination / 'captures/meetings').glob('*.md'))), 3)
            self.assertEqual((destination / 'state/stats.sqlite').read_bytes(), (fixtures / 'stats.sqlite').read_bytes())
            self.assertEqual((destination / 'logs/app.jsonl').read_bytes(), (fixtures / 'Logs/app.jsonl').read_bytes())
            with self.assertRaises(setup.UnsafeEvidence):
                setup.seed_layout(fixtures, destination)

    def test_closed_wal_family_survives_readonly_integrity_schema_and_rows(self):
        # Use the platform SQLite library, like the Swift generator. PERSIST_WAL
        # retains valid companion files after a successful sqlite3_close.
        library = '/usr/lib/libsqlite3.dylib' if setup.platform.system() == 'Darwin' else ctypes.util.find_library('sqlite3')
        lib = ctypes.CDLL(library)
        lib.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        lib.sqlite3_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        lib.sqlite3_file_control.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
        lib.sqlite3_close.argtypes = [ctypes.c_void_p]
        lib.sqlite3_open_v2.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_int, ctypes.c_char_p]
        lib.sqlite3_prepare_v2.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
        lib.sqlite3_step.argtypes = [ctypes.c_void_p]
        lib.sqlite3_column_count.argtypes = [ctypes.c_void_p]
        lib.sqlite3_column_text.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.sqlite3_column_text.restype = ctypes.c_char_p
        lib.sqlite3_finalize.argtypes = [ctypes.c_void_p]

        def readonly_query(path, sql):
            # Match Swift SQLiteReader: system SQLite, OPEN_READONLY, prepare,
            # step and finalize. Python's sqlite3 may use a different library
            # with different handling of missing WAL companions on hosted Macs.
            handle = ctypes.c_void_p()
            self.assertEqual(lib.sqlite3_open_v2(str(path).encode(), ctypes.byref(handle), 1, None), 0)
            statement = ctypes.c_void_p()
            try:
                code = lib.sqlite3_prepare_v2(handle, sql.encode(), -1, ctypes.byref(statement), None)
                if code != 0:
                    raise RuntimeError(f'System SQLite prepare failed with code {code}')
                rows = []
                while True:
                    code = lib.sqlite3_step(statement)
                    if code == 101:  # SQLITE_DONE
                        return rows
                    if code != 100:  # SQLITE_ROW
                        raise RuntimeError(f'System SQLite step failed with code {code}')
                    row = [lib.sqlite3_column_text(statement, column) for column in range(lib.sqlite3_column_count(statement))]
                    rows.append(tuple(value.decode() if value is not None else None for value in row))
            finally:
                if statement:
                    lib.sqlite3_finalize(statement)
                self.assertEqual(lib.sqlite3_close(handle), 0)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); fixtures = root / 'fixtures'; fixtures.mkdir()
            (fixtures / 'Logs').mkdir()
            (fixtures / 'Logs/app.jsonl').write_text('synthetic log')
            for name in ['Call_a.md', 'Call_b.md', 'Call_c.md']:
                (fixtures / name).write_text('synthetic transcript')
            for name in ['speakers.sqlite', 'stats.sqlite']:
                handle = ctypes.c_void_p()
                self.assertEqual(lib.sqlite3_open(str(fixtures / name).encode(), ctypes.byref(handle)), 0)
                try:
                    sql = b"PRAGMA journal_mode=WAL; CREATE TABLE samples(id INTEGER PRIMARY KEY, value TEXT); INSERT INTO samples VALUES(1, 'synthetic'), (2, 'second');"
                    self.assertEqual(lib.sqlite3_exec(handle, sql, None, None, None), 0)
                    persistent = ctypes.c_int(1)
                    self.assertEqual(lib.sqlite3_file_control(handle, b'main', 10, ctypes.byref(persistent)), 0)
                finally:
                    self.assertEqual(lib.sqlite3_close(handle), 0)
                for suffix in ['', '-wal', '-shm']:
                    self.assertTrue((fixtures / (name + suffix)).is_file())
                self.assertEqual(readonly_query(fixtures / name, 'PRAGMA integrity_check'), [('ok',)])
                self.assertEqual(readonly_query(fixtures / name, 'SELECT COUNT(*) FROM samples'), [('2',)])
            destination = root / 'complete'
            setup.seed_layout(fixtures, destination)
            for name in ['speakers.sqlite', 'stats.sqlite']:
                for suffix in ['', '-wal', '-shm']:
                    path = destination / 'state' / (name + suffix)
                    self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                database = destination / 'state' / name
                self.assertEqual(readonly_query(database, 'PRAGMA integrity_check'), [('ok',)])
                self.assertEqual(readonly_query(database, 'PRAGMA journal_mode'), [('wal',)])
                self.assertEqual([r[1] for r in readonly_query(database, 'PRAGMA table_info(samples)')], ['id', 'value'])
                self.assertEqual(readonly_query(database, 'SELECT * FROM samples ORDER BY id'), [('1', 'synthetic'), ('2', 'second')])
            # Reproduce the original transport: identical main bytes without
            # companions fail read-only queries on the supported macOS runner.
            if setup.platform.system() == 'Darwin':
                incomplete = root / 'incomplete'; incomplete.mkdir()
                shutil.copy2(fixtures / 'speakers.sqlite', incomplete / 'speakers.sqlite')
                with self.assertRaisesRegex(RuntimeError, 'System SQLite prepare failed with code 14'):
                    readonly_query(incomplete / 'speakers.sqlite', 'PRAGMA integrity_check')
            # A missing or redirected companion must stop before creating output.
            companion = fixtures / 'stats.sqlite-shm'
            companion.unlink()
            with self.assertRaises(setup.UnsafeEvidence):
                setup.seed_layout(fixtures, root / 'missing')
            self.assertFalse((root / 'missing').exists())
            companion.symlink_to(fixtures / 'speakers.sqlite-shm')
            with self.assertRaises(setup.UnsafeEvidence):
                setup.seed_layout(fixtures, root / 'linked')
            self.assertFalse((root / 'linked').exists())

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
