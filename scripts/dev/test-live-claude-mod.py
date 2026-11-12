#!/usr/bin/env python3
"""Run only the mod's synthetic plugin tests in a disposable, sandboxed host."""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
MOD = ROOT / 'Tools/TranscriptedLive/claude-mod'
# Source gate: the pinned SDK still traps during Bun startup under this profile.
# Keep all canonical invocations blocked until genuine isolated SDK proof exists.
# scripts/dev/agent-check.py lists this script in MANUAL_COMMAND_FRAGMENTS so the
# matrix reports it BLOCKED instead of FAIL; remove it there when this flips.
SDK_BOOTSTRAP_VERIFIED = False


def download_tool(destination):
    architecture = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64'}.get(platform.machine())
    if architecture is None:
        raise ValueError('Unsupported Claude mod-test architecture')
    folder = ROOT / '.github/claude-mod-tests'
    version = json.loads((folder / 'package.json').read_text())['dependencies']['@anthropic-ai/claude-code']
    lock = json.loads((folder / 'package-lock.json').read_text())
    package = lock['packages'][f'node_modules/@anthropic-ai/claude-code-darwin-{architecture}']
    if package['version'] != version or not package['resolved'].startswith('https://registry.npmjs.org/@anthropic-ai/'):
        raise ValueError('Invalid locked Claude test-tool identity')
    algorithm, encoded = package['integrity'].split('-', 1)
    expected = base64.b64decode(encoded, validate=True)
    if algorithm != 'sha512' or len(expected) != 64:
        raise ValueError('Invalid locked Claude test-tool integrity')
    # Fetch bytes only. No npm lifecycle script, login or Claude process runs here.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(package['resolved'], timeout=60) as response:
        data = response.read()
    if hashlib.sha512(data).digest() != expected:
        raise ValueError('Claude test-tool archive integrity mismatch')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        member = archive.getmember('package/claude')
        if not member.isfile():
            raise ValueError('Claude test-tool executable is not a regular file')
        with archive.extractfile(member) as executable:
            destination.write_bytes(executable.read())
    destination.chmod(0o755)


def sandbox_profile(case):
    quote = lambda value: json.dumps(str(value))
    # Default-deny blocks all other files (including the passwd home), network,
    # Mach/keychain/preferences IPC and executable paths. Worker copies of this
    # same native CLI are the only executable code under the owned case root.
    return '\n'.join([
        '(version 1)', '(deny default)',
        # Explicit non-internal dyld bootstrap operations; do not import system.sb.
        '(allow syscall-unix (syscall-number SYS___mac_syscall SYS_getfsstat SYS_getfsstat64 '
        'SYS_map_with_linking_np SYS_open SYS_openat SYS_fstatat SYS_fstatat64 SYS_dup))',
        '(allow system-fcntl (fcntl-command F_ADDFILESIGS_RETURN F_CHECK_LV F_GETPATH))',
        '(allow system-mac-syscall (require-all (mac-policy-name "Sandbox") (mac-syscall-number 2)))',
        # These are exact directory nodes, never subpath grants for /System or Data.
        '(allow file-read* file-test-existence (literal "/") (literal "/usr") (literal "/usr/share") '
        '(literal "/System") (literal "/System/Cryptexes") (literal "/System/Cryptexes/OS") '
        '(literal "/System/Cryptexes/OS/usr") (literal "/System/Volumes") (literal "/System/Volumes/Preboot") '
        '(literal "/System/Volumes/Preboot/Cryptexes") (literal "/System/Volumes/Preboot/Cryptexes/OS") '
        '(literal "/System/Volumes/Preboot/Cryptexes/OS/usr") (literal "/System/Volumes/Preboot/Cryptexes/OS/System") '
        '(literal "/private") (literal "/private/var") (literal "/private/var/db") '
        '(literal "/etc") (literal "/private/etc") (literal "/dev"))',
        '(allow process-fork)', '(allow process-exec (subpath ' + quote(case) + '))',
        '(allow sysctl-read (sysctl-name "hw.ncpu" "hw.logicalcpu" "hw.physicalcpu" "hw.memsize" '
        '"hw.machine" "hw.optional.arm64" "kern.ostype" "kern.osrelease" "kern.version" "kern.osproductversion"))',
        '(allow signal (target self))',
        '(allow file-map-executable (subpath ' + quote(case) + ') (subpath "/usr/lib") '
        '(subpath "/System/Library") (subpath "/System/Cryptexes/OS/usr/lib") '
        '(subpath "/System/Volumes/Preboot/Cryptexes/OS/usr/lib") '
        '(subpath "/System/Volumes/Preboot/Cryptexes/OS/System/Library"))',
        '(allow file-read* (subpath ' + quote(case) + ') (subpath "/System/Library") (subpath "/usr/lib") '
        '(subpath "/System/Cryptexes/OS/usr/lib") (subpath "/System/Volumes/Preboot/Cryptexes/OS/usr/lib") '
        '(subpath "/System/Volumes/Preboot/Cryptexes/OS/System/Library") (subpath "/usr/share/zoneinfo") (subpath "/private/var/db/dyld") '
        '(subpath "/private/var/db/timezone") (literal "/etc/localtime") (literal "/private/etc/localtime") '
        '(literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))',
        '(allow file-write* (subpath ' + quote(case) + ') (literal "/dev/null"))',
    ])


def run_isolated_command(arguments, *, cwd, env):
    process = subprocess.Popen(arguments, cwd=cwd, env=env, stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        return process.wait(timeout=120)
    except subprocess.TimeoutExpired:
        print('BLOCKED: mod test command timed out.', file=sys.stderr)
        return 3
    finally:
        # This process group was created exclusively for this child. Drain all
        # workers before the owned workspace can be removed, including on timeout.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def run_tests(case, executable, execute=run_isolated_command):
    plugin = case / 'plugin'
    shutil.copytree(MOD, plugin, symlinks=True, ignore=shutil.ignore_patterns('.claude', 'node_modules'))
    for name in ('home', 'config', 'tmp'):
        (case / name).mkdir()
    environment = {
        'PATH': '/usr/bin:/bin', 'HOME': str(case / 'home'), 'CLAUDE_CONFIG_DIR': str(case / 'config'),
        'TMPDIR': str(case / 'tmp'), 'CLAUDE_CODE_ENABLE_FUNCTION_HOOKS': '1',
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1',
        'DISABLE_TELEMETRY': '1', 'DISABLE_ERROR_REPORTING': '1',
        'TRANSCRIPTED_DISABLE_FILE_LOGGER': '1', 'CI': '1', 'TERM': 'dumb', 'TZ': 'UTC',
    }
    profile = case / 'sandbox.sb'
    profile.write_text(sandbox_profile(case))
    for command in ('validate', 'test'):
        status = execute(
            ['/usr/bin/sandbox-exec', '-f', str(profile), str(executable), 'plugin', command, str(plugin)],
            cwd=plugin, env=environment,
        )
        if status != 0:
            return status if status > 0 else 128 - status
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument('--claude', help='Existing native Claude Code binary; copied, never run in place')
    choice.add_argument('--download-tool', action='store_true', help='Download only the native package pinned by the CI lockfile')
    options = parser.parse_args(argv)
    if not SDK_BOOTSTRAP_VERIFIED:
        print('BLOCKED: pinned Claude Code 2.1.310 fails Bun startup in this sandbox; '
              'actual plugin validation/tests NOT RUN. Distinct isolated CI proof is pending.', file=sys.stderr)
        return 3
    if sys.platform != 'darwin':
        print('BLOCKED: mod-test process isolation requires macOS sandbox-exec.', file=sys.stderr)
        return 3
    try:
        with tempfile.TemporaryDirectory(prefix='transcripted-claude-mod-tests-') as temporary:
            case = Path(temporary).resolve()
            executable = case / 'claude-native'
            if options.download_tool:
                download_tool(executable)
            else:
                source = options.claude or shutil.which('claude')
                if source is None:
                    print('BLOCKED: install Claude Code or use --download-tool.', file=sys.stderr)
                    return 3
                shutil.copyfile(Path(source).resolve(strict=True), executable)
                executable.chmod(0o755)
            return run_tests(case, executable)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f'BLOCKED: could not prepare isolated mod tests ({type(error).__name__}).', file=sys.stderr)
        return 3


if __name__ == '__main__':
    sys.exit(main())
