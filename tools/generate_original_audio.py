#!/usr/bin/env python3
"""Generate original audio for the coastal-defense game; no source recordings.

Requires Python 3 and numpy. All PCM originates in seeded noise, oscillators,
modal resonances and envelopes described below. Names in LEGACY_MAP are only
adapter keys; no historic recording, tune, score, voice or tracker is loaded.
The generated manifest records every rendered file and its algorithm identity.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import wave

try:
    import numpy as np
except ImportError as error:
    raise SystemExit("numpy is required; use the bundled Codex Python runtime or a Python environment with numpy") from error

RATE = 44100
BASE_SEED = 0xC0A57A1
VERSION = "original-audio-1"


def seed_for(name: str) -> int:
    return BASE_SEED ^ int.from_bytes(hashlib.sha256(name.encode()).digest()[:4], "little")


def clock(seconds: float):
    return np.arange(round(seconds * RATE), dtype=np.float64) / RATE


def noise(t, rng, low=25.0, high=9000.0, slope=0.0):
    """Band-limited periodic noise, including seamless loop boundaries."""
    n = len(t)
    f = np.fft.rfftfreq(n, 1 / RATE)
    spectrum = rng.normal(size=len(f)) + 1j * rng.normal(size=len(f))
    spectrum *= (np.maximum(f, 20) / 500) ** (-slope)
    spectrum *= 1 / np.sqrt(1 + (f / high) ** 8)
    spectrum *= 1 / np.sqrt(1 + (low / np.maximum(f, 0.1)) ** 8)
    spectrum[0] = 0
    if n % 2 == 0:
        spectrum[-1] = spectrum[-1].real
    result = np.fft.irfft(spectrum, n=n)
    return result / max(float(np.std(result)), 1e-9)


def oscillator(t, frequency, phase=0):
    return np.sin(2 * np.pi * frequency * t + phase)


def sweep(t, start, end, decay):
    phase = end * t + (start - end) * decay * (1 - np.exp(-t / decay))
    return np.sin(2 * np.pi * phase)


def envelope(t, attack=0.002, decay=0.12):
    return (1 - np.exp(-t / attack)) * np.exp(-t / decay)


def finite_edges(a, attack=0.002, release=0.035):
    a = a.copy()
    na, nr = min(len(a), round(attack * RATE)), min(len(a), round(release * RATE))
    if na:
        a[:na] *= np.linspace(0, 1, na) ** 1.5
    if nr:
        a[-nr:] *= np.linspace(1, 0, nr) ** 1.5
    return a


def room_tail(dry, taps=(0.031, 0.057, 0.089, 0.131), strength=0.17):
    output = dry.copy()
    for index, seconds in enumerate(taps):
        offset = round(seconds * RATE)
        if offset < len(output):
            output[offset:] += dry[:-offset] * strength * (0.69 ** index)
    return output


def shot(rng, scale=1.0, automatic=False):
    t = clock(0.75 if scale < 1.5 else 1.45)
    attack = noise(t, rng, 950, 12000) * envelope(t, 0.00035, 0.012 * scale) * 0.43
    body = noise(t, rng, 90, 1150, 0.3) * envelope(t, 0.0008, 0.048 * scale) * 0.62
    thump = sweep(t, 180 / scale, 47 / scale, 0.021 * scale) * envelope(t, 0.001, 0.075 * scale) * 0.55
    mechanics = np.zeros_like(t)
    for delay, amplitude in [(0.055 * scale, 0.15), (0.105 * scale, 0.08)]:
        local = np.maximum(0, t - delay)
        click = noise(t, rng, 450, 7800) * envelope(local, 0.001, 0.012) * (t >= delay)
        mechanics += click * amplitude
    if automatic:
        mechanics += oscillator(t, 320) * envelope(t, 0.001, 0.027) * 0.045
    return finite_edges(room_tail(attack + body + thump + mechanics, strength=0.15))


def explosion(rng, size=1.0, distant=False, muffled=False):
    t = clock(2.9 * size)
    pressure = sweep(t, 82 / np.sqrt(size), 23, 0.06) * envelope(t, 0.002, 0.27 * size) * 0.8
    rumble = noise(t, rng, 26, 420 if muffled else 800, 0.48)
    rumble *= envelope(t, 0.005 if not distant else 0.035, 0.42 * size) * 0.6
    transient = noise(t, rng, 700, 6200 if not muffled else 1000)
    transient *= envelope(t, 0.001, 0.025 * size) * (0.12 if distant else 0.4)
    grit = noise(t, rng, 350, 3500, 0.1) * envelope(t, 0.08, 0.23 * size) * 0.10
    signal = pressure + rumble + transient + grit
    return finite_edges(room_tail(signal, (0.071, 0.139, 0.229, 0.371), 0.12))


def metal(rng, large=False, long=False):
    t = clock(1.5 if long else 1.1 if large else 0.48)
    base = 310 if large else 610
    decay = 0.28 if long else 0.16 if large else 0.065
    a = noise(t, rng, 700, 10000) * envelope(t, 0.0005, 0.008) * 0.48
    # Inharmonic damped modes make a plate/fixture impact, not a musical bell.
    for i, ratio in enumerate([1, 1.47, 2.03, 2.81, 3.63, 5.02, 6.71]):
        a += oscillator(t, base * ratio, rng.uniform(0, 6.28)) * envelope(t, 0.0007, decay / (1 + i * 0.27)) * 0.22 / (1 + i * 0.5)
    a += noise(t, rng, 80, 550) * envelope(t, 0.001, 0.045) * (0.24 if large else 0.09)
    return finite_edges(room_tail(a, strength=0.09))


def ricochet(rng, variation):
    t = clock(0.6)
    a = noise(t, rng, 1800, 11500) * envelope(t, 0.0005, 0.021) * 0.52
    a += sweep(t, 2450 + variation * 170, 860 + variation * 75, 0.018) * envelope(t, 0.001, 0.045) * 0.13
    a += noise(t, rng, 500, 4200) * envelope(t, 0.025, 0.085) * 0.11
    return finite_edges(a)


def equipment_drop(rng, variation):
    """Cloth, webbing and equipment settling; deliberately no human voice."""
    t = clock(0.7 + variation * 0.05)
    a = noise(t, rng, 80, 1600, 0.4) * envelope(t, 0.004, 0.09) * 0.7
    a += sweep(t, 110, 42, 0.027) * envelope(t, 0.002, 0.07) * 0.4
    for delay in [0.11, 0.19 + variation * 0.007]:
        local = np.maximum(t - delay, 0)
        a += noise(t, rng, 650, 6000) * envelope(local, 0.003, 0.025) * (t >= delay) * 0.09
    return finite_edges(a)


def engine(rng, kind):
    duration = 6.0
    t = clock(duration)
    integer_frequency = lambda f: round(f * duration) / duration
    # Every oscillator/modulator completes an integer number of cycles.
    if kind in ("rotor-light", "rotor-heavy"):
        fundamental = 18 if kind == "rotor-light" else 12
        blade = (0.5 + 0.5 * oscillator(t, fundamental)) ** 5
        low = noise(t, rng, 30, 470, 0.5)
        air = noise(t, rng, 350, 5300, 0.2)
        a = low * (0.25 + blade * 0.55) + air * (0.05 + blade * 0.20)
        a += oscillator(t, fundamental * 3) * 0.15 + oscillator(t, fundamental * 8) * 0.035
    elif kind in ("jet", "bomber", "transport"):
        fundamental = {"jet": 83, "bomber": 43, "transport": 31}[kind]
        a = noise(t, rng, 45, 4200 if kind == "jet" else 2200, 0.55) * 0.65
        a += oscillator(t, fundamental) * 0.12 + oscillator(t, integer_frequency(fundamental * 2.91)) * 0.035
        if kind == "transport":
            a *= 0.70 + 0.30 * oscillator(t, 17)
        else:
            a *= 0.91 + 0.09 * oscillator(t, 1 / 3)
    else:
        fundamental = 24 if kind == "tracked" else 33
        a = noise(t, rng, 28, 1600, 0.8) * (0.24 + 0.11 * oscillator(t, fundamental))
        for harmonic in range(1, 10):
            a += oscillator(t, integer_frequency(fundamental * harmonic + (harmonic % 2) / 3)) * 0.22 / harmonic
        a *= 0.92 + 0.08 * oscillator(t, 0.5)
    return a


def missile(rng):
    t = clock(1.3)
    burst = noise(t, rng, 180, 6300, 0.2) * envelope(t, 0.003, 0.12) * 0.7
    rush = noise(t, rng, 400, 8500, 0.3) * envelope(t, 0.05, 0.25) * 0.24
    pressure = sweep(t, 135, 43, 0.03) * envelope(t, 0.001, 0.07) * 0.6
    return finite_edges(burst + rush + pressure)


def falling_air(rng):
    t = clock(1.7)
    air = noise(t, rng, 800, 6700) * (0.08 + (t / 1.7) ** 2 * 0.5)
    air *= 0.85 + 0.15 * oscillator(t, 37)
    return finite_edges(air, 0.18, 0.16)


def radio(rng):
    t = clock(0.7)
    a = noise(t, rng, 380, 3200) * envelope(t, 0.004, 0.045) * 0.3
    for delay in [0.17, 0.39]:
        local = np.maximum(t - delay, 0)
        a += noise(t, rng, 850, 4900) * envelope(local, 0.001, 0.022) * (t >= delay) * 0.12
    return finite_edges(a)


def reward(rng):
    t = clock(1.6)
    a = noise(t, rng, 900, 5000) * envelope(t, 0.04, 0.10) * 0.025
    # A single soft suspended chord, created here, rather than a source jingle.
    for f in [196, 293.665, 440]:
        a += oscillator(t, f) * envelope(t, 0.008, 0.25) * 0.13
        a += oscillator(t, f * 2) * envelope(t, 0.003, 0.10) * 0.025
    return finite_edges(room_tail(a, (0.11, 0.23, 0.39), 0.12))


LEGACY_MAP = {
    "AntiAir": ("heavy-automatic", "shot", 1.14),
    "MachineGun": ("light-automatic", "shot", 0.90),
    "Pistol": ("sidearm", "shot", 0.76),
    "Rifle": ("distant-rifle", "shot", 0.84),
    "CanonClose": ("cannon-near", "shot", 2.10),
    "CannonClose": ("cannon-near", "shot", 2.10),
    "CanonFar": ("cannon-far", "far-cannon", 1.20),
    "CannonFar": ("cannon-far", "far-cannon", 1.20),
    "Missile": ("rocket-launch", "missile", 0),
    "ExBig": ("large-blast", "explosion", 1.5),
    "ExClose": ("near-blast", "explosion", 0.85),
    "ExFar": ("distant-blast", "distant-blast", 1.0),
    "ExMuffle": ("covered-blast", "muffled-blast", 0.9),
    "ExHit": ("defense-hit", "explosion", 0.55),
    "Metalbig": ("armor-strike", "metal-large", 0),
    "Metalshort": ("fixture-strike", "metal-short", 0),
    "Metallong": ("plate-rattle", "metal-long", 0),
    "Tank": ("tracked-engine", "engine", "tracked"),
    "Truck": ("diesel-engine", "engine", "wheeled"),
    "Jet": ("turbine-engine", "engine", "jet"),
    "C130": ("propeller-transport", "engine", "transport"),
    "B52": ("heavy-aircraft", "engine", "bomber"),
    "Bomber": ("heavy-aircraft", "engine", "bomber"),
    "HeliAttack": ("light-rotor", "engine", "rotor-light"),
    "Cobra": ("light-rotor", "engine", "rotor-light"),
    "HeliTransport": ("heavy-rotor", "engine", "rotor-heavy"),
    "CH53": ("heavy-rotor", "engine", "rotor-heavy"),
    "Radio": ("radio-switch", "radio", 0),
    "Bombfall": ("falling-air", "falling", 0),
    "Prize": ("supply-arrival", "reward", 0),
    **{f"Ricocht{i}": (f"ricochet-{i}", "ricochet", i) for i in range(1, 6)},
    **{f"Soldead{i}": (f"equipment-drop-{i}", "equipment-drop", i) for i in range(1, 6)},
}


def render_effect(name, kind, parameter):
    rng = np.random.default_rng(seed_for(name))
    if kind == "shot":
        return shot(rng, parameter, "automatic" in name)
    if kind == "far-cannon":
        return explosion(rng, parameter, distant=True)
    if kind.endswith("blast") or kind == "explosion":
        return explosion(rng, parameter, distant=kind == "distant-blast", muffled=kind == "muffled-blast")
    if kind.startswith("metal"):
        return metal(rng, large=kind != "metal-short", long=kind == "metal-long")
    if kind == "engine":
        return engine(rng, parameter)
    if kind == "ricochet":
        return ricochet(rng, parameter)
    if kind == "equipment-drop":
        return equipment_drop(rng, parameter)
    if kind == "radio":
        return radio(rng)
    if kind == "falling":
        return falling_air(rng)
    if kind == "reward":
        return reward(rng)
    if kind == "missile":
        return missile(rng)
    raise ValueError(kind)


def render_music(variant):
    """32-second seamless original ambient cue, no melodic quotations."""
    duration = 32.0
    t = clock(duration)
    rng = np.random.default_rng(seed_for("coastal-vigil" if variant == "2000" else "interior-lines"))
    left, right = np.zeros_like(t), np.zeros_like(t)
    roots = [73.416, 110.0, 146.832, 220.0, 261.626] if variant == "2000" else [61.735, 92.499, 123.471, 164.814, 220.0]
    for index, root in enumerate(roots):
        base = round(root * duration) / duration
        pad = np.zeros_like(t)
        for harmonic, volume in [(1, 1.0), (2, 0.28), (3, 0.10), (5, 0.035)]:
            detune = (index % 3 - 1) / duration
            pad += oscillator(t, base * harmonic + detune, index * 0.41) * volume
        breathe = 0.50 + 0.20 * oscillator(t, (index % 3 + 1) / duration, index * 1.19)
        pad *= breathe * (0.105 if index < 2 else 0.042)
        pan = (index / (len(roots) - 1) - 0.5) * 0.72
        left += pad * np.sqrt((1 - pan) * 0.5)
        right += pad * np.sqrt((1 + pan) * 0.5)
    # Broadband wind bed is periodically filtered and amplitude modulated.
    for channel in [left, right]:
        air = noise(t, rng, 140, 2300, 0.75)
        channel += air * (0.005 + 0.003 * oscillator(t, 1 / duration, 0.3))
    # Restrained non-melodic low percussion, with wrapped tails for a true loop.
    hit_t = clock(2.2)
    for index, second in enumerate([0, 5.5, 12, 18.5, 24, 29.5]):
        hit = sweep(hit_t, 78, 36, 0.07) * envelope(hit_t, 0.012, 0.22)
        hit += noise(hit_t, rng, 70, 480, 0.4) * envelope(hit_t, 0.03, 0.17) * 0.23
        hit = finite_edges(hit) * (0.032 if index % 2 else 0.05)
        positions = (np.arange(len(hit)) + round(second * RATE)) % len(t)
        left[positions] += hit * 0.80
        right[positions] += hit * 0.72
    stereo = np.column_stack([left, right])
    stereo -= stereo.mean(axis=0)
    # Menu plays at unity gain; an intentionally restrained RMS suits the UI.
    stereo *= min(0.22 / max(float(np.max(np.abs(stereo))), 1e-9), 0.042 / max(float(np.sqrt(np.mean(stereo**2))), 1e-9))
    return stereo


def write_pcm(path, audio, peak=0.86, normalize=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    a = np.asarray(audio, dtype=np.float64)
    a -= np.mean(a, axis=0)
    if normalize:
        # Soft compression preserves attack transients while leaving headroom.
        a = np.tanh(a * 0.8)
        a *= peak / max(float(np.max(np.abs(a))), 1e-9)
    if not np.isfinite(a).all() or float(np.max(np.abs(a))) >= 1:
        raise ValueError(f"Non-finite or clipped signal: {path}")
    pcm = np.rint(a * 32767).astype("<i2")
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1 if a.ndim == 1 else a.shape[1])
        stream.setsampwidth(2)
        stream.setframerate(RATE)
        stream.writeframes(pcm.tobytes())
    return {
        "seconds": round(len(a) / RATE, 6),
        "sampleRate": RATE,
        "channels": 1 if a.ndim == 1 else a.shape[1],
        "sampleBits": 16,
        "peak": round(float(np.max(np.abs(a))), 6),
        "rms": round(float(np.sqrt(np.mean(a * a))), 6),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def generate(out):
    manifest = {
        "version": VERSION,
        "source": "Original deterministic procedural composition and synthesis; no recordings, samples, tracker files, source-game waveforms or third-party musical works are read.",
        "baseSeed": BASE_SEED,
        "generator": "tools/generate_original_audio.py",
        "numpyVersion": np.__version__,
        "compatibilityNames": "WAV basenames are adapter keys only, not source attribution or sampled material.",
        "voicePolicy": "Equipment-drop effects replace historic character-voice slots. These files contain no voice performance.",
        "files": [],
    }
    rendered = {}
    for legacy, (name, kind, parameter) in LEGACY_MAP.items():
        path = out / "sounds" / f"{legacy}.wav"
        if name in rendered:
            source, metadata = rendered[name]
            shutil.copyfile(source, path)
        else:
            a = render_effect(name, kind, parameter)
            metadata = write_pcm(path, a, peak=0.63 if kind == "engine" else 0.86)
            rendered[name] = (path, metadata)
        manifest["files"].append({"path": str(path.relative_to(out)), "semanticName": name,
                                  "algorithm": kind, "seed": seed_for(name), "loop": kind == "engine", **metadata})
    for variant, title in [("2000", "Coastal Vigil"), ("2002", "Interior Lines")]:
        music = render_music(variant)
        for suffix in ["music.wav", "music-loop.wav"]:
            a = music.copy()
            if suffix == "music.wav":
                a[:RATE * 3] *= (np.sin(np.linspace(0, np.pi / 2, RATE * 3)) ** 2)[:, None]
            path = out / "menu" / variant / suffix
            metadata = write_pcm(path, a, normalize=False)
            manifest["files"].append({"path": str(path.relative_to(out)), "semanticName": title,
                                      "algorithm": "original-ambient-pad-composition", "seed": seed_for(title.lower().replace(" ", "-")),
                                      "loop": suffix == "music-loop.wav", **metadata})
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    check(out)


def check(out):
    manifest = json.loads((out / "manifest.json").read_text())
    expected = {f"sounds/{key}.wav" for key in LEGACY_MAP}
    expected |= {f"menu/{version}/{file}" for version in ["2000", "2002"] for file in ["music.wav", "music-loop.wav"]}
    if set(item["path"] for item in manifest["files"]) != expected:
        raise AssertionError("Manifest does not cover all catalog/music paths")
    results = []
    for item in manifest["files"]:
        path = out / item["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise AssertionError(f"Digest mismatch: {path}")
        with wave.open(str(path), "rb") as stream:
            if stream.getframerate() != RATE or stream.getsampwidth() != 2:
                raise AssertionError(f"Unsupported PCM: {path}")
            a = np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").astype(np.float64) / 32767
            a = a.reshape(-1, stream.getnchannels())
        peak, rms = float(np.max(np.abs(a))), float(np.sqrt(np.mean(a * a)))
        if not (0.004 < rms < 0.5 and peak < 0.98 and np.max(np.abs(a.mean(axis=0))) < 0.002):
            raise AssertionError(f"Invalid signal level/DC: {path}: {peak}, {rms}")
        jump = float(np.max(np.abs(a[0] - a[-1])))
        # Compare boundary with ordinary sample derivatives, not an artificial zero.
        derivative99 = float(np.quantile(np.max(np.abs(np.diff(a, axis=0)), axis=1), 0.99))
        if item["loop"] and jump > max(0.025, derivative99 * 2.5):
            raise AssertionError(f"Discontinuous loop: {path}: {jump} > {derivative99}")
        results.append({"path": item["path"], "peak": round(peak, 6), "rms": round(rms, 6),
                        "boundaryStep": round(jump, 6), "derivativeP99": round(derivative99, 6), "passed": True})
    report = {"status": "passed", "scope": "Catalog completeness, PCM readability, per-file digest, peak/RMS/DC bounds, and loop-boundary continuity. Not a subjective listening sign-off.",
              "fileCount": len(results), "files": results}
    (out / "validation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"PASS: {len(results)} original PCM files; catalog, hashes, levels, DC and seamless-loop checks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "original-assets" / "audio")
    parser.add_argument("--check", action="store_true", help="Validate existing generated files without rendering")
    args = parser.parse_args()
    if args.check:
        check(args.output)
    else:
        generate(args.output)


if __name__ == "__main__":
    main()
