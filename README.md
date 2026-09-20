# iOS Per-App Audio Research

This project investigates whether a normal, non-jailbroken iOS 27 app can capture, identify, isolate, or independently control audio from arbitrary third-party applications.

Current result:

- System mixed audio capture: **YES**
- Simultaneous multi-app PCM: **YES**
- Per-app source attribution: **NO**
- Per-app isolated PCM: **NO**
- Per-app gain control: **NO**

Normal public iOS 27 APIs currently expose **A+B**, not separate A and B streams.

> **This is NOT a working per-app volume mixer.** The included Analyzer is a research/demo tool.

## System Audio Analyzer Demo

The SwiftUI demo can start and stop ScreenCaptureKit capture, display live buffer count/RMS/peak/format/timestamps, and export PCM/WAV, scalar metrics and public CMSampleBuffer metadata. Offline tools provide basic FFT/tone analysis and timing analysis. The deterministic probe app generates synthetic tones for reproducible experiments.

Open `App/SystemAudioAnalyzerDemo/PerAppAudioLab.xcodeproj` in Xcode 27. The project targets iOS 27. No signing team is committed; select your own team only for physical-device installation.

Unsigned generic-device build:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
xcodebuild -project App/SystemAudioAnalyzerDemo/PerAppAudioLab.xcodeproj \
  -target PerAppAudioLab -sdk iphoneos -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Run API probes and the dependency-free synthetic analyzer check:

```sh
./Probes/run_all_probes.sh
python3 Tools/fft/verify_synthetic.py
```

## Repository map

- `Research/`: sanitized Phase 1–4 experiment summaries
- `App/SystemAudioAnalyzerDemo/`: minimal capture/analyzer and deterministic tone source
- `Probes/`: iPhoneOS 27 public-API compiler probes
- `Tools/`: FFT, timing and metadata analysis
- `Samples/synthetic/`: synthetic-only sample policy
- `Results/`: small sanitized result tables; no raw third-party media
- `docs/`: reproduction, environment, future-version watch and commercial boundary

## Scope and license

Original project code is licensed under MPL-2.0. Third-party dependencies remain under their own licenses. The current release has no third-party package or vendored framework dependency.

Commercial use is permitted subject to the license. Possible future hosted/workflow products are outside this repository; see `docs/CommercialBoundary.md`.

