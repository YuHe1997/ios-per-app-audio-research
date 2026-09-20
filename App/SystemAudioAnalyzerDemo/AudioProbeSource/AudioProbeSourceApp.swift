import AVFAudio
import SwiftUI

#if TONE_440
private let configuredFrequency = 440.0
#elseif TONE_997
// Phase 2D-Retry deliberately uses a non-harmonic companion frequency.
private let configuredFrequency = 997.0
#else
// Keep the default deterministic companion frequency safe even when a caller
// builds the target without an explicit frequency condition.
private let configuredFrequency = 997.0
#endif

@main
struct AudioProbeSourceApp: App {
    var body: some Scene {
        WindowGroup {
            ToneDashboard()
        }
    }
}

@MainActor
private final class ToneProbeModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var heartbeatFrames: UInt64 = 0
    @Published private(set) var outputVolume = AVAudioSession.sharedInstance().outputVolume

    let frequency: Double
    private let engine: ToneEngine
    private var heartbeatTimer: Timer?

    init() {
        frequency = configuredFrequency
        engine = ToneEngine(frequency: configuredFrequency)
    }

    func start() {
        do {
            try engine.start()
            isPlaying = true
            status = String(format: "Playing %.0f Hz", frequency)
        } catch {
            isPlaying = false
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine.stop()
        isPlaying = false
        status = "Stopped"
        heartbeatFrames = 0
    }

    func startTiming() {
        do {
            try engine.startTiming()
            isPlaying = true
            status = "Timing markers playing 0/30"
        } catch {
            status = "Timing start failed: \(error.localizedDescription)"
        }
    }

    func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.heartbeatFrames = self?.engine.heartbeatFrames ?? 0
            guard let self, self.isPlaying, self.status.hasPrefix("Timing") else { return }
            let count = min(30, Int(self.heartbeatFrames / 48_000) + 1)
            self.status = "Timing markers playing \(count)/30"
            if self.engine.timingFinished {
                let url = self.engine.exportMarkerLog()
                self.engine.stop()
                self.isPlaying = false
                self.status = url == nil ? "Timing export failed" : "Timing complete 30/30"
            }
        }
        refreshHeartbeat()
    }

    func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    func refreshHeartbeat() {
        heartbeatFrames = engine.heartbeatFrames
    }

    func refreshOutputVolume() {
        outputVolume = AVAudioSession.sharedInstance().outputVolume
    }
}

@MainActor
private struct ToneDashboard: View {
    @StateObject private var model = ToneProbeModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Probe")
                .font(.title2)
                .accessibilityIdentifier("probe-title")

            Text(String(format: "%.0f Hz", model.frequency))
                .font(.headline)
                .accessibilityIdentifier("tone-frequency")

            HStack(spacing: 16) {
                Button("Play Tone") {
                    model.start()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("play-tone")
                .disabled(model.isPlaying)

                Button("Stop") {
                    model.stop()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stop-tone")
                .disabled(!model.isPlaying)
            }


            Button("Start Timing Markers") { model.startTiming() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-timing-markers")
                .disabled(model.isPlaying)

            Text(model.status)
                .font(.footnote)
                .accessibilityIdentifier("tone-status")

            Button("Read Output Volume") {
                model.refreshOutputVolume()
            }
            .accessibilityIdentifier("probe-read-output-volume")

            Text(String(format: "Output Volume %.6f", model.outputVolume))
                .font(.footnote)
                .accessibilityIdentifier("probe-output-volume")

            Text("Render heartbeat frames: \(model.heartbeatFrames)")
                .font(.footnote)
                .accessibilityIdentifier("tone-heartbeat")
        }
        .padding()
        .onAppear { model.startHeartbeatTimer() }
        .onDisappear { model.stopHeartbeatTimer() }
    }
}
