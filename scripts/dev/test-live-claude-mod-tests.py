#!/usr/bin/env python3
"""Offline contracts for the isolated unit-test front door; never launch Claude."""
import base64
import hashlib
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mod_runner', ROOT / 'scripts/dev/test-live-claude-mod.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ModTestRunnerContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='transcripted-mod-runner-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.mod = self.root / 'source-mod'
        self.mod.mkdir()
        (self.mod / 'fixture.ts').write_text('synthetic source, never executed')
        self.case = self.root / 'case'
        self.case.mkdir()
        self.executable = self.case / 'claude-native'
        self.executable.write_bytes(b'synthetic binary, never executed')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS sandbox enforcement')
    def test_real_sandbox_reads_owned_fixture_and_denies_other_owned_fixture(self):
        reader = self.case / 'reader'
        source = self.case / 'reader.c'
        source.write_text('#include <fcntl.h>\n#include <unistd.h>\nint main(int argc, char **argv) {\n    if (argc != 2) return 64;\n    int file = open(argv[1], O_RDONLY);\n    if (file < 0) return 1;\n    char buffer[256];\n    ssize_t count;\n    while ((count = read(file, buffer, sizeof buffer)) > 0) {\n        ssize_t sent = 0;\n        while (sent < count) {\n            ssize_t amount = write(STDOUT_FILENO, buffer + sent, count - sent);\n            if (amount <= 0) { close(file); return 2; }\n            sent += amount;\n        }\n    }\n    int status = count < 0 ? 3 : 0;\n    return close(file) == 0 ? status : 3;\n}\n')
        (self.case / 'compile-home').mkdir()
        (self.case / 'compile-tmp').mkdir()
        subprocess.run(['/usr/bin/cc', str(source), '-o', str(reader)], check=True, capture_output=True,
                       env={'PATH': '/usr/bin:/bin', 'HOME': str(self.case / 'compile-home'),
                            'TMPDIR': str(self.case / 'compile-tmp'),
                            'CLANG_MODULE_CACHE_PATH': str(self.case / 'module-cache')})
        inside = self.case / 'inside'
        outside = self.root / 'outside'
        inside.write_text('owned allowed bytes')
        outside.write_text('owned blocked bytes')
        policy = self.case / 'sandbox.sb'
        policy.write_text(runner.sandbox_profile(self.case))
        base = ['/usr/bin/sandbox-exec', '-f', str(policy), str(reader)]
        allowed = subprocess.run(base + [str(inside)], capture_output=True, text=True, env={}, cwd=self.case)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(allowed.stdout, 'owned allowed bytes')
        candidates = [outside]
        # Probe only this owned fixture through the APFS Data alias as well.
        alias = Path('/System/Volumes/Data') / outside.relative_to('/')
        if alias.exists() and os.path.samefile(alias, outside):
            candidates.append(alias)
        for candidate in candidates:
            denied = subprocess.run(base + [str(candidate)], capture_output=True, text=True, env={}, cwd=self.case)
            self.assertNotEqual(denied.returncode, 0)
            self.assertNotIn('owned blocked bytes', denied.stdout)

    def test_frontdoor_enables_hooks_and_strips_credentials_for_both_commands(self):
        calls = []
        def execute(arguments, **options):
            calls.append((arguments, options))
            return 0
        with patch.object(runner, 'MOD', self.mod), patch.dict(os.environ, {'ANTHROPIC_API_KEY': 'synthetic-key', 'CLAUDE_CODE_OAUTH_TOKEN': 'synthetic-token'}):
            status = runner.run_tests(self.case, self.executable, execute)
        self.assertEqual(status, 0)
        self.assertEqual([args[-2] for args, _ in calls], ['validate', 'test'])
        for args, options in calls:
            self.assertEqual(args[:2], ['/usr/bin/sandbox-exec', '-f'])
            self.assertEqual(Path(args[3]), self.executable)
            self.assertEqual(Path(args[-1]), self.case / 'plugin')
            self.assertEqual(options['cwd'], self.case / 'plugin')
            env = options['env']
            self.assertEqual(env['CLAUDE_CODE_ENABLE_FUNCTION_HOOKS'], '1')
            self.assertEqual(env['HOME'], str(self.case / 'home'))
            self.assertEqual(env['CLAUDE_CONFIG_DIR'], str(self.case / 'config'))
            self.assertEqual(env['DISABLE_AUTOUPDATER'], '1')
            self.assertNotIn('ANTHROPIC_API_KEY', env)
            self.assertNotIn('CLAUDE_CODE_OAUTH_TOKEN', env)
            self.assertEqual((self.case / 'plugin/fixture.ts').read_bytes(), (self.mod / 'fixture.ts').read_bytes())

    def test_validation_failure_stops_before_test_command(self):
        execute = Mock(return_value=17)
        with patch.object(runner, 'MOD', self.mod):
            self.assertEqual(runner.run_tests(self.case, self.executable, execute), 17)
        self.assertEqual(execute.call_count, 1)
        self.assertEqual(execute.call_args.args[0][-2], 'validate')

    def test_canonical_entry_blocks_sdk_and_download_until_genuine_proof(self):
        with patch.object(runner.sys, 'platform', 'darwin'), patch.object(runner, 'download_tool') as download, patch.object(runner, 'run_tests') as run, patch.object(runner.tempfile, 'TemporaryDirectory') as prepare:
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                for args in ([], ['--download-tool'], ['--claude', str(self.executable)]):
                    self.assertEqual(runner.main(args), 3)
            self.assertIn('Bun startup', output.getvalue())
            self.assertIn('NOT RUN', output.getvalue())
            download.assert_not_called()
            run.assert_not_called()
            prepare.assert_not_called()

    def test_unsupported_host_does_not_prepare_or_launch_tools(self):
        with patch.object(runner, 'SDK_BOOTSTRAP_VERIFIED', True), patch.object(runner.sys, 'platform', 'linux'), patch.object(runner, 'run_tests') as run:
            self.assertEqual(runner.main([]), 3)
            run.assert_not_called()

    def test_timeout_drains_only_the_new_child_group(self):
        child = Mock(pid=123456)
        child.wait.side_effect = [subprocess.TimeoutExpired('synthetic', 120), 0]
        with patch.object(runner.subprocess, 'Popen', return_value=child) as spawn, patch.object(runner.os, 'killpg') as kill:
            self.assertEqual(runner.run_isolated_command(['synthetic'], cwd=self.case, env={}), 3)
            self.assertTrue(spawn.call_args.kwargs['start_new_session'])
            kill.assert_called_once_with(child.pid, runner.signal.SIGKILL)
            self.assertEqual(child.wait.call_count, 2)

    def archive(self, linked=False):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as output:
            member = tarfile.TarInfo('package/claude')
            if linked:
                member.type, member.linkname = tarfile.SYMTYPE, '/outside/owned-case'
                output.addfile(member)
            else:
                data = b'synthetic tool; never executed'
                member.size = len(data)
                output.addfile(member, io.BytesIO(data))
        return stream.getvalue()

    def download(self, data, expected=None):
        folder = self.root / '.github/claude-mod-tests'
        folder.mkdir(parents=True)
        (folder / 'package.json').write_text(json.dumps({'dependencies': {'@anthropic-ai/claude-code': '2.1.310'}}))
        integrity = base64.b64encode(hashlib.sha512(expected if expected is not None else data).digest()).decode()
        (folder / 'package-lock.json').write_text(json.dumps({'packages': {'node_modules/@anthropic-ai/claude-code-darwin-arm64': {
            'version': '2.1.310', 'resolved': 'https://registry.npmjs.org/@anthropic-ai/fixture.tgz', 'integrity': 'sha512-' + integrity,
        }}}))
        with patch.object(runner, 'ROOT', self.root), patch.object(runner.platform, 'machine', return_value='arm64'), patch.object(runner.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = io.BytesIO(data)
            runner.download_tool(self.case / 'downloaded')

    def test_verified_regular_tool_installs_without_lifecycle_execution(self):
        self.download(self.archive())
        self.assertEqual((self.case / 'downloaded').read_bytes(), b'synthetic tool; never executed')
        self.assertTrue(os.access(self.case / 'downloaded', os.X_OK))

    def test_modified_archive_is_rejected_before_any_executable_is_written(self):
        with self.assertRaisesRegex(ValueError, 'integrity mismatch'):
            self.download(self.archive() + b'modified', expected=self.archive())
        self.assertFalse((self.case / 'downloaded').exists())

    def test_symlink_executable_is_rejected_even_with_valid_archive_integrity(self):
        with self.assertRaisesRegex(ValueError, 'regular file'):
            self.download(self.archive(linked=True))
        self.assertFalse((self.case / 'downloaded').exists())

    def test_ci_frontdoor_runs_offline_contracts_only(self):
        lines = (ROOT / '.github/workflows/swift-ci.yml').read_text().splitlines()
        start = lines.index('      - name: Claude mod wrapper contracts')
        command = next(line.removeprefix('        run: ') for line in lines[start + 1:] if line.startswith('        run: '))
        fakebin = self.root / 'bin'
        fakebin.mkdir()
        output = self.root / 'arguments'
        fake = fakebin / 'python3'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CALLS"\n')
        fake.chmod(0o755)
        result = subprocess.run(['/bin/bash', '-c', command], env={'PATH': str(fakebin), 'CALLS': str(output)}, cwd=self.root)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(output.read_text().splitlines(), ['scripts/dev/test-live-claude-mod-tests.py'])


if __name__ == '__main__':
    unittest.main()
