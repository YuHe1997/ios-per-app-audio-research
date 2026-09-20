#!/usr/bin/env python3
"""Offline Phase 2D PCM/WAV and event-timeline analysis.

The device recorder emits signed 16-bit little-endian stereo WAV. This tool
keeps the original files untouched, adds automation-events.csv from the
XCTest log, and writes FFT summaries for the T4--T5 measurement interval.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import wave
from datetime import datetime, timezone
from pathlib import Path

import numpy as np


MARKER_RE = re.compile(r"PHASE2D_MARKER\s+(\S+)\s+(.*)$")
SOURCE_RE = re.compile(r"PHASE2D_SOURCE_ACTION\s+(.*)$")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def csv_escape(value: str) -> str:
    if any(ch in value for ch in (",", '"', "\n")):
        return '"' + value.replace('"', '""') + '"'
    return value


def foreground_for(description: str) -> str:
    lowered = description.lower()
    if "youtube" in lowered:
        return "com.google.ios.youtube"
    if "probe" in lowered or "source b" in lowered or "880 hz" in lowered:
        return "com.example.AudioProbeSource"
    if "source a" in lowered or "440 hz" in lowered:
        return "com.google.ios.youtube"
    if "capture" in lowered or "stop" in lowered:
        return "com.example.PerAppAudioLab"
    return ""


def parse_automation_events(log_path: Path) -> list[dict[str, str]]:
    events: list[dict[str, str]] = []
    if not log_path.exists():
        return events
    with log_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            marker = MARKER_RE.search(line)
            if marker:
                timestamp, description = marker.groups()
                events.append(
                    {
                        "timestamp": timestamp,
                        "description": description,
                        "foreground_app": foreground_for(description),
                    }
                )
                continue
            source = SOURCE_RE.search(line)
            if source:
                events.append(
                    {
                        "timestamp": "",
                        "description": source.group(1),
                        "foreground_app": "com.example.AudioProbeSource",
                    }
                )
    for index, event in enumerate(events, start=1):
        event["event_id"] = f"automation-{index:02d}"
    # The source-stop print in the current UI test predates the timestamped
    # marker helper. Keep the event in the timeline by assigning it the next
    # explicit stop/end marker rather than leaving a blank timestamp.
    for index, event in enumerate(events):
        if event["timestamp"]:
            continue
        for following in events[index + 1 :]:
            if following["timestamp"]:
                event["timestamp"] = following["timestamp"]
                break
        if not event["timestamp"] and events:
            event["timestamp"] = events[-1]["timestamp"]
    return events


def read_logger_times(run_dir: Path) -> dict[str, datetime]:
    times: dict[str, datetime] = {}
    capture_csv = run_dir / "capture.csv"
    if not capture_csv.exists():
        return times
    with capture_csv.open("r", encoding="utf-8", errors="replace", newline="") as handle:
        for row in csv.DictReader(handle):
            event = row.get("event", "")
            timestamp = row.get("timestamp", "")
            if event and timestamp:
                try:
                    times.setdefault(event, parse_time(timestamp))
                except ValueError:
                    pass
    return times


def write_automation_events(run_dir: Path, events: list[dict[str, str]]) -> None:
    output = run_dir / "automation-events.csv"
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["event_id", "timestamp", "description", "foreground_app"],
        )
        writer.writeheader()
        writer.writerows(events)


def event_window(events: list[dict[str, str]], logger_times: dict[str, datetime], duration: float) -> tuple[float, float]:
    stream_start = logger_times.get("stream_started") or logger_times.get("session_started")
    t4 = next((e for e in events if "T4 measurement start" in e["description"]), None)
    t5 = next((e for e in events if "T5 measurement end" in e["description"]), None)
    if stream_start and t4 and t5 and t4["timestamp"] and t5["timestamp"]:
        try:
            start = (parse_time(t4["timestamp"]) - stream_start).total_seconds()
            end = (parse_time(t5["timestamp"]) - stream_start).total_seconds()
            start = max(0.0, min(duration, start))
            end = max(start, min(duration, end))
            if end - start >= 1.0:
                return start, end
        except ValueError:
            pass
    return 0.0, duration


def dbfs(value: float, floor: float = -160.0) -> float:
    if not math.isfinite(value) or value <= 10 ** (floor / 20.0):
        return floor
    return 20.0 * math.log10(value)


def analyze_wav(
    run_dir: Path,
    log_path: Path,
    kind: str,
    start_override: float | None = None,
    end_override: float | None = None,
    prefix: str = "",
) -> dict:
    wav_path = run_dir / "capture.wav"
    with wave.open(str(wav_path), "rb") as source:
        channels = source.getnchannels()
        sample_rate = source.getframerate()
        frame_count = source.getnframes()
        sample_width = source.getsampwidth()
        frames = source.readframes(frame_count)

    if sample_width != 2 or channels < 1:
        raise RuntimeError(f"expected Int16 WAV, got width={sample_width}, channels={channels}")
    samples = np.frombuffer(frames, dtype="<i2").reshape(-1, channels).astype(np.float32) / 32768.0
    duration = len(samples) / float(sample_rate)

    events = parse_automation_events(log_path)
    write_automation_events(run_dir, events)
    logger_times = read_logger_times(run_dir)
    analysis_start, analysis_end = event_window(events, logger_times, duration)
    if start_override is not None:
        analysis_start = max(0.0, min(duration, start_override))
    if end_override is not None:
        analysis_end = max(analysis_start, min(duration, end_override))

    fft_size = 65_536
    hop = 32_768
    start_frame = int(analysis_start * sample_rate)
    end_frame = min(len(samples), int(analysis_end * sample_rate))
    segment = samples[start_frame:end_frame]
    if len(segment) < fft_size:
        segment = samples
        start_frame = 0
        analysis_start = 0.0
        analysis_end = duration

    window = np.hanning(fft_size).astype(np.float32)
    window_sum = float(window.sum())
    frequencies = np.fft.rfftfreq(fft_size, 1.0 / sample_rate)
    target_rows: list[dict] = []
    target_values: dict[str, list[float]] = {"440": [], "880": []}
    channel_target_values: dict[str, dict[str, list[float]]] = {
        str(channel): {"440": [], "880": []} for channel in range(channels)
    }
    noise_values: list[float] = []
    channel_noise_values: dict[str, list[float]] = {str(channel): [] for channel in range(channels)}
    rms_values: list[float] = []
    peak_values: list[float] = []

    if len(segment) < fft_size:
        starts = [0]
        padded = np.zeros((fft_size, channels), dtype=np.float32)
        padded[: len(segment)] = segment
        chunks = [padded]
    else:
        starts = list(range(0, len(segment) - fft_size + 1, hop))
        chunks = [segment[offset : offset + fft_size] for offset in starts]

    for offset, chunk in zip(starts, chunks):
        absolute_start = (start_frame + offset) / float(sample_rate)
        for channel in range(channels):
            signal = chunk[:, channel]
            rms_values.append(float(np.sqrt(np.mean(signal * signal))))
            peak_values.append(float(np.max(np.abs(signal))))
            spectrum = np.abs(np.fft.rfft(signal * window))
            normalized = 2.0 * spectrum / max(window_sum, 1.0)
            row = {
                "window_start_s": f"{absolute_start:.6f}",
                "channel": str(channel),
                "rms_dbfs": f"{dbfs(rms_values[-1]):.3f}",
                "peak_dbfs": f"{dbfs(peak_values[-1]):.3f}",
            }
            for frequency in (440, 880):
                mask = np.abs(frequencies - frequency) <= 5.0
                amplitude = float(np.sqrt(np.sum(np.square(normalized[mask]))))
                value = dbfs(amplitude / math.sqrt(2.0))
                target_values[str(frequency)].append(value)
                channel_target_values[str(channel)][str(frequency)].append(value)
                row[f"tone_{frequency}_dbfs"] = f"{value:.3f}"
            excluded = (np.abs(frequencies - 440) > 8.0) & (np.abs(frequencies - 880) > 8.0)
            noise_amplitude = float(np.median(normalized[excluded]))
            noise_dbfs = dbfs(noise_amplitude / math.sqrt(2.0))
            noise_values.append(noise_dbfs)
            channel_noise_values[str(channel)].append(noise_dbfs)
            row["noise_floor_dbfs"] = f"{noise_dbfs:.3f}"
            dominant_index = int(np.argmax(normalized[1:]) + 1)
            row["dominant_frequency_hz"] = f"{frequencies[dominant_index]:.3f}"
            row["dominant_dbfs"] = f"{dbfs(float(normalized[dominant_index]) / math.sqrt(2.0)):.3f}"
            target_rows.append(row)

    spectrum_path = run_dir / f"{prefix}spectrum.csv"
    fields = [
        "window_start_s", "channel", "rms_dbfs", "peak_dbfs",
        "tone_440_dbfs", "tone_880_dbfs", "noise_floor_dbfs",
        "dominant_frequency_hz", "dominant_dbfs",
    ]
    with spectrum_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(target_rows)

    def summarize(values: list[float]) -> dict:
        if not values:
            return {"median_dbfs": -160.0, "max_dbfs": -160.0, "detected": False}
        median = float(np.median(values))
        maximum = float(np.max(values))
        return {
            "median_dbfs": round(median, 3),
            "max_dbfs": round(maximum, 3),
            "detected": bool(median > -70.0 and sum(v > -80.0 for v in values) >= max(1, len(values) // 4)),
        }

    target_summary = {"440_hz": summarize(target_values["440"]), "880_hz": summarize(target_values["880"])}
    noise_median = float(np.median(noise_values)) if noise_values else -160.0
    for key, values in (("440_hz", target_values["440"]), ("880_hz", target_values["880"])):
        target_summary[key]["snr_db"] = round(float(np.median(values)) - noise_median, 3) if values else -160.0
    target_summary["relative_880_minus_440_db"] = round(
        target_summary["880_hz"]["median_dbfs"] - target_summary["440_hz"]["median_dbfs"], 3
    )

    per_channel = {}
    for channel in range(channels):
        channel_key = str(channel)
        channel_noise = float(np.median(channel_noise_values[channel_key])) if channel_noise_values[channel_key] else -160.0
        channel_summary = {
            "noise_floor_dbfs": round(channel_noise, 3),
            "440_hz": summarize(channel_target_values[channel_key]["440"]),
            "880_hz": summarize(channel_target_values[channel_key]["880"]),
        }
        channel_summary["440_hz"]["snr_db"] = round(channel_summary["440_hz"]["median_dbfs"] - channel_noise, 3)
        channel_summary["880_hz"]["snr_db"] = round(channel_summary["880_hz"]["median_dbfs"] - channel_noise, 3)
        per_channel[channel_key] = channel_summary

    summary = {
        "schema_version": 1,
        "run": run_dir.name,
        "kind": kind,
        "wav": "capture.wav",
        "raw": "capture.raw",
        "sample_rate": sample_rate,
        "channels": channels,
        "frame_count": int(frame_count),
        "duration_seconds": round(duration, 6),
        "analysis_start_seconds": round(analysis_start, 6),
        "analysis_end_seconds": round(analysis_end, 6),
        "analysis_window_seconds": round(max(0.0, analysis_end - analysis_start), 6),
        "fft_size": fft_size,
        "target_frequencies": target_summary,
        "per_channel": per_channel,
        "rms_dbfs": round(dbfs(float(np.median(rms_values))) if rms_values else -160.0, 3),
        "peak_dbfs": round(dbfs(float(np.max(peak_values))) if peak_values else -160.0, 3),
        "noise_floor_dbfs": round(float(np.median(noise_values)) if noise_values else -160.0, 3),
        "automation_events": "automation-events.csv",
        "spectrum": f"{prefix}spectrum.csv",
    }
    with (run_dir / f"{prefix}fft-summary.json").open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")

    with (run_dir / f"{prefix}fft-summary.md").open("w", encoding="utf-8") as handle:
        handle.write(f"# Phase 2D FFT summary — {run_dir.name}\n\n")
        handle.write(f"- Kind: `{kind}`\n")
        handle.write(f"- WAV: {sample_rate} Hz, {channels} ch, {duration:.3f} s\n")
        handle.write(f"- Analysis window: {analysis_start:.3f}–{analysis_end:.3f} s from WAV start\n")
        handle.write(f"- RMS / peak: {summary['rms_dbfs']:.3f} / {summary['peak_dbfs']:.3f} dBFS\n")
        handle.write(f"- Noise floor estimate: {summary['noise_floor_dbfs']:.3f} dBFS\n\n")
        handle.write("| Target | Median | Max | Detected by conservative threshold |\n")
        handle.write("|---:|---:|---:|:---:|\n")
        for label, key in (("440 Hz", "440_hz"), ("880 Hz", "880_hz")):
            value = summary["target_frequencies"][key]
            handle.write(f"| {label} | {value['median_dbfs']:.3f} dBFS | {value['max_dbfs']:.3f} dBFS | {value['detected']} |\n")
        handle.write("\nRaw files are retained beside this summary; `automation-events.csv` aligns XCTest markers to the WAV timeline.\n")

    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--kind", required=True)
    parser.add_argument("--start", type=float)
    parser.add_argument("--end", type=float)
    parser.add_argument("--prefix", default="")
    args = parser.parse_args()
    summary = analyze_wav(args.run, args.log, args.kind, args.start, args.end, args.prefix)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
