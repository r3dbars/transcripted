#!/usr/bin/env python3
"""Real Sparkle 1.1.70 -> 1.1.71 install/relaunch proof; hosted CI only.

Never changes a release surface or signed app. The CLI owns installation; Python
only downloads, stages, observes and verifies. Not a customer prompt/UI test.
"""
from __future__ import annotations
import argparse
import copy
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET

# TODO(1.1.71 RC): set to the verified 1.1.71 promotion SHA after the RC and appcast promotion.
SOURCE_SHA = 'PENDING-1.1.71-PROMOTION-SHA'
SPARKLE_SHA = '066e75a8b3e99962685d6a90cdd5293ebffd9261'
TOOLKIT_SHA = 'c0dde519fd2a43ddfc6a1eb76aec284d7d888fe281414f9177de3164d98ba4c7'
PUBLIC_KEY = 'Ib6MHm4eeZYjhsZblNT0DEo3LzK9fYvBLkmqvw/Vo7Q='
BUNDLE_ID = 'com.justinbetker.draft'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ASSETS = {
 'Transcripted-1.1.70.dmg': ('1.1.70', '72ba430b683fea9beca52806649096e42ff10646f0dc53f23bb15f7a6721779b', 701906186),
 # TODO(1.1.71 RC): fill digest/size from the verified RC artifact.
 'Transcripted-1.1.71.dmg': ('1.1.71', 'PENDING', 0),
 'Transcripted1.1.71-1.1.70.delta': ('1.1.71', 'PENDING', 0),
}
CLI_FILES = {
 'Info.plist': '0d04f5392050cf6ecd2f50ea7c06799f77878328ca3838fc707a4439cb17b852',
 'SPUCommandLineDriver.h': '3f7d8efdd5b1be0e150ecb75795e70b0cd4fadbd1b18818b2dcf7c26f0dd6171',
 'SPUCommandLineDriver.m': '0924b26df77f726afafed2bb149998c4c27813574c0a9e67ddf69cc0419490b1',
 'SPUCommandLineUserDriver.h': '525cc91b76b7c88d3f0bc476cfdf0df72c50739c31d3ff71e9da9a6bb4773c42',
 'SPUCommandLineUserDriver.m': '7e23c34763c74afbdbb7095cdd02d23343e9d0836e358e9da1099ff198e51600',
 'main.m': '6df90a46bc481a76261f1b5c1a3123572f316fa3dc4463ab4269e2f5ecd0051e',
}

class HarnessFailure(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise HarnessFailure(message)


def hosted_account(env, name, home, uid, euid):
    return (env.get('CI') == env.get('GITHUB_ACTIONS') == 'true'
            and env.get('RUNNER_ENVIRONMENT') == 'github-hosted'
            and name == 'runner' and home == '/Users/runner' and uid == euid and uid != 0)


def run(*args, timeout=300, log=None):
    try:
        result = subprocess.run([str(a) for a in args], text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise HarnessFailure(f'command_timeout:{Path(str(args[0])).name}') from None
    if log:
        Path(log).write_text(result.stdout)
    require(result.returncode == 0, f'command_failed:{Path(str(args[0])).name}:exit_{result.returncode}')
    return result.stdout


def bounded_error(error):
    # Never serialize OS errors, subprocess arguments/output, or paths.
    result = {'kind': type(error).__name__}
    if isinstance(error, HarnessFailure):
        result['code'] = re.sub(r'[^a-z0-9]+', '_', str(error).lower()).strip('_')[:160]
    return result


def output_path(requested, runner_temp):
    require(bool(runner_temp), 'RUNNER_TEMP missing')
    root = Path(runner_temp).resolve()
    out = Path(requested).resolve()
    require(root.is_dir() and root != out and root in out.parents, 'Output must be inside RUNNER_TEMP')
    require(not out.exists(), 'Output must be a new owned directory')
    return out


def workflow_provenance(value, actual):
    require(bool(re.fullmatch(r'[0-9a-f]{40}', value or '')) and value == actual,
            'Workflow revision missing or different from harness checkout')
    return value


def launch_status(report):
    fields = ('appLaunched', 'statusItemExists', 'popoverConfigured')
    status = {key: report.get(key) is True for key in fields}
    require(all(status.values()), 'App launch report did not confirm launch/menu/popover')
    return status


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hash_stream(stream)


def hash_stream(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(chunk)
    return result.hexdigest()


def download(url, path, expected, size=None):
    run('curl', '--fail', '--location', '--silent', '--show-error', '--connect-timeout', '30',
        '--max-time', '900', url, '-o', path, timeout=930)
    require(sha(path) == expected, f'Hash mismatch: {Path(path).name}')
    if size is not None:
        require(Path(path).stat().st_size == size, f'Length mismatch: {Path(path).name}')


def staged_feed(original, base, mode):
    root = ET.fromstring(original)
    channel = root.find('channel')
    require(channel is not None, 'Missing channel')
    items = channel.findall('item')
    require(items and items[0].findtext(NS+'version') == '1.1.71', 'Wrong candidate version')
    item = copy.deepcopy(items[0])
    for old in items:
        channel.remove(old)
    channel.append(item)
    enclosure = item.find('enclosure')
    require(enclosure is not None, 'Missing full enclosure')
    selected = [enclosure]
    deltas = item.find(NS+'deltas')
    if mode == 'full':
        if deltas is not None:
            item.remove(deltas)
    else:
        require(deltas is not None, 'Missing candidate deltas')
        matches = [e for e in deltas if e.get(NS+'deltaFrom') == '1.1.70']
        require(len(matches) == 1, 'Missing or duplicate 1.1.70 delta')
        for delta in list(deltas):
            if delta not in matches:
                deltas.remove(delta)
        selected += matches
    for entry in selected:
        url = entry.get('url', '')
        name = url.rsplit('/', 1)[-1]
        require(name in ASSETS and ASSETS[name][0] == '1.1.71', 'Unexpected artifact')
        version, _, size = ASSETS[name]
        require(url == f'https://github.com/r3dbars/transcripted/releases/download/v{version}/{name}', 'Unexpected artifact URL')
        require(entry.get('length') == str(size) and bool(entry.get(NS+'edSignature')), 'Missing signed artifact metadata')
        entry.set('url', base+'/'+name)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def selected_transport(mode, paths):
    full = '/Transcripted-1.1.71.dmg' in paths
    delta = '/Transcripted1.1.71-1.1.70.delta' in paths
    if mode == 'full':
        require(full and not delta, 'Full run did not download the full artifact alone')
    else:
        require(delta and not full, 'Delta run failed to select delta, or silently fell back to full')
    return mode


def tree_digest(bundle):
    entries = []
    for p in sorted(Path(bundle).rglob('*')):
        name = p.relative_to(bundle).as_posix()
        if p.is_symlink():
            entries.append((name, 'link', os.readlink(p)))
        elif p.is_file():
            entries.append((name, 'file', sha(p)))
    return hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode()).hexdigest()


def verify_app(app, version):
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    require(info['CFBundleShortVersionString'] == info['CFBundleVersion'] == version, 'Wrong version/build')
    require(info['CFBundleIdentifier'] == BUNDLE_ID and info['SUPublicEDKey'] == PUBLIC_KEY, 'Wrong app identity/key')
    run('codesign', '--verify', '--deep', '--strict', app)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    return tree_digest(app)


def copy_from_dmg(dmg, destination, mount):
    mount.mkdir()
    run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg)
    try:
        require((mount/'Transcripted.app').is_dir(), 'Expected app missing from DMG')
        run('ditto', mount/'Transcripted.app', destination)
    finally:
        run('hdiutil', 'detach', mount)


OBSERVER = r'''
#import <Cocoa/Cocoa.h>
int main(int argc, const char **argv) { @autoreleasepool {
 NSMutableArray *rows = [NSMutableArray array];
 for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.justinbetker.draft"]) {
  NSString *path = app.bundleURL.path ?: @"";
  if (argc == 3 && strcmp(argv[1], "terminate") == 0 && [path isEqualToString:@(argv[2])]) [app terminate];
  [rows addObject:@{@"pid": @(app.processIdentifier), @"bundle": path}];
 }
 NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
 fwrite(data.bytes, 1, data.length, stdout);
} return 0; }
'''


def build_cli(out):
    toolkit = out/'toolkit'
    toolkit.mkdir()
    archive = out/'Sparkle-2.9.1.tar.xz'
    download('https://github.com/sparkle-project/Sparkle/releases/download/2.9.1/Sparkle-2.9.1.tar.xz', archive, TOOLKIT_SHA)
    run('tar', '-xf', archive, '-C', toolkit)
    source = out/'cli-source'
    source.mkdir()
    for name, digest in CLI_FILES.items():
        download(f'https://raw.githubusercontent.com/sparkle-project/Sparkle/{SPARKLE_SHA}/sparkle-cli/{name}', source/name, digest)
    app = out/'sparkle.app'
    macos = app/'Contents/MacOS'
    frameworks = app/'Contents/Frameworks'
    macos.mkdir(parents=True)
    frameworks.mkdir()
    run('ditto', toolkit/'Sparkle.framework', frameworks/'Sparkle.framework')
    info = plistlib.loads((source/'Info.plist').read_bytes())
    info.update(CFBundleExecutable='sparkle', CFBundleIdentifier='app.transcripted.staged-update-test',
                CFBundleName='sparkle', CFBundleShortVersionString='2.9.1', CFBundleVersion='2.9.1',
                LSMinimumSystemVersion='13.0')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    cli = macos/'sparkle'
    run('clang', '-fobjc-arc', '-fmodules', f'-fmodules-cache-path={out}/clang-cache',
        '-DSPU_OBJC_DIRECT=__attribute__((objc_direct))',
        '-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))',
        '-mmacosx-version-min=13.0', '-F', toolkit, '-framework', 'Cocoa', '-framework', 'Sparkle',
        '-Wl,-rpath,@executable_path/../Frameworks', '-o', cli,
        *[source/n for n in ('main.m', 'SPUCommandLineDriver.m', 'SPUCommandLineUserDriver.m')], timeout=300,
        log=out/'cli-build.log')
    # Signs only our test executable bundle; never re-signs either released app.
    run('codesign', '--force', '--sign', '-', app)
    run('codesign', '--verify', '--deep', '--strict', app)
    observer_source = out/'observer.m'
    observer_source.write_text(OBSERVER)
    observer = out/'observer'
    run('clang', '-fobjc-arc', '-framework', 'Cocoa', observer_source, '-o', observer)
    return cli, observer


def wait_for(check, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(1)
    raise HarnessFailure('timed_out_waiting_for_process_or_report')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    user = pwd.getpwuid(os.getuid())
    require(sys.platform == 'darwin' and hosted_account(os.environ, user.pw_name, user.pw_dir, os.getuid(), os.geteuid()),
            'Refusing native execution outside a verified GitHub-hosted runner account')
    candidate = args.candidate_root.resolve()
    require('PENDING' not in SOURCE_SHA and all(d != 'PENDING' and n > 0 for _, d, n in ASSETS.values()), 'Harness pins for 1.1.71 are not filled in yet')
    require(run('git', '-C', candidate, 'rev-parse', 'HEAD').strip() == SOURCE_SHA, 'Wrong candidate revision')
    require(not run('git', '-C', candidate, 'status', '--porcelain').strip(), 'Candidate checkout must be clean')
    workflow_sha = workflow_provenance(os.environ.get('WORKFLOW_SHA'),
        run('git', '-C', Path(__file__).resolve().parents[2], 'rev-parse', 'HEAD').strip())
    out = output_path(args.output, os.environ.get('RUNNER_TEMP'))
    out.mkdir(parents=True)
    receipt = {'status': 'INCOMPLETE', 'candidate_sha': SOURCE_SHA, 'workflow_sha': workflow_sha, 'sparkle_source_sha': SPARKLE_SHA,
               'scope': 'Real external Sparkle CLI install/relaunch; native customer update prompt NOT TESTED', 'runs': []}
    cli = observer = None
    server = None
    launch_keys = ['TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT', 'TRANSCRIPTED_DISABLE_FILE_LOGGER']
    prior_env = {}
    try:
        cli, observer = build_cli(out)
        require(json.loads(run(observer)) == [], 'Existing Transcripted process on runner; refusing')
        # Fresh hosted user only. Persist opt-outs before either version launches.
        for key in ('observability-anonymous-analytics-enabled', 'observability-crash-reporting-enabled',
                    'SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUSendProfileInfo'):
            run('defaults', 'write', BUNDLE_ID, key, '-bool', 'false')
        for key in launch_keys:
            prior_env[key] = subprocess.run(['launchctl', 'getenv', key], text=True, capture_output=True).stdout.rstrip('\n')
        run('launchctl', 'setenv', 'TRANSCRIPTED_DISABLE_FILE_LOGGER', '1')
        assets = out/'assets'
        assets.mkdir()
        for name, (version, digest, size) in ASSETS.items():
            download(f'https://github.com/r3dbars/transcripted/releases/download/v{version}/{name}', assets/name, digest, size)
        receipt['assets'] = {name: {'sha256': sha(assets/name), 'size': (assets/name).stat().st_size} for name in ASSETS}
        for version in ('1.1.70', '1.1.71'):
            run('xcrun', 'stapler', 'validate', assets/f'Transcripted-{version}.dmg', log=out/f'notarization-{version}.log')
            copy_from_dmg(assets/f'Transcripted-{version}.dmg', out/f'original-{version}.app', out/f'mount-{version}')
        old_digest = verify_app(out/'original-1.1.70.app', '1.1.70')
        new_digest = verify_app(out/'original-1.1.71.app', '1.1.71')
        receipt['original_bundle_digests'] = {'1.1.70': old_digest, '1.1.71': new_digest}
        original = (candidate/'docs/appcast.xml').read_bytes()
        receipt['original_feed_sha256'] = hashlib.sha256(original).hexdigest()
        (out/'candidate-appcast.xml').write_bytes(original)
        requests = []
        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                path = urllib.parse.urlsplit(self.path).path
                requests.append(path if path in ['/appcast.xml'] + ['/'+n for n in ASSETS] else 'other')
                super().do_GET()
            def log_message(self, *_):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(assets)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f'http://127.0.0.1:{server.server_port}'
        for mode in ('full', 'delta'):
            entry = {'mode': mode, 'status': 'INCOMPLETE'}
            receipt['runs'].append(entry)
            case = out/mode
            case.mkdir()
            target = case/'Transcripted.app'
            requests.clear()
            try:
                run('ditto', out/'original-1.1.70.app', target)
                require(tree_digest(target) == old_digest, 'Copied old bundle changed')
                feed = staged_feed(original, base, mode)
                (assets/'appcast.xml').write_bytes(feed)
                (case/'staged-appcast.xml').write_bytes(feed)
                old_report, new_report = case/'old-launch.json', case/'relaunched.json'
                run('launchctl', 'setenv', 'TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT', old_report)
                run('open', '-n', target)
                def target_processes():
                    return [r for r in json.loads(run(observer)) if r['bundle'] == str(target)]
                before = wait_for(lambda: target_processes() if old_report.exists() else None)
                require(len(before) == 1, 'Ambiguous old app process')
                old_pid = before[0]['pid']
                entry['old_pid'] = old_pid
                entry['old_launch'] = launch_status(json.loads(old_report.read_text()))
                run('launchctl', 'setenv', 'TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT', new_report)
                run(cli, target, '--check-immediately', '--feed-url', base+'/appcast.xml',
                    '--user-agent-name', 'Transcripted-isolated-release-QA', '--verbose', timeout=900,
                    log=case/'sparkle-cli.log')
                entry['cli_exit'] = 0
                entry['transport'] = selected_transport(mode, requests)
                def relaunched():
                    rows = target_processes()
                    return rows if new_report.exists() and len(rows) == 1 and rows[0]['pid'] != old_pid else None
                after = wait_for(relaunched)
                require(not any(r['pid'] == old_pid for r in json.loads(run(observer))), 'Original process still running')
                entry['new_pid'] = after[0]['pid']
                actual_digest = verify_app(target, '1.1.71')
                require(actual_digest == new_digest, 'Installed app differs from published new app bytes/symlinks')
                entry['new_launch'] = launch_status(json.loads(new_report.read_text()))
                entry.update(status='PASS', installed_bundle_sha256=actual_digest, relaunch_report='relaunched.json')
            except Exception as error:
                entry.update(status='FAIL', error=bounded_error(error))
            finally:
                entry['http_gets'] = list(requests)
                (case/'requests.json').write_text(json.dumps(requests, indent=2))
                try:
                    run(observer, 'terminate', target)
                    wait_for(lambda: not [r for r in json.loads(run(observer)) if r['bundle'] == str(target)])
                except Exception as error:
                    entry.update(status='FAIL', cleanup_error=bounded_error(error))
                    raise
        require(all(r['status'] == 'PASS' for r in receipt['runs']), 'At least one real update route failed')
        receipt['status'] = 'PASS'
    except Exception as error:
        receipt.update(status='FAIL', error=bounded_error(error))
    finally:
        cleanup_errors = []
        if server:
            try:
                server.shutdown()
                server.server_close()
            except Exception as error:
                cleanup_errors.append(bounded_error(error))
        for key, value in prior_env.items():
            try:
                run('launchctl', 'setenv', key, value) if value else run('launchctl', 'unsetenv', key)
            except Exception as error:
                cleanup_errors.append(bounded_error(error))
        if cleanup_errors:
            receipt.update(status='FAIL', cleanup_errors=cleanup_errors)
        (out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))
    return 0 if receipt['status'] == 'PASS' else 1

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'status': 'FAIL', 'error': bounded_error(error)}))
        raise SystemExit(1)
