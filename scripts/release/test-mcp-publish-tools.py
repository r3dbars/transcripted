#!/usr/bin/env python3
"""Offline publisher-integrity and publish-rerun contracts; never publish anything."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def workflow_script(name):
    """Execute the real literal shell body, with all remote collaborators replaced."""
    lines = (ROOT / '.github/workflows/publish-mcp-registry.yml').read_text().splitlines()
    start = lines.index('      - name: ' + name)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith('      - name: ')), len(lines))
    body = lines[start:end]
    run = body.index('        run: |')
    return '\n'.join(line[10:] if line.startswith('          ') else line for line in body[run + 1:]) + '\n'


class PublishToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='transcripted-mcp-tool-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / 'bin').mkdir()
        (self.root / 'tmp').mkdir()
        self.env = {**os.environ, 'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                    'TMPDIR': str(self.root / 'tmp'), 'CALL_LOG': str(self.root / 'calls'),
                    'GH_TOKEN': '', 'GITHUB_TOKEN': ''}

    def executable(self, name, content):
        path = self.root / 'bin' / name
        path.write_text('#!/bin/bash\nset -eu\n' + content + '\n')
        path.chmod(0o755)

    def installer(self, architecture='arm64', corrupt=False, pin=True):
        script = self.root / 'scripts/release/install-mcp-publisher.sh'
        script.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/release/install-mcp-publisher.sh', script)
        pins = self.root / '.github/mcp-publish-tools'
        pins.mkdir(parents=True)
        archive = self.root / 'fixture.tar.gz'
        with tarfile.open(archive, 'w:gz') as output:
            entry = tarfile.TarInfo('mcp-publisher')
            data = b'synthetic publisher bytes; never executed\n'
            entry.size, entry.mode = len(data), 0o755
            output.addfile(entry, io.BytesIO(data))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        # Only trusted pin DATA differs in this owned repository; the installer is unchanged.
        (pins / 'mcp-publisher-v1.8.8.sha256').write_text(''.join(
            f'{digest}  mcp-publisher_darwin_{arch}.tar.gz\n' for arch in ('arm64', 'amd64')
        ) if pin else '')
        if corrupt:
            archive.write_bytes(archive.read_bytes() + b'tampered bytes')
        self.env['FIXTURE_ARCHIVE'] = str(archive)
        self.executable('uname', f'if [ "$1" = -s ]; then echo Darwin; else echo {architecture}; fi')
        self.executable('curl', 'printf "%s\\n" "$*" >> "$CALL_LOG"\nwhile [ "$1" != -o ]; do shift; done\ncp "$FIXTURE_ARCHIVE" "$2"')
        real_tar = shutil.which('tar')
        self.executable('tar', f'echo extracted >> "$CALL_LOG"\nexec "{real_tar}" "$@"')
        destination = self.root / 'publisher'
        result = subprocess.run(['bash', str(script), str(destination)], env=self.env, capture_output=True, text=True)
        return result, destination

    def test_valid_archive_installs_on_both_supported_architectures(self):
        for architecture in ('arm64', 'x86_64'):
            with self.subTest(architecture=architecture):
                # Each install is a separate, automatically cleaned owned fixture.
                result, destination = self.installer(architecture)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(destination.read_bytes(), b'synthetic publisher bytes; never executed\n')
                self.assertTrue(os.access(destination, os.X_OK))
                self.assertIn('/releases/download/v1.8.8/mcp-publisher_darwin_', (self.root / 'calls').read_text())
                self.assertEqual(list((self.root / 'tmp').iterdir()), [])
                shutil.rmtree(self.root / 'scripts')
                shutil.rmtree(self.root / '.github')

    def test_tampered_archive_is_rejected_before_extraction_or_installation(self):
        result, destination = self.installer(corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())
        self.assertNotIn('extracted', (self.root / 'calls').read_text())
        self.assertEqual(list((self.root / 'tmp').iterdir()), [])

    def test_missing_pin_fails_before_download(self):
        result, destination = self.installer(pin=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())
        self.assertFalse((self.root / 'calls').exists())

    def test_unsupported_architecture_fails_before_download(self):
        result, destination = self.installer(architecture='unrecognized')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())
        self.assertFalse((self.root / 'calls').exists())

    def test_reused_bundle_does_not_install_or_execute_tools(self):
        work = self.root / 'mcpb'
        work.mkdir()
        bundle = work / 'fixture.mcpb'
        bundle.write_bytes(b'previously published bundle')
        output = self.root / 'outputs'
        for name in ('npm', 'npx', 'gh', 'hdiutil', 'codesign', 'lipo', 'zip'):
            self.executable(name, 'echo unexpected-tool >> "$CALL_LOG"\nexit 97')
        env = {**self.env, 'RUNNER_TEMP': str(self.root), 'GITHUB_OUTPUT': str(output),
               'REUSED': 'true', 'BUNDLE_NAME': bundle.name, 'TAG': 'v1.2.3', 'VERSION': '1.2.3'}
        result = subprocess.run(['bash', '-c', workflow_script('Reuse or build the bundle')], cwd=self.root, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(bundle.read_bytes(), b'previously published bundle')
        self.assertIn('uploaded=true', output.read_text())
        self.assertFalse((self.root / 'calls').exists())

    def test_registered_version_skips_publisher_download_and_execution(self):
        self.executable('curl', 'printf 200')
        result = subprocess.run(['bash', '-c', workflow_script('Publish to MCP Registry')], cwd=self.root,
                                env={**self.env, 'VERSION': '1.2.3'}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('nothing to publish', result.stdout)
        self.assertFalse((self.root / 'mcp-publisher').exists())

    def test_validator_lock_covers_every_resolved_package(self):
        folder = ROOT / '.github/mcp-publish-tools'
        manifest = json.loads((folder / 'package.json').read_text())
        lock = json.loads((folder / 'package-lock.json').read_text())
        self.assertEqual(manifest['dependencies'], {'@anthropic-ai/mcpb': '2.1.2'})
        self.assertEqual(lock['packages']['']['dependencies'], manifest['dependencies'])
        for path, package in lock['packages'].items():
            if path:
                self.assertTrue(package['integrity'].startswith('sha512-'), path)
                self.assertTrue(package['resolved'].startswith('https://registry.npmjs.org/'), path)


if __name__ == '__main__':
    unittest.main()
