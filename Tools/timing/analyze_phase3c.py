#!/usr/bin/env python3
import csv, json, math, sys, wave
from pathlib import Path
import numpy as np

run = Path(sys.argv[1]); markers_path = Path(sys.argv[2]); out = Path(sys.argv[3])
metrics = [r for r in csv.DictReader((run / "metrics.csv").open()) if r["event"] == "audio_buffer"]
markers = list(csv.DictReader(markers_path.open()))
capture_log = list(csv.DictReader((run / "capture.csv").open()))
start_message = next(r["message"] for r in capture_log if r["event"] == "run_start_audio_session")
route_latency = float(start_message.split("outputLatency=")[1].split(",")[0])
first_pts = float(metrics[0]["pts_seconds"])
with wave.open(str(run / "capture.wav"), "rb") as w:
    sr, channels = w.getframerate(), w.getnchannels()
    pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, channels).mean(1) / 32768.0

state, sequence = 0x7FFF, []
for _ in range(4800):
    bit = ((state >> 14) ^ (state >> 13)) & 1
    state = ((state << 1) | bit) & 0x7FFF
    sequence.append(1.0 if state & 1 else -1.0)
reference = np.asarray(sequence); reference /= np.linalg.norm(reference)

rows = []
for marker in markers:
    marker_id = int(marker["marker_id"])
    render_pts = float(marker["render_host_time"]) * (125.0 / 3.0) / 1e9
    predicted = int(round((render_pts - first_pts) * sr))
    lo, hi = max(0, predicted - sr // 4), min(len(pcm) - len(reference), predicted + sr // 4)
    correlation = np.correlate(pcm[lo:hi + len(reference)], reference, "valid")
    local = int(np.argmax(np.abs(correlation))); onset = lo + local
    peak = float(abs(correlation[local]) / (np.linalg.norm(pcm[onset:onset + len(reference)]) + 1e-15))
    buffer_index = min(len(metrics) - 1, onset // 960)
    buffer = metrics[buffer_index]
    offset = onset - sum(int(r["sample_count"]) for r in metrics[:buffer_index])
    capture_pts = first_pts + onset / sr
    callback_ns = int(buffer["monotonic_ns"])
    render_continuous_ns = int(marker["render_continuous_ns"])
    rows.append({
        "marker_id": marker_id,
        "render_host_time": marker["render_host_time"],
        "render_continuous_ns": render_continuous_ns,
        "capture_callback_host_time_ns": callback_ns,
        "buffer_pts": float(buffer["pts_seconds"]),
        "sample_offset_in_buffer": offset,
        "correlation_peak": peak,
        "render_to_capture_ms": (capture_pts - render_pts) * 1000,
        "estimated_lead_budget_ms": ((render_continuous_ns / 1e9 + route_latency) - callback_ns / 1e9) * 1000,
    })

def stats(values):
    a = np.asarray(values)
    return {"count": len(a), "median": float(np.median(a)), "mean": float(a.mean()),
            "p05": float(np.percentile(a, 5)), "p95": float(np.percentile(a, 95)),
            "p99": float(np.percentile(a, 99)), "stddev": float(a.std()),
            "min": float(a.min()), "max": float(a.max())}

timing = stats([r["render_to_capture_ms"] for r in rows]); timing["jitter_span"] = timing["p95"] - timing["p05"]
lead = stats([r["estimated_lead_budget_ms"] for r in rows])
summary = {"render_to_capture_ms": timing, "estimated_lead_budget_ms": lead,
           "correlation_peak": stats([r["correlation_peak"] for r in rows])}
out.mkdir(parents=True, exist_ok=True)
with (out / "markers.csv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=rows[0].keys()); writer.writeheader(); writer.writerows(rows)
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary))
