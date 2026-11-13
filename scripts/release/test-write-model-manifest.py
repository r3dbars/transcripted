#!/usr/bin/env python3
"""Promise: packaging records every bundled model's files, hashes and cached
upstream revision, and refuses to write a manifest when a model folder is missing."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/release/write-model-manifest.py'


def sha(data):
    return hashlib.sha256(data).hexdigest()


class WriteModelManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='transcripted-model-manifest-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.cache = self.root / 'cache'
        self.app = self.root / 'build' / 'Transcripted.app'
        self.resources = self.app / 'Contents' / 'Resources'
        self.resources.mkdir(parents=True)
        self.output = self.root / 'build' / 'Transcripted-model-manifest.json'

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def run_script(self, *models):
        args = [sys.executable, str(SCRIPT), '--app', str(self.app), '--output', str(self.output)]
        for model in models:
            args += ['--model', *map(str, model)]
        return subprocess.run(args, capture_output=True, text=True,
                              env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})

    def fixture_models(self):
        # Diarizer cache: revision marker plus a provenance.json listing one
        # right hash and one wrong hash.
        diarizer_src = self.cache / 'speaker-diarization'
        self.write(diarizer_src / '.fluidaudio-revision', b'abc123def\n')
        self.write(diarizer_src / 'provenance.json', json.dumps({
            'artifact_snapshot': 'ignored-because-marker-wins',
            'artifacts': [
                {'path': 'Segmentation.mlmodelc/coremldata.bin', 'sha256': sha(b'seg')},
                {'path': 'plda-parameters.json', 'sha256': sha(b'not what shipped')},
            ]}).encode())
        diarizer_dest = self.resources / 'offline-diarizer-models' / 'speaker-diarization'
        self.write(diarizer_dest / 'Segmentation.mlmodelc' / 'coremldata.bin', b'seg')
        self.write(diarizer_dest / 'plda-parameters.json', b'{}')
        self.write(diarizer_dest / 'config.json', b'cfg')

        # Parakeet cache: Hugging Face local-dir metadata, no FluidAudio marker.
        parakeet_src = self.cache / 'parakeet-tdt-0.6b-v3'
        self.write(parakeet_src / '.cache' / 'huggingface' / 'download' / 'Encoder.mlmodelc' / 'weight.bin.metadata',
                   b'0123456789abcdef0123456789abcdef01234567\netag\n1700000000.0\n')
        parakeet_dest = self.resources / 'parakeet-models' / 'parakeet-tdt-0.6b-v3'
        self.write(parakeet_dest / 'Encoder.mlmodelc' / 'weights' / 'weight.bin', b'enc-weights')

        # Voiceprint cache: no metadata at all.
        voiceprint_src = self.cache / 'redimnet2-b4-slim'
        self.write(voiceprint_src / 'Model.mlmodelc' / 'model.mil', b'mil')
        voiceprint_dest = self.resources / 'redimnet2-voiceprint'
        self.write(voiceprint_dest / 'Model.mlmodelc' / 'model.mil', b'mil')
        return [
            ('offline-diarizer', diarizer_src, diarizer_dest),
            ('parakeet-tdt-0.6b-v3', parakeet_src, parakeet_dest),
            ('redimnet2-b4-voiceprint', voiceprint_src, voiceprint_dest),
        ]

    def test_fixture_cache_produces_expected_manifest(self):
        result = self.run_script(*self.fixture_models())
        self.assertEqual(result.returncode, 0, result.stderr)

        manifest = json.loads(self.output.read_text())
        self.assertEqual(manifest, {
            'schema': 1,
            'app': 'Transcripted.app',
            'models': [
                {
                    'id': 'offline-diarizer',
                    'source_cache_dir': 'speaker-diarization',
                    'bundle_path': 'Contents/Resources/offline-diarizer-models/speaker-diarization',
                    'upstream_revision': {'value': 'abc123def', 'from': '.fluidaudio-revision'},
                    'file_count': 3,
                    'total_bytes': 8,
                    'files': [
                        {'path': 'config.json', 'sha256': sha(b'cfg'), 'size': 3},
                        {'path': 'plda-parameters.json', 'sha256': sha(b'{}'), 'size': 2},
                        {'path': 'Segmentation.mlmodelc/coremldata.bin', 'sha256': sha(b'seg'), 'size': 3},
                    ],
                    'upstream_hash_check': {
                        'listed': 2, 'matched': 1,
                        'mismatched': ['plda-parameters.json'], 'unlisted': ['config.json'],
                    },
                },
                {
                    'id': 'parakeet-tdt-0.6b-v3',
                    'source_cache_dir': 'parakeet-tdt-0.6b-v3',
                    'bundle_path': 'Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3',
                    'upstream_revision': {'value': '0123456789abcdef0123456789abcdef01234567',
                                          'from': '.cache/huggingface/download'},
                    'file_count': 1,
                    'total_bytes': 11,
                    'files': [{'path': 'Encoder.mlmodelc/weights/weight.bin',
                               'sha256': sha(b'enc-weights'), 'size': 11}],
                },
                {
                    'id': 'redimnet2-b4-voiceprint',
                    'source_cache_dir': 'redimnet2-b4-slim',
                    'bundle_path': 'Contents/Resources/redimnet2-voiceprint',
                    'upstream_revision': None,
                    'file_count': 1,
                    'total_bytes': 3,
                    'files': [{'path': 'Model.mlmodelc/model.mil', 'sha256': sha(b'mil'), 'size': 3}],
                },
            ],
        })
        self.assertIn('parakeet-tdt-0.6b-v3', result.stdout)
        self.assertIn('upstream revision: not recorded by the cache', result.stdout)

    def test_manifest_never_contains_absolute_paths(self):
        result = self.run_script(*self.fixture_models())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(str(self.root), self.output.read_text())

    def test_missing_bundled_folder_fails_and_writes_nothing(self):
        models = self.fixture_models()
        models.append(('nemotron-3-diarizer', self.cache / 'nemotron-3-diarization',
                       self.resources / 'nemotron-diarizer-models'))
        (self.cache / 'nemotron-3-diarization').mkdir()
        result = self.run_script(*models)
        self.assertEqual(result.returncode, 1)
        self.assertIn('nemotron-3-diarizer', result.stderr)
        self.assertFalse(self.output.exists())

    def test_missing_source_cache_fails(self):
        models = self.fixture_models()
        models[1] = ('parakeet-tdt-0.6b-v3', self.cache / 'parakeet-tdt-0.6b-v3-coreml', models[1][2])
        result = self.run_script(*models)
        self.assertEqual(result.returncode, 1)
        self.assertIn('source cache folder is missing', result.stderr)
        self.assertFalse(self.output.exists())

    def test_empty_bundled_folder_fails(self):
        source = self.cache / 'nemotron-3-diarization'
        source.mkdir(parents=True)
        dest = self.resources / 'nemotron-diarizer-models'
        dest.mkdir()
        result = self.run_script(('nemotron-3-diarizer', source, dest))
        self.assertEqual(result.returncode, 1)
        self.assertIn('no files', result.stderr)

    def test_bundled_folder_outside_app_fails(self):
        source = self.cache / 'x'
        self.write(source / 'a', b'a')
        outside = self.root / 'elsewhere'
        self.write(outside / 'a', b'a')
        result = self.run_script(('x', source, outside))
        self.assertEqual(result.returncode, 1)
        self.assertIn('not inside the app bundle', result.stderr)

    def test_mixed_hugging_face_revisions_are_recorded_not_picked(self):
        source = self.cache / 'parakeet-tdt-0.6b-v3'
        meta = source / '.cache' / 'huggingface' / 'download'
        self.write(meta / 'a.metadata', b'1111\n')
        self.write(meta / 'b.metadata', b'2222\n')
        dest = self.resources / 'parakeet-models' / 'parakeet-tdt-0.6b-v3'
        self.write(dest / 'a', b'a')
        result = self.run_script(('parakeet', source, dest))
        self.assertEqual(result.returncode, 0, result.stderr)
        revision = json.loads(self.output.read_text())['models'][0]['upstream_revision']
        self.assertEqual(revision, {'value': None, 'from': '.cache/huggingface/download',
                                    'mixed': ['1111', '2222']})


if __name__ == '__main__':
    unittest.main()
