### voxceleb  (people≈30, qualities tested: 11)

| quality | baseline prompts/p | baseline false-auto % | baseline reach-AUTO % | best@<0.5% prompts/p | best false-auto % |
|---|---:|---:|---:|---:|---:|
| orig | 31.93 | 0.00 | 13.33 | 28.67 | 0.00 |
| mp3_64 | 31.83 | 0.00 | 16.67 | 28.77 | 0.00 |
| aac_32 | 32.00 | 0.00 | 10.00 | 29.77 | 0.00 |
| mp3_32 | 32.00 | 0.00 | 13.33 | 29.83 | 0.00 |
| opus_16k | 31.60 | 0.00 | 10.00 | 29.27 | 0.00 |
| mp3_16 | 30.40 | 10.34 | 40.00 | 28.00 | 0.00 |
| opus_8k | 32.47 | 40.00 | 10.00 | 30.77 | 0.00 |
| tel_g711 | 32.67 | 8.33 | 30.00 | 29.10 | 0.00 |
| reverb | 31.83 | 50.00 | 20.00 | 31.30 | 0.00 |
| noisy_snr10 | 32.63 | 25.00 | 6.67 | 31.47 | 0.00 |
| noisy_snr5 | 32.17 | 33.33 | 10.00 | 31.33 | 0.00 |

- **Quality-ROBUST gate** (false-auto ≤ 0.5% in *every* tested quality; 2159 policies qualify): mean **31.01 prompts/person**, worst-case false-auto 0.00%, mean reach-AUTO 42%
  - params: `floor=0.60 auto=0.83 margin=0.12 promo=fixed(cc>5) alpha=0.15 demote=off`

  per-quality prompts/person: orig=30.40, mp3_64=30.63, aac_32=31.07, mp3_32=30.93, opus_16k=30.50, mp3_16=29.53, opus_8k=31.70, tel_g711=30.70, reverb=31.50, noisy_snr10=32.20, noisy_snr5=31.90

### ami_scale  (people≈32, qualities tested: 11)

| quality | baseline prompts/p | baseline false-auto % | baseline reach-AUTO % | best@<0.5% prompts/p | best false-auto % |
|---|---:|---:|---:|---:|---:|
| orig | 3.16 | 0.00 | 0.00 | 2.53 | 0.00 |
| mp3_64 | 3.10 | 0.00 | 0.00 | 2.90 | 0.00 |
| aac_32 | 3.13 | 0.00 | 0.00 | 2.80 | 0.00 |
| mp3_32 | 3.24 | 0.00 | 0.00 | 3.00 | 0.00 |
| opus_16k | 3.10 | 0.00 | 0.00 | 2.42 | 0.00 |
| mp3_16 | 3.39 | 0.00 | 0.00 | 2.54 | 0.00 |
| opus_8k | 3.67 | 0.00 | 0.00 | 2.96 | 0.00 |
| tel_g711 | 2.86 | 0.00 | 0.00 | 2.52 | 0.00 |
| reverb | 3.34 | 0.00 | 0.00 | 2.62 | 0.00 |
| noisy_snr10 | 3.31 | 0.00 | 0.00 | 2.81 | 0.00 |
| noisy_snr5 | 3.42 | 0.00 | 0.00 | 2.81 | 0.00 |

- **Quality-ROBUST gate** (false-auto ≤ 0.5% in *every* tested quality; 3566 policies qualify): mean **3.02 prompts/person**, worst-case false-auto 0.00%, mean reach-AUTO 8%
  - params: `floor=0.60 auto=0.95 margin=0.12 promo=evid(>=0.25) alpha=0.15 demote=off`

  per-quality prompts/person: orig=2.91, mp3_64=3.03, aac_32=3.07, mp3_32=3.17, opus_16k=2.97, mp3_16=2.89, opus_8k=3.19, tel_g711=2.72, reverb=3.28, noisy_snr10=3.03, noisy_snr5=2.94
