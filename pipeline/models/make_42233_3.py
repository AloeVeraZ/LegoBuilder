#!/usr/bin/env python3
"""Writes 42233-3-dump-truck.mpd: LEGO Technic 42233-3 Dump Truck (46 pieces), following
the step order of the official printed instructions (23 steps):

  1-6    rear bogie (cross block, two split blocks, four wheel axle pins, articulation pin)
  7-12   front unit sub-build (cross block, split block, front axle pins, yellow triple
         connector, split block + axle)
  13     front unit onto the articulation pin
  14-15  cab sub-build (trapezoid frame, 3/4 pin, two axles)
  16     cab onto the front unit
  17     second trapezoid frame
  18     yellow L-beam on the rear bogie + axle
  19-21  tipper-bed half sub-build, x2 (two shovel panels, axle 2, axle 3)
  22     both bed halves onto the L-beam
  23     six wheels (rim + tyre)

Three 2026 parts are not in the LDraw library yet (7450, 7451 shovel panels and 7944
trapezoid frame): they are included here as simplified shapes. Positions are matched to
the instruction drawings by eye. LDraw units: 1 stud = 20 LDU, -Y up, truck front at -Z.
"""
import os
import numpy as np

YEL, BLK, LBG, DBG, TAN = 14, 0, 71, 72, 19
X, Y, Z = np.eye(3)
UP = -Y

def rot(ex, ey):
    """Rotation whose columns send local X to ex and local Y to ey (Z follows)."""
    ex, ey = np.array(ex, float), np.array(ey, float)
    m = np.column_stack([ex, ey, np.cross(ex, ey)])
    return " ".join(f"{v:g}" for v in m.reshape(-1))

def ref(colour, pos, r, name):
    return f"1 {colour} {pos[0]:g} {pos[1]:g} {pos[2]:g} {r} {name}"

I = rot(X, Y)
# pins / axles: local X is the shaft
SHAFT_X, SHAFT_NX, SHAFT_Z, SHAFT_UP = rot(X, Y), rot(-X, -Y), rot(Z, Y), rot(UP, X)
# 32184: local Y = length (axle through), local Z = centre pin hole. Length along Z, pin hole vertical.
CROSS_BLOCK = rot(-X, Z)                # local Y -> Z, local Z -> Y
# 92907: local Z = round pin hole, axle holes at local (+-10, 20, 0 / -20). Pin hole vertical,
# axle holes 20 behind the pin hole (rear) or in front (front).
SPLIT_REAR = rot(X, Z)                  # local Y -> +Z, local Z -> -Y (up): holes behind, body below
SPLIT_FRONT = rot(-X, -Z)
# 63869: axle hole along local X at (10,0,0); three holes along X at y=20, axis Z.
TRIPLE = rot(X, -Y)                     # holes above the axle hole, facing forward
# wheels: rim/tyre axis is local Z
WHEEL_R, WHEEL_L = rot(Z, Y), rot(-Z, Y)
# 32140: long arm along local Z (0..60), short arm along +X, holes axis Y.
LBEAM = rot(Y, -X)                      # long arm along +Z (rear), short arm pointing down, holes along X
# simplified parts are drawn in their own frames below
FRAME = rot(X, Y)

# ------------------------------------------------------------- simplified 2026 parts
def quads(p, faces):
    return ["4 16 " + " ".join(f"{c:g}" for i in f for c in p[i]) for f in faces]

BOX_FACES = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]

def box(x0, x1, y0, y1, z0, z1):
    p = [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1),
         (x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)]
    return quads(p, BOX_FACES)

def prism(profile, z0, z1):
    """Extrude a convex 2D (x, y) polygon along Z."""
    out = []
    n = len(profile)
    a = [(x, y, z0) for x, y in profile]
    b = [(x, y, z1) for x, y in profile]
    for i in range(n):
        j = (i + 1) % n
        out += quads([a[i], a[j], b[j], b[i]], [(0, 1, 2, 3)])
    for k in range(1, n - 1):
        out.append("3 16 " + " ".join(f"{c:g}" for p in (a[0], a[k], a[k + 1]) for c in p))
        out.append("3 16 " + " ".join(f"{c:g}" for p in (b[0], b[k + 1], b[k]) for c in p))
    return out

def part_file(name, title, lines):
    return [f"0 FILE {name}", f"0 {title}", f"0 Name: {name}", "0 Author: BuildLens (simplified stand-in)",
            "0 !LDRAW_ORG Unofficial_Part", "0 BFC NOCERTIFY", ""] + lines + ["0 NOFILE", ""]

# 7944: 1x3 thin beam along X (holes axle-pin-axle, axis Z) with a trapezoid frame loop above it
def bar(a, b, half_w=5, half_t=4):
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    ln = (dx * dx + dy * dy) ** 0.5
    nx, ny = -dy / ln * half_t, dx / ln * half_t
    return prism([(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)], -half_w, half_w)

frame = box(-30, 30, -10, 10, -5, 5)
frame += bar((-28, -8), (-18, -36)) + bar((28, -8), (18, -36)) + bar((-22, -34), (22, -34))
# 7450 / 7451: shovel panel 2x3x2 - bed side wall with a curved floor lip and an axle hole knuckle
def shovel(side):
    s = 1 if side == "R" else -1
    out = box(-20, 20, -4, 4, -30, 30)                                      # floor
    out += prism([(s * 16, 4), (s * 22, 4), (s * 26, -40), (s * 20, -40)][:: (1 if s > 0 else -1)], -30, 30)
    out += box(-20, 20, -40, 0, 26, 30)                                     # end wall
    out += box(min(s * 4, s * 24), max(s * 4, s * 24), 4, 16, -30, -18)     # knuckle with axle hole
    return out

files = []
files += part_file("7944.dat", "Technic Beam 1 x 3 Thin with Trapezoid Frame", frame)
files += part_file("7450.dat", "Technic Panel Shovel 2 x 3 x 2 Right", shovel("R"))
files += part_file("7451.dat", "Technic Panel Shovel 2 x 3 x 2 Left", shovel("L"))

def model(name, steps):
    out = [f"0 FILE {name}", f"0 {name[:-4]}", f"0 Name: {name}", "0 Author: BuildLens", "0 !LDRAW_ORG Model", ""]
    for s in steps:
        out += s + ["0 STEP", ""]
    return out + ["0 NOFILE", ""]

# ------------------------------------------------------------- layout
AXLE_Y = -19            # wheel centre height (tyre radius 19)
# rear bogie: split blocks with their lower axle-hole row at wheel height
R_BLOCK_Y = AXLE_Y - 20 # round pin hole 20 above the lower axle row
RB1_Z, RB2_Z = 40, 0    # rear split blocks (their axle holes sit 20 behind -> wheels at 60 and 20)
REAR_WHEELS = [RB1_Z + 20, RB2_Z + 20]

# front unit (local to the front unit: origin at the articulation hole)
FRONT_AXLE_Z = -70

def axle_pins(z, y=AXLE_Y, sides=("R", "L")):
    out = []
    if "R" in sides: out.append(ref(TAN, (30, y, z), SHAFT_X, "3749.dat"))
    if "L" in sides: out.append(ref(TAN, (-30, y, z), SHAFT_NX, "3749.dat"))
    return out

rear = [
    [ref(DBG, (0, R_BLOCK_Y + 30, 20), CROSS_BLOCK, "32184.dat"),
     ref(LBG, (0, R_BLOCK_Y + 10, 20), SHAFT_UP, "3673.dat")],                                   # 1
    [ref(BLK, (0, R_BLOCK_Y, RB1_Z), SPLIT_REAR, "92907.dat")],                                  # 2
    axle_pins(REAR_WHEELS[0], sides="R"),                                                        # 3
    [ref(BLK, (0, R_BLOCK_Y, RB2_Z), SPLIT_REAR, "92907.dat")] + axle_pins(REAR_WHEELS[1], sides="R"),  # 4
    axle_pins(REAR_WHEELS[0], sides="L") + axle_pins(REAR_WHEELS[1], sides="L"),                 # 5
    [ref(LBG, (0, R_BLOCK_Y - 20, RB2_Z), SHAFT_UP, "3673.dat")],                                # 6
]

FB_Y = R_BLOCK_Y - 20       # front unit sits one hole above the rear bogie
front_unit = model("Front Unit.ldr", [
    [ref(DBG, (0, AXLE_Y + 4, -60), CROSS_BLOCK, "32184.dat"),
     ref(LBG, (0, AXLE_Y - 16, -60), SHAFT_UP, "3673.dat")],                                     # 7
    [ref(BLK, (0, AXLE_Y - 20, -50), SPLIT_FRONT, "92907.dat")],                                 # 8
    axle_pins(FRONT_AXLE_Z, sides="R"),                                                          # 9
    [ref(BLK, (0, AXLE_Y - 30, -40), SHAFT_Z, "32062.dat")] + axle_pins(FRONT_AXLE_Z, sides="L"), # 10
    [ref(YEL, (-10, AXLE_Y - 50, -55), TRIPLE, "63869.dat")],                                    # 11
    [ref(BLK, (0, FB_Y, RB2_Z), SPLIT_FRONT, "92907.dat"),
     ref(BLK, (0, FB_Y + 10, RB2_Z - 30), SHAFT_Z, "32062.dat")],                                # 12
])

cab = model("Cab.ldr", [
    [ref(YEL, (0, 0, 0), FRAME, "7944.dat"), ref(TAN, (0, 0, 10), rot(Z, Y), "32002.dat")],      # 14
    [ref(BLK, (-20, 0, 15), SHAFT_Z, "32062.dat"), ref(BLK, (20, 0, 15), SHAFT_Z, "32062.dat")], # 15
])
CAB_POS = (0, AXLE_Y - 75, -66)

bed_half = model("Tipper Bed Half.ldr", [
    [ref(YEL, (20, 0, 0), I, "7450.dat"), ref(BLK, (20, 10, -24), SHAFT_X, "32062.dat")],        # 19
    [ref(YEL, (0, 10, -24), SHAFT_X, "4519.dat")],                                                # 20
    [ref(YEL, (-20, 0, 0), I, "7451.dat")],                                                       # 21
])

main = model("42233-3 Dump Truck.ldr", rear + [
    [ref(16, (0, 0, 0), I, "Front Unit.ldr")],                                                   # 13
    [ref(16, CAB_POS, I, "Cab.ldr")],                                                            # 16 (after cab sub-build)
    [ref(YEL, (CAB_POS[0], CAB_POS[1], CAB_POS[2] + 22), FRAME, "7944.dat")],                    # 17
    [ref(YEL, (10, FB_Y - 10, -5), LBEAM, "32140.dat"),
     ref(BLK, (0, AXLE_Y - 20, 55), SHAFT_X, "32062.dat")],                                      # 18
    [ref(16, (0, FB_Y - 40, 20), I, "Tipper Bed Half.ldr"),
     ref(16, (0, FB_Y - 40, 80), rot(-X, Y), "Tipper Bed Half.ldr")],                            # 22
    [ref(LBG, (40, AXLE_Y, z), WHEEL_R, "42610.dat") for z in [FRONT_AXLE_Z] + REAR_WHEELS] +
    [ref(LBG, (-40, AXLE_Y, z), WHEEL_L, "42610.dat") for z in [FRONT_AXLE_Z] + REAR_WHEELS] +
    [ref(BLK, (40, AXLE_Y, z), WHEEL_R, "50951.dat") for z in [FRONT_AXLE_Z] + REAR_WHEELS] +
    [ref(BLK, (-40, AXLE_Y, z), WHEEL_L, "50951.dat") for z in [FRONT_AXLE_Z] + REAR_WHEELS],   # 23
])

# The main model references the cab after step 13 but its own steps (14-15) must come
# first, which the converter does automatically for first-time sub-models.
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "42233-3-dump-truck.mpd")
with open(out, "w") as fh:
    fh.write("\n".join(main + front_unit + cab + bed_half + files))
print(out)
