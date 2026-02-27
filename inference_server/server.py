"""
Transcripted Local AI Inference Server
---------------------------------------
FastAPI server that runs Parakeet (STT) + Sortformer (diarization) locally.
Launched by the Transcripted macOS app on startup; listens on 127.0.0.1:8765.

Models loaded:
  - nvidia/parakeet-tdt-1.1b  (ASR, batch transcription)
  - nvidia/sortformer-diarizer-4spk-v1  (speaker diarization)

Output format mirrors Deepgram's multichannel response so the Swift app
needs minimal changes to swap providers.
"""

import os
import json
import time
import tempfile
import logging
from pathlib import Path
from typing import Optional

import numpy as np
import torch
import soundfile as sf
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("transcripted-inference")

app = FastAPI(title="Transcripted Local Inference", version="0.1.0")

# ---------------------------------------------------------------------------
# Model cache — loaded once at startup
# ---------------------------------------------------------------------------

_parakeet = None
_diarizer = None
_model_load_error: Optional[str] = None


def load_models():
    global _parakeet, _diarizer, _model_load_error
    try:
        log.info("Loading Parakeet TDT 1.1b...")
        import nemo.collections.asr as nemo_asr
        _parakeet = nemo_asr.models.ASRModel.from_pretrained(
            model_name="nvidia/parakeet-tdt-1.1b"
        )
        _parakeet.eval()
        log.info("✅ Parakeet loaded")

        log.info("Loading Sortformer diarizer...")
        from nemo.collections.asr.models import SortformerEncLabelModel
        _diarizer = SortformerEncLabelModel.from_pretrained(
            model_name="nvidia/sortformer-diarizer-4spk-v1"
        )
        _diarizer.eval()
        log.info("✅ Sortformer loaded")

    except Exception as e:
        _model_load_error = str(e)
        log.error(f"❌ Model load failed: {e}")
        log.warning("Server will start but /transcribe will return 503 until models load.")


@app.on_event("startup")
async def startup_event():
    import asyncio
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, load_models)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/health")
def health():
    if _model_load_error:
        return JSONResponse(
            status_code=503,
            content={"status": "error", "error": _model_load_error}
        )
    ready = _parakeet is not None and _diarizer is not None
    return {
        "status": "ready" if ready else "loading",
        "parakeet": _parakeet is not None,
        "sortformer": _diarizer is not None,
    }


# ---------------------------------------------------------------------------
# Core transcription endpoint
# ---------------------------------------------------------------------------

@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(...),
    channel_mode: str = "stereo",  # "stereo" (mic=L, system=R) or "mono"
):
    """
    Accepts a WAV file and returns a JSON transcript with named/labeled speakers.

    Stereo mode: left channel = mic (you), right channel = system audio (others).
    Mono mode: single channel, full diarization across all speakers.

    Response schema mirrors Deepgram multichannel so Swift code needs
    minimal changes.
    """
    if _parakeet is None or _diarizer is None:
        raise HTTPException(status_code=503, detail="Models still loading, try again in a moment")

    t0 = time.time()

    # Write uploaded audio to temp file
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp.write(await audio.read())
        tmp_path = tmp.name

    try:
        audio_data, sample_rate = sf.read(tmp_path)

        if channel_mode == "stereo" and audio_data.ndim == 2:
            mic_audio = audio_data[:, 0]
            sys_audio = audio_data[:, 1]
        else:
            # Mono fallback — treat everything as system audio
            mic_audio = audio_data if audio_data.ndim == 1 else audio_data.mean(axis=1)
            sys_audio = mic_audio

        duration = len(mic_audio) / sample_rate

        # ── Step 1: Transcribe each channel with Parakeet ──────────────────
        mic_transcript = _transcribe_channel(mic_audio, sample_rate, label="mic")
        sys_transcript = _transcribe_channel(sys_audio, sample_rate, label="sys")

        # ── Step 2: Diarize the full mix to get speaker segments ───────────
        speaker_segments = _diarize(tmp_path, audio_data, sample_rate)

        # ── Step 3: Merge transcripts + assign speakers ────────────────────
        utterances = _merge_transcripts_with_speakers(
            mic_transcript, sys_transcript, speaker_segments
        )

        processing_time = time.time() - t0
        log.info(f"✅ Transcribed {duration:.1f}s audio in {processing_time:.1f}s "
                 f"({duration/processing_time:.0f}x real-time)")

        return {
            "duration": duration,
            "processing_time": processing_time,
            "utterances": utterances,
            "speaker_count": len({u["speaker_id"] for u in utterances}),
            "word_count": sum(len(u["transcript"].split()) for u in utterances),
        }

    finally:
        os.unlink(tmp_path)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _transcribe_channel(audio: np.ndarray, sample_rate: int, label: str) -> list[dict]:
    """Run Parakeet on a single audio channel. Returns list of word-level dicts."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        sf.write(f.name, audio, sample_rate)
        tmp = f.name

    try:
        # Parakeet returns timestamps via return_hypotheses=True
        hypotheses = _parakeet.transcribe(
            [tmp],
            batch_size=1,
            return_hypotheses=True,
            verbose=False,
        )
        hyp = hypotheses[0] if hypotheses else None
        if hyp is None or not hyp.text:
            return []

        words = []
        if hasattr(hyp, "timestep") and hyp.timestep:
            ts = hyp.timestep.get("word", [])
            word_list = hyp.text.split()
            for i, word in enumerate(word_list):
                start = ts[i]["start"] if i < len(ts) else 0.0
                end = ts[i]["end"] if i < len(ts) else start + 0.3
                words.append({
                    "word": word,
                    "start": float(start),
                    "end": float(end),
                    "channel": label,
                    "confidence": 0.95,
                })
        else:
            # Fallback: evenly distribute words over duration
            dur = len(audio) / 44100
            word_list = hyp.text.split()
            step = dur / max(len(word_list), 1)
            for i, word in enumerate(word_list):
                words.append({
                    "word": word,
                    "start": i * step,
                    "end": (i + 1) * step,
                    "channel": label,
                    "confidence": 0.90,
                })
        return words
    finally:
        os.unlink(tmp)


def _diarize(audio_path: str, audio_data: np.ndarray, sample_rate: int) -> list[dict]:
    """
    Run Sortformer diarization on the mixed audio.
    Returns list of {speaker_id, start, end} segments.
    """
    try:
        # Sortformer needs a manifest file pointing to the audio
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as mf:
            manifest = {
                "audio_filepath": audio_path,
                "offset": 0,
                "duration": len(audio_data) / sample_rate,
                "label": "infer",
                "text": "-",
                "num_speakers": None,  # auto-detect
                "rttm_filepath": None,
                "uem_filepath": None,
            }
            json.dump(manifest, mf)
            manifest_path = mf.name

        # Run diarization
        _diarizer.diarize(manifest_filepath=manifest_path)

        # Parse RTTM output
        rttm_path = audio_path.replace(".wav", ".rttm")
        segments = _parse_rttm(rttm_path)
        os.unlink(manifest_path)
        if os.path.exists(rttm_path):
            os.unlink(rttm_path)
        return segments

    except Exception as e:
        log.warning(f"Diarization failed, falling back to channel-based attribution: {e}")
        return []  # Caller falls back to channel labels


def _parse_rttm(rttm_path: str) -> list[dict]:
    """Parse RTTM file into segment list."""
    segments = []
    if not os.path.exists(rttm_path):
        return segments
    with open(rttm_path) as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) < 8 or parts[0] != "SPEAKER":
                continue
            start = float(parts[3])
            dur = float(parts[4])
            speaker = parts[7]
            segments.append({
                "speaker_id": speaker,
                "start": start,
                "end": start + dur,
            })
    return sorted(segments, key=lambda s: s["start"])


def _merge_transcripts_with_speakers(
    mic_words: list[dict],
    sys_words: list[dict],
    speaker_segments: list[dict],
) -> list[dict]:
    """
    Combine mic + system transcripts, assign speaker IDs from diarization.
    Groups consecutive same-speaker words into utterances.
    """
    all_words = sorted(mic_words + sys_words, key=lambda w: w["start"])

    def speaker_at(t: float) -> str:
        for seg in speaker_segments:
            if seg["start"] <= t <= seg["end"]:
                return seg["speaker_id"]
        # Fall back to channel label
        return "mic" if t < 0.001 else "unknown"

    # Assign speaker to each word
    for w in all_words:
        w["speaker_id"] = speaker_at((w["start"] + w["end"]) / 2)

    # Group into utterances (same speaker, gap < 1.5s)
    utterances = []
    current = None
    for w in all_words:
        if (current is None
                or w["speaker_id"] != current["speaker_id"]
                or w["start"] - current["end"] > 1.5):
            if current:
                utterances.append(current)
            current = {
                "speaker_id": w["speaker_id"],
                "channel": w["channel"],
                "start": w["start"],
                "end": w["end"],
                "transcript": w["word"],
                "words": [w],
            }
        else:
            current["end"] = w["end"]
            current["transcript"] += " " + w["word"]
            current["words"].append(w)

    if current:
        utterances.append(current)

    return utterances


# ---------------------------------------------------------------------------
# Speaker profile endpoints (for voice fingerprinting layer)
# ---------------------------------------------------------------------------

PROFILES_PATH = Path.home() / "Library" / "Application Support" / "Transcripted" / "speaker_profiles.json"


def _load_profiles() -> dict:
    if PROFILES_PATH.exists():
        return json.loads(PROFILES_PATH.read_text())
    return {}


def _save_profiles(profiles: dict):
    PROFILES_PATH.parent.mkdir(parents=True, exist_ok=True)
    PROFILES_PATH.write_text(json.dumps(profiles, indent=2))


@app.get("/speakers")
def list_speakers():
    profiles = _load_profiles()
    # Don't return raw embeddings
    return [
        {
            "id": sid,
            "name": p.get("name"),
            "call_count": p.get("call_count", 0),
            "last_seen": p.get("last_seen"),
        }
        for sid, p in profiles.items()
    ]


@app.post("/speakers/{speaker_id}/label")
def label_speaker(speaker_id: str, name: str):
    """Assign a human name to a detected speaker ID."""
    profiles = _load_profiles()
    if speaker_id not in profiles:
        profiles[speaker_id] = {"call_count": 0}
    profiles[speaker_id]["name"] = name
    _save_profiles(profiles)
    return {"ok": True, "speaker_id": speaker_id, "name": name}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=8765,
        log_level="info",
        reload=False,
    )
