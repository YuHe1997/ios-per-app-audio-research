# Current Limitations

- Physical-device ScreenCaptureKit authorization and source behavior can require user interaction.
- Protected or source-specific playback may stop, mute or be restricted.
- The analyzer receives a mixed stream and cannot label arbitrary contributing Apps.
- No public per-App gain control is implemented or claimed.
- Offline FFT recognizes known experimental tones; it is not general source separation.
- The published result is tied to the tested iOS 27/Xcode 27 public SDK and should be rechecked on later major SDKs.

