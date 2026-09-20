# Phase 2 — Dual-Source Capture

## Goal

Determine whether the captured stream can contain two simultaneously sounding processes.

## Experiment

One source emitted 440 Hz and a separate deterministic source emitted 997 Hz. Automation maintained both sources and captured a shared interval. One-second FFT windows tested both frequencies.

## Observed data

In the final dual-source run, both tones were present in the same PCM stream. Representative medians were about -16.33 dBFS at 440 Hz and -21.01 dBFS at 997 Hz; median SNRs were 33.46 dB and 28.82 dB.

## Result

Simultaneous multi-App PCM in a single system mix: **YES**.

## Does not prove

The mixed result does not supply separate A/B streams or identify which App produced an arbitrary signal without experimental ground truth.

## Reproduce

Use two distinct synthetic frequencies, preserve an operation timeline, capture at least 10 seconds, and require both FFT peaks in overlapping windows.

