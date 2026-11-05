#!/usr/bin/env python3
"""Real Sparkle 1.1.75 -> 1.1.76 install/relaunch proof; hosted CI only.

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
import stat
import zipfile
import threading
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET

SOURCE_SHA = 'caa17f1bb522324bf8f756239347fb4c6308ab52'
SPARKLE_SHA = '066e75a8b3e99962685d6a90cdd5293ebffd9261'
TOOLKIT_SHA = 'c0dde519fd2a43ddfc6a1eb76aec284d7d888fe281414f9177de3164d98ba4c7'
PUBLIC_KEY = 'Ib6MHm4eeZYjhsZblNT0DEo3LzK9fYvBLkmqvw/Vo7Q='
BUNDLE_ID = 'com.justinbetker.draft'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ASSETS = {
 'Transcripted-1.1.75.dmg': ('1.1.75', '9e297c6c4154a5a6623c0fd711374fb45233faefab20bf718ded5b83068f6cca', 703372192),
 'Transcripted-1.1.76.dmg': ('1.1.76', 'c9c59dd56244592c200cccbc659ec103fda9a3a2cf06b1c6200369a9ef83c913', 703576924),
 'Transcripted1.1.76-1.1.75.delta': ('1.1.76', '18bdf4fc7e303435d5f906291a6f52fa1de0beac561731306ff7c57b4002cb0c', 3046518),
}
RC_RUN = 41978929739
RC_ARTIFACT = 13394641882
RC_WORKFLOW_SHA = '9f7076de5ae5e98cadf90b43975161db667fc175'
RC_ZIP_SHA = '0dc7201ebfb1fb60a88672c8d2d6bb4bb44ee87ba262fc90cbbf44189bb12348'
RC_ZIP_SIZE = 743785306
FEED_SHA = '2e8855adf7899bf57dc9235b5f5a62076d521c1b18e4b77138505be539ad27ae'
FEED_SIZE = 86820
RC_MEMBERS = {
 'build/Transcripted-1.1.76.dSYM.zip', 'build/Transcripted-1.1.76.dmg', 'build/appcast.xml',
 'build/packaged-app-smoke.json', 'build/privacy-leak-sweep-report.json', 'Casks/transcripted.rb',
 *{f'build/sparkle-deltas/Transcripted1.1.76-1.1.{v}.delta' for v in range(71, 76)},
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


def candidate_provenance(actual, clean):
    require(actual == SOURCE_SHA and clean, 'Wrong or dirty candidate revision')


def finalize_receipt(receipt, cleanup_errors):
    if cleanup_errors:
        receipt.update(status='FAIL', cleanup_errors=cleanup_errors)
    return receipt


def launch_value(key, read=None):
    result = (read or (lambda name: subprocess.run(['launchctl', 'getenv', name],
        text=True, capture_output=True)))(key)
    # Older launchctl returns zero even for absence. Preserve its terminating
    # newline distinction too: absent is '', present-empty is '\n'. Never strip
    # all newlines, since a real variable value can itself end with a newline.
    require(result.returncode in (0, 1) and not result.stderr, 'Cannot capture launch environment')
    require(result.returncode == 0 or result.stdout == '', 'Malformed launch environment result')
    present = result.returncode == 0 and result.stdout != ''
    require(not present or result.stdout.endswith('\n'), 'Malformed launch environment value')
    return {'present': present, 'value': result.stdout[:-1] if present else None,
            'getenv_exit': result.returncode}


def restore_launch_value(key, prior, write=run, read=None):
    if prior['present']:
        write('launchctl', 'setenv', key, prior['value'])
    else:
        write('launchctl', 'unsetenv', key)
    actual = launch_value(key, read)
    require((actual['present'], actual['value']) == (prior['present'], prior['value']),
            'Launch environment restoration mismatch')


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
    require(mode in ('full', 'delta'), 'Unknown update mode')
    require(items and items[0].findtext(NS+'version') == '1.1.76', 'Wrong candidate version')
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
        matches = [e for e in deltas if e.get(NS+'deltaFrom') == '1.1.75']
        require(len(matches) == 1, 'Missing or duplicate 1.1.75 delta')
        for delta in list(deltas):
            if delta not in matches:
                deltas.remove(delta)
        selected += matches
    for entry in selected:
        url = entry.get('url', '')
        name = url.rsplit('/', 1)[-1]
        require(name in ASSETS and ASSETS[name][0] == '1.1.76', 'Unexpected artifact')
        version, _, size = ASSETS[name]
        require(url == f'https://github.com/r3dbars/transcripted/releases/download/v{version}/{name}', 'Unexpected artifact URL')
        require(entry.get('length') == str(size) and bool(entry.get(NS+'edSignature')), 'Missing signed artifact metadata')
        entry.set('url', base+'/'+name)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def selected_transport(mode, paths):
    full = '/Transcripted-1.1.76.dmg' in paths
    delta = '/Transcripted1.1.76-1.1.75.delta' in paths
    if mode == 'full':
        require(full and not delta, 'Full run did not download the full artifact alone')
    else:
        require(delta and not full, 'Delta run failed to select delta, or silently fell back to full')
    return mode


def tree_digest(bundle):
    # Every enclosed entry: bytes, modes, directories and literal symlink targets.
    require(bundle.is_dir() and not bundle.is_symlink(), 'Invalid bundle root')
    rows = [['.', stat.S_IMODE(bundle.lstat().st_mode), 'directory']]
    for path in sorted(bundle.rglob('*')):
        info = path.lstat()
        row = [path.relative_to(bundle).as_posix(), stat.S_IMODE(info.st_mode)]
        if path.is_symlink():
            row += ['symlink', os.readlink(path)]
        elif path.is_file():
            row += ['file', sha(path)]
        elif path.is_dir():
            row += ['directory']
        else:
            raise HarnessFailure('Unsupported bundle entry')
        rows.append(row)
    return hashlib.sha256(json.dumps(rows, separators=(',', ':')).encode()).hexdigest()


def rc_metadata(metadata):
    require(metadata.get('id') == RC_ARTIFACT and metadata.get('expired') is False
            and metadata.get('name') == 'Transcripted-1.1.76-release-candidate'
            and metadata.get('size_in_bytes') == RC_ZIP_SIZE
            and metadata.get('digest') == 'sha256:'+RC_ZIP_SHA
            and metadata.get('workflow_run', {}).get('id') == RC_RUN
            and metadata.get('workflow_run', {}).get('head_sha') == RC_WORKFLOW_SHA,
            'Wrong final RC artifact metadata')


def rc_members(infos):
    names = [i.filename for i in infos]
    require(len(names) == len(set(names)) and set(names) == RC_MEMBERS, 'Unexpected RC ZIP members')
    require(all(not i.is_dir() and not stat.S_ISLNK(i.external_attr >> 16) for i in infos),
            'Unsafe RC ZIP member')


def stage_rc(archive, metadata, assets):
    rc_metadata(json.loads(metadata.read_text()))
    require(archive.is_file() and archive.stat().st_size == RC_ZIP_SIZE and sha(archive) == RC_ZIP_SHA,
            'Wrong final RC ZIP bytes')
    selected = {'build/appcast.xml': assets/'signed-appcast.xml',
                'build/Transcripted-1.1.76.dmg': assets/'Transcripted-1.1.76.dmg',
                'build/sparkle-deltas/Transcripted1.1.76-1.1.75.delta': assets/'Transcripted1.1.76-1.1.75.delta'}
    with zipfile.ZipFile(archive) as z:
        rc_members(z.infolist())
        for member, target in selected.items():
            with z.open(member) as src, target.open('xb') as dst:
                import shutil
                shutil.copyfileobj(src, dst)
    for name in ('Transcripted-1.1.76.dmg', 'Transcripted1.1.76-1.1.75.delta'):
        _, digest, size = ASSETS[name]
        require((assets/name).stat().st_size == size and sha(assets/name) == digest, 'Wrong final candidate bytes')
    feed = (assets/'signed-appcast.xml').read_bytes()
    require(len(feed) == FEED_SIZE and hashlib.sha256(feed).hexdigest() == FEED_SHA, 'Wrong signed candidate feed')
    return feed


def fresh_account(home):
    # These are all alternate model/app/state roots used by the packaged CLI.
    roots = ['/Applications/Transcripted.app', str(home/'Applications/Transcripted.app')]
    roots += [str(home/'Library/Application Support'/name) for name in ('Transcripted', 'Draft', 'FluidAudio')]
    require(not any(Path(p).exists() for p in roots), 'Hosted account contains alternate product state or models')


def product_preferences_state(home, query=run):
    # Bounded presence only: never serialize preference keys, values or paths.
    domains = {s.strip() for s in query('defaults', 'domains').split(',')}
    return {'domain_listed': BUNDLE_ID in domains,
            'standard_plist_present': (home/'Library/Preferences'/f'{BUNDLE_ID}.plist').exists(),
            'by_host_plist_present': bool(list((home/'Library/Preferences/ByHost').glob(BUNDLE_ID+'.*.plist')))}


def product_preferences_absent(home):
    return not any(product_preferences_state(home).values())


def process_alive(pid):
    try:
        os.kill(pid, 0)  # Existence check only, never a termination signal.
    except ProcessLookupError:
        return False
    except PermissionError:
        raise HarnessFailure('Cannot establish owned process exit') from None
    return True


def wait_owned_pids_exit(pids, proof, alive=process_alive, clock=time.monotonic,
                         pause=time.sleep, timeout=90):
    require(all(type(pid) is int and pid > 0 for pid in pids), 'Invalid owned process identifier')
    proof['owned_pid_count'] = len(pids)
    proof['owned_pids_exited'] = False
    deadline = clock() + timeout
    while any(alive(pid) for pid in pids):
        require(clock() < deadline, 'Owned process did not exit before preference cleanup')
        pause(0.25)
    proof['owned_pids_exited'] = True


def preference_file_identity(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def inspect_empty_preference(fd, expected_uid, proof):
    info = os.fstat(fd)
    proof.update(regular_file=stat.S_ISREG(info.st_mode), owned_by_runner=info.st_uid == expected_uid,
                 single_link=info.st_nlink == 1, bytes=info.st_size,
                 plist_parseable=False, root_is_dictionary=False, key_count=None)
    require(proof['regular_file'] and proof['owned_by_runner'] and proof['single_link']
            and not info.st_mode & 0o022 and 0 < info.st_size <= 1024 * 1024,
            'Unexpected residual preference file metadata')
    data = os.pread(fd, 1024 * 1024 + 1, 0)
    require(len(data) == info.st_size, 'Residual preference file changed during read')
    try:
        value = plistlib.loads(data)
    except Exception:
        raise HarnessFailure('Residual preference file is not a valid plist') from None
    proof.update(plist_parseable=True, root_is_dictionary=type(value) is dict,
                 key_count=len(value) if type(value) is dict else None)
    require(type(value) is dict and not value, 'Residual preference plist is not an empty dictionary')
    require(preference_file_identity(info) == preference_file_identity(os.fstat(fd)),
            'Residual preference file changed during inspection')
    return info


def retain_empty_preference(home, output, proof, expected_uid=None):
    # The only source entry allowed is the exact domain admitted as absent.
    # Descriptor-relative traversal rejects every symlink/foreign parent. No
    # preference bytes are ever unlinked, including on the empty-success path.
    expected_uid = os.getuid() if expected_uid is None else expected_uid
    proof.update(claimed=False, quarantine_retained=False, empty_claim_revalidated=False)
    require(home.is_absolute() and home.resolve() == home and output.is_absolute()
            and output.resolve() == output, 'Preference cleanup root is not canonical')
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptors = []
    name = BUNDLE_ID+'.plist'
    def own_directory(fd):
        info = os.fstat(fd)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == expected_uid and not info.st_mode & 0o022,
                'Unexpected preference cleanup directory owner or type')
        return info
    try:
        home_fd = os.open(home, directory_flags); descriptors.append(home_fd); own_directory(home_fd)
        library_fd = os.open('Library', directory_flags, dir_fd=home_fd)
        descriptors.append(library_fd); own_directory(library_fd)
        parent_fd = os.open('Preferences', directory_flags, dir_fd=library_fd)
        descriptors.append(parent_fd); parent_info = own_directory(parent_fd)
        fd = os.open(name, file_flags, dir_fd=parent_fd); descriptors.append(fd)
        before = inspect_empty_preference(fd, expected_uid, proof.setdefault('before_claim', {}))
        output_fd = os.open(output, directory_flags); descriptors.append(output_fd)
        require(own_directory(output_fd).st_dev == parent_info.st_dev, 'Preference quarantine crosses filesystems')
        quarantine = '.preference-quarantine-'+uuid.uuid4().hex
        os.mkdir(quarantine, mode=0o700, dir_fd=output_fd)
        quarantine_fd = os.open(quarantine, directory_flags, dir_fd=output_fd)
        descriptors.append(quarantine_fd); own_directory(quarantine_fd)
        require(preference_file_identity(os.stat(name, dir_fd=parent_fd, follow_symlinks=False))
                == preference_file_identity(before), 'Preference source entry changed before claim')
        os.rename(name, 'retained.plist', src_dir_fd=parent_fd, dst_dir_fd=quarantine_fd)
        proof.update(claimed=True, quarantine_retained=True)
        try:
            claimed_fd = os.open('retained.plist', file_flags, dir_fd=quarantine_fd)
            descriptors.append(claimed_fd)
            after = inspect_empty_preference(claimed_fd, expected_uid, proof.setdefault('after_claim', {}))
            # rename may update ctime; every other identity/content attribute
            # must still match the inspected source. Late writes remain retained.
            require(preference_file_identity(after)[:-1] == preference_file_identity(before)[:-1],
                    'Claimed preference file changed identity')
            try:
                os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise HarnessFailure('Preference source entry was recreated during claim')
            proof['empty_claim_revalidated'] = True
        except Exception:
            # link is atomic no-overwrite. Keep quarantine even after a restore:
            # no unexpected late bytes are destroyed and no new source is replaced.
            proof['empty_claim_revalidated'] = False
            try:
                os.link('retained.plist', name, src_dir_fd=quarantine_fd,
                        dst_dir_fd=parent_fd, follow_symlinks=False)
                proof['restored_without_overwrite'] = True
            except OSError:
                proof['restored_without_overwrite'] = False
            raise HarnessFailure('Preference quarantine revalidation failed; bytes retained') from None
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def restore_product_preferences(home, pids, proof, command=run, read=None,
                                alive=process_alive, clock=time.monotonic, pause=time.sleep, output=None):
    # Only called after admission proved the domain and both file classes absent.
    # NSRunningApplication removal alone is not BSD process-exit proof.
    read = read or (lambda: product_preferences_state(home))
    proof['delete_commands'] = 0
    proof['absence_restored'] = False
    wait_owned_pids_exit(pids, proof, alive, clock, pause)
    proof['before_delete'] = read()
    proof['delete_commands'] = 1
    command('defaults', 'delete', BUNDLE_ID)
    # CFPreferences persistence may complete after the command returns. Observe
    # convergence; never repeat deletion or relax any absence condition.
    proof['observations'] = 0
    def observe():
        deadline = clock() + 30
        while True:
            state = read()
            proof['observations'] += 1
            proof['after_delete'] = state
            if not any(state.values()):
                return True
            if clock() >= deadline:
                return False
            pause(0.25)
    if not observe():
        state = proof['after_delete']
        require(output is not None and state['standard_plist_present'] and not state['by_host_plist_present'],
                'Product preference absence not restored')
        retain_empty_preference(home, output, proof.setdefault('residual_plist', {}))
        proof['absence_restored'] = observe()
        require(proof['absence_restored'], 'Product preference absence not restored after empty claim')
    proof['absence_restored'] = True


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
    parser.add_argument('--rc-archive', type=Path, required=True)
    parser.add_argument('--rc-metadata', type=Path, required=True)
    args = parser.parse_args()
    user = pwd.getpwuid(os.getuid())
    require(sys.platform == 'darwin' and hosted_account(os.environ, user.pw_name, user.pw_dir, os.getuid(), os.geteuid()),
            'Refusing native execution outside a verified GitHub-hosted runner account')
    candidate = args.candidate_root.resolve()
    candidate_provenance(run('git', '-C', candidate, 'rev-parse', 'HEAD').strip(),
                         not run('git', '-C', candidate, 'status', '--porcelain').strip())
    workflow_sha = workflow_provenance(os.environ.get('WORKFLOW_SHA'),
        run('git', '-C', Path(__file__).resolve().parents[2], 'rev-parse', 'HEAD').strip())
    out = output_path(args.output, os.environ.get('RUNNER_TEMP'))
    os.umask(0o077)
    out.mkdir(parents=True, mode=0o700)
    receipt = {'status': 'INCOMPLETE', 'candidate_sha': SOURCE_SHA, 'workflow_sha': workflow_sha, 'sparkle_source_sha': SPARKLE_SHA,
               'scope': 'External Sparkle install/relaunch and signed CLI synthetic import; native customer update prompt NOT TESTED',
               'rc_run': RC_RUN, 'rc_artifact': RC_ARTIFACT, 'rc_zip_sha256': RC_ZIP_SHA, 'runs': []}
    cli = observer = None
    server = None
    launch_keys = ['TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT', 'TRANSCRIPTED_DISABLE_FILE_LOGGER', 'TRANSCRIPTED_CONTAINER_DIR']
    prior_env = {}
    owns_preferences = False
    owned_pids = set()
    try:
        receipt['host'] = {'os': run('sw_vers', '-productVersion').strip(),
                           'build': run('sw_vers', '-buildVersion').strip(),
                           'architecture': run('uname', '-m').strip(), 'account': 'fresh_github_hosted_runner'}
        cli, observer = build_cli(out)
        require(json.loads(run(observer)) == [], 'Existing Transcripted process on runner; refusing')
        fresh_account(Path(user.pw_dir))
        require(product_preferences_absent(Path(user.pw_dir)), 'Product preferences already exist')
        owns_preferences = True
        # Only a proven absent product domain in this disposable hosted account.
        for key in ('observability-anonymous-analytics-enabled', 'observability-crash-reporting-enabled',
                    'SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUSendProfileInfo'):
            run('defaults', 'write', BUNDLE_ID, key, '-bool', 'false')
        for key in launch_keys:
            prior_env[key] = launch_value(key)
        run('launchctl', 'setenv', 'TRANSCRIPTED_DISABLE_FILE_LOGGER', '1')
        container = out/'app-container'
        container.mkdir(mode=0o700)
        run('launchctl', 'setenv', 'TRANSCRIPTED_CONTAINER_DIR', container)
        assets = out/'assets'
        assets.mkdir()
        original = stage_rc(args.rc_archive, args.rc_metadata, assets)
        name = 'Transcripted-1.1.75.dmg'
        version, digest, size = ASSETS[name]
        download(f'https://github.com/r3dbars/transcripted/releases/download/v{version}/{name}', assets/name, digest, size)
        receipt['assets'] = {name: {'sha256': sha(assets/name), 'size': (assets/name).stat().st_size} for name in ASSETS}
        for version in ('1.1.75', '1.1.76'):
            run('xcrun', 'stapler', 'validate', assets/f'Transcripted-{version}.dmg', log=out/f'notarization-{version}.log')
            copy_from_dmg(assets/f'Transcripted-{version}.dmg', out/f'original-{version}.app', out/f'mount-{version}')
        old_digest = verify_app(out/'original-1.1.75.app', '1.1.75')
        new_digest = verify_app(out/'original-1.1.76.app', '1.1.76')
        receipt['original_bundle_digests'] = {'1.1.75': old_digest, '1.1.76': new_digest}
        # Exercise CLI before any app launch can seed a model cache.
        import runpy
        cli_proof = runpy.run_path(str(Path(__file__).with_name('test-signed-candidate-cli.py')))
        fresh_account(Path(user.pw_dir))
        receipt['cli_import'] = cli_proof['qualify'](out/'original-1.1.76.app', out/'cli-import',
                                                   SOURCE_SHA, run, require, tree_digest, sha)
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
                run('ditto', out/'original-1.1.75.app', target)
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
                owned_pids.add(old_pid)
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
                owned_pids.add(after[0]['pid'])
                actual_digest = verify_app(target, '1.1.76')
                require(actual_digest == new_digest, 'Installed app differs from published new app bytes/symlinks')
                entry['new_launch'] = launch_status(json.loads(new_report.read_text()))
                entry.update(status='PASS', installed_bundle_sha256=actual_digest, relaunch_report='relaunched.json')
            except Exception as error:
                entry.update(status='FAIL', error=bounded_error(error))
            finally:
                entry['http_gets'] = list(requests)
                (case/'requests.json').write_text(json.dumps(requests, indent=2))
                try:
                    terminating = json.loads(run(observer, 'terminate', target))
                    owned_pids.update(r['pid'] for r in terminating if r['bundle'] == str(target))
                    wait_for(lambda: not [r for r in json.loads(run(observer)) if r['bundle'] == str(target)])
                except Exception as error:
                    entry.update(status='FAIL', cleanup_error=bounded_error(error))
                    raise
        require(len(receipt['runs']) == 2 and all(r['status'] == 'PASS' for r in receipt['runs']),
                'At least one real update route failed')
        require(receipt['cli_import']['status'] == 'PASS', 'Candidate CLI import incomplete')
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
                restore_launch_value(key, value)
            except Exception as error:
                cleanup_errors.append(bounded_error(error))
        if owns_preferences:
            try:
                require(json.loads(run(observer)) == [], 'App still running before preference restoration')
                receipt['preference_cleanup'] = {}
                restore_product_preferences(Path(user.pw_dir), owned_pids, receipt['preference_cleanup'], output=out)
                receipt['preferences_restored_to_original_absence'] = True
            except Exception as error:
                cleanup_errors.append(bounded_error(error))
        finalize_receipt(receipt, cleanup_errors)
        (out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, indent=2))
    return 0 if receipt['status'] == 'PASS' else 1

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print(json.dumps({'status': 'FAIL', 'error': bounded_error(error)}))
        raise SystemExit(1)
