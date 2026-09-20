#!/usr/bin/env python3
import csv, json, math, sys, wave
from pathlib import Path
import numpy as np
from scipy.signal import correlate, correlation_lags

run, reference_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
reference = np.fromfile(reference_path, dtype="<f4").astype(np.float64)
with wave.open(str(run / "capture.wav"), "rb") as w:
    sr, channels = w.getframerate(), w.getnchannels()
    captured = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, channels).mean(1) / 32768.0

corr = correlate(captured, reference, mode="valid", method="fft")
delay = int(np.argmax(np.abs(corr)))
segment = captured[delay:delay + len(reference)]
gain = float(np.dot(segment, reference) / np.dot(reference, reference))
aligned = reference * gain
residual = segment - aligned
peak = float(abs(corr[delay]) / (np.linalg.norm(segment) * np.linalg.norm(reference) + 1e-15))

def rms(x): return float(np.sqrt(np.mean(x * x)))
before, after = rms(segment), rms(residual)
suppression = 20 * math.log10(max(before, 1e-15) / max(after, 1e-15))
windows = []
for i in range(30):
    a, b = i * sr, (i + 1) * sr
    rb, ra = rms(segment[a:b]), rms(residual[a:b])
    windows.append(20 * math.log10(max(rb, 1e-15) / max(ra, 1e-15)))

local_delays = []
for second in range(0, 30, 5):
    ref = reference[second * sr:(second + 5) * sr]
    center = delay + second * sr
    search = captured[max(0, center - 128):center + len(ref) + 128]
    c = correlate(search, ref, mode="valid", method="fft")
    local_delays.append(max(0, center - 128) + int(np.argmax(np.abs(c))) - second * sr)

result = {
    "before_rms_dbfs": 20 * math.log10(max(before, 1e-15)),
    "after_rms_dbfs": 20 * math.log10(max(after, 1e-15)),
    "suppression_db": suppression,
    "correlation_peak": peak,
    "estimated_delay_samples": delay,
    "estimated_delay_ms": delay / sr * 1000,
    "gain": gain,
    "delay_drift_samples": max(local_delays) - min(local_delays),
    "window_median_suppression_db": float(np.median(windows)),
    "window_p10_suppression_db": float(np.percentile(windows, 10)),
    "windows_ge_15_db_fraction": float(np.mean(np.asarray(windows) >= 15)),
}
out.mkdir(parents=True, exist_ok=True)
(out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
with (out / "one-second-windows.csv").open("w", newline="") as f:
    w = csv.writer(f); w.writerow(["second", "suppression_db"])
    w.writerows(enumerate(windows))
print(json.dumps(result))
