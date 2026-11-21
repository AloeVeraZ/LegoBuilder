#!/usr/bin/env python3
"""Checks that the 42233-3 model is physically put together, not just drawn close.

    python3 pipeline/models/check_42233_3.py app/BuildLens/Resources/BuildData

For every pin and axle it finds the holes the shaft actually passes through: a hole counts
only if it is on the shaft's centre line, parallel to it and within the shaft's length.
Each shaft must go through the number of parts the real build needs, and every hole that
should be filled must be. Exits with an error if anything is loose or floating.
"""
import json
import sys

import numpy as np

LDU = 0.0004
FLIP = np.diag([1.0, -1.0, -1.0, 1.0])
X, Y, Z = np.eye(3)

# Holes of each part in its own LDraw frame: (centre, axis, label)
HOLES = {
    "32184": [((0, 0, 0), Z, "centre pin hole"), ((0, -20, 0), X, "end axle hole"), ((0, 20, 0), X, "end axle hole")],
    "92907": [((0, 0, 0), Z, "round hole"),
              ((15, 20, 0), X, "arm hole"), ((-15, 20, 0), X, "arm hole"),
              ((15, 20, -20), X, "arm hole, 2nd row"), ((-15, 20, -20), X, "arm hole, 2nd row")],
    "63869": [((0, 0, 0), X, "lug axle hole"),
              ((-20, 20, 0), Z, "hole 1"), ((0, 20, 0), Z, "hole 2"), ((20, 20, 0), Z, "hole 3")],
    "32140": [((0, 0, 0), Y, "axle hole"), ((0, 0, 20), Y, "hole 2"), ((0, 0, 40), Y, "hole 3"),
              ((0, 0, 60), Y, "corner hole"), ((20, 0, 60), Y, "short-arm hole")],
    "7944": [((-20, 0, 0), Z, "axle hole"), ((0, 0, 0), Z, "pin hole"), ((20, 0, 0), Z, "axle hole")],
    "7450": [((20.5, 0, 30), X, "hinge boss"), ((20, 0, 10), Z, "joining boss")],
    "7451": [((20.5, 0, -30), X, "hinge boss"), ((20, 0, -10), Z, "joining boss")],
    "42610": [((0, 0, 0), Z, "hub")],
}
# Holes that are cross-shaped (take an axle, not a round pin).
AXLE_HOLES = {("32184", "end axle hole"), ("92907", "arm hole"), ("92907", "arm hole, 2nd row"),
              ("63869", "lug axle hole"), ("32140", "axle hole"), ("7944", "axle hole"),
              ("7450", "hinge boss"), ("7450", "joining boss"), ("7451", "hinge boss"), ("7451", "joining boss")}
# Shafts: extent along the part's own X axis, and how many holes each must pass through.
SHAFTS = {
    "3673": (-20, 20, 2, "pin"),
    "3749": (-20, 20, 3, "axle pin"),
    "32062": (-20, 20, None, "axle 2"),      # 3 across a split block, 2 when joining two panels
    "4519": (-30, 30, 3, "axle 3"),
    "32002": (-20, 10, 2, "3/4 pin"),
}


def main():
    build = sys.argv[1] if len(sys.argv) > 1 else "app/BuildLens/Resources/BuildData"
    pkg = json.load(open(f"{build}/build.json"))
    parts = pkg["parts"]
    placed = []
    for i, inst in enumerate(pkg["instances"]):
        m = np.array(inst["matrix"], float).reshape(4, 4).T        # column-major, metres, +Y up
        m = FLIP @ m @ FLIP                                         # back to LDraw axes
        m[:3, 3] /= LDU
        placed.append((i, parts[inst["part"]]["number"], m))

    holes = []
    for i, number, m in placed:
        for centre, axis, label in HOLES.get(number, []):
            holes.append({"owner": i, "part": number, "label": label, "used": 0,
                          "centre": (m @ np.array([*centre, 1.0]))[:3], "axis": m[:3, :3] @ axis})

    problems = []
    print(f"{'shaft':<10}{'at (x, y, z)':<22}passes through")
    for i, number, m in placed:
        if number not in SHAFTS:
            continue
        lo, hi, need, name = SHAFTS[number]
        origin, direction = m[:3, 3], m[:3, 0]
        through = []
        for h in holes:
            along = np.dot(h["centre"] - origin, direction)
            off = np.linalg.norm(h["centre"] - origin - along * direction)
            if abs(np.dot(h["axis"], direction)) > 0.99 and off < 0.6 and lo - 0.6 <= along <= hi + 0.6:
                h["used"] += 1
                through.append(f"{h['part']} {h['label']}")
                # Shapes must match: a round pin end cannot go into a cross-shaped axle hole,
                # and the axle pin's cross-shaped end (its +X half) belongs in one.
                cross_hole = (h["part"], h["label"]) in AXLE_HOLES
                round_end = number in ("3673", "32002") or (number == "3749" and along < -0.6)
                cross_end = number == "3749" and along > 0.6
                if round_end and cross_hole:
                    problems.append(f"round end of {name} at piece {i} is in a cross-shaped hole ({h['part']} {h['label']})")
                if cross_end and not cross_hole:
                    problems.append(f"axle end of {name} at piece {i} is in a round hole ({h['part']} {h['label']})")
        pos = "(" + ", ".join(f"{v:g}" for v in np.round(origin, 1)) + ")"
        print(f"{name:<10}{pos:<22}{'; '.join(through) or 'NOTHING'}")
        if len(through) < (need or 2):
            problems.append(f"{name} at {pos} only passes through {len(through)} hole(s)")

    # Holes that must not be left empty in the finished truck.
    # (The rear cab half's middle hole stays open: the 3/4 pin only reaches through the
    # front half and the connector.)
    must_fill = {"32184": None, "42610": None, "7944": ("axle hole",), "7450": None, "7451": None,
                 "63869": None, "92907": ("round hole",), "32140": ("axle hole", "corner hole", "short-arm hole")}
    for h in holes:
        wanted = must_fill.get(h["part"], ())
        if h["used"] == 0 and (wanted is None or h["label"] in wanted):
            problems.append(f"{h['part']} {h['label']} of piece {h['owner']} is empty")

    # Wheels: tyre on its rim, both on the ground.
    for i, number, m in placed:
        if number == "50951" and not any(n == "42610" and np.allclose(mm[:3, 3], m[:3, 3], atol=0.1) for _, n, mm in placed):
            problems.append(f"tyre {i} is not on a rim")
        if number == "50951" and abs(m[1, 3] + 19) > 0.1:
            problems.append(f"tyre {i} is not on the ground")

    print()
    if problems:
        print(f"{len(problems)} PROBLEM(S):")
        for p in problems:
            print("  -", p)
        sys.exit(1)
    print(f"OK: all {sum(1 for _, n, _ in placed if n in SHAFTS)} pins and axles are seated in the holes they connect.")


if __name__ == "__main__":
    main()
