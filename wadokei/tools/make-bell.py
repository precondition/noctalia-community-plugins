#!/usr/bin/env python3
"""Synthesizes sounds/bell.ogg, one stroke of a temple bell (梵鐘).

The bell is additive synthesis: a low hum and a set of inharmonic partials,
each decaying at its own rate, with a slightly detuned twin on the main
partials for the slow beating (うなり) a large bronze bell has, plus a short
filtered noise thump for the wooden beam (撞木) striking it.

Run from the plugin directory; needs numpy and ffmpeg (with libvorbis):
    python3 tools/make-bell.py
"""

import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

RATE = 48000
SECONDS = 7.0
FUNDAMENTAL = 110.0  # Hz

# (frequency ratio, amplitude, decay time constant in seconds, detune in Hz)
PARTIALS = [
    (0.5, 0.35, 3.5, 0.0),   # hum
    (1.0, 1.00, 2.8, 0.6),   # fundamental, beating
    (1.42, 0.45, 2.0, 0.4),
    (2.0, 0.55, 1.6, 0.9),
    (2.76, 0.40, 1.1, 0.0),
    (3.68, 0.30, 0.8, 1.3),
    (5.06, 0.18, 0.5, 0.0),
    (6.82, 0.10, 0.35, 0.0),
]


def synthesize() -> np.ndarray:
    t = np.arange(int(RATE * SECONDS)) / RATE
    out = np.zeros_like(t)
    rng = np.random.default_rng(1798)  # fixed seed: the same file every run

    for ratio, amp, decay, detune in PARTIALS:
        freq = FUNDAMENTAL * ratio
        envelope = amp * np.exp(-t / decay)
        tone = np.sin(2 * np.pi * freq * t + rng.uniform(0, 2 * np.pi))
        if detune:
            tone = 0.5 * (tone + np.sin(2 * np.pi * (freq + detune) * t + rng.uniform(0, 2 * np.pi)))
        out += envelope * tone

    # The strike: a few milliseconds of noise, low-passed by a running mean.
    thump_len = int(RATE * 0.06)
    noise = rng.standard_normal(thump_len) * np.exp(-np.arange(thump_len) / (RATE * 0.012))
    noise = np.convolve(noise, np.ones(24) / 24, mode="same")
    out[:thump_len] += 0.6 * noise

    # Soft attack so the start does not click, and a fade to silence at the end.
    attack = int(RATE * 0.004)
    out[:attack] *= np.linspace(0, 1, attack)
    fade = int(RATE * 1.0)
    out[-fade:] *= np.linspace(1, 0, fade) ** 2

    return out / np.max(np.abs(out)) * 0.8


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    wav_path = root / "sounds" / "bell.wav"
    ogg_path = root / "sounds" / "bell.ogg"
    wav_path.parent.mkdir(exist_ok=True)

    samples = (synthesize() * 32767).astype(np.int16)
    with wave.open(str(wav_path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(samples.tobytes())

    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav_path), "-c:a", "libvorbis", "-q:a", "4", str(ogg_path)],
        check=True,
    )
    wav_path.unlink()
    print(f"wrote {ogg_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
