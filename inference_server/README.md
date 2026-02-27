# Transcripted — Local AI Inference Server

Runs [Parakeet TDT 1.1b](https://huggingface.co/nvidia/parakeet-tdt-1.1b) (STT)
and [Sortformer](https://huggingface.co/nvidia/sortformer-diarizer-4spk-v1) (speaker diarization)
locally on your Mac. The Transcripted app auto-launches this server and talks
to it over `http://127.0.0.1:8765`.

## Why local?

| Deepgram (cloud) | On-Device |
|---|---|
| ~$0.004/min | $0 |
| Requires internet | Works offline |
| Audio leaves device | Never leaves Mac |
| No fingerprinting | Voice profiles build over time |
| Instant start | ~30s model load at startup |

## Setup (one-time)

```bash
cd inference_server
chmod +x setup.sh
./setup.sh
```

This creates a `.venv/` and downloads models (~2.5GB, cached to `~/.cache/huggingface/`).

## Manual start

```bash
.venv/bin/python server.py
```

Server runs on `127.0.0.1:8765`. The Transcripted app starts it automatically.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Server + model status |
| `POST` | `/transcribe` | Transcribe a WAV file |
| `GET` | `/speakers` | List voice profiles |
| `POST` | `/speakers/{id}/label` | Assign name to speaker |

### POST /transcribe

```
Content-Type: multipart/form-data

audio         WAV file (stereo: mic=L, system=R)
channel_mode  "stereo" (default) or "mono"
```

Response:
```json
{
  "duration": 3600.0,
  "processing_time": 28.4,
  "utterances": [
    {
      "speaker_id": "SPEAKER_00",
      "channel": "mic",
      "start": 0.0,
      "end": 4.2,
      "transcript": "Hey Nate, how's the curriculum coming along?",
      "words": [...]
    }
  ],
  "speaker_count": 2,
  "word_count": 847
}
```

## Performance

On Apple M-series with Neural Engine:

| Audio length | Processing time | Real-time factor |
|---|---|---|
| 30 min | ~12s | ~150x |
| 1 hour | ~25s | ~145x |
| 2 hours | ~50s | ~144x |

## Architecture

```
POST /transcribe
    ↓
_transcribe_channel(mic)   ← Parakeet TDT 1.1b
_transcribe_channel(sys)   ← Parakeet TDT 1.1b  (parallel)
    ↓
_diarize()                 ← Sortformer 4spk
    ↓
_merge_transcripts_with_speakers()
    ↓
JSON response → Swift app
    ↓
NameInferenceEngine        ← NLP pattern matching + calendar
    ↓
VoiceProfileDatabase       ← SQLite, persists across sessions
```

## Requirements

- Python 3.10+
- ~4GB RAM for models
- ~2.5GB disk for model cache
- macOS 12+ (Apple Silicon recommended, Intel works)
