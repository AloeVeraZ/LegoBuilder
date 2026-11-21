#!/usr/bin/env python3
"""Writes 42233-3-dump-truck.mpd: a reconstruction of LEGO Technic 42233-3 Dump Truck
(46 pieces) from the official parts list and product photo. Steps are our own order,
not the official booklet. Three 2026 parts that the LDraw library doesn't have yet
(7450, 7451 shovel panels and 7944 trapezoid frame) are included as simplified shapes.

LDraw units: 1 stud = 20 LDU, -Y is up, the truck's front points to -Z.
"""
import os

YEL, BLK, LBG, DBG, TAN = 14, 0, 71, 72, 19
I = "1 0 0 0 1 0 0 0 1"
WHEEL_R = "0 0 1 0 1 0 -1 0 0"     # wheel/tyre axle (local Z) -> +X
WHEEL_L = "0 0 -1 0 1 0 1 0 0"     # wheel/tyre axle -> -X
FLIP_X = "-1 0 0 0 1 0 0 0 -1"     # turn 180 deg about Y (pins pointing -X)
UPSIDE = "1 0 0 0 -1 0 0 0 -1"     # turn 180 deg about X
ALONG_Z = "0 0 -1 0 1 0 1 0 0"     # local X -> Z
VERTICAL = "0 -1 0 1 0 0 0 0 1"    # local X -> Y

def ref(colour, pos, rot, name):
    x, y, z = pos
    return f"1 {colour} {x} {y} {z} {rot} {name}"

# ------------------------------------------------------------- simplified new parts
def box(x0, x1, y0, y1, z0, z1):
    p = [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1),
         (x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    out = []
    for f in faces:
        out.append("4 16 " + " ".join(f"{c:g}" for i in f for c in p[i]))
    return out

def slab(a, b, half_w, half_t):
    """A bar from point a to point b (in the XY plane), half_w wide in Z, half_t thick."""
    ax, ay = a; bx, by = b
    dx, dy = bx - ax, by - ay
    ln = (dx * dx + dy * dy) ** 0.5
    nx, ny = -dy / ln * half_t, dx / ln * half_t
    q = [(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)]
    p = [(x, y, -half_w) for x, y in q] + [(x, y, half_w) for x, y in q]
    faces = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    return ["4 16 " + " ".join(f"{c:g}" for i in f for c in p[i]) for f in faces]

def part_file(name, title, lines):
    return [f"0 FILE {name}", f"0 {title}", f"0 Name: {name}", "0 Author: BuildLens (simplified stand-in)",
            "0 !LDRAW_ORG Unofficial_Part", "0 BFC NOCERTIFY", ""] + lines + ["0 NOFILE", ""]

# 7944: thin 1x3 beam (along X) with a trapezoid loop rising above it
frame = box(-30, 30, -10, 10, -5, 5)
frame += slab((-30, -8), (-18, -42), 5, 4) + slab((30, -8), (18, -42), 5, 4) + slab((-20, -40), (20, -40), 5, 4)
# 7450 / 7451: shovel panel 2x3x2 - a floor (X 2 wide, Z 3 long) with an outer side wall and a raised front
def shovel(side):
    s = 1 if side == "R" else -1
    out = box(-20, 20, -4, 4, -30, 30)                       # floor
    out += box(min(s * 16, s * 20), max(s * 16, s * 20), -40, 0, -30, 30)   # outer side wall
    out += box(-20, 20, -40, 0, -30, -26)                    # front wall
    out += box(min(s * 8, s * 24), max(s * 8, s * 24), -8, 8, 22, 30) # hinge knuckle
    return out

files = []
files += part_file("7944.dat", "Technic Beam 1 x 3 Thin with Trapezoid Frame", frame)
files += part_file("7450.dat", "Technic Panel Shovel 2 x 3 x 2 Right", shovel("R"))
files += part_file("7451.dat", "Technic Panel Shovel 2 x 3 x 2 Left", shovel("L"))

# ------------------------------------------------------------- sub-assemblies
wheel = ["0 FILE Wheel.ldr", "0 Wheel", "0 Name: Wheel.ldr", "0 !LDRAW_ORG Model", "",
         ref(LBG, (0, 0, 0), I, "42610.dat"), "0 STEP",
         ref(BLK, (0, 0, 0), I, "50951.dat"), "0 STEP", "0 NOFILE", ""]

bed = ["0 FILE Tipper Bed.ldr", "0 Tipper Bed", "0 Name: Tipper Bed.ldr", "0 !LDRAW_ORG Model", "",
       ref(YEL, (-20, 0, -30), I, "7451.dat"), ref(YEL, (20, 0, -30), I, "7450.dat"), "0 STEP",
       ref(YEL, (-20, 0, 30), I, "7451.dat"), ref(YEL, (20, 0, 30), I, "7450.dat"), "0 STEP",
       "0 NOFILE", ""]

# ------------------------------------------------------------- main model
WY = -19          # wheel centre height (tyre radius 19)
R1, R2, FA = 40, 80, -70   # rear axles and front axle (z)

def wheels_at(z):
    return [ref(TAN, (20, WY, z), I, "3749.dat"), ref(TAN, (-20, WY, z), FLIP_X, "3749.dat"),
            ref(16, (32, WY, z), WHEEL_R, "Wheel.ldr"), ref(16, (-32, WY, z), WHEEL_L, "Wheel.ldr")]

main = ["0 FILE 42233-3 Dump Truck.ldr", "0 Dump Truck", "0 Name: 42233-3 Dump Truck.ldr",
        "0 Author: BuildLens reconstruction", "0 !LDRAW_ORG Model", ""]
steps = [
    # 1 rear chassis: two split cross blocks joined by axles
    [ref(BLK, (0, WY, R1), UPSIDE, "92907.dat"), ref(BLK, (0, WY, R2), UPSIDE, "92907.dat")],
    [ref(BLK, (-10, WY - 12, 60), ALONG_Z, "32062.dat"), ref(BLK, (10, WY - 12, 60), ALONG_Z, "32062.dat")],
    [ref(BLK, (0, WY - 38, R1), I, "92907.dat"), ref(BLK, (0, WY - 38, R2), I, "92907.dat")],
    # 2 rear wheels
    wheels_at(R1),
    wheels_at(R2),
    # 3 articulation joint
    [ref(DBG, (-10, -32, 5), I, "32184.dat"), ref(DBG, (10, -32, 5), I, "32184.dat"),
     ref(BLK, (-10, -32, 20), ALONG_Z, "32062.dat"), ref(BLK, (10, -32, 20), ALONG_Z, "32062.dat")],
    [ref(LBG, (0, -32, -12), VERTICAL, "3673.dat"), ref(BLK, (0, -32, -30), ALONG_Z, "32062.dat")],
    # 4 front axle block and wheels
    [ref(YEL, (0, WY, FA), UPSIDE, "63869.dat"), ref(BLK, (0, WY - 20, FA + 25), ALONG_Z, "32062.dat"),
     ref(BLK, (0, WY - 30, FA), I, "32062.dat")],
    wheels_at(FA),
    # 5 cab
    [ref(YEL, (-10, -60, -95), I, "32140.dat"), ref(TAN, (0, -60, -40), I, "32002.dat")],
    [ref(YEL, (0, -68, -84), I, "7944.dat"), ref(YEL, (0, -68, -60), I, "7944.dat")],
    # 6 tipper bed on two hinge axles
    [ref(YEL, (0, -58, 100), I, "4519.dat"), ref(YEL, (0, -58, 30), I, "4519.dat"),
     ref(LBG, (-30, -58, 100), I, "3673.dat"), ref(LBG, (30, -58, 100), I, "3673.dat")],
    [ref(16, (0, -62, 60), I, "Tipper Bed.ldr")],
]
for s in steps:
    main += s + ["0 STEP", ""]
main += ["0 NOFILE", ""]

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "42233-3-dump-truck.mpd")
with open(out, "w") as fh:
    fh.write("\n".join(main + wheel + bed + files))
n = sum(1 for s in steps for l in s if not l.endswith(".ldr\"")) 
print(out)
