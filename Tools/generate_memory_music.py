#!/usr/bin/env python3
"""Render four original, contrasting café cues for Memories.

Run: python3 Tools/generate_memory_music.py
Requires NumPy and macOS afconvert. No recordings, samples, network services or
licensed music are used. CAF filenames stay stable for the app.
"""

from __future__ import annotations

import math
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np


RATE = 22_050
OUTPUT = Path(__file__).resolve().parents[1] / "Photo Libraries/Resources/MemoryMusic"


def frequency(midi: int) -> float:
    return 440.0 * 2 ** ((midi - 69) / 12)


class Score:
    def __init__(self, bpm: int, bars: int, meter: int, seed: int):
        self.beat = 60 / bpm
        self.bars = bars
        self.meter = meter
        self.frames = round(bars * meter * self.beat * RATE)
        self.audio = np.zeros((self.frames, 2), dtype=np.float64)
        self.rng = np.random.default_rng(seed)

    def put(self, at: float, signal: np.ndarray, pan: float = 0) -> None:
        """Wrap notes and echoes over the loop boundary."""
        start = round(at * self.beat * RATE) % self.frames
        length = min(len(signal), self.frames)
        indexes = (start + np.arange(length)) % self.frames
        self.audio[indexes, 0] += signal[:length] * math.sqrt((1 - pan) / 2)
        self.audio[indexes, 1] += signal[:length] * math.sqrt((1 + pan) / 2)

    def note(self, at: float, pitch: int, beats: float, volume: float,
             voice: str, pan: float = 0) -> None:
        t = np.arange(max(1, round(beats * self.beat * RATE))) / RATE
        phase = 2 * np.pi * frequency(pitch) * t
        if voice == "guitar":
            signal = sum(weight * np.sin(harmonic * phase) * np.exp(-t * decay)
                         for harmonic, weight, decay in
                         ((1, 1.0, 1.4), (2, 0.42, 2.4), (3, 0.20, 4.2),
                          (4, 0.10, 6.4)))
            signal += self.rng.normal(0, 0.12, len(t)) * np.exp(-t * 80)
            signal *= np.minimum(t * 190, 1)
        elif voice == "piano":
            signal = (np.sin(phase) * np.exp(-t * 1.3)
                      + 0.43 * np.sin(2.003 * phase) * np.exp(-t * 2.9)
                      + 0.16 * np.sin(3.01 * phase) * np.exp(-t * 4.3))
            signal *= np.minimum(t * 130, 1)
        elif voice == "rhodes":
            signal = (np.sin(phase + 0.26 * np.sin(2 * phase)) * np.exp(-t * 0.85)
                      + 0.25 * np.sin(2.98 * phase) * np.exp(-t * 3.7))
            signal *= np.minimum(t * 110, 1)
        elif voice == "bass":
            signal = np.sin(phase) + 0.22 * np.sin(2 * phase) * np.exp(-t * 3)
            signal *= (1 - np.exp(-t * 80)) * np.exp(-t * 2.0)
        elif voice == "mallet":
            signal = np.sin(phase) + 0.31 * np.sin(3.98 * phase)
            signal *= (1 - np.exp(-t * 70)) * np.exp(-t * 2.7)
        else:
            raise ValueError(voice)
        self.put(at, signal * volume, pan)

    def drum(self, at: float, kind: str, volume: float, pan: float = 0) -> None:
        length = {"kick": 0.30, "brush": 0.28, "shaker": 0.18,
                  "rim": 0.10, "hat": 0.11}[kind]
        t = np.arange(round(length * RATE)) / RATE
        noise = self.rng.normal(0, 1, len(t))
        if kind == "kick":
            phase = 2 * np.pi * (72 * t + 55 * (1 - np.exp(-t * 38)) / 38)
            signal = np.sin(phase) * np.exp(-t * 24)
        elif kind == "brush":
            signal = noise - np.convolve(noise, np.ones(11) / 11, mode="same")
            signal *= np.exp(-t * 14)
        elif kind == "shaker":
            signal = noise - np.convolve(noise, np.ones(17) / 17, mode="same")
            signal *= np.exp(-t * 24)
        elif kind == "rim":
            signal = (0.55 * noise + 0.45 * np.sin(2 * np.pi * 1230 * t))
            signal *= np.exp(-t * 70)
        else:
            signal = noise - np.convolve(noise, np.ones(7) / 7, mode="same")
            signal *= np.exp(-t * 45)
        self.put(at, signal * volume, pan)

    def finish(self, echo: float) -> np.ndarray:
        dry = self.audio.copy()
        for delay, gain in ((0.19, echo), (0.37, echo * 0.48)):
            shift = round(delay * RATE)
            self.audio[:, 0] += np.roll(dry[:, 1], shift) * gain
            self.audio[:, 1] += np.roll(dry[:, 0], shift) * gain
        # Match the first and last sample without fading away the beat.
        discontinuity = self.audio[0] - self.audio[-1]
        edge = round(0.012 * RATE)
        self.audio[:edge] -= (1 - np.arange(edge) / edge)[:, None] * discontinuity
        peak = np.max(np.abs(self.audio))
        rms = np.sqrt(np.mean(self.audio ** 2))
        self.audio *= min(0.095 / max(rms, 1e-9), 0.78 / max(peak, 1e-9))
        return np.round(self.audio * 32767).astype("<i2")


def morning_bossa() -> np.ndarray:
    """Syncopated nylon-guitar-style chords, shaker and two-beat bass."""
    score = Score(100, 12, 4, 1041)
    chords = [((55, 59, 62, 66, 69), 43), ((52, 55, 59, 62, 66), 40),
              ((57, 60, 64, 67, 71), 45), ((50, 54, 60, 64, 69), 38)]
    melody = [(0.5, 74), (2.5, 76), (4.5, 79), (7, 76),
              (8.5, 74), (10.5, 71), (12.5, 72), (15, 74)]
    for bar in range(score.bars):
        start = bar * 4
        chord, root = chords[bar % 4]
        for beat, bass in ((0, root), (2, root + 7)):
            score.note(start + beat, bass, 1.25, 0.28, "bass", -0.15)
        for beat, indexes in ((0, (1, 2, 3)), (1.5, (2, 3, 4)),
                              (2.5, (1, 2, 3)), (3.5, (2, 3, 4))):
            for i, index in enumerate(indexes):
                score.note(start + beat + i * 0.018, chord[index], 1.5,
                           0.084, "guitar", -0.26 + i * 0.24)
        for beat in (0, 2):
            score.drum(start + beat, "kick", 0.15)
        for beat in (0.5, 1.5, 2.5, 3.5):
            score.drum(start + beat, "shaker", 0.055, 0.42)
        for beat in (1.5, 3.5):
            score.drum(start + beat, "rim", 0.085, -0.33)
        for position, pitch in melody:
            if 4 * (bar % 4) <= position < 4 * (bar % 4 + 1):
                score.note(start + position % 4, pitch, 1, 0.16, "guitar", 0.18)
    return score.finish(0.055)


def piano_jazz() -> np.ndarray:
    """Light swing, walking upright-style bass and brushed snare."""
    score = Score(84, 12, 4, 2207)
    chords = [((60, 64, 67, 71, 74), (36, 40, 43, 47)),
              ((53, 57, 60, 64, 67), (41, 45, 48, 52)),
              ((62, 65, 69, 72, 76), (38, 41, 45, 48)),
              ((55, 59, 62, 65, 69), (43, 47, 50, 53))]
    melody = [(0, 76), (1.67, 74), (3, 71), (4.67, 72),
              (6, 69), (7.67, 72), (8, 74), (10.67, 76),
              (12, 77), (13.67, 76), (15, 74)]
    for bar in range(score.bars):
        start = bar * 4
        chord, walk = chords[bar % 4]
        for beat, pitch in enumerate(walk):
            score.note(start + beat, pitch, 1.2, 0.29, "bass", -0.12)
        for beat in (0, 2.67):
            for i, pitch in enumerate(chord[1:4]):
                score.note(start + beat + i * 0.025, pitch, 2.1,
                           0.095, "piano", -0.25 + i * 0.26)
        for beat in (1, 3):
            score.drum(start + beat, "brush", 0.095, 0.24)
        for beat in (0, 0.67, 1, 1.67, 2, 2.67, 3, 3.67):
            score.drum(start + beat, "hat", 0.027, -0.38)
        for position, pitch in melody:
            if 4 * (bar % 4) <= position < 4 * (bar % 4 + 1):
                score.note(start + position % 4, pitch, 1.8,
                           0.22, "piano", 0.20)
    return score.finish(0.10)


def afternoon_lofi() -> np.ndarray:
    """Rhodes-style chords, soft mallet and relaxed half-time drums."""
    score = Score(76, 10, 4, 3319)
    chords = [((57, 60, 64, 67), 33), ((53, 57, 60, 64), 29),
              ((60, 64, 67, 71), 36), ((55, 59, 62, 65), 31),
              ((57, 60, 64, 69), 33)]
    melody = [(0, 76), (2.5, 72), (5, 69), (7.5, 72),
              (10, 76), (12.5, 79), (15, 76), (17.5, 72)]
    for bar in range(score.bars):
        start = bar * 4
        chord, root = chords[bar % 5]
        for beat in (0, 2.5):
            for i, pitch in enumerate(chord):
                score.note(start + beat + i * 0.02, pitch + 12, 3.5,
                           0.083, "rhodes", -0.45 + i * 0.30)
        score.note(start, root, 2, 0.31, "bass", -0.15)
        score.note(start + 2.5, root + 7, 1, 0.22, "bass", -0.15)
        score.drum(start, "kick", 0.26)
        score.drum(start + 2.75, "kick", 0.12)
        score.drum(start + 2, "brush", 0.18, 0.08)
        for beat in (0.5, 1.5, 2.5, 3.5):
            score.drum(start + beat, "hat", 0.042, 0.40)
        if bar < 8:
            for position, pitch in melody:
                if 4 * (bar % 8) <= position < 4 * (bar % 8 + 1):
                    score.note(start + position % 4, pitch, 2,
                               0.15, "mallet", 0.25)
    return score.finish(0.16)


def evening_acoustic() -> np.ndarray:
    """Sparse three-beat fingerpicked café waltz with no drum kit."""
    score = Score(92, 16, 3, 4493)
    chords = [((57, 60, 64, 69), 33), ((53, 57, 60, 64), 29),
              ((60, 64, 67, 72), 36), ((55, 59, 62, 67), 31)]
    melody = [(0, 72), (2, 76), (4, 72), (6, 69), (8, 67),
              (10, 69), (12, 72), (14, 74), (16, 72), (18, 76),
              (20, 79), (22, 76)]
    for bar in range(score.bars):
        start = bar * 3
        chord, root = chords[bar % 4]
        score.note(start, root, 1.6, 0.23, "bass", -0.12)
        for beat, index in ((0.5, 1), (1, 2), (1.5, 3), (2, 2), (2.5, 1)):
            score.note(start + beat, chord[index] + 12, 1.7,
                       0.12, "guitar", (-0.36, 0.20, 0.34)[index - 1])
        if bar % 2 == 0:
            score.drum(start + 2.5, "shaker", 0.022, 0.50)
        if bar < 8 or bar >= 12:
            for position, pitch in melody:
                if 3 * (bar % 8) <= position < 3 * (bar % 8 + 1):
                    score.note(start + position % 3, pitch, 1.8,
                               0.17, "guitar", 0.23)
    return score.finish(0.07)


TRACKS = {
    "memory-warmth": morning_bossa,
    "memory-dream": piano_jazz,
    "memory-journey": afternoon_lofi,
    "memory-stillness": evening_acoustic,
}


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="memory-music-") as temporary:
        for name, compose in TRACKS.items():
            samples = compose()
            wav_path = Path(temporary) / f"{name}.wav"
            with wave.open(str(wav_path), "wb") as wav:
                wav.setnchannels(2)
                wav.setsampwidth(2)
                wav.setframerate(RATE)
                wav.writeframes(samples.tobytes())
            destination = OUTPUT / f"{name}.caf"
            subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16",
                            str(wav_path), str(destination)], check=True)
            print(f"Created {destination} ({len(samples) / RATE:.1f} s)")


if __name__ == "__main__":
    main()
