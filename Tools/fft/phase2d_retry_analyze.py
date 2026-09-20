#!/usr/bin/env python3
"""Strict Phase 2D-Retry one-second PCM analysis.

The retry gate uses a non-harmonic 997 Hz probe.  This tool keeps the WAV
untouched, writes a timestamped automation timeline, computes one-second
mono-average tone windows, and emits the exact precheck/background/measurement
counts used by the report.
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


MARKER_RE = re.compile(r"PHASE2D_RETRY_MARKER\s+(\S+)\s+(.*)$")
SOURCE_RE = re.compile(r"PHASE2D_RETRY_SOURCE_ACTION\s+(.*)$")
SNR_RE = re.compile(r"SNR\s+(-?\d+(?:\.\d+)?)")
TONE_FREQUENCY_OFFSETS = (-0.2, -0.1, 0.0, 0.1, 0.2)


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def dbfs(value: float, floor: float = -160.0) -> float:
    if not math.isfinite(value) or value <= 0:
        return floor
    return max(floor, 20.0 * math.log10(value))


def parse_events(log_path: Path) -> list[dict[str, str]]:
    events: list[dict[str, str]] = []
    if log_path.exists():
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            marker = MARKER_RE.search(line)
            if marker:
                timestamp, description = marker.groups()
                events.append({"timestamp": timestamp, "description": description, "foreground_app": foreground_for(description)})
                continue
            source = SOURCE_RE.search(line)
            if source:
                events.append({"timestamp": "", "description": source.group(1), "foreground_app": "com.example.AudioProbeSource"})
    for index, event in enumerate(events, 1):
        event["event_id"] = f"automation-{index:02d}"
    # The source-stop line is emitted after the timestamped stop marker helper
    # was introduced. Preserve it and align it to the next explicit marker.
    for index, event in enumerate(events):
        if event["timestamp"]:
            continue
        following = next((item for item in events[index + 1 :] if item["timestamp"]), None)
        event["timestamp"] = following["timestamp"] if following else (events[-1]["timestamp"] if events else "")
    return events


def foreground_for(description: str) -> str:
    lowered = description.lower()
    if "youtube" in lowered or "440 hz" in lowered:
        return "com.google.ios.youtube"
    if "probe" in lowered or "997 hz" in lowered:
        return "com.example.AudioProbeSource"
    if "perappaudiolab" in lowered or "capture" in lowered:
        return "com.example.PerAppAudioLab"
    return ""


def write_events(run_dir: Path, events: list[dict[str, str]]) -> None:
    path = run_dir / "automation-events.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["event_id", "timestamp", "description", "foreground_app"])
        writer.writeheader()
        writer.writerows(events)


def logger_times(run_dir: Path) -> dict[str, datetime]:
    result: dict[str, datetime] = {}
    path = run_dir / "capture.csv"
    if not path.exists():
        return result
    with path.open("r", encoding="utf-8", errors="replace", newline="") as handle:
        for row in csv.DictReader(handle):
            event = row.get("event", "")
            stamp = row.get("timestamp", "")
            if event and stamp:
                try:
                    result.setdefault(event, parse_time(stamp))
                except ValueError:
                    pass
    return result


def marker_seconds(events: list[dict[str, str]], stream_start: datetime, text: str) -> float | None:
    event = next((item for item in events if text.lower() in item["description"].lower()), None)
    if not event or not event["timestamp"]:
        return None
    try:
        return (parse_time(event["timestamp"]) - stream_start).total_seconds()
    except ValueError:
        return None


def has_marker(events: list[dict[str, str]], text: str) -> bool:
    lowered = text.lower()
    return any(lowered in item["description"].lower() for item in events)


def interval_from_markers(
    events: list[dict[str, str]],
    stream_start: datetime,
    start_text: str,
    end_text: str,
    duration: float,
) -> dict[str, float | None]:
    start = marker_seconds(events, stream_start, start_text)
    end = marker_seconds(events, stream_start, end_text)
    if start is not None:
        start = max(0.0, min(duration, start))
    if end is not None:
        end = max(0.0, min(duration, end))
    if start is not None and end is not None and end < start:
        start, end = end, start
    return {"start_seconds": start, "end_seconds": end}


def analyze_window(
    samples: np.ndarray,
    sample_rate: int,
    cosines: dict[int, list[np.ndarray]],
    sines: dict[int, list[np.ndarray]],
) -> dict[str, float | bool]:
    count = len(samples)
    if count == 0:
        return {
            "tone_440_dbfs": -160.0,
            "tone_440_snr_db": -160.0,
            "tone_997_dbfs": -160.0,
            "tone_997_snr_db": -160.0,
            "rms_dbfs": -160.0,
            "peak_dbfs": -160.0,
            "noise_floor_dbfs": -160.0,
        }
    rms = float(np.sqrt(np.mean(np.square(samples))))
    peak = float(np.max(np.abs(samples)))
    tone_rms: dict[int, float] = {}
    for frequency in (440, 997):
        magnitudes = []
        for cosine, sine in zip(cosines[frequency], sines[frequency]):
            cosine_sum = float(np.dot(samples, cosine))
            sine_sum = float(np.dot(samples, sine))
            magnitudes.append(math.sqrt(cosine_sum * cosine_sum + sine_sum * sine_sum))
        amplitude = 2.0 * max(magnitudes, default=0.0) / count
        tone_rms[frequency] = amplitude / math.sqrt(2.0)

    residual_power = max(1.0e-12, rms * rms - tone_rms[440] ** 2 - tone_rms[997] ** 2)

    def snr(value: float) -> float:
        if value <= 0:
            return -160.0
        return 10.0 * math.log10(max(1.0e-12, value * value) / residual_power)

    tone440_db = dbfs(tone_rms[440])
    tone997_db = dbfs(tone_rms[997])
    tone440_snr = snr(tone_rms[440])
    tone997_snr = snr(tone_rms[997])
    return {
        "tone_440_dbfs": tone440_db,
        "tone_440_snr_db": tone440_snr,
        "tone_997_dbfs": tone997_db,
        "tone_997_snr_db": tone997_snr,
        "rms_dbfs": dbfs(rms),
        "peak_dbfs": dbfs(peak),
        "noise_floor_dbfs": dbfs(math.sqrt(residual_power)),
    }


def mark_target(row: dict[str, float | bool], frequency: int) -> bool:
    return bool(
        float(row[f"tone_{frequency}_dbfs"]) > -70.0
        and float(row[f"tone_{frequency}_snr_db"]) > 15.0
    )


def summarize(rows: list[dict[str, float | bool]]) -> dict[str, object]:
    if not rows:
        return {
            "window_count": 0,
            "dual_valid_count": 0,
            "tone_440_valid_count": 0,
            "tone_997_valid_count": 0,
            "dual_pass": False,
        }
    dual_rows = [row for row in rows if row["dual_valid"]]
    valid_440 = [row for row in rows if row["tone_440_valid"]]
    valid_997 = [row for row in rows if row["tone_997_valid"]]
    return {
        "window_count": len(rows),
        "dual_valid_count": len(dual_rows),
        "tone_440_valid_count": len(valid_440),
        "tone_997_valid_count": len(valid_997),
        "dual_pass": len(dual_rows) >= 18,
        "tone_440_median_dbfs": round(float(np.median([float(row["tone_440_dbfs"]) for row in rows])), 3),
        "tone_997_median_dbfs": round(float(np.median([float(row["tone_997_dbfs"]) for row in rows])), 3),
        "tone_440_median_snr_db": round(float(np.median([float(row["tone_440_snr_db"]) for row in rows])), 3),
        "tone_997_median_snr_db": round(float(np.median([float(row["tone_997_snr_db"]) for row in rows])), 3),
    }


def rows_in_interval(rows: list[dict[str, float | bool]], interval: dict[str, float | None]) -> list[dict[str, float | bool]]:
    start = interval.get("start_seconds")
    end = interval.get("end_seconds")
    if start is None or end is None or end <= start:
        return []
    return [
        row for row in rows
        if float(row["window_start_s"]) >= float(start) - 1.0e-6
        and float(row["window_end_s"]) <= float(end) + 1.0e-6
    ]


def write_spectrum(path: Path, rows: list[dict[str, float | bool]]) -> None:
    fields = [
        "second_index", "window_start_s", "window_end_s", "timestamp",
        "foreground_app",
        "tone_440_dbfs", "tone_440_snr_db", "tone_440_valid",
        "tone_997_dbfs", "tone_997_snr_db", "tone_997_valid",
        "rms_dbfs", "peak_dbfs", "noise_floor_dbfs", "dual_valid",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def foreground_at(timestamp: datetime, events: list[dict[str, str]]) -> str:
    current = ""
    for event in events:
        if not event["timestamp"] or not event["foreground_app"]:
            continue
        try:
            if parse_time(event["timestamp"]) <= timestamp:
                current = event["foreground_app"]
        except ValueError:
            continue
    return current


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--kind", default="phase2d-retry")
    args = parser.parse_args()

    run_dir = args.run_dir
    wav_path = run_dir / "capture.wav"
    with wave.open(str(wav_path), "rb") as source:
        channels = source.getnchannels()
        sample_rate = source.getframerate()
        frame_count = source.getnframes()
        width = source.getsampwidth()
        frames = source.readframes(frame_count)
    if width != 2 or channels < 1:
        raise RuntimeError(f"expected Int16 WAV, got width={width}, channels={channels}")
    raw = np.frombuffer(frames, dtype="<i2")
    samples = raw.reshape(-1, channels).astype(np.float64) / float(2**15)
    mono = np.mean(samples, axis=1)
    duration = len(mono) / float(sample_rate)

    events = parse_events(args.log)
    write_events(run_dir, events)
    times = logger_times(run_dir)
    stream_start = times.get("stream_started") or times.get("session_started")
    if stream_start is None:
        stream_start = datetime.fromtimestamp(0, tz=timezone.utc)

    window_frames = int(sample_rate)
    phases = np.arange(window_frames, dtype=np.float64)
    cosines = {
        frequency: [
            np.cos(2.0 * np.pi * (frequency + offset) * phases / sample_rate)
            for offset in TONE_FREQUENCY_OFFSETS
        ]
        for frequency in (440, 997)
    }
    sines = {
        frequency: [
            np.sin(2.0 * np.pi * (frequency + offset) * phases / sample_rate)
            for offset in TONE_FREQUENCY_OFFSETS
        ]
        for frequency in (440, 997)
    }

    rows: list[dict[str, float | bool]] = []
    complete_windows = len(mono) // window_frames
    for index in range(complete_windows):
        start = index * window_frames
        end = start + window_frames
        measured = analyze_window(mono[start:end], sample_rate, cosines, sines)
        window_start = float(index)
        window_end = float(index + 1)
        timestamp = (stream_start.timestamp() + window_start)
        row: dict[str, float | bool] = {
            "second_index": index,
            "window_start_s": round(window_start, 6),
            "window_end_s": round(window_end, 6),
            "timestamp": datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat().replace("+00:00", "Z"),
            "foreground_app": foreground_at(datetime.fromtimestamp(timestamp, tz=timezone.utc), events),
            **measured,
        }
        row["tone_440_valid"] = mark_target(row, 440)
        row["tone_997_valid"] = mark_target(row, 997)
        row["dual_valid"] = bool(row["tone_440_valid"] and row["tone_997_valid"])
        rows.append(row)

    write_spectrum(run_dir / "spectrum_per_second.csv", rows)
    stream_interval = {"start_seconds": 0.0, "end_seconds": duration}
    precheck_interval = interval_from_markers(events, stream_start, "T6 Overlap Precheck Start", "T7 Overlap Precheck", duration)
    # XCTest markers are intentionally second-resolution and T6/T7 can land in
    # the same second even though the runtime detector has already observed two
    # consecutive one-second windows.  The strict retry gate is defined as the
    # *recent* two seconds immediately before the PASS marker, so use that
    # evidence window rather than treating equal marker timestamps as an empty
    # interval.
    precheck_end = (
        marker_seconds(events, stream_start, "T7 Overlap Precheck PASS")
        or marker_seconds(events, stream_start, "T7 Overlap Precheck FAIL")
    )
    if precheck_end is not None:
        precheck_interval = {
            "start_seconds": max(0.0, min(duration, precheck_end - 2.0)),
            "end_seconds": max(0.0, min(duration, precheck_end)),
        }
    measurement_interval = interval_from_markers(events, stream_start, "T8 Measurement Window Start", "T9 Measurement Window End", duration)
    background_interval = interval_from_markers(events, stream_start, "T4 Probe Background Start", "T5 Probe Background Measurement End", duration)
    y0_interval = interval_from_markers(events, stream_start, "T5 YouTube Play 440 Hz", "T13 Capture Stop", duration)

    has_measurement_markers = (
        measurement_interval.get("start_seconds") is not None
        and measurement_interval.get("end_seconds") is not None
    )
    has_precheck_pass = has_marker(events, "T7 Overlap Precheck PASS")
    if has_measurement_markers:
        measurement_rows = rows_in_interval(rows, measurement_interval)
    elif has_marker(events, "T7 Overlap Precheck FAIL"):
        # A strict main run that fails T7 must never be promoted to a
        # measurement result merely because its full stream contains tone
        # energy. Keep the precheck windows for diagnosis, but report zero
        # formal measurement seconds.
        measurement_rows = []
    else:
        # P0/P1/Y0 baselines have no T7 marker and intentionally summarize the
        # complete captured stream.
        measurement_rows = rows
    write_spectrum(run_dir / "dual_window_spectrum.csv", measurement_rows)
    precheck_rows = rows_in_interval(rows, precheck_interval)
    background_rows = rows_in_interval(rows, background_interval)

    precheck_dual = [row for row in precheck_rows if row["dual_valid"]]
    background_valid = [row for row in background_rows if row["tone_997_valid"]]
    background_ratio = len(background_valid) / len(background_rows) if background_rows else 0.0
    measurement_dual = [row for row in measurement_rows if row["dual_valid"]]

    payload = {
        "schema_version": 2,
        "run": args.kind,
        "wav": "capture.wav",
        "raw": "capture.raw",
        "sample_rate": sample_rate,
        "channels": channels,
        "frame_count": frame_count,
        "duration_seconds": round(duration, 6),
        "window_seconds": 1.0,
        "thresholds": {
            "minimum_snr_db": 15.0,
            "minimum_tone_dbfs": -70.0,
            "background_survival_fraction": 0.8,
            "measurement_dual_windows": 18,
            "precheck_dual_windows": 2,
        },
        "intervals": {
            "stream": stream_interval,
            "precheck": precheck_interval,
            "measurement": measurement_interval,
            "background": background_interval,
            "y0": y0_interval,
        },
        "stream_summary": summarize(rows),
        "precheck_summary": {
            **summarize(precheck_rows),
            "dual_valid_count": len(precheck_dual),
            "pass": bool(has_precheck_pass and len(precheck_dual) >= 2),
        },
        "background_summary": {
            **summarize(background_rows),
            "tone_997_valid_count": len(background_valid),
            "survival_fraction": round(background_ratio, 4),
            "pass": bool(background_rows and background_ratio >= 0.8),
        },
        "measurement_summary": {
            **summarize(measurement_rows),
            "dual_valid_count": len(measurement_dual),
            "valid_seconds": len(measurement_dual),
            "pass": len(measurement_dual) >= 18,
        },
        "runtime_gates": {
            "overlap_precheck_pass_marker": has_precheck_pass,
            "measurement_window_markers": has_measurement_markers,
            "runtime_valid": bool(has_precheck_pass and has_measurement_markers),
        },
        "automation_events": "automation-events.csv",
        "spectrum_per_second": "spectrum_per_second.csv",
        "dual_window_spectrum": "dual_window_spectrum.csv",
    }
    (run_dir / "retry-fft-summary.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def fmt(value: object) -> str:
        if isinstance(value, float):
            return f"{value:.3f}"
        return str(value)

    summary = payload["measurement_summary"]
    text = f"""# Phase 2D-Retry strict FFT summary — {args.kind}

- WAV: {sample_rate} Hz, {channels} ch, {duration:.3f} s
- Window: 1.000 s, mono-average of captured channels
- Threshold: SNR > 15 dB and tone level > -70 dBFS
- Measurement valid seconds: {summary['valid_seconds']} / {summary['window_count']}

| Target | Median dBFS | Median SNR | Valid windows |
|---:|---:|---:|---:|
| 440 Hz | {fmt(summary.get('tone_440_median_dbfs', -160.0))} | {fmt(summary.get('tone_440_median_snr_db', -160.0))} | {summary.get('tone_440_valid_count', 0)} |
| 997 Hz | {fmt(summary.get('tone_997_median_dbfs', -160.0))} | {fmt(summary.get('tone_997_median_snr_db', -160.0))} | {summary.get('tone_997_valid_count', 0)} |

`retry-fft-summary.json` contains the precheck, background-survival and measurement gates.
`spectrum_per_second.csv` retains every complete one-second window; `dual_window_spectrum.csv`
contains the marked measurement interval when one exists.
"""
    (run_dir / "retry-fft-summary.md").write_text(text, encoding="utf-8")
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
