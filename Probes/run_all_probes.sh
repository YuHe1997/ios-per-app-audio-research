#!/bin/sh
set -eu

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.0.0.app/Contents/Developer}"
export DEVELOPER_DIR
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
TARGET="arm64-apple-ios27.0"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ios-per-app-audio-probes"
mkdir -p "$OUT"

expect_fail() {
  name="$1"
  source="$2"
  log="$OUT/$name.log"
  if "$SWIFTC" -target "$TARGET" -sdk "$SDK" -typecheck "$source" >"$log" 2>&1; then
    echo "FAIL: $name unexpectedly compiled"
    return 1
  fi
  echo "PASS: $name reproduced expected iPhoneOS unavailability"
  sed -n '1,16p' "$log"
}

expect_pass() {
  name="$1"
  source="$2"
  log="$OUT/$name.log"
  "$SWIFTC" -target "$TARGET" -sdk "$SDK" -typecheck "$source" >"$log" 2>&1
  echo "PASS: $name imports on iPhoneOS (classification still depends on API scope)"
}

expect_fail sck-application-filter "$ROOT/Probes/ScreenCaptureKit/SCKApplicationFilterProbe.swift"
expect_fail coreaudio-process-tap "$ROOT/Probes/CoreAudio/CoreAudioProcessTapProbe.swift"
expect_pass audiounit-current-process "$ROOT/Probes/CoreAudio/AudioUnitSystemMixerProbe.swift"
expect_pass avaudiopsession "$ROOT/Probes/AVAudioSession/AVAudioSessionOriginProbe.swift"
expect_pass replaykit-source-compatibility "$ROOT/Probes/ReplayKit/ReplayKitProbe.swift"

echo "Probe logs: $OUT"

