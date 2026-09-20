# Phase 4 — Source-Origin Public API Audit

## Goal

Audit the public iOS 27 surface for source attribution, per-App PCM, or direct gain.

## Result

- Level 1 Attribution = **NO**
- Level 2 Per-App PCM = **NO**
- Level 3 Per-App Gain Control = **NO**

ScreenCaptureKit application enumeration/filter APIs tested from the SDK were unavailable on iOS. Public iPhoneOS Core Audio did not import the macOS process/tap surface. AudioUnit/AVAudioEngine operated on the current process graph. AVAudioSession exposed current-session/route/global Boolean state, not foreign identity. Public CMSampleBuffer metadata contained format/timing/layout information but no stable source identity.

macOS Core Audio process taps exist, but equivalent public iPhoneOS process-tap surface was not available in the tested iOS 27 SDK.

## True-device metadata comparison

M1 (440 only), M2 (997 only), and M3 (both) produced 23,214 dumped audio buffers. The signal contents differed as expected, while the public metadata exposed no bundle ID, PID, source token or foreign audio-session identity.

## Conclusion

Public iOS 27 provided A+B, not separate A and B. This project does not proceed into private APIs, jailbreak techniques, active cancellation or AI source separation.

