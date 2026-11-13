#!/usr/bin/env python3
"""Record which model files packaging copied into the app, and where they came from.

    python3 scripts/release/write-model-manifest.py --app <Transcripted.app> \
        --output <manifest.json> \
        --model <id> <source-cache-dir> <bundled-dir> [--model ...]

For each model: its id, the source cache folder's name (never its absolute
path), the upstream revision the cache recorded if it recorded one, and the
SHA-256 and size of every file in the bundled copy. When the cache carries a
FluidAudio `provenance.json` with per-file hashes, the bundled files are
checked against it and the result is recorded.

Exits non-zero, writing nothing, when a source or bundled folder is missing,
the bundled folder is outside the app, or a bundled folder has no files. A
missing upstream revision is recorded as null, not an error: the cache simply
didn't keep one, and the manifest says so instead of guessing.

build-beta.sh runs this after it copies the models and prints the result.
Read-only on its inputs.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

# Text markers FluidAudio writes beside a cached model, in the order we trust them.
REVISION_MARKERS = ('.fluidaudio-revision', '.fluidaudio-nemotron3-weights')
# Keys in a cache's provenance.json that name an upstream snapshot.
PROVENANCE_REVISION_KEYS = ('revision', 'commit', 'artifact_snapshot')


class ManifestError(Exception):
    pass


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def bundled_files(folder):
    files = []
    for root, dirs, names in os.walk(folder):
        dirs.sort()
        for name in sorted(names):
            path = Path(root) / name
            if path.is_symlink() or not path.is_file():
                continue
            files.append(path)
    return files


def hf_cache_revisions(source):
    """Commit hashes from huggingface_hub's local-dir download metadata, if any."""
    meta_root = source / '.cache' / 'huggingface' / 'download'
    revisions = set()
    if meta_root.is_dir():
        for meta in meta_root.rglob('*.metadata'):
            try:
                first = meta.read_text(errors='replace').splitlines()[0].strip()
            except (OSError, IndexError):
                continue
            if first:
                revisions.add(first)
    return sorted(revisions)


def load_provenance(source):
    path = source / 'provenance.json'
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise ManifestError(f'{source.name}/provenance.json is not readable JSON: {error}')
    return data if isinstance(data, dict) else None


def upstream_revision(source, provenance):
    for marker in REVISION_MARKERS:
        path = source / marker
        if path.is_file():
            value = path.read_text(errors='replace').strip()
            if value:
                return {'value': value, 'from': marker}
    if provenance:
        for key in PROVENANCE_REVISION_KEYS:
            value = provenance.get(key)
            if isinstance(value, str) and value.strip():
                return {'value': value.strip(), 'from': f'provenance.json:{key}'}
    hf = hf_cache_revisions(source)
    if len(hf) == 1:
        return {'value': hf[0], 'from': '.cache/huggingface/download'}
    if len(hf) > 1:
        # Files from more than one commit: record all of them, pick none.
        return {'value': None, 'from': '.cache/huggingface/download', 'mixed': hf}
    return None


def upstream_hash_check(files, provenance):
    """Compare bundled files to a provenance.json artifact list (paths relative to the cache)."""
    if not provenance or not isinstance(provenance.get('artifacts'), list):
        return None
    listed = {}
    for item in provenance['artifacts']:
        if isinstance(item, dict) and isinstance(item.get('path'), str) and isinstance(item.get('sha256'), str):
            listed[item['path']] = item['sha256'].lower()
    matched, mismatched, unlisted = 0, [], []
    for entry in files:
        expected = listed.get(entry['path'])
        if expected is None:
            unlisted.append(entry['path'])
        elif expected == entry['sha256']:
            matched += 1
        else:
            mismatched.append(entry['path'])
    return {'listed': len(listed), 'matched': matched, 'mismatched': mismatched, 'unlisted': unlisted}


def describe_model(model_id, source, dest, app):
    if not source.is_dir():
        raise ManifestError(f'{model_id}: source cache folder is missing: {source.name}')
    if not dest.is_dir():
        raise ManifestError(f'{model_id}: bundled model folder is missing: {dest.name}')
    try:
        bundle_path = dest.resolve().relative_to(app.resolve())
    except ValueError:
        raise ManifestError(f'{model_id}: bundled folder {dest.name} is not inside the app bundle')
    paths = bundled_files(dest)
    if not paths:
        raise ManifestError(f'{model_id}: bundled model folder has no files: {bundle_path}')
    files = [{'path': p.relative_to(dest).as_posix(), 'sha256': sha256_of(p), 'size': p.stat().st_size}
             for p in paths]
    provenance = load_provenance(source)
    entry = {
        'id': model_id,
        'source_cache_dir': source.name,
        'bundle_path': bundle_path.as_posix(),
        'upstream_revision': upstream_revision(source, provenance),
        'file_count': len(files),
        'total_bytes': sum(f['size'] for f in files),
        'files': files,
    }
    check = upstream_hash_check(files, provenance)
    if check is not None:
        entry['upstream_hash_check'] = check
    return entry


def build_manifest(app, models):
    if not app.is_dir():
        raise ManifestError(f'app bundle is missing: {app.name}')
    seen = set()
    entries = []
    for model_id, source, dest in models:
        if model_id in seen:
            raise ManifestError(f'model id listed twice: {model_id}')
        seen.add(model_id)
        entries.append(describe_model(model_id, Path(source), Path(dest), app))
    return {'schema': 1, 'app': app.name, 'models': entries}


def summary_lines(manifest):
    lines = [f'Bundled model manifest ({len(manifest["models"])} models):']
    for model in manifest['models']:
        revision = model['upstream_revision']
        if revision is None:
            rev_text = 'upstream revision: not recorded by the cache'
        elif revision.get('value') is None:
            rev_text = 'upstream revision: mixed (' + ', '.join(revision.get('mixed', [])) + ')'
        else:
            rev_text = f'upstream revision: {revision["value"]} (from {revision["from"]})'
        lines.append(f'  {model["id"]}: {model["bundle_path"]} <- {model["source_cache_dir"]}; '
                     f'{model["file_count"]} files, {model["total_bytes"]} bytes; {rev_text}')
        check = model.get('upstream_hash_check')
        if check is not None:
            lines.append(f'    provenance.json hashes: {check["matched"]} matched, '
                         f'{len(check["mismatched"])} mismatched, {len(check["unlisted"])} not listed')
    return lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--model', action='append', nargs=3, metavar=('ID', 'SOURCE', 'BUNDLED'), default=[])
    args = parser.parse_args(argv)
    if not args.model:
        print('write-model-manifest: no --model given; nothing to record', file=sys.stderr)
        return 2
    try:
        manifest = build_manifest(args.app, args.model)
    except ManifestError as error:
        print(f'❌ write-model-manifest: {error}', file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name + '.tmp')
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    temporary.replace(args.output)
    for line in summary_lines(manifest):
        print(line)
    print(f'Wrote {args.output}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
