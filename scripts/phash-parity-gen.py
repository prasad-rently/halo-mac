#!/usr/bin/env python3
"""Generates the INPUT half of docs/specs/phash-parity.v1.json (F-025 pHash cross-language parity).

Deterministic and dependency-free: it uses its own xorshift64* PRNG (not Python's `random`, whose stream is an
implementation detail), so the same seed gives the same matrices on any machine. Each case is a 32x32 grid of
8-bit grayscale values, row-major (index = y*32 + x) - exactly what `grayscale32x32` hands to `perceptualHash`
in Halo/Core/Scanner/PerceptualDuplicateDetector.swift.

Pipeline:   python3 scripts/phash-parity-gen.py          # writes inputs, drops any stale expectations
            swift scripts/phash-parity-swift.swift --write   # the SWIFT code fills in expected hashes
            (Kotlin: android/halophotos PHashParityTest asserts the same hashes)
"""
import json, math, os, sys

SEED = 0x48414C4F50484153  # "HALOPHAS"
M64 = (1 << 64) - 1

class Rng:
    def __init__(self, seed): self.s = seed or 1
    def next(self):
        x = self.s
        x ^= x >> 12; x ^= (x << 25) & M64; x ^= x >> 27
        self.s = x
        return (x * 0x2545F4914F6CDD1D) & M64
    def byte(self): return (self.next() >> 56) & 0xFF
    def unit(self): return (self.next() >> 11) / float(1 << 53)

def clamp(v): return max(0, min(255, int(round(v))))
def grid(f): return [clamp(f(x, y)) for y in range(32) for x in range(32)]

def noise(r): return [r.byte() for _ in range(1024)]
def perturb(base, r, amp):
    return [clamp(v + (r.byte() % (2 * amp + 1)) - amp) for v in base]
def smooth_scene(r):
    # a few random low-frequency blobs: the sort of thing real photos reduce to at 32x32
    blobs = [(r.unit() * 32, r.unit() * 32, 3 + r.unit() * 10, 40 + r.unit() * 180) for _ in range(5)]
    def f(x, y):
        v = 40.0
        for (cx, cy, rad, amp) in blobs:
            v += amp * math.exp(-(((x - cx) ** 2 + (y - cy) ** 2) / (2 * rad * rad)))
        return v
    return grid(f)

def build():
    r = Rng(SEED)
    cases = []
    def add(name, px, degenerate=False, note=""):
        assert len(px) == 1024 and all(0 <= v <= 255 for v in px)
        cases.append({"name": name, "degenerate": degenerate, "note": note, "pixels": px})

    # Degenerate: every AC coefficient is ~0, so which side of the median a bit falls on is floating-point
    # noise (~1e-13). They are recorded for completeness but the Kotlin test does NOT assert their bits.
    add("flat-0", [0] * 1024, True, "all AC terms are rounding noise")
    add("flat-128", [128] * 1024, True, "all AC terms are rounding noise")
    add("flat-255", [255] * 1024, True, "all AC terms are rounding noise")

    # Structured shapes. Their pure forms are symmetric, so many DCT coefficients are exact zeros that only exist as
    # +-1e-15 rounding noise - the hash bit for those is a coin-flip decided by the libm's last ulp, not by the algorithm.
    # Each is therefore recorded twice: "pure-*" (degenerate, not asserted bit-for-bit) and "*-noisy" (+-2 seeded noise,
    # which lifts every coefficient clear of the median and is asserted).
    shapes = [
        ("gradient-horizontal", lambda x, y: x * 255 / 31),
        ("gradient-vertical", lambda x, y: y * 255 / 31),
        ("gradient-diagonal", lambda x, y: (x + y) * 255 / 62),
        ("checkerboard-4", lambda x, y: 255 if ((x // 4) + (y // 4)) % 2 == 0 else 0),
        ("stripes-vertical-8", lambda x, y: 255 if (x // 8) % 2 == 0 else 20),
        ("half-split", lambda x, y: 220 if x < 16 else 30),
        ("quadrants", lambda x, y: [200, 60, 90, 240][(y >= 16) * 2 + (x >= 16)]),
        ("impulse-centre", lambda x, y: 255 if (x, y) == (16, 16) else 10),
        ("cosine-1-0", lambda x, y: 128 + 100 * math.cos(math.pi * (x + 0.5) * 1 / 32)),
        ("cosine-3-2", lambda x, y: 128 + 90 * math.cos(math.pi * (x + 0.5) * 3 / 32) * math.cos(math.pi * (y + 0.5) * 2 / 32)),
        ("radial", lambda x, y: 255 * math.hypot(x - 15.5, y - 15.5) / 22),
        ("saturated-edges", lambda x, y: 255 if x in (0, 31) or y in (0, 31) else 0),
    ]
    for name, f in shapes:
        px = grid(f)
        add("pure-" + name, px, True, "symmetric: coefficients are exact zeros up to rounding noise")
        add(name + "-noisy", perturb(px, r, 2), note="+-2 seeded noise so no coefficient sits on the median")

    for i in range(6):
        add(f"noise-{i}", noise(r))
    for i in range(6):
        s = smooth_scene(r)
        add(f"scene-{i}", s)
        add(f"scene-{i}-jpegish", perturb(s, r, 3), note="same scene + +-3 noise (re-compression stand-in)")
    base = smooth_scene(r)
    add("scene-bright", [clamp(v + 40) for v in base], note="brightness shift of scene-base")
    add("scene-base", base)
    add("scene-contrast", [clamp((v - 128) * 1.3 + 128) for v in base], note="contrast stretch of scene-base")
    return cases

if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "specs", "phash-parity.v1.json")
    doc = {
        "version": 1,
        "description": "Cross-language pHash parity for F-025 Similar Photos. Inputs: 32x32 8-bit grayscale matrices (row-major). "
                       "Expected: produced by the real Swift DCT/median code (scripts/phash-parity-swift.swift, verified identical to "
                       "Halo/Core/Scanner/PerceptualDuplicateDetector.swift). Hash bit i (MSB first) = coefficient (y=i/8, x=i%8) > median of the 63 AC terms.",
        "generator": "scripts/phash-parity-gen.py",
        "seed": hex(SEED),
        "cases": build(),
    }
    # One case per line: reviewable diffs, and the exact layout the Swift writer reproduces.
    with open(out, "w") as f:
        f.write("{\n")
        for k in ("version", "description", "generator", "seed"):
            f.write(" %s: %s,\n" % (json.dumps(k), json.dumps(doc[k])))
        f.write(' "cases": [\n')
        f.write(",\n".join("  " + json.dumps(c, sort_keys=True, separators=(",", ":")) for c in doc["cases"]))
        f.write("\n ]\n}\n")
    print("wrote", len(doc["cases"]), "cases ->", os.path.normpath(out))
