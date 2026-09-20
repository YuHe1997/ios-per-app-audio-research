# Reproducing Experiments

1. Use Xcode 27 and an iOS 27 physical device with Developer Mode enabled.
2. Build the analyzer with your own signing team; no team is stored in this repository.
3. Use only synthetic or otherwise authorized audio.
4. Start capture through the system-provided authorization UI.
5. For dual-source work, assign distinct frequencies (for example 440 and 997 Hz), retain timestamps, and capture at least 10 seconds.
6. Export WAV/metrics, run the FFT tool, and require overlapping verified frequency windows.
7. Run `Probes/run_all_probes.sh` to reproduce SDK availability findings.

Do not publish device IDs, local paths, signing output, raw third-party media or xcresult bundles without a separate privacy review.

