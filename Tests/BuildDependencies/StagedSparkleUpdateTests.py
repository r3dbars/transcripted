#!/usr/bin/env python3
"""Offline contract tests: no app launch, network, defaults, or signing changes."""
import copy
import json
import subprocess
import struct
import zipfile
from pathlib import Path
import runpy
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
M = runpy.run_path(str(ROOT/'scripts/release/test-staged-sparkle-update.py'))
NS = M['NS']
C = runpy.run_path(str(ROOT/'scripts/release/test-signed-candidate-cli.py'))

class StagedUpdateTests(unittest.TestCase):
    def feed(self):
        # Independent fixture: one signed target and two prior-version deltas.
        return f'''<rss xmlns:sparkle="{NS[1:-1]}"><channel><item>
        <sparkle:version>1.1.76</sparkle:version>
        <enclosure url="https://github.com/r3dbars/transcripted/releases/download/v1.1.76/Transcripted-1.1.76.dmg" length="703576924" sparkle:edSignature="full-signature" />
        <sparkle:deltas><enclosure url="https://github.com/r3dbars/transcripted/releases/download/v1.1.76/Transcripted1.1.76-1.1.75.delta" length="3046518" sparkle:deltaFrom="1.1.75" sparkle:edSignature="delta-signature" sparkle:deltaFromSparkleExecutableSize="977808" />
        <enclosure sparkle:deltaFrom="1.1.74" /></sparkle:deltas>
        </item><item><sparkle:version>1.1.75</sparkle:version></item></channel></rss>'''.encode()

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
        self.assertEqual(enclosure.get('length'),'703576924')
        self.assertEqual(enclosure.get('url'),'http://127.0.0.1:8000/Transcripted-1.1.76.dmg')
        self.assertEqual(original,self.feed())

    def test_delta_feed_preserves_delta_validation_metadata_and_full_fallback(self):
        result = ET.fromstring(M['staged_feed'](self.feed(),'http://127.0.0.1:8000','delta'))
        item = result.find('channel/item')
        self.assertIsNotNone(item.find('enclosure'))
        deltas = item.find(NS+'deltas')
        self.assertEqual(len(deltas),1)
        self.assertEqual(deltas[0].get(NS+'deltaFrom'),'1.1.75')
        self.assertEqual(deltas[0].get(NS+'edSignature'),'delta-signature')
        self.assertEqual(deltas[0].get(NS+'deltaFromSparkleExecutableSize'),'977808')

    def test_wrong_release_artifact_or_length_rejected(self):
        for original in [self.feed().replace(b'>1.1.76<',b'>1.1.77<'),
                         self.feed().replace(b'https://github.com/',b'https://attacker.example/'),
                         self.feed().replace(b'703576924',b'703576925'),
                         self.feed().replace(b'sparkle:edSignature="full-signature"',b'')]:
            with self.assertRaises(RuntimeError):
                M['staged_feed'](original,'http://127.0.0.1:8000','full')

    def test_delta_fallback_cannot_be_reported_as_delta_pass(self):
        full='/Transcripted-1.1.76.dmg'
        delta='/Transcripted1.1.76-1.1.75.delta'
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

    def test_candidate_source_and_cleanup_are_fail_closed(self):
        M['candidate_provenance']('caa17f1bb522324bf8f756239347fb4c6308ab52',True)
        for source,clean in [('a'*40,True),(M['SOURCE_SHA'],False)]:
            with self.assertRaises(RuntimeError): M['candidate_provenance'](source,clean)
        receipt={'status':'PASS'}
        M['finalize_receipt'](receipt,[{'kind':'HarnessFailure','code':'restore_failed'}])
        self.assertEqual(receipt['status'],'FAIL')

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

    def test_bundle_manifest_covers_file_modes_and_empty_directories(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name)
            file=root/'binary'; file.write_bytes(b'published'); file.chmod(0o644)
            original=M['tree_digest'](root)
            file.chmod(0o755)
            self.assertNotEqual(original,M['tree_digest'](root))
            file.chmod(0o644)
            empty=root/'empty'; empty.mkdir()
            added=M['tree_digest'](root)
            self.assertNotEqual(original,added)
            empty.chmod(0o700)
            self.assertNotEqual(added,M['tree_digest'](root))

    def test_bundle_root_mode_is_part_of_complete_manifest(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); root.chmod(0o755)
            (root/'binary').write_bytes(b'published')
            before=M['tree_digest'](root)
            root.chmod(0o700)
            self.assertNotEqual(before,M['tree_digest'](root))

    def test_launch_environment_preserves_absent_empty_and_trailing_newlines(self):
        values={}
        calls=[]
        def read(key):
            return subprocess.CompletedProcess([],0,values[key]+'\n' if key in values else '', '')
        def write(tool,action,key,*args):
            calls.append((tool,action,key,*args))
            if action=='setenv': values[key]=args[0]
            else: values.pop(key,None)
        for prior in [None,'','value','value\n']:
            values.clear()
            if prior is not None: values['KEY']=prior
            captured=M['launch_value']('KEY',read)
            self.assertEqual(captured['present'],prior is not None)
            self.assertEqual(captured['value'],prior)
            values['KEY']='harness-owned'
            M['restore_launch_value']('KEY',captured,write,read)
            self.assertEqual(values.get('KEY'),prior)
            self.assertEqual('KEY' in values,prior is not None)
        self.assertIn(('launchctl','setenv','KEY',''),calls)
        self.assertIn(('launchctl','unsetenv','KEY'),calls)
        with self.assertRaises(RuntimeError):
            M['restore_launch_value']('KEY',{'present':False,'value':None},lambda *args:None,read)
        for status,out,err in [(2,'','failure'),(0,'unterminated',''),(1,'unexpected','')]:
            with self.assertRaises(RuntimeError):
                M['launch_value']('KEY',lambda key:subprocess.CompletedProcess([],status,out,err))

    def test_only_exact_final_rc_metadata_is_accepted(self):
        good={'id':13394641882,'expired':False,'name':'Transcripted-1.1.76-release-candidate',
              'size_in_bytes':743785306,'digest':'sha256:'+M['RC_ZIP_SHA'],
              'workflow_run':{'id':41978929739,'head_sha':'9f7076de5ae5e98cadf90b43975161db667fc175'}}
        M['rc_metadata'](good)
        for key,value in [('id',13394641881),('expired',True),('size_in_bytes',743785305),
                          ('digest','sha256:'+'0'*64),('workflow_run',{'id':41978929738}),
                          ('name','Transcripted-1.1.75-release-candidate')]:
            with self.assertRaises(RuntimeError): M['rc_metadata']({**good,key:value})
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); archive=root/'rc.zip'; archive.write_bytes(b'wrong archive')
            metadata=root/'metadata.json'; metadata.write_text(json.dumps(good))
            assets=root/'assets'; assets.mkdir()
            with self.assertRaises(RuntimeError): M['stage_rc'](archive,metadata,assets)
            self.assertEqual(list(assets.iterdir()),[])

    def test_rc_zip_members_are_exact_unique_regular_files(self):
        infos=[zipfile.ZipInfo(n) for n in M['RC_MEMBERS']]
        M['rc_members'](infos)
        for bad in [infos[:-1],infos+[infos[0]],infos+[zipfile.ZipInfo('../escape')]]:
            with self.assertRaises(RuntimeError): M['rc_members'](bad)
        info=copy.copy(infos[0]); info.external_attr=0o120777 << 16
        with self.assertRaises(RuntimeError): M['rc_members']([info]+infos[1:])

    def test_experimental_model_overrides_are_removed_from_cli_environment(self):
        env=C['clean_environment']({'PATH':'/usr/bin','TRANSCRIPTED_NEMOTRON_EMBEDDER':'online',
            'TRANSCRIPTED_CONTAINER_DIR':'/foreign','TRANSCRIPTED_DIARIZATION_BACKEND':'pyannote'},Path('/owned'))
        self.assertEqual(env['PATH'],'/usr/bin')
        self.assertEqual(env['TMPDIR'],'/owned/tmp/')
        self.assertEqual(env['TRANSCRIPTED_CONTAINER_DIR'],'/owned/container')
        self.assertNotIn('TRANSCRIPTED_NEMOTRON_EMBEDDER',env)
        self.assertNotIn('TRANSCRIPTED_DIARIZATION_BACKEND',env)

    def write_wav(self,path,seconds=12):
        size=16000*2*seconds
        path.write_bytes(b'RIFF'+struct.pack('<I',36+size)+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,16000,32000,2,16)
                         +b'data'+struct.pack('<I',size)+bytes(size))

    def cli_fixture(self,root):
        transcript=root/'capture.md'; audio=root/'audio.wav'; self.write_wav(audio)
        capture='11111111-2222-3333-4444-555555555555'
        text=f'''---
capture_id: "{capture}"
transcript_id: "{capture}"
capture_type: meeting
sources: [system_audio]
mic_utterances: 0
mic_speakers: 0
system_utterances: 1
transcription_engine: parakeet_local
diarization_engine: nemotron_offline
voiceprint_model: "redimnet2-b4"
total_word_count: 3
speakers:
  - id: "0"
    name: "Speaker 0"
---
Original recording transcript schedule.
'''
        transcript.write_text(text)
        obj={'captureID':capture,'transcriptPath':str(transcript),'audioPath':str(audio)}
        return transcript,audio,text,obj

    def test_complete_import_rejects_false_success_and_wrong_engines(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); transcript,audio,text,obj=self.cli_fixture(root)
            self.assertEqual(C['validate_import'](json.dumps(obj),root,12,M['require'])['status'],'PASS')
            for bad in [json.dumps(obj)+' log',json.dumps({**obj,'audioPath':None}),
                        json.dumps({**obj,'captureID':'not-a-uuid'}),json.dumps({**obj,'extra':True})]:
                with self.assertRaises((ValueError,TypeError,RuntimeError)):
                    C['validate_import'](bad,root,12,M['require'])
            for before,after in [('parakeet_local','whisper'),('nemotron_offline','pyannote_offline'),
                                 ('redimnet2-b4','wespeaker'),('Speaker 0','Named Person'),
                                 ('recording transcript schedule','irrelevant speech'),
                                 ('mic_utterances: 0','mic_utterances: 1')]:
                transcript.write_text(text.replace(before,after))
                with self.assertRaises(RuntimeError): C['validate_import'](json.dumps(obj),root,12,M['require'])
            transcript.write_text(text)
            (root/'.transcripted-import-incomplete').mkdir()
            with self.assertRaises(RuntimeError): C['validate_import'](json.dumps(obj),root,12,M['require'])

    def test_import_paths_and_wav_truncation_fail_closed(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); output=root/'output'; output.mkdir()
            transcript,audio,text,obj=self.cli_fixture(output)
            outside=root/'outside.wav'; self.write_wav(outside)
            with self.assertRaises(RuntimeError):
                C['validate_import'](json.dumps({**obj,'audioPath':str(outside)}),output,12,M['require'])
            audio.unlink(); audio.symlink_to(outside)
            with self.assertRaises(RuntimeError): C['validate_import'](json.dumps(obj),output,12,M['require'])
            audio.unlink(); audio.write_bytes(b'RIFF'+bytes(20))
            with self.assertRaises(ValueError): C['wav_duration'](audio)
            self.write_wav(audio,seconds=1)
            with self.assertRaises(RuntimeError): C['validate_import'](json.dumps(obj),output,12,M['require'])

if __name__ == '__main__': unittest.main()
