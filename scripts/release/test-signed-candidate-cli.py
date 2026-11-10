#!/usr/bin/env python3
"""Owned synthetic import proof, called only after the staged harness's hosted guard.

Importing this module performs no execution. Never run the signed helper locally.
"""
import json
import math
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import uuid

SPEECH = ('Today we are testing the local meeting transcription workflow. The original recording must stay safe. '
          'We will save a readable transcript and check that the command reports success only after all files '
          'have been written. Tomorrow we will review the project schedule and confirm the next steps.')
MODEL_ROOTS = ('parakeet-models/parakeet-tdt-0.6b-v3', 'nemotron-diarizer-models',
               'redimnet2-voiceprint/Model.mlmodelc')


def wav_duration(path):
    # AVAudioFile emits IEEE-float WAV, which Python's wave module cannot read.
    with path.open('rb') as stream:
        header = stream.read(12)
        if len(header) != 12 or header[:4] != b'RIFF' or header[8:] != b'WAVE':
            raise ValueError('invalid WAV')
        total = path.stat().st_size
        if struct.unpack('<I', header[4:8])[0] + 8 > total:
            raise ValueError('truncated WAV')
        fmt = data_size = None
        while stream.tell() + 8 <= total:
            kind, size = struct.unpack('<4sI', stream.read(8))
            if stream.tell() + size > total:
                raise ValueError('truncated WAV chunk')
            if kind == b'fmt ':
                raw = stream.read(size)
                if len(raw) < 16:
                    raise ValueError('missing WAV format')
                fmt = struct.unpack('<HHIIHH', raw[:16])
                if fmt[0] == 65534 and len(raw) >= 40:
                    fmt = (struct.unpack('<H', raw[24:26])[0], *fmt[1:])
            elif kind == b'data':
                if data_size is not None:
                    raise ValueError('ambiguous WAV data')
                data_size = size
                stream.seek(size, 1)
            else:
                stream.seek(size, 1)
            if size % 2:
                stream.seek(1, 1)
        if not fmt or fmt[0] not in (1, 3) or not data_size or fmt[1] < 1 or fmt[2] < 1:
            raise ValueError('invalid WAV format/data')
        _, channels, rate, byte_rate, alignment, bits = fmt
        if alignment != channels * bits // 8 or byte_rate != rate * alignment or data_size % alignment:
            raise ValueError('invalid WAV framing')
        seconds = data_size / byte_rate
        if not math.isfinite(seconds):
            raise ValueError('nonfinite WAV duration')
        return seconds


def clean_environment(environment, root):
    # No inherited experimental model/backend overrides or user model directories.
    result = {k: v for k, v in environment.items() if not k.startswith('TRANSCRIPTED_')}
    result.update(TRANSCRIPTED_DISABLE_FILE_LOGGER='1', TRANSCRIPTED_AUTOMATED_HARNESS='1',
                  TRANSCRIPTED_CONTAINER_DIR=str(root/'container'), TMPDIR=str(root/'tmp')+'/')
    return result


def validate_import(stdout, output, expected_seconds, require):
    obj = json.loads(stdout)  # Whole stdout, never a matching log fragment.
    require(isinstance(obj, dict) and set(obj) == {'captureID', 'transcriptPath', 'audioPath'}, 'Invalid CLI receipt shape')
    capture = str(uuid.UUID(obj['captureID']))
    paths = []
    for key in ('transcriptPath', 'audioPath'):
        raw = Path(obj[key])
        require(raw.is_absolute() and not raw.is_symlink(), 'Invalid CLI artifact path')
        path = raw.resolve()
        require(path.is_relative_to(output.resolve()) and path.is_file(), 'CLI artifact escaped owned output')
        paths.append(path)
    transcript, audio = paths
    text = transcript.read_text()
    pieces = text.split('---', 2)
    require(len(pieces) == 3 and pieces[0] == '', 'Missing transcript frontmatter')
    fields = {}
    for line in pieces[1].splitlines():
        if line and not line[0].isspace() and ':' in line:
            key, value = line.split(':', 1)
            require(key not in fields, 'Duplicate transcript metadata')
            fields[key] = value.strip().strip('"')
    require(fields.get('capture_id', '').lower() == capture and fields.get('transcript_id', '').lower() == capture,
            'Capture identity mismatch')
    expected = {'capture_type': 'meeting', 'sources': '[system_audio]', 'mic_utterances': '0',
                'mic_speakers': '0', 'transcription_engine': 'parakeet_local',
                'diarization_engine': 'nemotron_offline', 'voiceprint_model': 'redimnet2-b4'}
    require(all(fields.get(k) == v for k, v in expected.items()), 'Actual engine/source metadata mismatch')
    require(int(fields.get('total_word_count', '0')) > 0 and int(fields.get('system_utterances', '0')) > 0,
            'Transcript contains no speech')
    words = set(re.findall(r'[a-z]+', pieces[2].lower()))
    require({'recording', 'transcript', 'schedule'} <= words, 'Synthetic speech content not recovered')
    require(not re.search(r'^\s+db_id:', pieces[1], re.M), 'Unexpected saved person identity')
    names = re.findall(r'^    name: "([^"]+)"$', pieces[1], re.M)
    require(names and all(re.fullmatch(r'Speaker \d+', n) for n in names), 'Unexpected named speaker')
    seconds = wav_duration(audio)
    require(seconds >= 10 and abs(seconds - expected_seconds) <= 0.1, 'Retained WAV duration mismatch')
    require(len(list(output.rglob('*.md'))) == 1 and len(list(output.rglob('*.wav'))) == 1,
            'Unexpected committed artifacts')
    require(not any(p.name.startswith('.transcripted-import-') for p in output.rglob('*')), 'Publication scratch remains')
    return {'status': 'PASS', 'json_complete': True, 'artifact_identity_matches': True,
            'synthetic_expected_words': True, 'retained_audio_seconds': seconds,
            'actual_stt': 'parakeet_local', 'actual_diarization': 'nemotron_offline',
            'actual_voiceprint': 'redimnet2-b4', 'saved_person_identity': False}


def qualify(original, root, source_sha, run, require, tree_digest, sha):
    root.mkdir(mode=0o700)
    for name in ('input', 'output', 'container', 'tmp'):
        (root/name).mkdir(mode=0o700)
    app = root/'relocated'/'Transcripted.app'
    app.parent.mkdir(mode=0o700)
    run('ditto', original, app)
    pristine = tree_digest(original)
    require(tree_digest(app) == pristine, 'CLI relocated app differs')
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleShortVersionString') == '1.1.76' and info.get('CFBundleVersion') == '1.1.76'
            and info.get('TranscriptedBuildRevision') == source_sha[:12]
            and info.get('TranscriptedBuildChannel') == 'release', 'CLI candidate build identity mismatch')
    model_proof = {}
    for name in MODEL_ROOTS:
        folder = app/'Contents/Resources'/name
        require(folder.is_dir() and any(p.is_file() for p in folder.rglob('*')), 'Missing bundled default model')
        model_proof[name] = tree_digest(folder)
    binary = app/'Contents/Helpers/transcripted-cli'
    require(binary.is_file() and os.access(binary, os.X_OK), 'Packaged CLI missing')
    require(Path('/usr/bin/sandbox-exec').is_file(), 'Network-deny sandbox unavailable')
    aiff, audio = root/'input/voice.aiff', root/'input/voice.wav'
    run('/usr/bin/say', '-v', 'Samantha', '-r', '150', '-o', aiff, SPEECH)
    run('/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEI16', aiff, audio)
    duration = wav_duration(audio)
    require(duration >= 10, 'Synthetic fixture shorter than ten seconds')
    before = tree_digest(root/'input')
    environment = clean_environment(os.environ, root)
    result = subprocess.run(['/usr/bin/sandbox-exec', '-p', '(version 1) (allow default) (deny network*)',
        str(binary), 'import-audio', str(audio), '--output-dir', str(root/'output'), '--title', 'CLI release fixture',
        '--diarization-engine', 'nemotron', '--speaker-embedder', 'redimnet2',
        '--no-speaker-identification', '--no-download', '--json'],
        capture_output=True, text=True, env=environment, timeout=1200)
    (root/'import.stdout').write_text(result.stdout)
    (root/'import.stderr').write_text(result.stderr)
    require(result.returncode == 0, 'Signed candidate CLI import failed')
    # Exact resolved local path in the real resolver log, never published.
    expected = str(app/'Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3')
    require('Loading Parakeet models from '+expected in result.stderr, 'Parakeet loaded from another model root')
    proof = validate_import(result.stdout, root/'output', duration, require)
    require(not list((root/'tmp').iterdir()), 'CLI import scratch remains')
    require(tree_digest(root/'input') == before, 'Synthetic input changed')
    require(tree_digest(app) == pristine and tree_digest(original) == pristine, 'Signed app or models changed')
    run('codesign', '--verify', '--deep', '--strict', app)
    proof.update(helper_sha256=sha(binary), bundle_sha256=pristine, bundled_models=model_proof,
                 network_denied=True, downloads_disabled=True, default_relocated_models=True,
                 input_unchanged=True, bundle_unchanged=True, exit_code=0)
    return proof
