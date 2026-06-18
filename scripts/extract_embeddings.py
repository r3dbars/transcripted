#!/usr/bin/env python
"""Re-extract speaker embeddings for the EXACT AMI dump segments with an alternative model
(measurement only — runs in the .venv_emb venv; writes drop-in dumps the existing analysis
scripts consume unchanged). Tests whether a stronger / codec-robust embedding model breaks
the within-meeting separability floor that WeSpeaker hits.

For an arm it regenerates the codec-degraded audio from the clean AMI wav (same ffmpeg
recipe as run_ami_codec_sweep.sh), slices at each baseline dump segment's [start,end], runs
the chosen model, and writes data/eval/ami_<arm>__<model>/dumps/<meeting>.json with the SAME
schema (speakerId/start/end/quality preserved; only `embedding` swapped). Same segmentation,
same time spans -> a clean apples-to-apples embedding-model comparison.

Models (public, non-gated):
  ecapa  speechbrain/spkrec-ecapa-voxceleb           (192-d ECAPA-TDNN)
  xvect  speechbrain/spkrec-xvect-voxceleb           (512-d x-vector; weaker control)
  resnet speechbrain/spkrec-resnet-voxceleb          (256-d ResNet)
  wavlm  microsoft/wavlm-base-plus-sv (transformers) (512-d SSL XVector head; robustness candidate)
"""
import argparse, glob, json, os, subprocess, sys, tempfile
import numpy as np
import soundfile as sf
import torch

SR = 16000
FF = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]


def regen_audio(arm, clean_wav, out_wav):
    if arm == "clean":
        return clean_wav
    if arm.startswith("opus"):
        br = arm[len("opus"):]
        tmp = out_wav + ".opus"
        subprocess.run(FF + ["-i", clean_wav, "-c:a", "libopus", "-b:a", br, "-ar", "16000", "-ac", "1", tmp], check=True)
        subprocess.run(FF + ["-i", tmp, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out_wav], check=True)
        os.remove(tmp)
    elif arm == "g711u":
        tmp = out_wav + ".mu.wav"
        subprocess.run(FF + ["-i", clean_wav, "-ar", "8000", "-ac", "1", "-c:a", "pcm_mulaw", tmp], check=True)
        subprocess.run(FF + ["-i", tmp, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out_wav], check=True)
        os.remove(tmp)
    else:
        raise SystemExit(f"unknown arm {arm}")
    return out_wav


class Embedder:
    def __init__(self, model, device):
        self.model = model
        if model in ("ecapa", "xvect", "resnet"):
            # speechbrain 1.1.0 has a run_opts device bug; load on CPU (default) instead.
            self.kind = "speechbrain"; self.device = "cpu"
            from speechbrain.inference.speaker import EncoderClassifier
            src = {"ecapa": "speechbrain/spkrec-ecapa-voxceleb",
                   "xvect": "speechbrain/spkrec-xvect-voxceleb",
                   "resnet": "speechbrain/spkrec-resnet-voxceleb"}[model]
            self.enc = EncoderClassifier.from_hparams(source=src, savedir=f".venv_emb/sb_{model}")
        elif model in ("wavlm", "unisat"):
            self.kind = "hf_xvector"; self.device = device
            from transformers import Wav2Vec2FeatureExtractor
            src = {"wavlm": "microsoft/wavlm-base-plus-sv", "unisat": "microsoft/unispeech-sat-base-plus-sv"}[model]
            self.fe = Wav2Vec2FeatureExtractor.from_pretrained(src)
            if model == "wavlm":
                from transformers import WavLMForXVector as XV
            else:
                from transformers import UniSpeechSatForXVector as XV
            self.net = XV.from_pretrained(src).to(device).eval()
        elif model.startswith("redimnet"):  # redimnet or redimnet_b6 / _b3 ...
            self.kind = "raw_wave"; self.device = device
            mn = model.split("_", 1)[1] if "_" in model else "b6"
            self.net = torch.hub.load("IDRnD/ReDimNet", "ReDimNet", model_name=mn,
                                      train_type="ft_lm", dataset="vox2", verbose=False).to(device).eval()
        elif model in ("campplus", "eres2net", "eres2netv2"):
            # 3D-Speaker (Alibaba) models via modelscope — handles the kaldi-fbank front-end
            # correctly (hand-rolling it risks garbage embeddings). Runs on CPU.
            self.kind = "modelscope"; self.device = "cpu"
            from modelscope.pipelines import pipeline
            mid = {"campplus": "iic/speech_campplus_sv_en_voxceleb_16k",
                   "eres2net": "iic/speech_eres2net_sv_en_voxceleb_16k",
                   "eres2netv2": "iic/speech_eres2netv2_sv_en_voxceleb_16k"}[model]
            self.sv = pipeline(task="speaker-verification", model=mid)
        else:
            raise SystemExit(f"unknown model {model}")

    @torch.no_grad()
    def embed_batch(self, wavs):
        # wavs: list of 1-D float32 np arrays at 16k. Returns [n, dim] L2-normalized float32.
        lens = [len(w) for w in wavs]; mx = max(lens)
        if self.kind == "speechbrain":
            batch = torch.zeros(len(wavs), mx, dtype=torch.float32)
            for i, w in enumerate(wavs):
                batch[i, :len(w)] = torch.from_numpy(w)
            wav_lens = torch.tensor([l / mx for l in lens], dtype=torch.float32)
            emb = self.enc.encode_batch(batch.to(self.device), wav_lens.to(self.device)).squeeze(1)
        elif self.kind == "hf_xvector":
            inp = self.fe([w for w in wavs], sampling_rate=SR, return_tensors="pt", padding=True)
            inp = {k: v.to(self.device) for k, v in inp.items()}
            emb = self.net(**inp).embeddings
        elif self.kind == "raw_wave":
            batch = torch.zeros(len(wavs), mx, dtype=torch.float32)
            for i, w in enumerate(wavs):
                batch[i, :len(w)] = torch.from_numpy(w)
            emb = self.net(batch.to(self.device))
            if isinstance(emb, (tuple, list)):
                emb = emb[0]
        elif self.kind == "modelscope":
            wl = [w.astype("float32") for w in wavs]
            try:
                arr = np.array(self.sv(wl, output_emb=True)["embs"])
                if arr.shape[0] != len(wl):
                    raise ValueError("batch size mismatch")
            except Exception:
                arr = np.array([self.sv([w], output_emb=True)["embs"][0] for w in wl])
            emb = torch.from_numpy(arr).float()
        emb = torch.nn.functional.normalize(emb, dim=-1)
        return emb.detach().cpu().float().numpy()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--model", required=True,
                    help="ecapa|xvect|resnet|wavlm|unisat|redimnet[_b6]|campplus|eres2net")
    ap.add_argument("--base-dumps", default=None, help="dumps for segment timings (default data/eval/ami_<arm>/dumps)")
    ap.add_argument("--clean-audio", default="data/ami/audio")
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--max-sec", type=float, default=20.0)
    ap.add_argument("--batch", type=int, default=24)
    args = ap.parse_args()
    base = args.base_dumps or f"data/eval/ami_{args.arm}/dumps"
    out = args.out_dir or f"data/eval/ami_{args.arm}__{args.model}/dumps"
    os.makedirs(out, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"[embed] arm={args.arm} model={args.model} device={device} -> {out}", flush=True)
    emb = Embedder(args.model, device)

    files = sorted(glob.glob(os.path.join(base, "*.json")))
    with tempfile.TemporaryDirectory() as td:
        for fi, f in enumerate(files):
            m = os.path.basename(f)[:-5]
            outf = os.path.join(out, m + ".json")
            if os.path.exists(outf):
                continue
            d = json.load(open(f))
            clean = os.path.join(args.clean_audio, f"{m}.Mix-Headset.wav")
            wavp = regen_audio(args.arm, clean, os.path.join(td, f"{m}.wav"))
            audio, sr = sf.read(wavp)
            if audio.ndim > 1:
                audio = audio.mean(axis=1)
            audio = audio.astype(np.float32)
            if args.arm != "clean":
                os.remove(wavp)
            segs = d["segments"]
            clips = []
            for s in segs:
                a = int(s["start"] * SR); b = min(int(s["end"] * SR), a + int(args.max_sec * SR), len(audio))
                w = audio[a:b]
                if len(w) < SR // 2:  # pad very short clips to 0.5s
                    w = np.pad(w, (0, SR // 2 - len(w)))
                clips.append(w)
            # batch by similar length to limit padding
            order = sorted(range(len(clips)), key=lambda i: len(clips[i]))
            embs = [None] * len(clips)
            for i in range(0, len(order), args.batch):
                idx = order[i:i + args.batch]
                vecs = emb.embed_batch([clips[j] for j in idx])
                for j, v in zip(idx, vecs):
                    embs[j] = [round(float(x), 6) for x in v]
            for s, v in zip(segs, embs):
                s["embedding"] = v
            d["embModel"] = args.model
            json.dump(d, open(outf, "w"))
            print(f"[embed] {args.arm}/{args.model} {m} ({fi+1}/{len(files)}) {len(segs)} segs", flush=True)
    print(f"[embed] done arm={args.arm} model={args.model}", flush=True)


if __name__ == "__main__":
    main()
