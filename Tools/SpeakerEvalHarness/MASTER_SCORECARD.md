# Master embedding scorecard — all models × all codec arms

Within-meeting = how well speakers are separated inside a meeting (oracle-k). Cross-call AUC = threshold-free same-vs-different separability (1.0 = perfect). Coverage/AUC higher = better; DER lower = better. `·` = not run.

### Within-meeting coverage — speakers correctly separated (higher better)

| model | dim | clean | opus24k | opus16k | opus12k | opus8k | g711u |
|---|---|---|---|---|---|---|---|
| WeSpeaker (current) | 256 | 0.727 | 0.680 | 0.719 | 0.664 | 0.625 | 0.633 |
| ECAPA-TDNN | 192 | 0.805 | 0.750 | 0.758 | 0.719 | 0.742 | 0.797 |
| x-vector (control) | 512 | 0.664 | 0.711 | 0.633 | 0.648 | 0.641 | 0.703 |
| WavLM-SV | 512 | 0.711 | 0.719 | 0.703 | 0.664 | 0.711 | 0.713 |
| UniSpeech-SAT | 512 | 0.742 | · | · | 0.703 | 0.733 | 0.728 |
| ReDimNet-b6 | 192 | 0.812 | · | · | 0.695 | 0.766 | 0.828 |
| CAM++ | 512 | 0.812 | 0.781 | 0.734 | 0.703 | 0.820 | 0.797 |
| ERes2Net | 192 | 0.805 | 0.766 | 0.758 | 0.734 | 0.734 | 0.773 |

### Within-meeting error — DER (lower better)

| model | dim | clean | opus24k | opus16k | opus12k | opus8k | g711u |
|---|---|---|---|---|---|---|---|
| WeSpeaker (current) | 256 | 0.319 | 0.372 | 0.338 | 0.375 | 0.480 | 0.432 |
| ECAPA-TDNN | 192 | 0.267 | 0.281 | 0.301 | 0.302 | 0.307 | 0.281 |
| x-vector (control) | 512 | 0.507 | 0.511 | 0.539 | 0.530 | 0.501 | 0.488 |
| WavLM-SV | 512 | 0.336 | 0.378 | 0.373 | 0.357 | 0.358 | 0.333 |
| UniSpeech-SAT | 512 | 0.347 | · | · | 0.372 | 0.359 | 0.337 |
| ReDimNet-b6 | 192 | 0.252 | · | · | 0.313 | 0.276 | 0.221 |
| CAM++ | 512 | 0.274 | 0.290 | 0.311 | 0.340 | 0.301 | 0.294 |
| ERes2Net | 192 | 0.238 | 0.292 | 0.281 | 0.308 | 0.329 | 0.274 |

### Within-meeting purity (higher better)

| model | dim | clean | opus24k | opus16k | opus12k | opus8k | g711u |
|---|---|---|---|---|---|---|---|
| WeSpeaker (current) | 256 | 0.831 | 0.836 | 0.817 | 0.798 | 0.753 | 0.780 |
| ECAPA-TDNN | 192 | 0.860 | 0.859 | 0.817 | 0.845 | 0.846 | 0.843 |
| x-vector (control) | 512 | 0.854 | 0.828 | 0.824 | 0.827 | 0.839 | 0.836 |
| WavLM-SV | 512 | 0.827 | 0.802 | 0.806 | 0.811 | 0.790 | 0.830 |
| UniSpeech-SAT | 512 | 0.812 | · | · | 0.827 | 0.803 | 0.801 |
| ReDimNet-b6 | 192 | 0.836 | · | · | 0.796 | 0.850 | 0.867 |
| CAM++ | 512 | 0.863 | 0.865 | 0.838 | 0.851 | 0.842 | 0.843 |
| ERes2Net | 192 | 0.875 | 0.847 | 0.852 | 0.846 | 0.831 | 0.849 |

### Cross-call separability — AUC (higher better, 1.0=perfect)

| model | dim | clean | opus24k | opus16k | opus12k | opus8k | g711u |
|---|---|---|---|---|---|---|---|
| WeSpeaker (current) | 256 | 0.9788 | 0.9727 | 0.9768 | 0.9716 | 0.9479 | 0.9696 |
| ECAPA-TDNN | 192 | 1.0000 | 1.0000 | 1.0000 | 0.9999 | 0.9999 | 1.0000 |
| x-vector (control) | 512 | 0.9982 | 0.9973 | 0.9965 | 0.9954 | 0.9962 | 0.9966 |
| WavLM-SV | 512 | 0.9986 | 0.9964 | 0.9988 | 0.9968 | 0.9964 | 0.9948 |
| UniSpeech-SAT | 512 | 0.9994 | · | · | 0.9957 | 0.9941 | 0.9915 |
| ReDimNet-b6 | 192 | 0.9999 | · | · | 0.9985 | 1.0000 | 0.9997 |
| CAM++ | 512 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| ERes2Net | 192 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |

### Cross-call raw separation — same minus different cosine (higher=less anisotropic)

| model | dim | clean | opus24k | opus16k | opus12k | opus8k | g711u |
|---|---|---|---|---|---|---|---|
| WeSpeaker (current) | 256 | 0.544 | 0.506 | 0.478 | 0.421 | 0.287 | 0.421 |
| ECAPA-TDNN | 192 | 0.693 | 0.658 | 0.637 | 0.597 | 0.537 | 0.596 |
| x-vector (control) | 512 | 0.034 | 0.031 | 0.029 | 0.027 | 0.024 | 0.026 |
| WavLM-SV | 512 | 0.266 | 0.263 | 0.263 | 0.260 | 0.276 | 0.268 |
| UniSpeech-SAT | 512 | 0.241 | · | · | 0.228 | 0.226 | 0.228 |
| ReDimNet-b6 | 192 | 0.715 | · | · | 0.620 | 0.603 | 0.657 |
| CAM++ | 512 | 0.698 | 0.674 | 0.640 | 0.593 | 0.556 | 0.660 |
| ERes2Net | 192 | 0.733 | 0.694 | 0.659 | 0.613 | 0.554 | 0.661 |