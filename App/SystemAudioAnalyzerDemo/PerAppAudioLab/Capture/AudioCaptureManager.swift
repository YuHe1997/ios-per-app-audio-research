import Combine
import CoreMedia
import Foundation
import AVFAudio

#if canImport(ScreenCaptureKit)
import AudioToolbox
import ScreenCaptureKit
#endif

enum CaptureState: Equatable, Sendable {
    case idle
    case awaitingPicker
    case starting
    case capturing
    case stopping
    case unavailable
    case failed

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .awaitingPicker: return "Awaiting system picker"
        case .starting: return "Starting"
        case .capturing: return "Capturing"
        case .stopping: return "Stopping"
        case .unavailable: return "Unavailable in this SDK"
        case .failed: return "Failed"
        }
    }
}

/// One completed one-second frequency window used by the strict Phase 2D
/// Retry gate. The values are derived from the captured PCM, not from a UI
/// state string in either source app.
struct Phase2DRetryToneWindow: Codable, Equatable, Sendable {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double
    let tone440DBFS: Double
    let tone440SNRDB: Double
    let tone997DBFS: Double
    let tone997SNRDB: Double
    let rmsDBFS: Double
    let peakDBFS: Double

    var has440: Bool {
        tone440SNRDB > 15.0 && tone440DBFS > -70.0
    }

    var has997: Bool {
        tone997SNRDB > 15.0 && tone997DBFS > -70.0
    }

    var isDual: Bool {
        has440 && has997
    }
}

#if canImport(ScreenCaptureKit)
/// SCContentFilter is an Objective-C reference type without a Sendable
/// annotation in the iOS 27 SDK. The picker delivers it from a nonisolated
/// callback, so this small wrapper makes the handoff explicit and local.
private final class ContentFilterBox: @unchecked Sendable {
    let value: SCContentFilter

    init(_ value: SCContentFilter) {
        self.value = value
    }
}

/// One process-wide recorder is enough for the single PerAppAudioLab scene.
/// It is intentionally independent from the MainActor so ScreenCaptureKit's
/// sample-handler queue can copy samples without crossing an actor boundary.
private let phase2DPCMRecorder = Phase2DPCMRecorder()
#endif

@MainActor
final class AudioCaptureManager: NSObject, ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var bufferCount = 0
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var channelCount = 0
    @Published private(set) var rmsDBFS = -120.0
    @Published private(set) var peakDBFS = -120.0
    @Published private(set) var latestPTS: Double?
    @Published private(set) var droppedBuffers = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var phase2DRetryLatestToneWindow: Phase2DRetryToneWindow?
    @Published private(set) var phase2DRetryToneWindowCount = 0
    @Published private(set) var phase2DRetryConsecutiveDualWindows = 0
    @Published private(set) var phase2DRetryOverlapPrecheckPassed = false
    @Published var excludesCurrentProcessAudio = true
    @Published private(set) var outputVolume: Float = AVAudioSession.sharedInstance().outputVolume
    @Published private(set) var outputLatency = AVAudioSession.sharedInstance().outputLatency
    @Published private(set) var ioBufferDuration = AVAudioSession.sharedInstance().ioBufferDuration

    let logger = CaptureLogger()

#if canImport(ScreenCaptureKit)
    private let picker = SCContentSharingPicker.shared
    private let sampleHandlerQueue = DispatchQueue(label: "com.example.PerAppAudioLab.audio-samples")
    private var stream: SCStream?
    private var phase2DRunDirectory: URL?
    private var nextSequenceNumber: UInt64 = 0
    private var previousPTS: Double?
    private var phase2DRetryLastWindowIndex = 0
#endif

    override init() {
        super.init()
        logger.append(event: "manager_initialized")
        refreshAudioSessionSnapshot(event: "manager_audio_session")
    }

    var canStartCapture: Bool {
        switch state {
        case .idle, .unavailable, .failed:
            return true
        case .awaitingPicker, .starting, .capturing, .stopping:
            return false
        }
    }

    var canStopCapture: Bool {
        switch state {
        case .awaitingPicker, .starting, .capturing, .stopping:
            return true
        case .idle, .unavailable, .failed:
            return false
        }
    }

    func startCapture() {
        guard canStartCapture else { return }
        resetMeasurements()
        logger.startSession()
        refreshAudioSessionSnapshot(event: "run_start_audio_session")

#if canImport(ScreenCaptureKit)
        state = .awaitingPicker
        lastError = nil
        do {
            phase2DRunDirectory = try phase2DPCMRecorder.start()
            logger.append(event: "phase2d_bundle_started", message: phase2DRunDirectory?.path)
        } catch {
            recordError("Phase 2D raw recorder start failed: \(error.localizedDescription)")
            return
        }
        logger.append(event: "picker_requested")
        picker.add(self)
        picker.isActive = true
        picker.present()
#else
        state = .unavailable
        let message = "ScreenCaptureKit is not present in the current iOS SDK. An iOS 27 SDK and device are required for Phase 1."
        lastError = message
        logger.append(event: "phase0_blocked", message: message)
#endif
    }

    func stopCapture() {
        guard canStopCapture else { return }
        state = .stopping
        logger.append(event: "stop_requested")
        refreshAudioSessionSnapshot(event: "run_end_audio_session")

#if canImport(ScreenCaptureKit)
        picker.remove(self)
        let activeStream = stream
        stream = nil
        Task { @MainActor [weak self] in
            do {
                try await activeStream?.stopCapture()
            } catch {
                self?.recordError("stopCapture failed: \(error.localizedDescription)")
            }
            if let directory = phase2DPCMRecorder.finish() {
                self?.phase2DRunDirectory = directory
                self?.logger.append(event: "pcm_finalized", message: directory.path)
            }
            self?.state = .idle
            self?.logger.append(event: "stream_stopped")
        }
#else
        state = .idle
        logger.append(event: "capture_stopped_without_stream")
#endif
    }

    func refreshOutputVolume() {
        outputVolume = AVAudioSession.sharedInstance().outputVolume
        logger.append(event: "output_volume_read", message: String(format: "outputVolume=%.6f", outputVolume))
    }

    func markPhase3Event(_ name: String, message: String? = nil) {
        logger.append(event: name, message: message)
    }

    private func refreshAudioSessionSnapshot(event: String) {
        let session = AVAudioSession.sharedInstance()
        outputVolume = session.outputVolume
        outputLatency = session.outputLatency
        ioBufferDuration = session.ioBufferDuration
        let route = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ";")
        logger.append(event: event, message: String(format: "outputVolume=%.6f, outputLatency=%.9f, ioBufferDuration=%.9f, sampleRate=%.3f, route=%@", outputVolume, outputLatency, ioBufferDuration, session.sampleRate, route))
    }

    func exportLog() {
        do {
            #if canImport(ScreenCaptureKit)
            let directory: URL
            if let existingDirectory = phase2DRunDirectory {
                directory = existingDirectory
            } else {
                directory = try phase2DPCMRecorder.start()
                phase2DRunDirectory = directory
            }
            _ = phase2DPCMRecorder.finish()
            try logger.exportPhase2DBundle(to: directory)
            logger.append(event: "log_exported", message: directory.path)
            // Re-export so the terminal log_exported event is included.
            try logger.exportPhase2DBundle(to: directory)
            lastExportURL = directory
            #else
            lastExportURL = try logger.exportCSV()
            logger.append(event: "log_exported", message: lastExportURL?.path)
            #endif
        } catch {
            recordError("Could not export CSV: \(error.localizedDescription)")
        }
    }

    private func resetMeasurements() {
        bufferCount = 0
        sampleRate = 0
        channelCount = 0
        rmsDBFS = -120
        peakDBFS = -120
        latestPTS = nil
        droppedBuffers = 0
        lastError = nil
        lastExportURL = nil
        phase2DRetryLatestToneWindow = nil
        phase2DRetryToneWindowCount = 0
        phase2DRetryConsecutiveDualWindows = 0
        phase2DRetryOverlapPrecheckPassed = false
#if canImport(ScreenCaptureKit)
        nextSequenceNumber = 0
        previousPTS = nil
        phase2DRetryLastWindowIndex = 0
#endif
    }

    private func recordError(_ message: String) {
        lastError = message
        state = .failed
        logger.append(event: "error", message: message)
    }

#if canImport(ScreenCaptureKit)
    private func startStream(with filter: SCContentFilter) {
        state = .starting
        logger.append(event: "filter_received")

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        logger.append(event: "capture_configuration", message: "sampleRate=48000, channels=2, excludesCurrentProcessAudio=\(excludesCurrentProcessAudio)")

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        } catch {
            recordError("addStreamOutput failed: \(error.localizedDescription)")
            return
        }

        stream = newStream
        Task { @MainActor [weak self, weak newStream] in
            do {
                try await newStream?.startCapture()
                self?.state = .capturing
                self?.logger.append(event: "stream_started")
            } catch {
                self?.recordError("startCapture failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleAudioSnapshot(_ snapshot: AudioBufferSnapshot) {
        nextSequenceNumber += 1
        let metrics = AudioMetrics(
            sequenceNumber: nextSequenceNumber,
            capturedAt: snapshot.capturedAt,
            callbackMonotonicNanoseconds: snapshot.callbackMonotonicNanoseconds,
            ptsSeconds: snapshot.ptsSeconds,
            durationSeconds: snapshot.durationSeconds,
            sampleCount: snapshot.sampleCount,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount,
            rmsDBFS: snapshot.rmsDBFS,
            peakDBFS: snapshot.peakDBFS,
            interBufferDeltaSeconds: snapshot.ptsSeconds.flatMap { pts in
                previousPTS.map { pts - $0 }
            }
        )
        previousPTS = metrics.ptsSeconds
        bufferCount = Int(metrics.sequenceNumber)
        sampleRate = metrics.sampleRate
        channelCount = metrics.channelCount
        rmsDBFS = metrics.rmsDBFS
        peakDBFS = metrics.peakDBFS
        latestPTS = metrics.ptsSeconds

        if let delta = metrics.interBufferDeltaSeconds,
           let duration = metrics.durationSeconds,
           duration > 0,
           delta > duration * 1.5 {
            let estimatedMissing = max(1, Int((delta / duration).rounded(.down)) - 1)
            droppedBuffers += estimatedMissing
            logger.append(
                event: "buffer_gap",
                message: "estimated_missing=\(estimatedMissing), delta=\(delta), duration=\(duration)"
            )
        }

        logger.append(metrics: metrics)
        refreshPhase2DRetryToneWindow()
    }

    private func refreshPhase2DRetryToneWindow() {
#if canImport(ScreenCaptureKit)
        guard let window = phase2DPCMRecorder.latestToneWindow(),
              window.index > phase2DRetryLastWindowIndex else { return }
        phase2DRetryLastWindowIndex = window.index
        phase2DRetryLatestToneWindow = window
        phase2DRetryToneWindowCount = window.index
        if window.isDual {
            phase2DRetryConsecutiveDualWindows += 1
        } else {
            phase2DRetryConsecutiveDualWindows = 0
        }
        phase2DRetryOverlapPrecheckPassed = phase2DRetryConsecutiveDualWindows >= 2
        logger.append(
            event: "tone_window",
            message: String(
                format: "index=%d, start=%.3f, end=%.3f, tone440_dbfs=%.3f, tone440_snr_db=%.3f, tone997_dbfs=%.3f, tone997_snr_db=%.3f, dual=%@",
                window.index,
                window.startSeconds,
                window.endSeconds,
                window.tone440DBFS,
                window.tone440SNRDB,
                window.tone997DBFS,
                window.tone997SNRDB,
                window.isDual ? "true" : "false"
            )
        )
#endif
    }
#endif
}

#if canImport(ScreenCaptureKit)
extension AudioCaptureManager: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        phase2DPCMRecorder.append(sampleBuffer: sampleBuffer)
        let snapshot = AudioMetrics.snapshot(sampleBuffer: sampleBuffer)
        Task { @MainActor [weak self, snapshot] in
            self?.handleAudioSnapshot(snapshot)
        }
    }
}

extension AudioCaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self, message] in
            self?.recordError("stream stopped with error: \(message)")
        }
    }
}

extension AudioCaptureManager: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let filterBox = ContentFilterBox(filter)
        let hasExistingStream = stream != nil
        Task { @MainActor [weak self, filterBox, hasExistingStream] in
            guard let self else { return }
            if hasExistingStream {
                // `updateContentFilter` is unavailable on iOS. The iOS picker
                // flow starts a new stream (with a nil stream argument); if a
                // future callback supplies an existing stream, surface the
                // platform limitation instead of calling an unavailable API.
                self.recordError("Updating an existing picker stream is unavailable on iOS; stop and restart capture.")
            } else {
                self.startStream(with: filterBox.value)
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            if let directory = phase2DPCMRecorder.finish() {
                self?.phase2DRunDirectory = directory
                self?.logger.append(event: "pcm_finalized", message: directory.path)
            }
            self?.state = .idle
            self?.logger.append(event: "picker_cancelled")
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self, message] in
            self?.recordError("picker failed: \(message)")
        }
    }
}
#endif

#if canImport(ScreenCaptureKit)
/// A small, lossless-enough PCM recorder for the Phase 2D experiment.
///
/// ScreenCaptureKit delivers CMSampleBuffers on its sample-handler queue. The
/// recorder copies each buffer immediately into a deterministic stereo,
/// signed-16-bit little-endian stream. The original input ASBD is retained in
/// `format.json`, while `capture.wav` is directly usable by macOS analysis
/// tools. All mutable state is protected because the callback and stop/export
/// paths can run on different queues.
private final class Phase2DPCMRecorder: @unchecked Sendable {
    private static let floatFlag: UInt32 = 1 << 0
    private static let signedIntegerFlag: UInt32 = 1 << 2
    private static let nonInterleavedFlag: UInt32 = 1 << 5

    private let lock = NSLock()
    private let analysisQueue = DispatchQueue(label: "com.example.PerAppAudioLab.phase2d-retry-analysis")
    private let analysisLock = NSLock()
    private let outputSampleRate = 48_000
    private let outputChannels = 2
    private let outputBitsPerSample = 16
    private let analysisWindowFrames = 48_000
    private let retryToneFrequencies = (tone440: 440.0, tone997: 997.0)
    // A media app can resample a nominal 440 Hz file by a fraction of a Hz.
    // Keep the strict amplitude/SNR gates, but evaluate a narrow frequency
    // neighborhood so that clock drift is not mistaken for source loss.
    private let retryToneFrequencyOffsets = [-0.2, -0.1, 0.0, 0.1, 0.2]

    private var runDirectory: URL?
    private var rawHandle: FileHandle?
    private var wavHandle: FileHandle?
    private var metadataHandle: FileHandle?
    private var dataByteCount = 0
    private var frameCount = 0
    private var started = false
    private var inputMetadata: InputMetadata?
    private var analysisSamples: [Float] = []
    private var analysisWindowIndex = 0
    private var analysisResults: [Phase2DRetryToneWindow] = []
    private var latestAnalysisWindow: Phase2DRetryToneWindow?

    private struct InputMetadata: Codable, Sendable {
        let sampleRate: Double
        let channelCount: Int
        let bitsPerChannel: Int
        let sampleFormat: String
        let interleaved: Bool
        let bytesPerFrame: Int
        let formatFlags: UInt32
    }

    private struct FormatMetadata: Codable, Sendable {
        let schemaVersion: Int
        let inputSampleRate: Double
        let inputChannelCount: Int
        let inputBitsPerChannel: Int
        let inputSampleFormat: String
        let inputInterleaved: Bool
        let inputBytesPerFrame: Int
        let inputFormatFlags: UInt32
        let outputSampleRate: Int
        let outputChannelCount: Int
        let outputBitsPerSample: Int
        let outputFormat: String
        let dataBytes: Int
        let frameCount: Int
        let rawFile: String
        let wavFile: String

        init(input: InputMetadata?, dataBytes: Int, frameCount: Int) {
            schemaVersion = 1
            inputSampleRate = input?.sampleRate ?? 0
            inputChannelCount = input?.channelCount ?? 0
            inputBitsPerChannel = input?.bitsPerChannel ?? 0
            inputSampleFormat = input?.sampleFormat ?? "unknown"
            inputInterleaved = input?.interleaved ?? true
            inputBytesPerFrame = input?.bytesPerFrame ?? 0
            inputFormatFlags = input?.formatFlags ?? 0
            outputSampleRate = 48_000
            outputChannelCount = 2
            outputBitsPerSample = 16
            outputFormat = "signed-int16-le"
            self.dataBytes = dataBytes
            self.frameCount = frameCount
            rawFile = "capture.raw"
            wavFile = "capture.wav"
        }
    }

    @discardableResult
    func start() throws -> URL {
        _ = finish()

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let directory = documents
            .appendingPathComponent("Phase2D-Retry", isDirectory: true)
            .appendingPathComponent("run-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawURL = directory.appendingPathComponent("capture.raw")
        let wavURL = directory.appendingPathComponent("capture.wav")
        let metadataURL = directory.appendingPathComponent("metadata.jsonl")
        guard FileManager.default.createFile(atPath: rawURL.path, contents: nil),
              FileManager.default.createFile(atPath: wavURL.path, contents: nil),
              FileManager.default.createFile(atPath: metadataURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }

        let raw = try FileHandle(forWritingTo: rawURL)
        let wav = try FileHandle(forWritingTo: wavURL)
        let metadata = try FileHandle(forWritingTo: metadataURL)
        wav.write(Self.wavHeader(dataBytes: 0, sampleRate: outputSampleRate, channels: outputChannels, bitsPerSample: outputBitsPerSample))

        lock.withLock {
            runDirectory = directory
            rawHandle = raw
            wavHandle = wav
            metadataHandle = metadata
            dataByteCount = 0
            frameCount = 0
            inputMetadata = nil
            started = true
        }
        analysisQueue.sync {
            analysisLock.withLock {
                analysisSamples.removeAll(keepingCapacity: true)
                analysisWindowIndex = 0
                analysisResults.removeAll(keepingCapacity: true)
                latestAnalysisWindow = nil
            }
        }
        return directory
    }

    func append(sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }
        let asbd = asbdPointer.pointee
        let frames = max(0, Int(CMSampleBufferGetNumSamples(sampleBuffer)))
        guard frames > 0 else { return }

        let payload: Data
        do {
            payload = try sampleBuffer.withAudioBufferList { bufferList, _ in
                Self.interleavedInt16(
                    from: bufferList,
                    asbd: asbd,
                    frameCount: frames
                )
            }
        } catch {
            return
        }
        guard !payload.isEmpty else { return }

        let input = Self.metadata(for: asbd)
        let shouldAnalyze = lock.withLock { () -> Bool in
            guard started, let rawHandle, let wavHandle, let metadataHandle else { return false }
            if inputMetadata == nil { inputMetadata = input }
            if let line = Self.metadataJSONLine(sampleBuffer: sampleBuffer, asbd: asbd) {
                metadataHandle.write(line)
            }
            rawHandle.write(payload)
            wavHandle.write(payload)
            dataByteCount += payload.count
            frameCount += payload.count / (outputChannels * MemoryLayout<Int16>.size)
            return true
        }
        if shouldAnalyze {
            analysisQueue.async { [weak self] in
                self?.consumeForToneAnalysis(payload)
            }
        }
    }

    func latestToneWindow() -> Phase2DRetryToneWindow? {
        analysisLock.withLock { latestAnalysisWindow }
    }

    @discardableResult
    func finish() -> URL? {
        // All pending sample-analysis work must finish before the per-second
        // CSV is written and the run directory is finalized.
        analysisQueue.sync { }
        return lock.withLock {
            guard started, let directory = runDirectory else { return runDirectory }
            let raw = rawHandle
            let wav = wavHandle
            let metadataFile = metadataHandle
            let dataBytes = dataByteCount
            let frames = frameCount
            let input = inputMetadata

            if let wav {
                wav.seek(toFileOffset: 0)
                wav.write(Self.wavHeader(
                    dataBytes: dataBytes,
                    sampleRate: outputSampleRate,
                    channels: outputChannels,
                    bitsPerSample: outputBitsPerSample
                ))
                wav.synchronizeFile()
                wav.closeFile()
            }
            raw?.synchronizeFile()
            raw?.closeFile()
            metadataFile?.synchronizeFile()
            metadataFile?.closeFile()

            let metadata = FormatMetadata(input: input, dataBytes: dataBytes, frameCount: frames)
            if let data = try? JSONEncoder.phase2D.encode(metadata) {
                try? data.write(to: directory.appendingPathComponent("format.json"), options: .atomic)
            }
            writeToneWindowsCSV(to: directory)

            rawHandle = nil
            wavHandle = nil
            metadataHandle = nil
            runDirectory = nil
            dataByteCount = 0
            frameCount = 0
            inputMetadata = nil
            started = false
            return directory
        }
    }

    private static func metadataJSONLine(sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> Data? {
        var timingCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        if timingCount > 0 {
            CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: timingCount, arrayToFill: &timings, entriesNeededOut: &timingCount)
        }

        let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: sampleBuffer,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        let sampleAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let extensions = format.flatMap { CMFormatDescriptionGetExtensions($0) }
        var channelLayoutSize = 0
        let channelLayout = format.flatMap {
            CMAudioFormatDescriptionGetChannelLayout($0, sizeOut: &channelLayoutSize)
        }

        let object: [String: Any] = [
            "schemaVersion": 1,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "numSamples": CMSampleBufferGetNumSamples(sampleBuffer),
            "totalSampleSize": CMSampleBufferGetTotalSampleSize(sampleBuffer),
            "isValid": CMSampleBufferIsValid(sampleBuffer),
            "dataReady": CMSampleBufferDataIsReady(sampleBuffer),
            "pts": timeObject(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
            "dts": timeObject(CMSampleBufferGetDecodeTimeStamp(sampleBuffer)),
            "duration": timeObject(CMSampleBufferGetDuration(sampleBuffer)),
            "timing": timings.map { [
                "duration": timeObject($0.duration),
                "presentationTimeStamp": timeObject($0.presentationTimeStamp),
                "decodeTimeStamp": timeObject($0.decodeTimeStamp)
            ] },
            "asbd": [
                "sampleRate": asbd.mSampleRate,
                "formatID": fourCC(asbd.mFormatID),
                "formatFlags": asbd.mFormatFlags,
                "bytesPerPacket": asbd.mBytesPerPacket,
                "framesPerPacket": asbd.mFramesPerPacket,
                "bytesPerFrame": asbd.mBytesPerFrame,
                "channelsPerFrame": asbd.mChannelsPerFrame,
                "bitsPerChannel": asbd.mBitsPerChannel
            ],
            "formatMediaType": format.map { fourCC(CMFormatDescriptionGetMediaType($0)) } ?? "none",
            "formatMediaSubType": format.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "none",
            "formatExtensions": normalize(extensions),
            "bufferAttachments": normalize(attachments),
            "sampleAttachments": normalize(sampleAttachments),
            "channelLayoutSize": channelLayoutSize,
            "channelLayout": channelLayout.map { String(describing: $0.pointee) } ?? "none",
            "blockBuffer": CMSampleBufferGetDataBuffer(sampleBuffer).map { [
                "dataLength": CMBlockBufferGetDataLength($0),
                "typeID": CFGetTypeID($0),
                "typeName": String(describing: CFCopyTypeIDDescription(CFGetTypeID($0)))
            ] } ?? NSNull()
        ]
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func timeObject(_ time: CMTime) -> [String: Any] {
        [
            "value": time.value,
            "timescale": time.timescale,
            "flags": time.flags.rawValue,
            "epoch": time.epoch,
            "seconds": time.isNumeric ? CMTimeGetSeconds(time) : NSNull()
        ]
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08x", value)
    }

    private static func normalize(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                result[String(describing: key)] = normalize(child)
            }
            return result
        }
        if let array = value as? NSArray { return array.map { normalize($0) } }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number }
        if let data = value as? Data { return ["base64": data.base64EncodedString(), "count": data.count] }
        let cfValue = value as CFTypeRef
        let typeID = CFGetTypeID(cfValue)
        return [
            "cfTypeID": typeID,
            "typeName": String(describing: CFCopyTypeIDDescription(typeID)),
            "description": String(describing: value)
        ]
    }

    private func consumeForToneAnalysis(_ payload: Data) {
        let samples: [Float] = payload.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Int16.self)
            guard !values.isEmpty else { return [] }
            var mono = [Float](repeating: 0, count: values.count / outputChannels)
            for frame in 0..<mono.count {
                let left = Float(values[frame * outputChannels]) / Float(Int16.max)
                let right = Float(values[frame * outputChannels + 1]) / Float(Int16.max)
                mono[frame] = (left + right) * 0.5
            }
            return mono
        }
        guard !samples.isEmpty else { return }

        analysisLock.withLock {
            analysisSamples.append(contentsOf: samples)
        }
        while true {
            let window: [Float]? = analysisLock.withLock {
                guard analysisSamples.count >= analysisWindowFrames else { return nil }
                let result = Array(analysisSamples.prefix(analysisWindowFrames))
                analysisSamples.removeFirst(analysisWindowFrames)
                return result
            }
            guard let window else { return }
            let result = analyzeToneWindow(window)
            analysisLock.withLock {
                analysisWindowIndex += 1
                let indexed = Phase2DRetryToneWindow(
                    index: analysisWindowIndex,
                    startSeconds: Double(analysisWindowIndex - 1),
                    endSeconds: Double(analysisWindowIndex),
                    tone440DBFS: result.tone440DBFS,
                    tone440SNRDB: result.tone440SNRDB,
                    tone997DBFS: result.tone997DBFS,
                    tone997SNRDB: result.tone997SNRDB,
                    rmsDBFS: result.rmsDBFS,
                    peakDBFS: result.peakDBFS
                )
                analysisResults.append(indexed)
                latestAnalysisWindow = indexed
            }
        }
    }

    private func analyzeToneWindow(_ samples: [Float]) -> (tone440DBFS: Double, tone440SNRDB: Double, tone997DBFS: Double, tone997SNRDB: Double, rmsDBFS: Double, peakDBFS: Double) {
        let count = samples.count
        guard count > 0 else {
            return (-160, -160, -160, -160, -160, -160)
        }

        var sumSquares = 0.0
        var peak = 0.0
        var cos440 = [Double](repeating: 0.0, count: retryToneFrequencyOffsets.count)
        var sin440 = [Double](repeating: 0.0, count: retryToneFrequencyOffsets.count)
        var cos997 = [Double](repeating: 0.0, count: retryToneFrequencyOffsets.count)
        var sin997 = [Double](repeating: 0.0, count: retryToneFrequencyOffsets.count)
        let sampleRate = Double(outputSampleRate)
        let twoPi = 2.0 * Double.pi

        for index in 0..<count {
            let sample = Double(samples[index])
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
            let position = Double(index)
            for (offsetIndex, offset) in retryToneFrequencyOffsets.enumerated() {
                let phase440 = twoPi * (retryToneFrequencies.tone440 + offset) * position / sampleRate
                let phase997 = twoPi * (retryToneFrequencies.tone997 + offset) * position / sampleRate
                cos440[offsetIndex] += sample * cos(phase440)
                sin440[offsetIndex] += sample * sin(phase440)
                cos997[offsetIndex] += sample * cos(phase997)
                sin997[offsetIndex] += sample * sin(phase997)
            }
        }

        let rms = sqrt(sumSquares / Double(count))
        func toneRMS(cosines: [Double], sines: [Double]) -> Double {
            let magnitude = zip(cosines, sines)
                .map { sqrt($0 * $0 + $1 * $1) }
                .max() ?? 0.0
            return (2.0 * magnitude / Double(count)) / sqrt(2.0)
        }
        let tone440RMS = toneRMS(cosines: cos440, sines: sin440)
        let tone997RMS = toneRMS(cosines: cos997, sines: sin997)
        let residualPower = max(1.0e-12, rms * rms - tone440RMS * tone440RMS - tone997RMS * tone997RMS)

        func dbfs(_ value: Double) -> Double {
            guard value.isFinite, value > 0 else { return -160.0 }
            return max(-160.0, 20.0 * log10(value))
        }
        func snr(_ toneRMS: Double) -> Double {
            guard toneRMS > 0 else { return -160.0 }
            return 10.0 * log10(max(1.0e-12, toneRMS * toneRMS) / residualPower)
        }

        return (
            dbfs(tone440RMS),
            snr(tone440RMS),
            dbfs(tone997RMS),
            snr(tone997RMS),
            dbfs(rms),
            dbfs(peak)
        )
    }

    private func writeToneWindowsCSV(to directory: URL) {
        let results = analysisLock.withLock { analysisResults }
        var text = "second_index,window_start_s,window_end_s,tone_440_dbfs,tone_440_snr_db,tone_997_dbfs,tone_997_snr_db,rms_dbfs,peak_dbfs,dual_verified\n"
        for window in results {
            text += String(
                format: "%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%@\n",
                window.index,
                window.startSeconds,
                window.endSeconds,
                window.tone440DBFS,
                window.tone440SNRDB,
                window.tone997DBFS,
                window.tone997SNRDB,
                window.rmsDBFS,
                window.peakDBFS,
                window.isDual ? "true" : "false"
            )
        }
        try? text.data(using: .utf8)?.write(
            to: directory.appendingPathComponent("tone-windows.csv"),
            options: .atomic
        )
    }

    private static func metadata(for asbd: AudioStreamBasicDescription) -> InputMetadata {
        let flags = asbd.mFormatFlags
        let isFloat = (flags & floatFlag) != 0
        let isSignedInteger = (flags & signedIntegerFlag) != 0
        let sampleFormat: String
        if isFloat {
            sampleFormat = "Float\(asbd.mBitsPerChannel)"
        } else if isSignedInteger {
            sampleFormat = "Int\(asbd.mBitsPerChannel)"
        } else {
            sampleFormat = "unknown"
        }
        return InputMetadata(
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            sampleFormat: sampleFormat,
            interleaved: (flags & nonInterleavedFlag) == 0,
            bytesPerFrame: Int(asbd.mBytesPerFrame),
            formatFlags: flags
        )
    }

    private static func interleavedInt16(
        from bufferList: UnsafeMutableAudioBufferListPointer,
        asbd: AudioStreamBasicDescription,
        frameCount: Int
    ) -> Data {
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isPlanar = (asbd.mFormatFlags & nonInterleavedFlag) != 0 || bufferList.count >= channels
        let bytesPerSample: Int
        if isPlanar {
            bytesPerSample = max(1, Int(asbd.mBytesPerFrame))
        } else {
            bytesPerSample = max(1, Int(asbd.mBytesPerFrame) / channels)
        }
        let bufferFrameCounts = bufferList.map { buffer -> Int in
            guard bytesPerSample > 0 else { return 0 }
            let bytesPerFrame = isPlanar ? bytesPerSample : bytesPerSample * channels
            return Int(buffer.mDataByteSize) / max(1, bytesPerFrame)
        }
        var output = Data(capacity: frameCount * 2 * MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let left = sample(
                frame: frame,
                channel: 0,
                channels: channels,
                bytesPerSample: bytesPerSample,
                isPlanar: isPlanar,
                asbdFlags: asbd.mFormatFlags,
                bufferList: bufferList,
                availableFrames: bufferFrameCounts
            )
            let right = channels > 1 ? sample(
                frame: frame,
                channel: 1,
                channels: channels,
                bytesPerSample: bytesPerSample,
                isPlanar: isPlanar,
                asbdFlags: asbd.mFormatFlags,
                bufferList: bufferList,
                availableFrames: bufferFrameCounts
            ) : left
            appendInt16(left, to: &output)
            appendInt16(right, to: &output)
        }
        return output
    }

    private static func sample(
        frame: Int,
        channel: Int,
        channels: Int,
        bytesPerSample: Int,
        isPlanar: Bool,
        asbdFlags: UInt32,
        bufferList: UnsafeMutableAudioBufferListPointer,
        availableFrames: [Int]
    ) -> Float {
        let bufferIndex = isPlanar ? min(channel, max(0, bufferList.count - 1)) : 0
        guard bufferIndex < bufferList.count,
              frame < availableFrames[bufferIndex],
              let data = bufferList[bufferIndex].mData else { return 0 }
        let byteOffset = isPlanar
            ? frame * bytesPerSample
            : (frame * channels + channel) * bytesPerSample
        let pointer = data.advanced(by: byteOffset)
        return normalizedSample(at: pointer, bytesPerSample: bytesPerSample, asbdFlags: asbdFlags)
    }

    private static func normalizedSample(at pointer: UnsafeMutableRawPointer, bytesPerSample: Int, asbdFlags: UInt32) -> Float {
        if (asbdFlags & floatFlag) != 0 {
            if bytesPerSample >= MemoryLayout<Float>.size {
                var value: Float = 0
                memcpy(&value, pointer, MemoryLayout<Float>.size)
                return value.isFinite ? max(-1, min(1, value)) : 0
            }
            return 0
        }
        if (asbdFlags & signedIntegerFlag) != 0 {
            switch bytesPerSample {
            case 2:
                var value: Int16 = 0
                memcpy(&value, pointer, MemoryLayout<Int16>.size)
                return Float(value) / Float(Int16.max)
            case 4:
                var value: Int32 = 0
                memcpy(&value, pointer, MemoryLayout<Int32>.size)
                return Float(value) / Float(Int32.max)
            default:
                return 0
            }
        }
        return 0
    }

    private static func appendInt16(_ value: Float, to data: inout Data) {
        let clipped = max(-1, min(1, value))
        let scaled = clipped >= 0
            ? clipped * Float(Int16.max)
            : clipped * (-Float(Int16.min))
        let bounded = max(Int(Int16.min), min(Int(Int16.max), Int(scaled.rounded())))
        let integer = Int16(bounded)
        var littleEndian = UInt16(bitPattern: integer).littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func wavHeader(dataBytes: Int, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let riffSize = 36 + dataBytes
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendUInt32LE(UInt32(clamping: riffSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.appendUInt32LE(16)
        header.appendUInt16LE(1)
        header.appendUInt16LE(UInt16(clamping: channels))
        header.appendUInt32LE(UInt32(clamping: sampleRate))
        header.appendUInt32LE(UInt32(clamping: byteRate))
        header.appendUInt16LE(UInt16(clamping: blockAlign))
        header.appendUInt16LE(UInt16(clamping: bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.appendUInt32LE(UInt32(clamping: dataBytes))
        return header
    }
}

private extension JSONEncoder {
    static var phase2D: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
#endif
