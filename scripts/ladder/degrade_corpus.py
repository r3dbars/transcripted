#!/usr/bin/env python3
"""degrade_corpus.py — produce an audio-QUALITY variant of a corpus for the ladder eval.

Re-encodes every WAV in --audio-dir through a lossy codec / band-limit / noise / reverb
chain (ffmpeg), then decodes back to a uniform 16 kHz mono s16 WAV so the diarizer ingests
every quality identically — only the spectral degradation persists. This is how we test the
confidence ladder against real-world audio: VoIP/cellphone codecs, telephone band, noise,
far-field reverb.

Parallel across cores (CPU-bound). Idempotent: a non-empty output is skipped.

Qualities (name -> chain):
  orig        16k mono, no lossy step (reference)
  mp3_64/32/16   MP3 @ 64/32/16 kbps
  opus_16k/8k    Opus @ 16/8 kbps   (modern VoIP / very low)
  aac_32         AAC @ 32 kbps
  tel_g711       8 kHz + G.711 mu-law (landline telephone band)
  noisy_snr10/5  additive white noise at 10 / 5 dB SNR (signal-relative, measured per file)
  reverb         room reflections (aecho) — far-field meeting mic

Usage:
  degrade_corpus.py --audio-dir IN --out-dir OUT --quality mp3_32 [--suffix .wav] [--jobs 14]
"""
import os, sys, re, subprocess, argparse, tempfile, shutil
from concurrent.futures import ProcessPoolExecutor, as_completed

FFMPEG = "ffmpeg"
SR = "16000"

# Lossy round-trip qualities: (encode_args, container_ext). Decoded back to 16k wav after.
CODEC = {
    "mp3_64":  (["-c:a", "libmp3lame", "-b:a", "64k"],  "mp3"),
    "mp3_32":  (["-c:a", "libmp3lame", "-b:a", "32k"],  "mp3"),
    "mp3_16":  (["-c:a", "libmp3lame", "-b:a", "16k"],  "mp3"),
    "opus_16k":(["-c:a", "libopus",    "-b:a", "16k"],  "opus"),
    "opus_8k": (["-c:a", "libopus",    "-b:a", "8k"],   "opus"),
    "aac_32":  (["-c:a", "aac",        "-b:a", "32k"],  "m4a"),
}

def run(cmd):
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode()[-400:])

def measure_dbfs(path):
    """mean volume (dBFS) via ffmpeg volumedetect."""
    r = subprocess.run([FFMPEG, "-hide_banner", "-i", path, "-af", "volumedetect",
                        "-f", "null", "-"], stderr=subprocess.PIPE, stdout=subprocess.DEVNULL)
    m = re.search(r"mean_volume:\s*(-?\d+\.?\d*) dB", r.stderr.decode())
    return float(m.group(1)) if m else -25.0

def degrade_one(args):
    src, dst, quality = args
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return ("skip", dst)
    src = os.path.realpath(src)  # follow VoxCeleb symlinks
    try:
        if quality == "orig":
            run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", src,
                 "-ar", SR, "-ac", "1", "-c:a", "pcm_s16le", dst])
        elif quality in CODEC:
            enc, ext = CODEC[quality]
            with tempfile.NamedTemporaryFile(suffix="." + ext, delete=False) as tf:
                tmp = tf.name
            try:
                run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", src,
                     "-ar", SR, "-ac", "1"] + enc + [tmp])
                run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", tmp,
                     "-ar", SR, "-ac", "1", "-c:a", "pcm_s16le", dst])
            finally:
                os.path.exists(tmp) and os.remove(tmp)
        elif quality == "tel_g711":
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
                tmp = tf.name
            try:
                run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", src,
                     "-ar", "8000", "-ac", "1", "-c:a", "pcm_mulaw", tmp])
                run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", tmp,
                     "-ar", SR, "-ac", "1", "-c:a", "pcm_s16le", dst])
            finally:
                os.path.exists(tmp) and os.remove(tmp)
        elif quality in ("noisy_snr10", "noisy_snr5"):
            snr = 10 if quality.endswith("10") else 5
            dbfs = measure_dbfs(src)
            # anoisesrc 'amplitude' is a peak/scale param whose realized RMS sits ~4.7 dB
            # below it (FFT-measured), so add a calibration term to hit the nominal SNR.
            # normalize=0 stops amix's default 1/n gain (which would attenuate signal+noise
            # 6 dB and leave the noisy file quieter than orig — a confound).
            NOISE_RMS_CAL_DB = 4.7
            noise_db = dbfs - snr + NOISE_RMS_CAL_DB   # noise RMS target, signal-relative
            amp = 10 ** (noise_db / 20.0)
            amp = max(1e-4, min(amp, 0.9))
            run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", src,
                 "-filter_complex",
                 f"anoisesrc=color=white:amplitude={amp:.5f}:sample_rate={SR}[n];"
                 f"[0:a]aformat=sample_rates={SR}:channel_layouts=mono[s];"
                 f"[s][n]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[m]",
                 "-map", "[m]", "-ar", SR, "-ac", "1", "-c:a", "pcm_s16le", dst])
        elif quality == "reverb":
            run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", src,
                 "-af", "aecho=0.8:0.88:50|80|120:0.4|0.3|0.2,aformat=sample_rates=" + SR,
                 "-ar", SR, "-ac", "1", "-c:a", "pcm_s16le", dst])
        else:
            return ("badquality", quality)
        return ("ok", dst)
    except Exception as e:
        return ("fail", f"{os.path.basename(src)}: {e}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--quality", required=True)
    ap.add_argument("--suffix", default=".wav")
    ap.add_argument("--jobs", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    a = ap.parse_args()

    os.makedirs(a.out_dir, exist_ok=True)
    files = sorted(f for f in os.listdir(a.audio_dir) if f.endswith(a.suffix))
    if not files:
        sys.exit(f"no {a.suffix} files in {a.audio_dir}")
    # output keeps the meeting basename (strip suffix), always .wav
    work = []
    for f in files:
        base = f[:-len(a.suffix)] if a.suffix and f.endswith(a.suffix) else os.path.splitext(f)[0]
        work.append((os.path.join(a.audio_dir, f), os.path.join(a.out_dir, base + ".wav"), a.quality))

    ok = skip = fail = 0
    with ProcessPoolExecutor(max_workers=a.jobs) as ex:
        for status, info in ex.map(degrade_one, work):
            if status == "ok": ok += 1
            elif status == "skip": skip += 1
            else:
                fail += 1
                if fail <= 5: print(f"  [{status}] {info}", file=sys.stderr)
    print(f"[degrade:{a.quality}] {ok} ok, {skip} cached, {fail} failed of {len(work)} -> {a.out_dir}")
    if fail and ok == 0:
        sys.exit(1)

if __name__ == "__main__":
    main()
