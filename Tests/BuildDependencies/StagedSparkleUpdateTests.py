#!/usr/bin/env python3
"""Offline contract tests: no app launch, network, defaults, or signing changes."""
import copy
import json
import os
import plistlib
import subprocess
import struct
import zipfile
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest import mock
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
            empty=root/'empty'; empty.mkdir(); empty.chmod(0o755)
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

    def test_preference_presence_reports_all_three_strict_conditions_without_values(self):
        with tempfile.TemporaryDirectory() as name:
            home=Path(name); standard=home/'Library/Preferences'; by_host=standard/'ByHost'
            by_host.mkdir(parents=True)
            (standard/(M['BUNDLE_ID']+'.plist')).write_bytes(b'private preference values')
            (by_host/(M['BUNDLE_ID']+'.controlled-host.plist')).write_bytes(b'private host values')
            state=M['product_preferences_state'](home,lambda *args:M['BUNDLE_ID'])
            self.assertEqual(state,{'domain_listed':True,'standard_plist_present':True,'by_host_plist_present':True})
            self.assertNotIn('private',json.dumps(state))

    class Clock:
        def __init__(self): self.now=0
        def read(self): return self.now
        def pause(self,seconds): self.now+=seconds

    def test_preference_cleanup_waits_owned_process_exit_then_deletes_exactly_once(self):
        clock=self.Clock(); events=[]; proof={}
        present={'domain_listed':True,'standard_plist_present':True,'by_host_plist_present':False}
        absent=dict.fromkeys(present,False)
        states=iter([present,present,{**present,'domain_listed':False},absent])
        def alive(pid):
            self.assertEqual(pid,42)
            events.append(('alive',clock.now))
            return clock.now < 1
        def command(*args):
            self.assertGreaterEqual(clock.now,1)
            events.append(('delete',args))
        M['restore_product_preferences'](Path('/unused'),{42},proof,command,lambda:next(states),
                                          alive,clock.read,clock.pause)
        self.assertEqual(sum(e[0]=='delete' for e in events),1)
        self.assertEqual(proof['delete_commands'],1)
        self.assertEqual(proof['owned_pid_count'],1)
        self.assertTrue(proof['owned_pids_exited'])
        self.assertTrue(proof['absence_restored'])
        self.assertEqual(proof['observations'],3)
        self.assertEqual(proof['after_delete'],absent)

    def test_live_owned_process_blocks_preference_deletion(self):
        clock=self.Clock(); proof={}; calls=[]
        with self.assertRaises(RuntimeError):
            M['restore_product_preferences'](Path('/unused'),{42},proof,lambda *args:calls.append(args),
                lambda:self.fail('preference reads must wait for process exit'),
                lambda pid:True,clock.read,clock.pause)
        self.assertEqual(calls,[])
        self.assertEqual(proof['delete_commands'],0)
        self.assertFalse(proof['owned_pids_exited'])

    def test_each_permanent_preference_residue_fails_without_repeating_delete(self):
        for residue in ['domain_listed','standard_plist_present','by_host_plist_present']:
            with self.subTest(residue=residue):
                clock=self.Clock(); proof={}; calls=[]
                state={k:k==residue for k in ['domain_listed','standard_plist_present','by_host_plist_present']}
                with self.assertRaises(RuntimeError):
                    M['restore_product_preferences'](Path('/unused'),{42},proof,lambda *args:calls.append(args),
                        lambda:dict(state),lambda pid:False,clock.read,clock.pause)
                self.assertEqual(calls,[('defaults','delete',M['BUNDLE_ID'])])
                self.assertEqual(proof['delete_commands'],1)
                self.assertFalse(proof['absence_restored'])
                self.assertEqual(proof['after_delete'],state)

    def test_delete_command_failure_stops_without_convergence_or_second_delete(self):
        clock=self.Clock(); proof={}; calls=[]; reads=[]
        def command(*args):
            calls.append(args)
            raise RuntimeError('controlled deletion failure')
        def read():
            reads.append(True)
            return {'domain_listed':True,'standard_plist_present':True,'by_host_plist_present':False}
        with self.assertRaises(RuntimeError):
            M['restore_product_preferences'](Path('/unused'),{42},proof,command,read,
                lambda pid:False,clock.read,clock.pause)
        self.assertEqual(calls,[('defaults','delete',M['BUNDLE_ID'])])
        self.assertEqual(proof['delete_commands'],1)
        self.assertEqual(len(reads),1)

    def preference_fixture(self,root,data=None):
        root=root.resolve(); home=root/'home'; output=root/'output'
        (home/'Library/Preferences').mkdir(parents=True)
        output.mkdir()
        for directory in [home,home/'Library',home/'Library/Preferences',output]: directory.chmod(0o700)
        source=home/'Library/Preferences'/(M['BUNDLE_ID']+'.plist')
        source.write_bytes(plistlib.dumps({}) if data is None else data); source.chmod(0o600)
        return home,output,source

    def test_empty_claim_retains_exact_inode_and_any_late_open_writer_bytes(self):
        with tempfile.TemporaryDirectory() as name:
            home,output,source=self.preference_fixture(Path(name))
            inode=source.stat().st_ino; proof={}
            with source.open('r+b') as writer:
                M['retain_empty_preference'](home,output,proof)
                retained=list(output.rglob('retained.plist'))
                self.assertFalse(source.exists()); self.assertEqual(len(retained),1)
                self.assertEqual(retained[0].stat().st_ino,inode)
                self.assertTrue(proof['empty_claim_revalidated']); self.assertTrue(proof['quarantine_retained'])
                self.assertEqual(proof['before_claim']['key_count'],0)
                late=plistlib.dumps({'controlled late data':True})
                writer.seek(0); writer.write(late); writer.truncate(); writer.flush()
                self.assertEqual(retained[0].read_bytes(),late)

    def test_nonempty_malformed_wrong_type_unsafe_size_and_links_are_never_claimed(self):
        cases=[plistlib.dumps({'controlled':True}),b'malformed',plistlib.dumps([]),b'',b'x'*(1024*1024+1)]
        for data in cases:
            with self.subTest(size=len(data)),tempfile.TemporaryDirectory() as name:
                home,output,source=self.preference_fixture(Path(name),data)
                with self.assertRaises(RuntimeError): M['retain_empty_preference'](home,output,{})
                self.assertEqual(source.read_bytes(),data); self.assertEqual(list(output.iterdir()),[])
        for kind in ['hardlink','symlink','writable','wrong-owner']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as name:
                home,output,source=self.preference_fixture(Path(name)); before=source.read_bytes()
                if kind=='hardlink': os.link(source,home/'second-link')
                if kind=='symlink':
                    target=home/'unrelated.plist'; target.write_bytes(before)
                    source.unlink(); source.symlink_to(target)
                if kind=='writable': source.chmod(0o666)
                uid=os.getuid()+1 if kind=='wrong-owner' else os.getuid()
                with self.assertRaises((RuntimeError,OSError)):
                    M['retain_empty_preference'](home,output,{},expected_uid=uid)
                self.assertEqual(source.read_bytes(),before); self.assertEqual(list(output.iterdir()),[])

    def test_preference_parent_and_output_symlinks_cannot_redirect_claim(self):
        for kind in ['parent','output']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as name:
                home,output,source=self.preference_fixture(Path(name)); before=source.read_bytes()
                if kind=='parent':
                    real=home/'actual-preferences'; source.parent.rename(real)
                    (home/'Library/Preferences').symlink_to(real,target_is_directory=True)
                else:
                    real=output.with_name('actual-output'); output.rename(real)
                    output.symlink_to(real,target_is_directory=True)
                with self.assertRaises((RuntimeError,OSError)): M['retain_empty_preference'](home,output,{})
                self.assertEqual(source.read_bytes(),before)

    def test_wrong_file_owner_and_directory_type_fail_before_claim(self):
        with tempfile.TemporaryDirectory() as name:
            home,output,source=self.preference_fixture(Path(name))
            with source.open('rb') as stream:
                with self.assertRaises(RuntimeError): M['inspect_empty_preference'](stream.fileno(),os.getuid()+1,{})
            source.unlink(); source.mkdir()
            with self.assertRaises(RuntimeError): M['retain_empty_preference'](home,output,{})
            self.assertTrue(source.is_dir()); self.assertEqual(list(output.iterdir()),[])

    def test_source_inode_swap_before_claim_fails_without_moving_replacement(self):
        with tempfile.TemporaryDirectory() as name:
            home,output,source=self.preference_fixture(Path(name)); proof={}; original=os.stat; replaced=False
            unexpected=plistlib.dumps({'controlled replacement':True})
            def stat_entry(path,*args,**kwargs):
                nonlocal replaced
                if path==M['BUNDLE_ID']+'.plist' and kwargs.get('dir_fd') is not None and not replaced:
                    source.unlink(); source.write_bytes(unexpected); source.chmod(0o600); replaced=True
                return original(path,*args,**kwargs)
            with mock.patch.object(M['os'],'stat',side_effect=stat_entry):
                with self.assertRaises(RuntimeError): M['retain_empty_preference'](home,output,proof)
            self.assertEqual(source.read_bytes(),unexpected); self.assertFalse(proof['claimed'])
            self.assertFalse(list(output.rglob('retained.plist')))

    def test_existing_quarantine_is_never_reused_or_overwritten(self):
        with tempfile.TemporaryDirectory() as name:
            home,output,source=self.preference_fixture(Path(name)); before=source.read_bytes()
            identifier=M['uuid'].UUID(int=1)
            existing=output/('.preference-quarantine-'+identifier.hex); existing.mkdir(mode=0o700)
            sentinel=existing/'retained.plist'; sentinel.write_bytes(b'controlled existing sentinel')
            with mock.patch.object(M['uuid'],'uuid4',return_value=identifier):
                with self.assertRaises(OSError): M['retain_empty_preference'](home,output,{})
            self.assertEqual(source.read_bytes(),before)
            self.assertEqual(sentinel.read_bytes(),b'controlled existing sentinel')

    def test_raced_source_replacement_is_restored_or_retained_without_overwrite(self):
        for kind in ['different-inode','late-write','new-source']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as name:
                home,output,source=self.preference_fixture(Path(name)); proof={}; original=os.rename
                unexpected=plistlib.dumps({'controlled unexpected':True})
                def rename(*args,**kwargs):
                    if kind=='different-inode':
                        source.unlink(); source.write_bytes(plistlib.dumps({})); source.chmod(0o600)
                    original(*args,**kwargs)
                    retained=next(output.rglob('retained.plist'))
                    if kind=='late-write': retained.write_bytes(unexpected)
                    if kind=='new-source': source.write_bytes(unexpected)
                with mock.patch.object(M['os'],'rename',side_effect=rename):
                    with self.assertRaises(RuntimeError): M['retain_empty_preference'](home,output,proof)
                retained=next(output.rglob('retained.plist'))
                self.assertTrue(proof['quarantine_retained']); self.assertFalse(proof['empty_claim_revalidated'])
                if kind=='new-source':
                    self.assertEqual(source.read_bytes(),unexpected)
                    self.assertFalse(proof['restored_without_overwrite'])
                else:
                    self.assertTrue(proof['restored_without_overwrite'])
                    self.assertEqual(source.read_bytes(),retained.read_bytes())
                    if kind=='late-write': self.assertEqual(retained.read_bytes(),unexpected)

    def test_one_delete_can_restore_absence_by_retaining_only_proven_empty_residue(self):
        with tempfile.TemporaryDirectory() as name:
            home,output,source=self.preference_fixture(Path(name)); clock=self.Clock(); calls=[]; proof={}
            def state():
                return {'domain_listed':source.exists(),'standard_plist_present':source.exists(),
                        'by_host_plist_present':False}
            M['restore_product_preferences'](home,{42},proof,lambda *args:calls.append(args),state,
                lambda pid:False,clock.read,clock.pause,output=output)
            self.assertEqual(calls,[('defaults','delete',M['BUNDLE_ID'])])
            self.assertTrue(proof['absence_restored']); self.assertFalse(source.exists())
            self.assertTrue(proof['residual_plist']['quarantine_retained'])
            self.assertEqual(len(list(output.rglob('retained.plist'))),1)

    def test_post_claim_domain_byhost_or_new_standard_residue_still_fails(self):
        for residue in ['domain','byhost','standard']:
            with self.subTest(residue=residue),tempfile.TemporaryDirectory() as name:
                home,output,source=self.preference_fixture(Path(name)); clock=self.Clock(); calls=[]; proof={}
                recreated=False
                def state():
                    nonlocal recreated
                    claimed=bool(list(output.rglob('retained.plist')))
                    if claimed and residue=='standard' and not recreated:
                        source.write_bytes(plistlib.dumps({'unexpected new source':True})); recreated=True
                    return {'domain_listed':source.exists() or (claimed and residue=='domain'),
                            'standard_plist_present':source.exists(),
                            'by_host_plist_present':claimed and residue=='byhost'}
                with self.assertRaises(RuntimeError):
                    M['restore_product_preferences'](home,{42},proof,lambda *args:calls.append(args),state,
                        lambda pid:False,clock.read,clock.pause,output=output)
                self.assertEqual(len(calls),1); self.assertFalse(proof['absence_restored'])
                self.assertTrue(proof['residual_plist']['quarantine_retained'])
                if residue=='standard': self.assertEqual(plistlib.loads(source.read_bytes()),{'unexpected new source':True})

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
