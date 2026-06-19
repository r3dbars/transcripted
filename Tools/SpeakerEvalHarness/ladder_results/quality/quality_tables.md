### ami  (people≈175, qualities tested: 6)

| quality | baseline prompts/p | baseline false-auto % | baseline reach-AUTO % | best@<0.5% prompts/p | best false-auto % |
|---|---:|---:|---:|---:|---:|
| orig | 3.07 | 0.00 | 0.00 | 2.78 | 0.00 |
| mp3_32 | 3.04 | 0.00 | 0.00 | 2.75 | 0.00 |
| opus_8k | 3.14 | 0.00 | 0.00 | 2.64 | 0.00 |
| tel_g711 | 2.86 | 0.00 | 0.00 | 2.57 | 0.00 |
| reverb | 3.26 | 0.00 | 0.00 | 2.94 | 0.00 |
| noisy_snr5 | 3.31 | 0.00 | 0.00 | 2.86 | 0.00 |

- **Quality-ROBUST gate** (false-auto ≤ 0.5% in *every* tested quality; 3171 policies qualify): mean **2.83 prompts/person**, worst-case false-auto 0.00%, mean reach-AUTO 14%
  - params: `floor=0.60 auto=0.92 margin=0.12 promo=fixed(cc>2) alpha=0.25 demote=off`

  per-quality prompts/person: orig=2.81, mp3_32=2.89, opus_8k=2.69, tel_g711=2.68, reverb=3.06, noisy_snr5=2.87
