# Research Overview

## Question

Can a normal, non-jailbroken iOS 27 application use public APIs to capture, identify, isolate or independently control arbitrary third-party application audio?

## Tested environment

iPhone 15 Pro Max, iOS 27.0; Xcode 27.0; iPhoneOS 27.0 SDK; built-in speaker; 48 kHz stereo. Identifiers and signing data are intentionally omitted.

## Answer

ScreenCaptureKit provided one system mixed PCM stream. Two independent Apps were simultaneously observable in that stream. Public APIs did not provide stable source identity, separate per-App PCM or independent per-App gain.

This result describes the tested public SDK/device behavior, not undocumented/private or future APIs.

