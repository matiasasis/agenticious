#!/usr/bin/env python3
"""Generate the soft ascending summon cue: python3 design/make_summon_sound.py."""
import math
import struct
import wave
from pathlib import Path

RATE = 44100
DURATION = 0.48
OUTPUT = Path(__file__).resolve().parents[1] / "Sources/Agenticious/Resources/Summon.wav"


def note(time, start, frequency, duration):
    elapsed = time - start
    if not 0 <= elapsed < duration:
        return 0.0
    attack = min(elapsed / 0.025, 1.0)
    release = min((duration - elapsed) / 0.09, 1.0)
    envelope = attack * release * math.exp(-5 * elapsed)
    phase = 2 * math.pi * frequency * elapsed
    return envelope * (math.sin(phase) + 0.12 * math.sin(2 * phase))


samples = []
for index in range(round(RATE * DURATION)):
    time = index / RATE
    value = 0.23 * (note(time, 0, 523.25, 0.30) + note(time, 0.10, 783.99, 0.38))
    samples.append(struct.pack("<h", round(max(-1, min(1, value)) * 32767)))

with wave.open(str(OUTPUT), "wb") as sound:
    sound.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
    sound.writeframes(b"".join(samples))
