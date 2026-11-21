#!/usr/bin/env python3
"""How the glasses' gyroscope sits against their camera, from a real session.

The glasses log, for every camera picture in which the phone's code is seen, which way the
gyroscope says the glasses point (a quaternion) and how the code is turned in the camera
picture ("axes:" lines, MainActivity.onMarker). The code lies still on the table, so for
the right camera-to-glasses turn X, glassesTurn * X * codeTurnInCamera is the same for
every picture. This tries all 24 square turns and prints how well each holds still.

    adb logcat -d -s BuildLens | python3 glasses/tools/axes.py

Turn the head slowly while looking at the code for ten seconds or so first. The lines are only
logged by a build with MainActivity.LOG_AXES set to true.
"""
import itertools
import math
import sys

import numpy as np


def quat_matrix(w, x, y, z):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
        [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
        [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ])


def angle(a, b):
    c = (np.trace(a.T @ b) - 1) / 2
    return math.degrees(math.acos(max(-1.0, min(1.0, c))))


rows = []
for line in sys.stdin:
    if "axes:" not in line:
        continue
    v = [float(t) for t in line.split("axes:")[1].split()]
    rows.append((quat_matrix(*v[1:5]), np.array(v[5:14]).reshape(3, 3)))
if len(rows) < 10:
    sys.exit(f"only {len(rows)} readings: look at the code and turn the head slowly for longer")

turned = max(angle(rows[0][0], d) for d, _ in rows)
print(f"{len(rows)} readings; the head turned up to {turned:.0f} degrees")

candidates = []
for perm in itertools.permutations(range(3)):
    for signs in itertools.product((1, -1), repeat=3):
        x = np.zeros((3, 3))
        for col, (row, s) in enumerate(zip(perm, signs)):
            x[row, col] = s
        if round(np.linalg.det(x)) != 1:
            continue
        held = [d @ x @ c for d, c in rows]
        spread = sum(angle(held[0], h) for h in held) / len(held)
        candidates.append((spread, x))
candidates.sort(key=lambda t: t[0])
for spread, x in candidates[:4]:
    cols = ["".join("+" if v > 0 else "-" for v in x[:, i] if v) + "xyz"[int(np.argmax(abs(x[:, i])))] for i in range(3)]
    print(f"  spread {spread:5.1f} deg: camera x,y,z = glasses {cols[0]}, {cols[1]}, {cols[2]}")
best = candidates[0][1]
print("HeadTracker CAMERA_IN_GLASSES =", [int(v) for v in best.flatten()])
