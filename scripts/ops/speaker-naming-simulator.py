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
from dataclasses import asdict, dataclass, field

# --- Constants mirrored from EmbeddingClusterer.swift ------------------------
MIN_CLUSTER_DURATION = 30.0
ABSORPTION_THRESHOLD = 0.72
MICRO_CLUSTER_DURATION = 10.0
MICRO_ABSORPTION_THRESHOLD = 0.62
CONSOLIDATION_THRESHOLD = 0.88  # SpeakerNamingPolicy auto-accept bar (> 0.88).
QUALITY_MIN_SCORE = 0.3
QUALITY_MIN_DURATION = 1.0


@dataclass
class Segment:
    speaker_id: int
    start: float
    end: float
    embedding: list[float]
    quality: float = 0.95
    true_speaker: int = 0
    channel: str = "system"

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
                if sim > best_sim:
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
        out.append(
            Segment(
                speaker_id=new_id,
                start=seg.start,
                end=seg.end,
                embedding=seg.embedding,
                quality=seg.quality,
                true_speaker=seg.true_speaker,
                channel=seg.channel,
            )
        )
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
    channel: str = "system"
    local_split_enabled: bool = False
    known_state: str = "unknown"  # unknown, mature_named, tentative_named
    expected_review_after: int | None = None
    expected_cluster_after: int | None = None
    expected_labels_after: tuple[str, ...] = ()


@dataclass
class Result:
    scenario: str
    channel: str
    true_speakers: int
    raw_clusters: int
    after_absorb: int
    after_consolidate: int
    names_before: int
    names_after: int
    expected_review_after: int
    expected_cluster_after: int
    labels_after: list[str]
    expected_labels_after: list[str]
    false_merge_after: bool
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


KNOWN_NAMES = [
    "Alex Rivera",
    "Blair Chen",
    "Casey Morgan",
    "Dev Patel",
    "Emery Stone",
    "Finley Cruz",
]


def _channel_prefix(scn: Scenario) -> str:
    return "local" if scn.channel == "mic" else "remote"


def _known_name(true_speaker: int) -> str:
    return KNOWN_NAMES[(true_speaker - 1) % len(KNOWN_NAMES)]


def _cluster_truth(segments: list[Segment]) -> dict[int, set[int]]:
    clusters: dict[int, set[int]] = {}
    for seg in segments:
        clusters.setdefault(seg.speaker_id, set()).add(seg.true_speaker)
    return clusters


def false_merge_detected(segments: list[Segment]) -> bool:
    return any(len(true_speakers) > 1 for true_speakers in _cluster_truth(segments).values())


def semantic_labels(scn: Scenario, segments: list[Segment]) -> list[str]:
    """Labels the user-facing review rows, not just raw diarizer clusters."""
    prefix = _channel_prefix(scn)
    if scn.channel == "mic" and not scn.local_split_enabled:
        return [f"{prefix}:You"]

    clusters = _cluster_truth(segments)
    has_false_merge = any(len(true_speakers) > 1 for true_speakers in clusters.values())

    # Known speakers that hit the same persistent DB profile are collapsed by the
    # pipeline before review. Mature matches auto-apply; tentative matches become
    # one confirmation row per known person.
    if scn.channel == "system" and scn.known_state != "unknown" and not has_false_merge:
        labels = []
        for true_speaker in sorted({next(iter(values)) for values in clusters.values()}):
            name = _known_name(true_speaker)
            if scn.known_state == "tentative_named":
                name = f"{name} (confirm)"
            labels.append(f"{prefix}:{name}")
        return labels

    labels = []
    for speaker_id in sorted(clusters):
        true_speakers = sorted(clusters[speaker_id])
        if len(true_speakers) > 1:
            joined = "+".join(f"voice{idx}" for idx in true_speakers)
            labels.append(f"{prefix}:FALSE_MERGE({joined})")
        elif scn.channel == "mic":
            labels.append(f"{prefix}:room voice {true_speakers[0]}")
        elif scn.known_state == "mature_named":
            labels.append(f"{prefix}:{_known_name(true_speakers[0])}")
        elif scn.known_state == "tentative_named":
            labels.append(f"{prefix}:{_known_name(true_speakers[0])} (confirm)")
        else:
            labels.append(f"{prefix}:new voice {true_speakers[0]}")
    return labels


def review_row_count(scn: Scenario, segments: list[Segment]) -> int:
    if scn.channel == "mic" and not scn.local_split_enabled:
        return 0
    if scn.channel == "system" and scn.known_state == "mature_named":
        return 0 if not false_merge_detected(segments) else len(semantic_labels(scn, segments))
    return len(semantic_labels(scn, segments))


def expected_labels(scn: Scenario) -> list[str]:
    if scn.expected_labels_after:
        return list(scn.expected_labels_after)
    prefix = _channel_prefix(scn)
    if scn.channel == "mic" and not scn.local_split_enabled:
        return [f"{prefix}:You"]
    labels = []
    for idx in range(1, scn.true_speakers + 1):
        if scn.channel == "mic":
            labels.append(f"{prefix}:room voice {idx}")
        elif scn.known_state == "mature_named":
            labels.append(f"{prefix}:{_known_name(idx)}")
        elif scn.known_state == "tentative_named":
            labels.append(f"{prefix}:{_known_name(idx)} (confirm)")
        else:
            labels.append(f"{prefix}:new voice {idx}")
    return labels


def expected_review_count(scn: Scenario) -> int:
    if scn.expected_review_after is not None:
        return scn.expected_review_after
    if scn.channel == "mic" and not scn.local_split_enabled:
        return 0
    if scn.channel == "system" and scn.known_state == "mature_named":
        return 0
    return scn.true_speakers


def expected_cluster_count(scn: Scenario) -> int:
    if scn.expected_cluster_after is not None:
        return scn.expected_cluster_after
    if scn.channel == "mic" and not scn.local_split_enabled:
        return 1
    return scn.true_speakers


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

    for true_speaker, base in enumerate(bases, start=1):
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
                    Segment(
                        speaker_id=cluster_id,
                        start=clock,
                        end=clock + scn.seg_duration,
                        embedding=emb,
                        quality=0.95,
                        true_speaker=true_speaker,
                        channel=scn.channel,
                    )
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
    Scenario("remote_unknown_1on1_overseg", 1, 5,
             note="cold-start single remote voice split into 5 review rows"),
    Scenario("remote_named_repeat_1on1", 1, 5, known_state="mature_named",
             note="same voice after naming: should auto-apply the saved person"),
    Scenario("remote_tentative_repeat", 1, 5, known_state="tentative_named",
             expected_review_after=1,
             note="known but not mature enough: one confirmation row, not 5 duplicates"),
    Scenario("remote_unknown_group_3", 3, 2,
             note="3 remote people, each split in two"),
    Scenario("remote_crowded_6_clean", 6, 1,
             note="6 distinct remote people, no over-segmentation"),
    Scenario("remote_crowded_5_overseg", 5, 2,
             note="5 remote people each split in two"),
    Scenario("remote_similar_voice_pair", 2, 1, cross_override=0.86,
             note="two genuinely similar voices near the threshold must stay separate"),
    Scenario("local_default_off_shared_room", 3, 1, channel="mic",
             local_split_enabled=False, expected_review_after=0, expected_cluster_after=1,
             expected_labels_after=("local:You",),
             note="default local role: shared mic stays one You row and no review inbox work"),
    Scenario("local_split_room_3", 3, 1, channel="mic", local_split_enabled=True,
             note="opt-in local split: local room speakers become review rows"),
]


def run_scenario(
    scn: Scenario, dim: int, intra_sim: float, cross_sim: float, seed: int
) -> Result:
    rng = random.Random(seed)
    segments, realized_intra, realized_cross = build_scenario(scn, dim, intra_sim, cross_sim, rng)
    if scn.channel == "mic" and not scn.local_split_enabled:
        raw = 1
        after_absorb = 1
        after_consolidate = 1
        names_before = 0
        names_after = 0
        labels_after = semantic_labels(scn, segments)
        false_merge_after = False
    else:
        raw = speaker_count(segments)
        absorbed = absorb_small_clusters(segments)
        consolidated = post_process(segments, CONSOLIDATION_THRESHOLD)
        without_consolidation = post_process(segments, None)
        after_absorb = speaker_count(absorbed)
        after_consolidate = speaker_count(consolidated)
        names_before = review_row_count(scn, without_consolidation)
        names_after = review_row_count(scn, consolidated)
        labels_after = semantic_labels(scn, consolidated)
        false_merge_after = false_merge_detected(consolidated)

    expected_review = expected_review_count(scn)
    expected_clusters = expected_cluster_count(scn)
    expected_label_list = expected_labels(scn)
    correct = (
        names_after == expected_review
        and after_consolidate == expected_clusters
        and labels_after == expected_label_list
        and not false_merge_after
    )
    return Result(
        scenario=scn.name,
        channel=scn.channel,
        true_speakers=scn.true_speakers,
        raw_clusters=raw,
        after_absorb=after_absorb,
        after_consolidate=after_consolidate,
        names_before=names_before,
        names_after=names_after,
        expected_review_after=expected_review,
        expected_cluster_after=expected_clusters,
        labels_after=labels_after,
        expected_labels_after=expected_label_list,
        false_merge_after=false_merge_after,
        correct=correct,
        note=scn.note,
        realized_intra=realized_intra,
        realized_cross=realized_cross,
    )


def run_suite(dim: int, intra_sim: float, cross_sim: float, seed: int) -> list[Result]:
    return [run_scenario(scn, dim, intra_sim, cross_sim, seed + idx)
            for idx, scn in enumerate(SUITE)]


def print_suite(results: list[Result]) -> None:
    header = (f"{'scenario':<30}{'role':>8}{'true':>5}{'raw':>5}{'post':>6}"
              f"{'review_before':>15}{'review_after':>14}{'expected':>10}"
              f"{'false_merge':>13}{'ok':>5}")
    print(header)
    print("-" * len(header))
    for r in results:
        role = "local" if r.channel == "mic" else "remote"
        print(f"{r.scenario:<30}{role:>8}{r.true_speakers:>5}{r.raw_clusters:>5}"
              f"{r.after_consolidate:>6}{r.names_before:>15}{r.names_after:>14}"
              f"{r.expected_review_after:>10}{str(r.false_merge_after):>13}"
              f"{'  ✓' if r.correct else '  ✗':>5}")
        print(f"{'':<30} labels_after: {', '.join(r.labels_after)}")
    intra = max((r.realized_intra for r in results), default=0.0)
    # Report the typical different-speaker separation from a clean multi-speaker
    # scenario, not the deliberately-similar pair.
    typical = next((r for r in results if r.scenario == "remote_crowded_6_clean"), None)
    cross = typical.realized_cross if typical else 0.0
    print()
    print(f"realized embedding geometry: same-speaker ~{intra:.2f}, "
          f"typical different-speaker ~{cross:.2f}  (consolidation threshold {CONSOLIDATION_THRESHOLD})")


def run_sweep(dim: int, intra_sim: float, cross_sim: float, seed: int) -> None:
    # Columns chosen to show the tradeoff: the 1-on-1 should collapse to its true
    # count, the crowded and similar-voice cases should NOT drop below theirs.
    by_name = {scn.name: (idx, scn) for idx, scn in enumerate(SUITE)}
    cols = ["remote_unknown_1on1_overseg", "remote_crowded_6_clean", "remote_similar_voice_pair"]
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
            processed = post_process(segments, threshold)
            count = review_row_count(scn, processed)
            off = count != expected_review_count(scn) or false_merge_detected(processed)
            flag = "" if not off else "  <-off"
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
        print(json.dumps([asdict(r) for r in results], indent=2))
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
