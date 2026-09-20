@preconcurrency import AVFAudio
import Foundation

/// Deterministic stereo sine source for Phase 2D-Retry automation.
///
/// The audio render callback runs on Core Audio's real-time thread. This small
/// research utility deliberately owns the callback boundary and is marked
/// unchecked Sendable; no UI state is touched from the render callback.
final class ToneEngine: @unchecked Sendable {
    struct MarkerRecord { let id: Int; let hostTime: UInt64; let continuousNanoseconds: UInt64 }
    enum Mode { case tone, timing }
    private let audioEngine = AVAudioEngine()
    private lazy var sourceNode: AVAudioSourceNode = {
        AVAudioSourceNode(format: format) { [weak self] _, timestamp, frameCount, audioBufferList in
            guard let self else { return noErr }
            return self.render(timestamp: timestamp.pointee, frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }()
    private let format: AVAudioFormat
    private let frequency: Double
    private let sampleRate = 48_000.0
    private let amplitude = Float(pow(10.0, -18.0 / 20.0))
    private let phaseLock = NSLock()
    private var phase = 0.0
    private var running = false
    private var renderedFrameCount: UInt64 = 0
    private var mode: Mode = .tone
    private var markers: [MarkerRecord] = []
    private var timingRunID = ""
    private lazy var prbs: [Float] = Self.makePRBS()

    init(frequency: Double) {
        self.frequency = frequency
        self.format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!

        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 1.0
    }

    var isRunning: Bool {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return running
    }

    /// Monotonic render heartbeat. It is read by the foreground UI after the
    /// app returns from background; PCM frequency analysis remains the primary
    /// proof that the engine actually produced audio while backgrounded.
    var heartbeatFrames: UInt64 {
        phaseLock.lock()
        defer { phaseLock.unlock() }
        return renderedFrameCount
    }

    func start() throws {
        mode = .tone
        try startEngine()
    }

    func startTiming() throws {
        mode = .timing
        markers = []
        timingRunID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try startEngine()
    }

    private func startEngine() throws {
        phaseLock.lock()
        let alreadyRunning = running
        phaseLock.unlock()
        guard !alreadyRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true)

        audioEngine.prepare()
        try audioEngine.start()

        phaseLock.lock()
        running = true
        renderedFrameCount = 0
        phaseLock.unlock()
    }

    var timingFinished: Bool { heartbeatFrames >= 30 * 48_000 }

    func exportMarkerLog() -> URL? {
        phaseLock.lock(); let snapshot = markers; phaseLock.unlock()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phase3c-render-markers-\(timingRunID).csv")
        var csv = "marker_id,render_host_time,render_continuous_ns\n"
        for r in snapshot { csv += "\(r.id),\(r.hostTime),\(r.continuousNanoseconds)\n" }
        do { try csv.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    func stop() {
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        phaseLock.lock()
        running = false
        phase = 0
        renderedFrameCount = 0
        phaseLock.unlock()
    }

    private func render(
        timestamp: AudioTimeStamp,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frames = Int(frameCount)
        let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let increment = 2.0 * Double.pi * frequency / sampleRate

        phaseLock.lock()
        defer { phaseLock.unlock() }

        for frame in 0..<frames {
            let absoluteFrame = renderedFrameCount
            let secondFrame = Int(absoluteFrame % 48_000)
            let markerID = Int(absoluteFrame / 48_000)
            let value: Float
            if mode == .timing {
                value = markerID < 30 && secondFrame < prbs.count ? prbs[secondFrame] : 0
                if markerID < 30 && secondFrame == 0 {
                    let offsetSeconds = Double(frame) / sampleRate
                    let hostTime = timestamp.mHostTime + AVAudioTime.hostTime(forSeconds: offsetSeconds)
                    var info = mach_timebase_info_data_t()
                    mach_timebase_info(&info)
                    let absoluteNow = mach_absolute_time()
                    let continuousNow = mach_continuous_time()
                    let toNS: (UInt64) -> UInt64 = {
                        $0.multipliedReportingOverflow(by: UInt64(info.numer)).partialValue / UInt64(info.denom)
                    }
                    let bridge = toNS(continuousNow) - toNS(absoluteNow)
                    markers.append(MarkerRecord(id: markerID, hostTime: hostTime, continuousNanoseconds: toNS(hostTime) + bridge))
                }
            } else {
                value = amplitude * Float(sin(phase))
                phase += increment
                if phase >= 2.0 * Double.pi { phase.formTruncatingRemainder(dividingBy: 2.0 * Double.pi) }
            }

            for buffer in bufferList {
                guard let data = buffer.mData else { continue }
                let channelCount = max(1, Int(buffer.mNumberChannels))
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<channelCount {
                    samples[frame * channelCount + channel] = value
                }
            }
            renderedFrameCount &+= 1
        }

        return noErr
    }

    private static func makePRBS() -> [Float] {
        var state: UInt16 = 0x7FFF
        let amplitude = Float(pow(10.0, -24.0 / 20.0))
        return (0..<4_800).map { _ in
            let bit = ((state >> 14) ^ (state >> 13)) & 1
            state = ((state << 1) | bit) & 0x7FFF
            return (state & 1) == 1 ? amplitude : -amplitude
        }
    }
}
