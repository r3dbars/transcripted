#!/usr/bin/env python3
"""Offline contract tests: no app launch, network, defaults, or signing changes."""
import copy
from pathlib import Path
import runpy
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
M = runpy.run_path(str(ROOT/'scripts/release/test-staged-sparkle-update.py'))
# 1.1.71 RC pins are PENDING until the RC is verified; exercise feed logic with fixture sizes.
M['ASSETS']['Transcripted-1.1.71.dmg'] = ('1.1.71', 'fixture', 701604387)
M['ASSETS']['Transcripted1.1.71-1.1.70.delta'] = ('1.1.71', 'fixture', 12314150)
NS = M['NS']

class StagedUpdateTests(unittest.TestCase):
    def feed(self):
        # Independent fixture: one signed target and two prior-version deltas.
        return f'''<rss xmlns:sparkle="{NS[1:-1]}"><channel><item>
        <sparkle:version>1.1.71</sparkle:version>
        <enclosure url="https://github.com/r3dbars/transcripted/releases/download/v1.1.71/Transcripted-1.1.71.dmg" length="701604387" sparkle:edSignature="full-signature" />
        <sparkle:deltas><enclosure url="https://github.com/r3dbars/transcripted/releases/download/v1.1.71/Transcripted1.1.71-1.1.70.delta" length="12314150" sparkle:deltaFrom="1.1.70" sparkle:edSignature="delta-signature" sparkle:deltaFromSparkleExecutableSize="977808" />
        <enclosure sparkle:deltaFrom="1.1.67" /></sparkle:deltas>
        </item><item><sparkle:version>1.1.70</sparkle:version></item></channel></rss>'''.encode()

    def test_only_verified_hosted_runner_account_can_execute(self):
        good = {'CI':'true','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted'}
        self.assertTrue(M['hosted_account'](good, 'runner', '/Users/runner', 501, 501))
        for env, name, home, uid, euid in [
            ({},'runner','/Users/runner',501,501),
            ({**good,'RUNNER_ENVIRONMENT':'self-hosted'},'runner','/Users/runner',501,501),
            (good,'owner','/Users/owner',501,501),
            (good,'runner','/Users/runner',0,0),
            (good,'runner','/Users/runner',501,0),
        ]:
            self.assertFalse(M['hosted_account'](env,name,home,uid,euid))

    def test_full_feed_preserves_signature_and_removes_all_deltas(self):
        original = self.feed()
        result = ET.fromstring(M['staged_feed'](original,'http://127.0.0.1:8000','full'))
        items = result.findall('channel/item')
        self.assertEqual(len(items),1)
        self.assertIsNone(items[0].find(NS+'deltas'))
        enclosure = items[0].find('enclosure')
        self.assertEqual(enclosure.get(NS+'edSignature'),'full-signature')
        self.assertEqual(enclosure.get('length'),'701604387')
        self.assertEqual(enclosure.get('url'),'http://127.0.0.1:8000/Transcripted-1.1.71.dmg')
        self.assertEqual(original,self.feed())

    def test_delta_feed_preserves_delta_validation_metadata_and_full_fallback(self):
        result = ET.fromstring(M['staged_feed'](self.feed(),'http://127.0.0.1:8000','delta'))
        item = result.find('channel/item')
        self.assertIsNotNone(item.find('enclosure'))
        deltas = item.find(NS+'deltas')
        self.assertEqual(len(deltas),1)
        self.assertEqual(deltas[0].get(NS+'deltaFrom'),'1.1.70')
        self.assertEqual(deltas[0].get(NS+'edSignature'),'delta-signature')
        self.assertEqual(deltas[0].get(NS+'deltaFromSparkleExecutableSize'),'977808')

    def test_wrong_release_artifact_or_length_rejected(self):
        for original in [self.feed().replace(b'>1.1.71<',b'>1.1.70<'),
                         self.feed().replace(b'https://github.com/',b'https://attacker.example/'),
                         self.feed().replace(b'701604387',b'701604388'),
                         self.feed().replace(b'sparkle:edSignature="full-signature"',b'')]:
            with self.assertRaises(RuntimeError):
                M['staged_feed'](original,'http://127.0.0.1:8000','full')

    def test_delta_fallback_cannot_be_reported_as_delta_pass(self):
        full='/Transcripted-1.1.71.dmg'
        delta='/Transcripted1.1.71-1.1.70.delta'
        self.assertEqual(M['selected_transport']('full',[full]),'full')
        self.assertEqual(M['selected_transport']('delta',[delta]),'delta')
        for mode, paths in [('delta',[delta,full]),('delta',[full]),('full',[delta]),('full',[])]:
            with self.assertRaises(RuntimeError): M['selected_transport'](mode,paths)

    def test_non_hosted_paths_and_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name)
            runner=root/'runner'; runner.mkdir()
            outside=root/'outside'; outside.mkdir()
            (runner/'escape').symlink_to(outside,target_is_directory=True)
            self.assertEqual(M['output_path'](runner/'fresh',str(runner)),(runner/'fresh').resolve())
            for bad in [root/'new',runner,runner/'escape'/'new']:
                with self.assertRaises(RuntimeError): M['output_path'](bad,str(runner))

    def test_receipt_never_serializes_exception_details(self):
        canary='/Users/private-person/private-transcript secret-token@example.test'
        for error in [OSError(canary), RuntimeError(canary)]:
            self.assertNotIn(canary,str(M['bounded_error'](error)))
        self.assertEqual(M['bounded_error'](M['HarnessFailure']('command_failed:clang:exit_1')),
                         {'kind':'HarnessFailure','code':'command_failed_clang_exit_1'})

    def test_workflow_receipt_requires_exact_harness_commit(self):
        good='a'*40
        self.assertEqual(M['workflow_provenance'](good,good),good)
        for value,actual in [(None,good),('branch-name',good),(good,'b'*40),('A'*40,good)]:
            with self.assertRaises(RuntimeError): M['workflow_provenance'](value,actual)

    def test_runtime_report_must_confirm_actual_launch_and_menu(self):
        good={'appLaunched':True,'statusItemExists':True,'popoverConfigured':True}
        self.assertEqual(M['launch_status'](good),good)
        for bad in [{},{'unrelated':True},{**good,'appLaunched':False},
                    {**good,'statusItemExists':'true'},{**good,'popoverConfigured':False}]:
            with self.assertRaises(RuntimeError): M['launch_status'](bad)

    def test_bundle_hash_detects_bytes_and_symlink_changes(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name)
            (root/'binary').write_bytes(b'published')
            (root/'link').symlink_to('binary')
            original=M['tree_digest'](root)
            (root/'binary').write_bytes(b'mutated')
            self.assertNotEqual(original,M['tree_digest'](root))
            (root/'binary').write_bytes(b'published')
            self.assertEqual(original,M['tree_digest'](root))
            (root/'link').unlink()
            (root/'link').symlink_to('different')
            self.assertNotEqual(original,M['tree_digest'](root))

if __name__ == '__main__': unittest.main()
