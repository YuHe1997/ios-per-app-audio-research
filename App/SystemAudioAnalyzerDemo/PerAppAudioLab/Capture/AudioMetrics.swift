import AVFAudio
import CoreMedia
import Foundation
import Darwin

/// Sendable values extracted from one ScreenCaptureKit audio sample buffer.
/// The CMSampleBuffer itself never crosses the callback queue boundary.
struct AudioBufferSnapshot: Sendable {
    let capturedAt: Date
    let callbackMonotonicNanoseconds: UInt64
    let ptsSeconds: Double?
    let durationSeconds: Double?
    let sampleCount: Int
    let sampleRate: Double
    let channelCount: Int
    let rmsDBFS: Double
    let peakDBFS: Double
}

/// One raw audio sample-buffer measurement. Values are intentionally kept
/// lossless enough for later CSV export and offline analysis.
struct AudioMetrics: Codable, Identifiable, Sendable {
    let sequenceNumber: UInt64
    let capturedAt: Date
    let callbackMonotonicNanoseconds: UInt64
    let ptsSeconds: Double?
    let durationSeconds: Double?
    let sampleCount: Int
    let sampleRate: Double
    let channelCount: Int
    let rmsDBFS: Double
    let peakDBFS: Double
    let interBufferDeltaSeconds: Double?

    var id: UInt64 { sequenceNumber }

    init(
        sequenceNumber: UInt64,
        capturedAt: Date = Date(),
        callbackMonotonicNanoseconds: UInt64,
        ptsSeconds: Double?,
        durationSeconds: Double?,
        sampleCount: Int,
        sampleRate: Double,
        channelCount: Int,
        rmsDBFS: Double,
        peakDBFS: Double,
        interBufferDeltaSeconds: Double?
    ) {
        self.sequenceNumber = sequenceNumber
        self.capturedAt = capturedAt
        self.callbackMonotonicNanoseconds = callbackMonotonicNanoseconds
        self.ptsSeconds = ptsSeconds
        self.durationSeconds = durationSeconds
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
        self.interBufferDeltaSeconds = interBufferDeltaSeconds
    }

#if canImport(ScreenCaptureKit)
    /// Builds a measurement from an SCK audio CMSampleBuffer.
    ///
    /// ScreenCaptureKit's audio output is expected to be non-interleaved or
    /// interleaved Float32 PCM. If the buffer is not readable as Float32, the
    /// timing/format fields are still retained and RMS/peak are reported as
    /// `-120 dBFS` rather than guessing at a sample format.
    init(sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64, previousPTS: Double?) {
        let snapshot = Self.snapshot(sampleBuffer: sampleBuffer)
        let delta: Double?
        if let ptsSeconds = snapshot.ptsSeconds, let previousPTS {
            delta = ptsSeconds - previousPTS
        } else {
            delta = nil
        }

        self.init(
            sequenceNumber: sequenceNumber,
            capturedAt: snapshot.capturedAt,
            callbackMonotonicNanoseconds: snapshot.callbackMonotonicNanoseconds,
            ptsSeconds: snapshot.ptsSeconds,
            durationSeconds: snapshot.durationSeconds,
            sampleCount: snapshot.sampleCount,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount,
            rmsDBFS: snapshot.rmsDBFS,
            peakDBFS: snapshot.peakDBFS,
            interBufferDeltaSeconds: delta
        )
    }

    /// Converts the non-Sendable CMSampleBuffer into scalar values while it
    /// is still on ScreenCaptureKit's sample-handler queue.
    static func snapshot(sampleBuffer: CMSampleBuffer) -> AudioBufferSnapshot {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        let callbackNS = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(timebase.denom)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let ptsSeconds = pts.isNumeric ? pts.seconds : nil
        let durationSeconds = duration.isNumeric ? duration.seconds : nil
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)

        var sampleRate = 0.0
        var channelCount = 0
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
            sampleRate = asbd.mSampleRate
            channelCount = Int(asbd.mChannelsPerFrame)
        }

        let stats = Self.float32Statistics(in: sampleBuffer)
        return AudioBufferSnapshot(
            capturedAt: Date(),
            callbackMonotonicNanoseconds: callbackNS,
            ptsSeconds: ptsSeconds,
            durationSeconds: durationSeconds,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            channelCount: channelCount,
            rmsDBFS: Self.dbfs(stats.rms),
            peakDBFS: Self.dbfs(stats.peak)
        )
    }

    private static func float32Statistics(in sampleBuffer: CMSampleBuffer) -> (rms: Double, peak: Double) {
        do {
            return try sampleBuffer.withAudioBufferList { bufferList, _ in
                var sumSquares = 0.0
                var peak = 0.0
                var count = 0

                for buffer in bufferList {
                    guard let data = buffer.mData else { continue }
                    let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for index in 0..<floatCount {
                        let sample = Double(samples[index])
                        sumSquares += sample * sample
                        peak = max(peak, abs(sample))
                    }
                    count += floatCount
                }

                guard count > 0 else { return (0, 0) }
                return (sqrt(sumSquares / Double(count)), peak)
            }
        } catch {
            return (0, 0)
        }
    }

    private static func dbfs(_ linear: Double) -> Double {
        guard linear.isFinite, linear > 0 else { return -120 }
        return max(-120, 20 * log10(linear))
    }
#endif
}
