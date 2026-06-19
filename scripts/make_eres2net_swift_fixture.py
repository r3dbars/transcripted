#!/usr/bin/env python3
"""
Emit a small deterministic golden fixture for the Swift ERes2NetEmbedder parity
test: a synthetic 1.5s signal + the embedding the CoreML model produces for it.
The Swift test feeds the same samples through ERes2NetEmbedder and asserts cosine
>= 0.999 against this vector, proving the Swift MLMultiArray plumbing matches.
"""
import os, json, numpy as np

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "out", "eres2net_swift_golden.json")
MLPACKAGE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "..", "objective-noyce-06bac2", "scripts", "out",
                         "eres2net_fused.mlpackage")
MLPACKAGE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "scripts", "out", "eres2net_fused.mlpackage")


def main():
    import coremltools as ct
    sr = 16000
    n = 24000  # 1.5 s
    i = np.arange(n, dtype=np.float64)
    sig = (0.30 * np.sin(2 * np.pi * 220 * i / sr)
           + 0.20 * np.sin(2 * np.pi * 440 * i / sr)
           + 0.10 * np.sin(2 * np.pi * 880 * i / sr))
    sig = sig.astype(np.float32)
    m = ct.models.MLModel(MLPACKAGE)
    out = m.predict({"audio": sig.reshape(1, n)})
    emb = np.asarray(out["embedding"]).flatten().astype(np.float64)
    emb = emb / (np.linalg.norm(emb) + 1e-12)  # L2-normalize (Swift does too)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({
            "sampleRate": sr,
            "samples": [round(float(x), 7) for x in sig.tolist()],
            "embedding": [round(float(x), 7) for x in emb.tolist()],
            "dim": int(emb.shape[0]),
        }, f)
    print(f"[ok] wrote {OUT}  (n={n}, dim={emb.shape[0]})")


if __name__ == "__main__":
    main()
