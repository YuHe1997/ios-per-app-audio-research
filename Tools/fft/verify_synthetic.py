#!/usr/bin/env python3
"""Dependency-free deterministic tone power check used by the public release gate."""

import math

RATE = 48_000
DURATION = 2.0
FREQUENCIES = (440.0, 997.0)


def samples(frequency: float) -> list[float]:
    count = int(RATE * DURATION)
    return [0.5 * math.sin(2.0 * math.pi * frequency * n / RATE) for n in range(count)]


def tone_power(signal: list[float], frequency: float) -> float:
    omega = 2.0 * math.pi * frequency / RATE
    cosine = sum(x * math.cos(omega * n) for n, x in enumerate(signal))
    sine = sum(x * math.sin(omega * n) for n, x in enumerate(signal))
    magnitude = 2.0 * math.hypot(cosine, sine) / len(signal)
    return 20.0 * math.log10(max(magnitude, 1e-12))


def main() -> None:
    for expected in FREQUENCIES:
        signal = samples(expected)
        expected_db = tone_power(signal, expected)
        other = FREQUENCIES[1] if expected == FREQUENCIES[0] else FREQUENCIES[0]
        other_db = tone_power(signal, other)
        if expected_db < -7.0 or expected_db - other_db < 40.0:
            raise SystemExit(f"FAIL {expected:g} Hz: expected={expected_db:.2f}, other={other_db:.2f}")
        print(f"PASS {expected:g} Hz: expected={expected_db:.2f} dBFS, other={other_db:.2f} dBFS")


if __name__ == "__main__":
    main()
