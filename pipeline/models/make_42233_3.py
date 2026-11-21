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

def prism_x(profile_yz, x0, x1, colour=16):
    """Extrude a convex (y, z) polygon along X."""
    out = []
    n = len(profile_yz)
    a = [(x0, y, z) for y, z in profile_yz]
    b = [(x1, y, z) for y, z in profile_yz]
    for i in range(n):
        j = (i + 1) % n
        out.append(f"4 {colour} " + " ".join(f"{c:g}" for p in (a[i], a[j], b[j], b[i]) for c in p))
    for k in range(1, n - 1):
        out.append(f"3 {colour} " + " ".join(f"{c:g}" for p in (a[0], a[k], a[k + 1]) for c in p))
        out.append(f"3 {colour} " + " ".join(f"{c:g}" for p in (b[0], b[k + 1], b[k]) for c in p))
    return out

def cross_mark(cx, cy, z):
    """Black axle-hole cross drawn on a face at depth z (facing -Z)."""
    out = []
    for (w, h) in ((8, 2.4), (2.4, 8)):
        out.append(f"4 0 {cx - w:g} {cy - h:g} {z:g} {cx + w:g} {cy - h:g} {z:g} {cx + w:g} {cy + h:g} {z:g} {cx - w:g} {cy + h:g} {z:g}")
    return out

# 7944: thin 1x3 beam at the front (axle-pin-axle holes, axis Z) plus half of the cab shell:
# a hood sloping up and back, a flat roof, and side frames with a window.
frame = box(-30, 30, -10, 10, -5, 5)
frame += prism_x([(-10, -5), (-10, 5), (-36, 14), (-40, 14), (-40, 4)], -30, 30)   # sloped hood
frame += box(-30, 30, -42, -36, 4, 30)                                            # roof
for sx in (-30, 25):                                                              # side frames
    frame += box(sx, sx + 5, -40, 10, 25, 30)
    frame += box(sx, sx + 5, 3, 10, -5, 30)
frame += cross_mark(-20, 0, -5.2) + cross_mark(20, 0, -5.2)

# 7450 / 7451: one panel of a tipper-bed side: floor, outer wall leaning out, end wall
# leaning out, rim, and a hinge knuckle with an axle hole at the bottom corner.
def shovel(side):
    e = -1 if side == "R" else 1                                                   # closed end
    out = box(0, 40, -4, 4, -22, 22)                                               # floor
    out += prism([(40, 4), (45, 4), (51, -38), (46, -38)], -22, 22)               # outer wall
    end = [(4, e * 22), (4, e * 26), (-38, e * 31), (-38, e * 27)]
    out += prism_x(end, 0, 50)                                                     # end wall
    out += box(0, 51, -42, -38, e * 31 - 3, e * 31 + 1) if e > 0 else box(0, 51, -42, -38, e * 31 - 1, e * 31 + 3)
    out += box(30, 46, 4, 18, e * 22 - 12, e * 22 + 2) if e > 0 else box(30, 46, 4, 18, e * 22 - 2, e * 22 + 12)
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
R_BLOCK_Y = AXLE_Y - 20 # split blocks: round pin hole on top, lower axle row at wheel height
RB1_Z, RB2_Z = 40, 0    # rear split blocks (axle holes 20 behind -> wheels at 60 and 20)
REAR_WHEELS = [RB1_Z + 20, RB2_Z + 20]
FRONT_AXLE_Z = -50

def axle_pins(z, y=AXLE_Y, sides=("R", "L")):
    out = []
    if "R" in sides: out.append(ref(TAN, (30, y, z), SHAFT_X, "3749.dat"))
    if "L" in sides: out.append(ref(TAN, (-30, y, z), SHAFT_NX, "3749.dat"))
    return out

rear = [
    [ref(DBG, (0, R_BLOCK_Y + 28, 20), CROSS_BLOCK, "32184.dat"),
     ref(LBG, (0, R_BLOCK_Y + 8, 20), SHAFT_UP, "3673.dat")],                                    # 1
    [ref(BLK, (0, R_BLOCK_Y, RB1_Z), SPLIT_REAR, "92907.dat")],                                  # 2
    axle_pins(REAR_WHEELS[0], sides="R"),                                                        # 3
    [ref(BLK, (0, R_BLOCK_Y, RB2_Z), SPLIT_REAR, "92907.dat")] + axle_pins(REAR_WHEELS[1], sides="R"),  # 4
    axle_pins(REAR_WHEELS[0], sides="L") + axle_pins(REAR_WHEELS[1], sides="L"),                 # 5
    [ref(LBG, (0, R_BLOCK_Y - 20, RB2_Z), SHAFT_UP, "3673.dat")],                                # 6
]

FB_Y = R_BLOCK_Y - 20       # front unit's articulation block sits on the rear pin
front_unit = model("Front Unit.ldr", [
    [ref(DBG, (0, AXLE_Y + 8, -40), CROSS_BLOCK, "32184.dat"),
     ref(LBG, (0, AXLE_Y - 12, -40), SHAFT_UP, "3673.dat")],                                     # 7
    [ref(BLK, (0, AXLE_Y - 20, -30), SPLIT_FRONT, "92907.dat")],                                 # 8
    axle_pins(FRONT_AXLE_Z, sides="R"),                                                          # 9
    [ref(BLK, (0, AXLE_Y - 30, -15), SHAFT_Z, "32062.dat")] + axle_pins(FRONT_AXLE_Z, sides="L"), # 10
    [ref(YEL, (0, AXLE_Y - 16, -45), TRIPLE, "63869.dat")],                                      # 11
    [ref(BLK, (0, FB_Y, RB2_Z), SPLIT_FRONT, "92907.dat"),
     ref(BLK, (0, FB_Y + 10, RB2_Z - 25), SHAFT_Z, "32062.dat")],                                # 12
])

# Cab sub-build (steps 14-15) is the REAR half: frame facing backwards, with the 3/4 pin
# and two axles pointing forward. Step 17's frame is the front half and slides onto them.
BEHIND = rot(-X, Y)          # turned 180 degrees
cab = model("Cab.ldr", [
    [ref(YEL, (0, 0, 0), BEHIND, "7944.dat"), ref(TAN, (0, 0, -10), rot(-Z, Y), "32002.dat")],   # 14
    [ref(BLK, (-20, 0, -20), SHAFT_Z, "32062.dat"), ref(BLK, (20, 0, -20), SHAFT_Z, "32062.dat")], # 15
])
CAB_FRONT = (0, -46, -68)
CAB_POS = (0, -46, -8)

# one side of the tipper bed: front panel + rear panel joined by an axle, hinge axle in front
bed_half = model("Tipper Bed Half.ldr", [
    [ref(YEL, (0, 0, -22), I, "7451.dat"), ref(BLK, (37, 11, 0), SHAFT_Z, "32062.dat")],         # 19
    [ref(YEL, (22, 11, -34), SHAFT_X, "4519.dat")],                                               # 20
    [ref(YEL, (0, 0, 22), I, "7450.dat")],                                                        # 21
])
BED_Y, BED_Z = -66, 40

main = model("42233-3 Dump Truck.ldr", rear + [
    [ref(16, (0, 0, 0), I, "Front Unit.ldr")],                                                   # 13
    [ref(16, CAB_POS, I, "Cab.ldr")],                                                            # 16 (after cab sub-build)
    [ref(YEL, CAB_FRONT, FRAME, "7944.dat")],                                                    # 17
    [ref(YEL, (0, -52, 5), LBEAM, "32140.dat"),
     ref(BLK, (0, AXLE_Y - 22, 40), SHAFT_X, "32062.dat")],                                      # 18
    [ref(16, (0, BED_Y, BED_Z), I, "Tipper Bed Half.ldr"),
     ref(16, (0, BED_Y, BED_Z), BEHIND, "Tipper Bed Half.ldr")],                                 # 22
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
