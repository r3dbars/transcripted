#!/usr/bin/env python3
"""Speaker-naming simulator: model how many speakers a meeting asks you to name.

The post-meeting "Review meeting speakers" sheet lists one row per distinct
system (remote) speaker that diarization produced. Offline VBx clustering often
splits a single remote voice across several clusters, so a one-on-one call can
ask you to name 4-7 "people" for the single person you actually talked to.

This simulator reproduces that failure without needing audio or ML models. It
generates synthetic diarization output (true speakers over-segmented into
multiple clusters, with realistic intra/cross-speaker embedding geometry), runs
a faithful model of TranscriptedCore's EmbeddingClusterer post-processing, and
reports how many speakers land in the naming sheet before and after the
same-voice consolidation pass.

Pure stdlib, deterministic under --seed. The thresholds below mirror
Sources/TranscriptedCore/Speaker/EmbeddingClusterer.swift — keep them in sync if
that file changes.

Usage:
  scripts/ops/speaker-naming-simulator.py            # run the scenario suite
  scripts/ops/speaker-naming-simulator.py --sweep    # threshold sweep on a 1:1 call
  scripts/ops/speaker-naming-simulator.py --json      # machine-readable suite output
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from dataclasses import dataclass, field

# --- Constants mirrored from EmbeddingClusterer.swift ------------------------
MIN_CLUSTER_DURATION = 30.0
ABSORPTION_THRESHOLD = 0.72
MICRO_CLUSTER_DURATION = 10.0
MICRO_ABSORPTION_THRESHOLD = 0.62
CONSOLIDATION_THRESHOLD = 0.88  # SpeakerNamingPolicy auto-accept bar.
QUALITY_MIN_SCORE = 0.3
QUALITY_MIN_DURATION = 1.0


@dataclass
class Segment:
    speaker_id: int
    start: float
    end: float
    embedding: list[float]
    quality: float = 0.95

    @property
    def duration(self) -> float:
        return self.end - self.start


# --- Vector helpers ----------------------------------------------------------
def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def normalize(v: list[float]) -> list[float]:
    n = math.sqrt(sum(x * x for x in v))
    if n == 0:
        return v
    return [x / n for x in v]


def mean_embedding(vectors: list[list[float]]) -> list[float]:
    if not vectors:
        return []
    dim = len(vectors[0])
    acc = [0.0] * dim
    for v in vectors:
        for i in range(dim):
            acc[i] += v[i]
    return [x / len(vectors) for x in acc]


def _quality_means(segments: list[Segment]) -> dict[int, list[float]]:
    """Quality-filtered mean embedding per speaker, matching the Swift gate."""
    buckets: dict[int, list[list[float]]] = {}
    for seg in segments:
        if not seg.embedding:
            continue
        if seg.quality >= QUALITY_MIN_SCORE and seg.duration >= QUALITY_MIN_DURATION:
            buckets.setdefault(seg.speaker_id, []).append(seg.embedding)
    return {sid: mean_embedding(embs) for sid, embs in buckets.items()}


# --- Post-processing (faithful port of EmbeddingClusterer) -------------------
def absorb_small_clusters(segments: list[Segment]) -> list[Segment]:
    duration: dict[int, float] = {}
    seg_count: dict[int, int] = {}
    raw: dict[int, list[list[float]]] = {}
    for seg in segments:
        duration[seg.speaker_id] = duration.get(seg.speaker_id, 0.0) + seg.duration
        seg_count[seg.speaker_id] = seg_count.get(seg.speaker_id, 0) + 1
        if seg.embedding:
            raw.setdefault(seg.speaker_id, []).append(seg.embedding)

    small_ids = {sid for sid, d in duration.items() if d < MIN_CLUSTER_DURATION}
    large_ids = {sid for sid, d in duration.items() if d >= MIN_CLUSTER_DURATION}
    if not small_ids or not large_ids:
        return segments

    means = _quality_means(segments)
    for sid in small_ids:
        if sid not in means and raw.get(sid):
            means[sid] = mean_embedding(raw[sid])

    merge_map: dict[int, int] = {}
    for sid in small_ids:
        if seg_count.get(sid, 0) >= 3:  # multi-turn speaker, protect it
            continue
        if sid not in means:
            continue
        best_id, best_sim = None, 0.0
        for lid in large_ids:
            if lid not in means:
                continue
            sim = cosine(means[sid], means[lid])
            if sim > best_sim:
                best_sim, best_id = sim, lid
        is_micro = duration[sid] < MICRO_CLUSTER_DURATION
        threshold = MICRO_ABSORPTION_THRESHOLD if is_micro else ABSORPTION_THRESHOLD
        if best_id is not None and best_sim >= threshold:
            merge_map[sid] = best_id

    if not merge_map:
        return segments
    surviving = set(duration.keys()) - set(merge_map.keys())
    if len(surviving) < 2:  # never collapse to a single speaker here
        return segments
    return _remap(segments, merge_map)


def consolidate_same_voice_clusters(
    segments: list[Segment], threshold: float = CONSOLIDATION_THRESHOLD
) -> list[Segment]:
    distinct = {seg.speaker_id for seg in segments}
    if len(distinct) < 2:
        return segments

    quality: dict[int, list[list[float]]] = {}
    allv: dict[int, list[list[float]]] = {}
    for seg in segments:
        if not seg.embedding:
            continue
        allv.setdefault(seg.speaker_id, []).append(seg.embedding)
        if seg.quality >= QUALITY_MIN_SCORE and seg.duration >= QUALITY_MIN_DURATION:
            quality.setdefault(seg.speaker_id, []).append(seg.embedding)

    cluster: dict[int, list[list[float]]] = {}
    for sid in distinct:
        embs = quality.get(sid) or allv.get(sid) or []
        if embs:
            cluster[sid] = list(embs)
    if len(cluster) < 2:
        return segments

    centroids = {sid: mean_embedding(embs) for sid, embs in cluster.items()}
    merge_map = {sid: sid for sid in cluster}

    while len(centroids) >= 2:
        live = sorted(centroids.keys())
        best_sim, best_pair = threshold, None
        for i in range(len(live)):
            for j in range(i + 1, len(live)):
                a, b = live[i], live[j]  # a < b
                sim = cosine(centroids[a], centroids[b])
                if sim >= best_sim:
                    best_sim, best_pair = sim, (a, b)
        if best_pair is None:
            break
        keep, drop = best_pair
        cluster[keep].extend(cluster[drop])
        del cluster[drop]
        centroids[keep] = mean_embedding(cluster[keep])
        del centroids[drop]
        for old, canonical in list(merge_map.items()):
            if canonical == drop:
                merge_map[old] = keep

    if all(k == v for k, v in merge_map.items()):
        return segments
    return _remap(segments, merge_map)


def _remap(segments: list[Segment], merge_map: dict[int, int]) -> list[Segment]:
    out = []
    for seg in segments:
        new_id = merge_map.get(seg.speaker_id, seg.speaker_id)
        out.append(Segment(new_id, seg.start, seg.end, seg.embedding, seg.quality))
    return out


def post_process(segments: list[Segment], consolidation_threshold: float | None) -> list[Segment]:
    # Offline/PyAnnote path: pairwise merge is skipped (VBx handles the base case).
    result = absorb_small_clusters(segments)
    if consolidation_threshold is not None:
        result = consolidate_same_voice_clusters(result, consolidation_threshold)
    # DB-informed split needs known profiles; the synthetic suite has none.
    return result


def speaker_count(segments: list[Segment]) -> int:
    return len({seg.speaker_id for seg in segments})


# --- Synthetic scenario generation -------------------------------------------
@dataclass
class Scenario:
    name: str
    true_speakers: int
    fragments_per_speaker: int
    segs_per_fragment: int = 5
    seg_duration: float = 8.0  # 5 x 8s = 40s -> survives small-cluster absorption
    note: str = ""
    cross_override: float | None = None  # force a specific different-speaker cosine


@dataclass
class Result:
    scenario: str
    true_speakers: int
    raw_clusters: int
    after_absorb: int
    after_consolidate: int
    names_before: int
    names_after: int
    correct: bool
    note: str = ""
    realized_intra: float = 0.0
    realized_cross: float = 0.0
    extra: dict = field(default_factory=dict)


def _rand_unit(dim: int, rng: random.Random) -> list[float]:
    return normalize([rng.gauss(0, 1) for _ in range(dim)])


def _mix(a: list[float], b: list[float], frac_a: float) -> list[float]:
    # Combine two unit vectors so the result has ~frac_a cosine^2 with a.
    ca, cb = math.sqrt(frac_a), math.sqrt(1.0 - frac_a)
    return normalize([ca * x + cb * y for x, y in zip(a, b)])


def build_scenario(
    scn: Scenario, dim: int, intra_sim: float, cross_sim: float, rng: random.Random
) -> tuple[list[Segment], float, float]:
    cross = scn.cross_override if scn.cross_override is not None else cross_sim
    shared = _rand_unit(dim, rng)
    bases = []
    for _ in range(scn.true_speakers):
        # Cross-speaker cosine ~= cross via a shared component.
        base = _mix(shared, _rand_unit(dim, rng), cross)
        bases.append(base)

    segments: list[Segment] = []
    next_id = 0
    clock = 0.0
    intra_samples, cross_samples = [], []
    fragment_means_by_speaker: list[list[list[float]]] = []

    for base in bases:
        frag_means = []
        for _ in range(scn.fragments_per_speaker):
            cluster_id = next_id
            next_id += 1
            embs = []
            for _ in range(scn.segs_per_fragment):
                # Same-speaker segment cosine ~= intra_sim.
                emb = _mix(base, _rand_unit(dim, rng), intra_sim)
                embs.append(emb)
                segments.append(
                    Segment(cluster_id, clock, clock + scn.seg_duration, emb, 0.95)
                )
                clock += scn.seg_duration
            frag_means.append(mean_embedding(embs))
            for i in range(len(embs)):
                for j in range(i + 1, len(embs)):
                    intra_samples.append(cosine(embs[i], embs[j]))
        fragment_means_by_speaker.append(frag_means)

    for i in range(len(bases)):
        for j in range(i + 1, len(bases)):
            cross_samples.append(cosine(bases[i], bases[j]))

    realized_intra = sum(intra_samples) / len(intra_samples) if intra_samples else 0.0
    realized_cross = sum(cross_samples) / len(cross_samples) if cross_samples else 0.0
    return segments, realized_intra, realized_cross


SUITE = [
    Scenario("one_on_one_oversegmented", 1, 5,
             note="single remote voice split into 5 large clusters (the reported bug)"),
    Scenario("one_on_one_clean", 1, 1, note="already one cluster, must stay one"),
    Scenario("small_group_3", 3, 2, note="3 people, each split in two"),
    Scenario("crowded_6_clean", 6, 1, note="6 distinct people, no over-segmentation"),
    Scenario("crowded_5_oversegmented", 5, 2, note="5 people each split in two"),
    Scenario("similar_voices_pair", 2, 1, cross_override=0.80,
             note="two genuinely similar voices (~0.80) must stay separate"),
]


def run_scenario(
    scn: Scenario, dim: int, intra_sim: float, cross_sim: float, seed: int
) -> Result:
    rng = random.Random(seed)
    segments, realized_intra, realized_cross = build_scenario(scn, dim, intra_sim, cross_sim, rng)
    raw = speaker_count(segments)
    absorbed = absorb_small_clusters(segments)
    consolidated = post_process(segments, CONSOLIDATION_THRESHOLD)
    names_before = speaker_count(post_process(segments, None))
    names_after = speaker_count(consolidated)
    return Result(
        scenario=scn.name,
        true_speakers=scn.true_speakers,
        raw_clusters=raw,
        after_absorb=speaker_count(absorbed),
        after_consolidate=names_after,
        names_before=names_before,
        names_after=names_after,
        correct=(names_after == scn.true_speakers),
        note=scn.note,
        realized_intra=realized_intra,
        realized_cross=realized_cross,
    )


def run_suite(dim: int, intra_sim: float, cross_sim: float, seed: int) -> list[Result]:
    return [run_scenario(scn, dim, intra_sim, cross_sim, seed + idx)
            for idx, scn in enumerate(SUITE)]


def print_suite(results: list[Result]) -> None:
    header = (f"{'scenario':<28}{'true':>5}{'raw':>5}{'absorb':>8}"
              f"{'names_before':>14}{'names_after':>13}{'ok':>5}")
    print(header)
    print("-" * len(header))
    for r in results:
        print(f"{r.scenario:<28}{r.true_speakers:>5}{r.raw_clusters:>5}{r.after_absorb:>8}"
              f"{r.names_before:>14}{r.names_after:>13}{'  ✓' if r.correct else '  ✗':>5}")
    intra = max((r.realized_intra for r in results), default=0.0)
    # Report the typical different-speaker separation from a clean multi-speaker
    # scenario, not the deliberately-similar pair.
    typical = next((r for r in results if r.scenario == "crowded_6_clean"), None)
    cross = typical.realized_cross if typical else 0.0
    print()
    print(f"realized embedding geometry: same-speaker ~{intra:.2f}, "
          f"typical different-speaker ~{cross:.2f}  (consolidation threshold {CONSOLIDATION_THRESHOLD})")


def run_sweep(dim: int, intra_sim: float, cross_sim: float, seed: int) -> None:
    # Columns chosen to show the tradeoff: the 1-on-1 should collapse to its true
    # count, the crowded and similar-voice cases should NOT drop below theirs.
    by_name = {scn.name: (idx, scn) for idx, scn in enumerate(SUITE)}
    cols = ["one_on_one_oversegmented", "crowded_6_clean", "similar_voices_pair"]
    print("Consolidation-threshold sweep (cell = speakers you'd name; want it to match 'true'):\n")
    truth = "  ".join(f"{name} (true {by_name[name][1].true_speakers})" for name in cols)
    print(f"  legend: {truth}\n")
    print(f"{'threshold':>10}" + "".join(f"{name:>28}" for name in cols))
    print("-" * (10 + 28 * len(cols)))
    for threshold in [0.62, 0.72, 0.80, 0.85, 0.88, 0.92, 0.95]:
        row = f"{threshold:>10.2f}"
        for name in cols:
            idx, scn = by_name[name]
            rng = random.Random(seed + idx)
            segments, _, _ = build_scenario(scn, dim, intra_sim, cross_sim, rng)
            count = speaker_count(post_process(segments, threshold))
            flag = "" if count == scn.true_speakers else "  <-off"
            row += f"{f'{count}{flag}':>28}"
        print(row)
    print("\nLower = merges more aggressively (fewer names, but distinct voices start to collapse).")
    print(f"Shipping default is {CONSOLIDATION_THRESHOLD} (the SpeakerNamingPolicy auto-accept bar).")


def main() -> int:
    parser = argparse.ArgumentParser(description="Simulate the meeting speaker-naming count.")
    parser.add_argument("--dim", type=int, default=256, help="Embedding dimension (default 256).")
    parser.add_argument("--intra-sim", type=float, default=0.90,
                        help="Target same-speaker segment cosine (default 0.90).")
    parser.add_argument("--cross-sim", type=float, default=0.35,
                        help="Target different-speaker cosine (default 0.35).")
    parser.add_argument("--seed", type=int, default=7, help="Deterministic seed (default 7).")
    parser.add_argument("--sweep", action="store_true", help="Run a consolidation-threshold sweep.")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of a table.")
    args = parser.parse_args()

    if args.sweep:
        run_sweep(args.dim, args.intra_sim, args.cross_sim, args.seed)
        return 0

    results = run_suite(args.dim, args.intra_sim, args.cross_sim, args.seed)
    if args.json:
        print(json.dumps([r.__dict__ for r in results], indent=2))
    else:
        print_suite(results)

    failures = [r for r in results if not r.correct]
    if failures:
        names = ", ".join(r.scenario for r in failures)
        print(f"\nFAIL: {len(failures)} scenario(s) did not reduce to the true speaker count: {names}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
