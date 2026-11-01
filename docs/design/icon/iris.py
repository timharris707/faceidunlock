#!/usr/bin/env python3
"""Print the six iris-blade geometries (wedges, leading edges) for the aperture icon as SVG path data.

Usage: iris.py cx cy R r_in sweep_deg rot_deg bow
Each blade's leading edge is an arc from radius r_in (hidden inside the keyhole) to the rim, turning sweep_deg.
"""
import math, sys, json

def pt(cx, cy, r, a):
    return (cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))

def f(p):
    return f"{p[0]:.2f} {p[1]:.2f}"

def iris(cx, cy, R, r_in, sweep, rot, bow, n=6):
    step = 360 / n
    starts = [pt(cx, cy, r_in, rot + i * step) for i in range(n)]
    ends = [pt(cx, cy, R, rot + i * step + sweep) for i in range(n)]
    edges, wedges = [], []
    for i in range(n):
        j = (i + 1) % n
        edges.append(f"M{f(starts[i])}A{bow} {bow} 0 0 1 {f(ends[i])}")
        wedges.append(
            f"M{cx} {cy}L{f(starts[i])}A{bow} {bow} 0 0 1 {f(ends[i])}"
            f"A{R} {R} 0 0 1 {f(ends[j])}A{bow} {bow} 0 0 0 {f(starts[j])}Z"
        )
    return {"edges": edges, "wedges": wedges, "mid": [rot + i * step + sweep * 0.6 + step / 2 for i in range(n)]}

if __name__ == "__main__":
    a = list(map(float, sys.argv[1:8]))
    print(json.dumps(iris(*a)))
