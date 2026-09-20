# Phase 1 — System Audio Capture

## Goal

Determine whether public iOS 27 ScreenCaptureKit can provide digital audio buffers from other Apps.

## Experiment

The demo started user-authorized capture and observed audio while synthetic/video/game sources played. It logged sample rate, channels, RMS, peak, PTS, dropped buffers and exported PCM/WAV.

## Observed data

The device delivered 48 kHz stereo audio buffers. YouTube, Bilibili and a game produced captured PCM in tested runs; source-specific protected/interruption behavior can differ.

## Result

System mixed audio capture: **YES**.

## Does not prove

It does not prove per-App identity, isolation, controllability, or universal compatibility with every media source.

## Reproduce

Build the demo on a physical iOS 27 device, start capture through the system flow, play a permitted synthetic source, stop, and inspect exported metrics/WAV.

