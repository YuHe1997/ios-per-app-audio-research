import Foundation
import Darwin

struct CaptureLogEntry: Sendable {
    let timestamp: Date
    let monotonicNanoseconds: UInt64
    let event: String
    let metrics: AudioMetrics?
    let message: String?
}

/// Thread-safe raw-session logger. It deliberately keeps one row per audio
/// buffer so the exported file can be analyzed outside the app.
final class CaptureLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CaptureLogEntry] = []

    func startSession() {
        lock.withLock {
            entries.removeAll(keepingCapacity: true)
            entries.append(CaptureLogEntry(timestamp: Date(), monotonicNanoseconds: Self.monotonicNanoseconds(), event: "session_started", metrics: nil, message: nil))
        }
    }

    func append(event: String, message: String? = nil) {
        lock.withLock {
            entries.append(CaptureLogEntry(timestamp: Date(), monotonicNanoseconds: Self.monotonicNanoseconds(), event: event, metrics: nil, message: message))
        }
    }

    func append(metrics: AudioMetrics) {
        lock.withLock {
            entries.append(CaptureLogEntry(timestamp: metrics.capturedAt, monotonicNanoseconds: metrics.callbackMonotonicNanoseconds, event: "audio_buffer", metrics: metrics, message: nil))
        }
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    func exportCSV(to directory: URL? = nil) throws -> URL {
        let outputDirectory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return try exportCSV(
            to: outputDirectory,
            fileName: "PerAppAudioLab-\(stamp).csv"
        )
    }

    /// Writes the Phase 2D bundle without changing the original Phase 2C
    /// export contract. `capture.csv` preserves every logger entry;
    /// `metrics.csv` contains only per-buffer rows; `events.csv` contains the
    /// lifecycle events that can be aligned with the WAV timeline.
    @discardableResult
    func exportPhase2DBundle(to directory: URL) throws -> URL {
        let snapshot = lock.withLock { entries }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try exportCSV(to: directory, fileName: "capture.csv", snapshot: snapshot)
        try exportMetricsCSV(to: directory.appendingPathComponent("metrics.csv"), snapshot: snapshot)
        try exportEventsCSV(to: directory.appendingPathComponent("events.csv"), snapshot: snapshot)
        try writeRunSummary(to: directory.appendingPathComponent("run-summary.md"), snapshot: snapshot)
        return directory
    }

    private func exportCSV(to directory: URL, fileName: String) throws -> URL {
        let snapshot = lock.withLock { entries }
        return try exportCSV(to: directory, fileName: fileName, snapshot: snapshot)
    }

    private func exportCSV(to directory: URL, fileName: String, snapshot: [CaptureLogEntry]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let url = directory.appendingPathComponent(fileName)
        var csv = Self.metricsHeader
        for entry in snapshot {
            csv += Self.csvLine(for: entry, formatter: formatter)
        }
        try Self.writeUTF8(csv, to: url)
        return url
    }

    private func exportMetricsCSV(to url: URL, snapshot: [CaptureLogEntry]) throws {
        let formatter = ISO8601DateFormatter()
        var csv = Self.metricsHeader
        for entry in snapshot where entry.metrics != nil {
            csv += Self.csvLine(for: entry, formatter: formatter)
        }
        try Self.writeUTF8(csv, to: url)
    }

    private func exportEventsCSV(to url: URL, snapshot: [CaptureLogEntry]) throws {
        let formatter = ISO8601DateFormatter()
        var csv = "event_id,timestamp,monotonic_ns,monotonic_seconds,description,foreground_app\n"
        for (index, entry) in snapshot.enumerated() where entry.metrics == nil {
            let description = entry.message.map { "\(entry.event): \($0)" } ?? entry.event
            let fields = [
                "event-\(index + 1)",
                formatter.string(from: entry.timestamp),
                String(entry.monotonicNanoseconds),
                String(format: "%.9f", Double(entry.monotonicNanoseconds) / 1_000_000_000.0),
                description,
                ""
            ]
            csv += fields.map(Self.escapeCSV).joined(separator: ",") + "\n"
        }
        try Self.writeUTF8(csv, to: url)
    }

    private func writeRunSummary(to url: URL, snapshot: [CaptureLogEntry]) throws {
        let formatter = ISO8601DateFormatter()
        let audioEntries = snapshot.compactMap { $0.metrics }
        let first = snapshot.first.map { formatter.string(from: $0.timestamp) } ?? ""
        let last = snapshot.last.map { formatter.string(from: $0.timestamp) } ?? ""
        var counts: [String: Int] = [:]
        for entry in snapshot { counts[entry.event, default: 0] += 1 }
        let countText = counts.keys.sorted().map { "- \($0): \(counts[$0] ?? 0)" }.joined(separator: "\n")
        let summary = """
        # Phase 2D-Retry capture bundle

        - First logger event: `\(first)`
        - Last logger event: `\(last)`
        - Audio buffer rows: \(audioEntries.count)
        - PCM artifacts: `capture.raw`, `capture.wav`, `format.json`, `tone-windows.csv`

        ## Event counts

        \(countText)

        The current recorder stores scalar metrics and PCM artifacts. Source
        identity is supplied by the automation event timeline, not by the
        ScreenCaptureKit sample buffer.
        """
        try Self.writeUTF8(summary, to: url)
    }

    private static let metricsHeader = "timestamp,monotonic_ns,monotonic_seconds,event,sequence_number,pts_seconds,duration_seconds,sample_count,sample_rate,channel_count,rms_dbfs,peak_dbfs,inter_buffer_delta_seconds,message\n"

    private static func csvLine(for entry: CaptureLogEntry, formatter: ISO8601DateFormatter) -> String {
        let metrics = entry.metrics
        let fields: [String] = [
            formatter.string(from: entry.timestamp),
            String(entry.monotonicNanoseconds),
            String(format: "%.9f", Double(entry.monotonicNanoseconds) / 1_000_000_000.0),
            entry.event,
            metrics.map { String($0.sequenceNumber) } ?? "",
            metrics.map { Self.numberString($0.ptsSeconds) } ?? "",
            metrics.map { Self.numberString($0.durationSeconds) } ?? "",
            metrics.map { String($0.sampleCount) } ?? "",
            metrics.map { String($0.sampleRate) } ?? "",
            metrics.map { String($0.channelCount) } ?? "",
            metrics.map { String($0.rmsDBFS) } ?? "",
            metrics.map { String($0.peakDBFS) } ?? "",
            metrics.map { Self.numberString($0.interBufferDeltaSeconds) } ?? "",
            entry.message ?? ""
        ]
        return fields.map(Self.escapeCSV).joined(separator: ",") + "\n"
    }

    private static func writeUTF8(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func numberString(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func monotonicNanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        return ticks.multipliedReportingOverflow(by: UInt64(info.numer)).partialValue / UInt64(info.denom)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
