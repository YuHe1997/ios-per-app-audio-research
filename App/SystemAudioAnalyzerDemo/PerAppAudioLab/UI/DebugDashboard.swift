import SwiftUI
import AVFAudio
import MediaPlayer
import UIKit

@MainActor
struct DebugDashboard: View {
    @StateObject private var captureManager = AudioCaptureManager()
    @StateObject private var selfTone = Phase3SelfToneModel()
    @StateObject private var selfPRBS = Phase3SelfPRBSModel()
    @State private var selfToneArmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    phase3Controls
                    metrics
                    phase2DRetryMetrics
                    export
                    notice
                }
                .padding()
            }
            .navigationTitle("PerAppAudioLab")
        }
    }

    private var phase3Controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Phase 3 Debug Controls").font(.headline)
            Toggle("Exclude Current Process Audio", isOn: $captureManager.excludesCurrentProcessAudio)
                .accessibilityIdentifier("phase3-excludes-current-process")
                .disabled(!captureManager.canStartCapture)
            Phase3SystemVolumeView()
                .frame(height: 32)
                .accessibilityIdentifier("phase3-system-volume-view")
            Button("Read Output Volume") { captureManager.refreshOutputVolume() }
                .accessibilityIdentifier("phase3-read-output-volume")
            Text(String(format: "Output Volume %.6f", captureManager.outputVolume))
                .accessibilityIdentifier("phase3-output-volume")
            Text(String(format: "Output Latency %.6f s", captureManager.outputLatency))
                .accessibilityIdentifier("phase3-output-latency")
            Text(String(format: "I/O Buffer %.6f s", captureManager.ioBufferDuration))
                .accessibilityIdentifier("phase3-io-buffer-duration")
            Button("Prepare Self Tone") {
                selfTone.prepare()
            }
            .accessibilityIdentifier("phase3-self-tone-prepare")
            .disabled(selfTone.isPlaying)
            Button("Arm Self Tone After Capture") {
                selfToneArmed = true
                selfTone.markArmed()
            }
            .accessibilityIdentifier("phase3-self-tone-arm")
            .disabled(selfTone.isPlaying || selfToneArmed)
            HStack {
                Button("Play Self 1231 Hz") {
                    selfTone.start()
                    captureManager.markPhase3Event("self_tone_start", message: "frequency=1231, amplitude_dbfs=-18")
                }
                .accessibilityIdentifier("phase3-self-tone-play")
                .disabled(selfTone.isPlaying)
                Button("Stop Self Tone") {
                    selfTone.stop()
                    captureManager.markPhase3Event("self_tone_stop")
                }
                .accessibilityIdentifier("phase3-self-tone-stop")
                .disabled(!selfTone.isPlaying)
            }
            Text(selfTone.status).accessibilityIdentifier("phase3-self-tone-status")
        }
        .onChange(of: captureManager.state) { _, newState in
            if newState == .capturing, ProcessInfo.processInfo.environment["PHASE3D_AUTO"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    selfPRBS.start()
                    captureManager.markPhase3Event("self_prbs_start", message: selfPRBS.referenceURL?.path)
                    try? await Task.sleep(for: .seconds(30))
                    selfPRBS.stop()
                    captureManager.markPhase3Event("self_prbs_stop")
                    try? await Task.sleep(for: .seconds(2))
                    captureManager.stopCapture()
                    try? await Task.sleep(for: .seconds(2))
                    captureManager.exportLog()
                }
            }
            if newState == .capturing, ProcessInfo.processInfo.environment["PHASE3C_AUTO_EXPORT"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(42))
                    captureManager.stopCapture()
                    try? await Task.sleep(for: .seconds(2))
                    captureManager.exportLog()
                }
            }
            guard newState == .capturing, selfToneArmed else { return }
            selfToneArmed = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                selfTone.start()
                if selfTone.isPlaying {
                    captureManager.markPhase3Event("self_tone_start", message: "frequency=1231, amplitude_dbfs=-18, armed=true")
                    try? await Task.sleep(for: .seconds(15))
                    selfTone.stop()
                    captureManager.markPhase3Event("self_tone_stop", message: "automatic=true, duration_seconds=15")
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Start Capture") {
                    captureManager.startCapture()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-capture")
                .disabled(!captureManager.canStartCapture)

                Button("Stop Capture") {
                    captureManager.stopCapture()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stop-capture")
                .disabled(!captureManager.canStopCapture)
            }

            LabeledContent("Capture State", value: captureManager.state.label)
                .accessibilityIdentifier("capture-state")
            if let error = captureManager.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("capture-error")
            }
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Metrics")
                .font(.headline)
            metricRow("Audio Buffers", value: "\(captureManager.bufferCount)")
            metricRow("Sample Rate", value: captureManager.sampleRate > 0 ? String(format: "%.0f Hz", captureManager.sampleRate) : "—")
            metricRow("Channels", value: captureManager.channelCount > 0 ? "\(captureManager.channelCount)" : "—")
            metricRow("RMS", value: String(format: "%.2f dBFS", captureManager.rmsDBFS))
            metricRow("Peak", value: String(format: "%.2f dBFS", captureManager.peakDBFS))
            metricRow("PTS", value: captureManager.latestPTS.map { String(format: "%.6f s", $0) } ?? "—")
            metricRow("Dropped Buffers", value: "\(captureManager.droppedBuffers)")
        }
    }

    private var export: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Export Log (CSV)") {
                captureManager.exportLog()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("export-log-csv")

            if let url = captureManager.lastExportURL {
                Text(url.path)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("last-export-url")
            }
        }
    }

    private var phase2DRetryMetrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phase 2D-Retry Tone Gate")
                .font(.headline)
            if let window = captureManager.phase2DRetryLatestToneWindow {
                Text(String(format: "Window %d: %.0f–%.0f s", window.index, window.startSeconds, window.endSeconds))
                    .accessibilityIdentifier("phase2d-tone-window")
                Text(String(format: "440 Hz %.2f dBFS / SNR %.2f dB", window.tone440DBFS, window.tone440SNRDB))
                    .accessibilityIdentifier("phase2d-tone-440")
                Text(String(format: "997 Hz %.2f dBFS / SNR %.2f dB", window.tone997DBFS, window.tone997SNRDB))
                    .accessibilityIdentifier("phase2d-tone-997")
                Text(captureManager.phase2DRetryOverlapPrecheckPassed
                    ? "PASS — 2 consecutive 440 + 997 windows"
                    : "WAITING — overlap not established")
                    .accessibilityIdentifier("phase2d-overlap-status")
            } else {
                Text("No completed 1-second tone window")
                    .accessibilityIdentifier("phase2d-tone-window")
                Text("WAITING — overlap not established")
                    .accessibilityIdentifier("phase2d-overlap-status")
            }
            Text("Completed tone windows: \(captureManager.phase2DRetryToneWindowCount)")
                .accessibilityIdentifier("phase2d-tone-window-count")
        }
    }

    private var notice: some View {
        Text("This is a Phase 0–1 research probe. It does not implement per-app mixing and does not change another app's output volume.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private final class Phase3SelfPRBSModel: ObservableObject {
    @Published var status = "PRBS stopped"
    private let engine = Phase3SelfPRBSEngine()
    var referenceURL: URL? { engine.referenceURL }
    func start() {
        do { try engine.start(); status = "PRBS playing" }
        catch { status = "PRBS failed: \(error.localizedDescription)" }
    }
    func stop() { engine.stop(); status = "PRBS stopped" }
}

private final class Phase3SelfPRBSEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 48_000.0
    private(set) var referenceURL: URL?

    init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        let frames = 30 * 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        var state: UInt32 = 0x7FFFFF
        var low: Float = 0, previousLow: Float = 0, high: Float = 0
        let lowAlpha = Float(1 - exp(-2 * Double.pi * 5000 / sampleRate))
        let highAlpha = Float(exp(-2 * Double.pi * 300 / sampleRate))
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let bit = ((state >> 22) ^ (state >> 17)) & 1
            state = ((state << 1) | bit) & 0x7FFFFF
            let white: Float = state & 1 == 1 ? 1 : -1
            low += lowAlpha * (white - low)
            high = highAlpha * (high + low - previousLow)
            previousLow = low
            mono[i] = high
        }
        let rms = sqrt(mono.reduce(0) { $0 + $1 * $1 } / Float(frames))
        let scale = Float(pow(10.0, -24.0 / 20.0)) / max(rms, 1e-9)
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<frames { data[i] = mono[i] * scale }
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phase3d-reference-\(UUID().uuidString).f32")
        try Data(bytes: buffer.floatChannelData![0], count: frames * MemoryLayout<Float>.size).write(to: url)
        referenceURL = url
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true)
        engine.prepare(); try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()
    }

    func stop() {
        player.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

@MainActor
private final class Phase3SelfToneModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Self tone stopped"
    private let engine = Phase3SelfToneEngine()

    func prepare() {
        do {
            try engine.prepareSession()
            status = "Self tone prepared"
        } catch {
            status = "Self tone prepare failed: \(error.localizedDescription)"
        }
    }

    func markArmed() {
        status = "Self tone armed"
    }

    func start() {
        do {
            try engine.start()
            isPlaying = true
            status = "Playing 1231 Hz at -18 dBFS"
        } catch {
            status = "Self tone failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine.stop()
        isPlaying = false
        status = "Self tone stopped"
    }
}

private final class Phase3SelfToneEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var phase = 0.0
    private var sessionPrepared = false
    private let lock = NSLock()
    private lazy var source = AVAudioSourceNode(format: format) { [weak self] _, _, frames, list in
        guard let self else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let increment = 2.0 * Double.pi * 1231.0 / 48_000.0
        let amplitude = Float(pow(10.0, -18.0 / 20.0))
        self.lock.lock()
        defer { self.lock.unlock() }
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(self.phase))
            self.phase = (self.phase + increment).truncatingRemainder(dividingBy: 2.0 * Double.pi)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let channels = max(1, Int(buffer.mNumberChannels))
                for channel in 0..<channels { samples[frame * channels + channel] = value }
            }
        }
        return noErr
    }

    init() {
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        if !sessionPrepared { try prepareSession() }
        engine.prepare()
        try engine.start()
    }

    func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        engine.prepare()
        sessionPrepared = true
    }

    func stop() {
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        sessionPrepared = false
    }
}

private struct Phase3SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        DispatchQueue.main.async {
            let slider = view.subviews.compactMap { $0 as? UISlider }.first
            slider?.accessibilityIdentifier = "phase3-system-volume-slider"
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
