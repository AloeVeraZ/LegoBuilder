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

Three 2026 parts are not in the LDraw library yet (7450, 7451 tipper-bed panels and the
7944 cab half): they are modelled here from the instruction drawings. Every part is
placed where its holes line up with what it connects to, pins and axles fully seated. LDraw units: 1 stud = 20 LDU, -Y up, truck front at -Z.
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

# ------------------------------------------------------------- 2026 parts not in LDraw yet
# 7944 (cab half) and 7450 / 7451 (tipper-bed quarter panels) are modelled here from the
# official instruction drawings, using real LDraw sub-parts for the holes so they look
# and connect like the moulded parts.
class Mesh:
    def __init__(self):
        self.lines = []

    def face(self, pts, hint):
        """Convex planar polygon, wound so its normal points along `hint` (CCW from outside)."""
        p = [np.asarray(q, float) for q in pts]
        n = np.zeros(3)
        for i in range(len(p)):
            n += np.cross(p[i], p[(i + 1) % len(p)])
        if np.dot(n, np.asarray(hint, float)) < 0:
            p.reverse()
        for k in range(1, len(p) - 1):
            self.lines.append("3 16 " + " ".join(f"{c:.3f}" for q in (p[0], p[k], p[k + 1]) for c in q))

    def prim(self, name, origin, ex, ey, ez):
        m = np.column_stack([ex, ey, ez])
        self.lines.append("1 16 " + " ".join(f"{c:g}" for c in origin) + " "
                          + " ".join(f"{v:g}" for v in m.reshape(-1)) + " " + name)

    def box(self, x0, x1, y0, y1, z0, z1):
        z0, z1 = min(z0, z1), max(z0, z1)
        c = [(x, y, z) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
        for idx, hint in (((0, 1, 3, 2), -Z), ((4, 5, 7, 6), Z), ((0, 1, 5, 4), -Y),
                          ((2, 3, 7, 6), Y), ((0, 2, 6, 4), -X), ((1, 3, 7, 5), X)):
            self.face([c[i] for i in idx], hint)

    def prism_z(self, poly, z0, z1):
        """Extrude a convex (x, y) polygon along Z."""
        z0, z1 = min(z0, z1), max(z0, z1)
        centre = np.mean(np.asarray(poly, float), axis=0)
        self.face([(x, y, z0) for x, y in poly], -Z)
        self.face([(x, y, z1) for x, y in poly], Z)
        for i in range(len(poly)):
            (ax, ay), (bx, by) = poly[i], poly[(i + 1) % len(poly)]
            out = np.array([(ax + bx) / 2 - centre[0], (ay + by) / 2 - centre[1], 0])
            self.face([(ax, ay, z0), (bx, by, z0), (bx, by, z1), (ax, ay, z1)], out)

    def ring_prism(self, outer, inner, z0, z1):
        """Extrude a frame (outer loop and matching inner loop, in x, y) along Z."""
        centre = np.mean(np.asarray(outer, float), axis=0)
        n = len(outer)
        for i in range(n):
            j = (i + 1) % n
            (ox0, oy0), (ox1, oy1), (ix0, iy0), (ix1, iy1) = outer[i], outer[j], inner[i], inner[j]
            for z, hint in ((z0, -Z), (z1, Z)):
                self.face([(ox0, oy0, z), (ox1, oy1, z), (ix1, iy1, z), (ix0, iy0, z)], hint)
            out = np.array([(ox0 + ox1) / 2 - centre[0], (oy0 + oy1) / 2 - centre[1], 0])
            self.face([(ox0, oy0, z0), (ox1, oy1, z0), (ox1, oy1, z1), (ox0, oy0, z1)], out)
            inn = np.array([centre[0] - (ix0 + ix1) / 2, centre[1] - (iy0 + iy1) / 2, 0])
            self.face([(ix0, iy0, z0), (ix1, iy1, z0), (ix1, iy1, z1), (ix0, iy0, z1)], inn)

    def loft(self, a, b, hint):
        """Strip between two matching open 3D polylines. `hint(mid)` gives the outside direction."""
        for i in range(len(a) - 1):
            quad = [a[i], a[i + 1], b[i + 1], b[i]]
            mid = np.mean(np.asarray(quad, float), axis=0)
            self.face(quad, hint(mid))

    def boss(self, start, axis, length, r=9):
        """Round Technic boss with an axle hole through it (like the end of a cross block)."""
        start, axis = np.asarray(start, float), np.asarray(axis, float)
        ex = Y
        ez = np.cross(ex, axis)
        end = start + axis * length
        self.prim("4-4cyli.dat", start, ex * r, axis * length, ez * r)
        self.prim("4-4ring2.dat", start, ex * 3, axis, ez * 3)        # end faces (hole r 6 to r 9)
        self.prim("4-4ring2.dat", end, ex * 3, -axis, -ez * 3)
        self.prim("axlehole.dat", start, ex, axis * length, ez)


def rounded(corners, radii, segs=4):
    """Closed (x, y) polygon with each corner replaced by an arc of `segs` segments."""
    pts, n = [], len(corners)
    for i, r in enumerate(radii):
        p, a, b = (np.asarray(corners[k % n], float) for k in (i, i - 1, i + 1))
        u, v = (a - p) / np.linalg.norm(a - p), (b - p) / np.linalg.norm(b - p)
        phi = np.arccos(np.clip(np.dot(u, v), -1, 1)) / 2
        t1, t2 = p + u * r / np.tan(phi), p + v * r / np.tan(phi)
        c = p + (u + v) / np.linalg.norm(u + v) * r / np.sin(phi)
        a1 = np.arctan2(*(t1 - c)[::-1])
        da = (np.arctan2(*(t2 - c)[::-1]) - a1 + np.pi) % (2 * np.pi) - np.pi
        for k in range(segs + 1):
            ang = a1 + da * k / segs
            pts.append((c[0] + r * np.cos(ang), c[1] + r * np.sin(ang)))
    return pts


def part_file(name, title, mesh):
    return [f"0 FILE {name}", f"0 {title}", f"0 Name: {name}", "0 Author: BuildLens (modelled from the instructions)",
            "0 !LDRAW_ORG Unofficial_Part", "0 BFC CERTIFY CCW", ""] + mesh.lines + ["0 NOFILE", ""]


# 7944, cab half. Local frame: X across the truck, hole axes along Z, origin at the middle
# hole. A thin 1 x 3 beam (axle, pin, axle holes; the real part 6632) carries a trapezoid
# frame, wider at the bottom than at the roof, that is 1 stud deep. Two halves clamp the
# yellow triple connector between them and their frames meet over it to make the cab.
cab_half = Mesh()
cab_half.lines.append("1 16 -20 0 0 0 0 1 1 0 0 0 1 0 6632.dat")
cab_half.ring_prism(
    rounded([(29, -8), (20, -44), (-20, -44), (-29, -8)], [1.5, 6, 6, 1.5]),
    rounded([(23, -13), (16.5, -38.5), (-16.5, -38.5), (-23, -13)], [1.5, 3, 3, 1.5]),
    -5, 15)

# 7450 / 7451, tipper-bed quarter panels. Local frame of a bed half: origin on the hinge
# axis at the seam between its two panels, X out to the side, Z along the truck.
# The bed is a tub with a flat floor, walls leaning out and a rolled rim. Under the floor
# each panel has a hinge boss (axle hole across the truck) and a boss facing the seam
# (axle hole along the truck) for the axle that joins the two panels of a half.
Y_FLOOR_BOTTOM, Y_FLOOR_TOP, Y_LIP, Y_RIM = -10, -14, -49, -52

def tub_outline(w, l, r, y, sz, segs=6):
    pts = [(w, y, 0)]
    for k in range(segs + 1):
        a = np.pi / 2 * k / segs
        pts.append((w - r + r * np.cos(a), y, sz * (l - r + r * np.sin(a))))
    return pts + [(0, y, sz * l)]

def bed_panel(sz):
    m = Mesh()
    outward = lambda mid: (mid[0], 0, mid[2])
    inward = lambda mid: (-mid[0], 0, -mid[2])
    up, down = (lambda mid: -Y), (lambda mid: Y)
    floor_out = tub_outline(30, 42, 9, Y_FLOOR_BOTTOM, sz)
    wall_top = tub_outline(42, 52, 13, Y_LIP, sz)
    lip_low = tub_outline(44.5, 54.5, 15.5, Y_LIP, sz)
    lip_high = tub_outline(44.5, 54.5, 15.5, Y_RIM, sz)
    rim_in = tub_outline(39, 49, 10, Y_RIM, sz)
    floor_in = tub_outline(27, 39, 6, Y_FLOOR_TOP, sz)
    m.loft(floor_out, wall_top, outward)
    m.loft(wall_top, lip_low, down)
    m.loft(lip_low, lip_high, outward)
    m.loft(lip_high, rim_in, up)
    m.loft(rim_in, floor_in, inward)
    m.face([(0, Y_FLOOR_TOP, 0)] + floor_in, -Y)
    m.face([(0, Y_FLOOR_BOTTOM, 0)] + floor_out, Y)
    # cut faces where the panel meets its neighbours (z = 0 and x = 0)
    gx, gz = 27 + 12 * 35 / 38, 39 + 10 * 35 / 38
    dims = {"floor_out": (30, 42), "floor_in": (27, 39), "wall": (42, 52), "inner": (gx, gz),
            "lip": (44.5, 54.5), "rim": (39, 49)}
    for k, flat, hint in ((0, lambda a, y: (a, y, 0), -sz * Z), (1, lambda a, y: (0, y, sz * a), -X)):
        d = {name: v[k] for name, v in dims.items()}
        m.face([flat(0, Y_FLOOR_BOTTOM), flat(d["floor_out"], Y_FLOOR_BOTTOM),
                flat(d["floor_in"], Y_FLOOR_TOP), flat(0, Y_FLOOR_TOP)], hint)
        m.face([flat(d["floor_out"], Y_FLOOR_BOTTOM), flat(d["wall"], Y_LIP),
                flat(d["inner"], Y_LIP), flat(d["floor_in"], Y_FLOOR_TOP)], hint)
        m.face([flat(d["inner"], Y_LIP), flat(d["lip"], Y_LIP), flat(d["lip"], Y_RIM), flat(d["rim"], Y_RIM)], hint)
    # gusset ribs on the outside of the side wall
    for zc in (4.5, 17.5, 30):
        m.prism_z([(30, -9), (36, -9), (43.3, -40), (43.3, Y_LIP), (42, Y_LIP)], sz * zc - 1.2, sz * zc + 1.2)
    # hinge boss (across the truck) and joining boss (along the truck), each on a short neck
    m.boss((10, 0, sz * 30), X, 21)
    m.box(10, 31, -10.5, -3, sz * 30 - 6, sz * 30 + 6)
    m.boss((20, 0, 0), sz * Z, 20)
    m.box(14, 26, -10.5, -3, 0, sz * 20)
    return m

# 50951, tyre. The library version is drawn with 16 flat sides, which shows on the outline,
# so the same shape is turned here with 48 sides: 38 across, 16 wide, rounded shoulders.
def lathe_z(mesh, profile, sides=48):
    """Solid of revolution around Z from a closed (z, r) profile."""
    centre = np.mean(np.asarray(profile, float), axis=0)
    for i in range(len(profile)):
        (z0, r0), (z1, r1) = profile[i], profile[(i + 1) % len(profile)]
        nz, nr = (z0 + z1) / 2 - centre[0], (r0 + r1) / 2 - centre[1]
        ez, er = z1 - z0, r1 - r0                      # outward normal of this profile edge
        oz, orr = er, -ez
        if oz * nz + orr * nr < 0:
            oz, orr = -oz, -orr
        for k in range(sides):
            a0, a1 = 2 * np.pi * k / sides, 2 * np.pi * (k + 1) / sides
            am = (a0 + a1) / 2
            pt = lambda z, r, a: (r * np.cos(a), r * np.sin(a), z)
            mesh.face([pt(z0, r0, a0), pt(z1, r1, a0), pt(z1, r1, a1), pt(z0, r0, a1)],
                      (orr * np.cos(am), orr * np.sin(am), oz))

def tyre_profile(radius=19, half_width=8, shoulder=3.5, bore=12.2, segs=5):
    pts = [(-half_width + 1.5, bore), (-half_width, bore + 1.3)]
    for side in (-1, 1):
        arc = []
        for k in range(segs + 1):
            a = np.pi / 2 * k / segs
            arc.append((side * (half_width - shoulder + shoulder * np.cos(a)), radius - shoulder + shoulder * np.sin(a)))
        pts += arc[::-1] if side > 0 else arc
    return pts + [(half_width, bore + 1.3), (half_width - 1.5, bore)]

tyre = Mesh()
lathe_z(tyre, tyre_profile())

files = []
files += part_file("7944.dat", "Technic Beam 1 x 3 Thin with Trapezoid Frame", cab_half)
files += part_file("7450.dat", "Technic Panel Shovel 2 x 3 x 2 Right", bed_panel(1))
files += part_file("7451.dat", "Technic Panel Shovel 2 x 3 x 2 Left", bed_panel(-1))
files += part_file("50951.dat", "Tyre 14 x 6 Solid Smooth", tyre)

def model(name, steps):
    out = [f"0 FILE {name}", f"0 {name[:-4]}", f"0 Name: {name}", "0 Author: BuildLens", "0 !LDRAW_ORG Model", ""]
    for s in steps:
        out += s + ["0 STEP", ""]
    return out + ["0 NOFILE", ""]

# ------------------------------------------------------------- layout
# Every position below follows from how the parts lock together, with pins and axles
# fully seated (pipeline/models/check_42233_3.py verifies each one):
#
#   * A cross block lies along the truck at wheel-axle height. Its two end axle holes
#     point across the truck; its centre pin hole points up.
#   * A pin stands in that centre hole with its collar seated, and a split block's round
#     hole slides down over the pin's top half. The split block's two arms then straddle
#     one end of the cross block, and the wheel's axle pin goes through arm and cross
#     block together, which is what locks them.
#   * The rear bogie's second split block is upside down: its round hole sits low, in
#     front of the cross block, and holds the articulation pin. The front unit's last
#     split block sits on top of that pin, so the truck bends in the middle.
AXLE_Y = -19                 # wheel-axle height (tyre radius 19) = level of both cross blocks
UPPER = AXLE_Y - 20          # one hole row up
TOP = AXLE_Y - 40            # two rows up: connector holes, L-beam long arm, bed hinges
REAR_Z = 20                  # rear cross block centre; its axle holes are at z = 0 and 40
FRONT_Z = -60                # front cross block centre; its axle holes are at z = -80 and -40
PIVOT_Z = -20                # articulation pin
REAR_WHEELS = [REAR_Z - 20, REAR_Z + 20]
FRONT_AXLE_Z = FRONT_Z - 20
# 92907 again: round hole up, arms towards the front (SPLIT_FRONT) or rear (SPLIT_REAR) with
# the second hole row below; SPLIT_FLIPPED is upside down, second row above.
SPLIT_FLIPPED = rot(-X, Z)

# Which way each piece is pushed home, always square to the model: straight down, or
# straight in from one side, the front or the back. The app holds the piece just off its
# place along this line, shows an arrow, and slots it in on the next step.
DOWN, FROM_RIGHT, FROM_LEFT, FROM_FRONT, FROM_BEHIND = Y, -X, X, Z, -Z

def push(direction, line):
    return "0 !PUSH " + " ".join(f"{v:g}" for v in direction) + "\n" + line

def axle_pins(z, sides=("R", "L")):
    """3749: the cross-shaped axle end goes through the split block's arm into the cross
    block (both are axle holes); the round pin end stays out for the wheel to spin on.
    In the part's own frame the axle end is +X and the pin end is -X."""
    out = []
    if "R" in sides: out.append(push(FROM_RIGHT, ref(TAN, (20, AXLE_Y, z), SHAFT_NX, "3749.dat")))
    if "L" in sides: out.append(push(FROM_LEFT, ref(TAN, (-20, AXLE_Y, z), SHAFT_X, "3749.dat")))
    return out

def seated_pin(z, hole_y=AXLE_Y):
    """3673 standing in a 1-stud-deep hole centred at hole_y, collar at the hole's top."""
    return push(DOWN, ref(LBG, (0, hole_y - 10, z), SHAFT_UP, "3673.dat"))

rear = [
    [ref(DBG, (0, AXLE_Y, REAR_Z), CROSS_BLOCK, "32184.dat"), seated_pin(REAR_Z)],               # 1
    [push(DOWN, ref(BLK, (0, UPPER, REAR_Z), SPLIT_REAR, "92907.dat"))],                         # 2
    axle_pins(REAR_WHEELS[1], sides="R"),                                                        # 3
    [push(DOWN, ref(BLK, (0, AXLE_Y, PIVOT_Z), SPLIT_FLIPPED, "92907.dat"))]
    + axle_pins(REAR_WHEELS[0], sides="R"),                                                      # 4
    axle_pins(REAR_WHEELS[0], sides="L") + axle_pins(REAR_WHEELS[1], sides="L"),                 # 5
    [seated_pin(PIVOT_Z)],                                                                       # 6
]

# The printed step 10 starts the black axle in the split block's upper hole and step 11
# pushes it on through the yellow connector's lug. Here the axle arrives in step 11, after
# the connector has dropped between the arms, so it slides through both in one go.
front_unit = model("Front Unit.ldr", [
    [ref(DBG, (0, AXLE_Y, FRONT_Z), CROSS_BLOCK, "32184.dat"), seated_pin(FRONT_Z)],             # 7
    [push(DOWN, ref(BLK, (0, UPPER, FRONT_Z), SPLIT_FRONT, "92907.dat"))],                       # 8
    axle_pins(FRONT_AXLE_Z, sides="R"),                                                          # 9
    axle_pins(FRONT_AXLE_Z, sides="L"),                                                          # 10
    [push(DOWN, ref(YEL, (0, UPPER, FRONT_AXLE_Z), TRIPLE, "63869.dat")),
     push(FROM_RIGHT, ref(BLK, (0, UPPER, FRONT_AXLE_Z), SHAFT_X, "32062.dat"))],                # 11
    [push(DOWN, ref(BLK, (0, UPPER, PIVOT_Z), SPLIT_FRONT, "92907.dat")),
     push(FROM_RIGHT, ref(BLK, (0, AXLE_Y, FRONT_Z + 20), SHAFT_X, "32062.dat"))],               # 12
])

# The triple connector's three holes run across the truck at this height, pointing along it.
HOLE_Y, CONNECTOR_Z = TOP, FRONT_AXLE_Z
BEHIND = rot(-X, Y)          # turned 180 degrees

# Cab sub-build (steps 14-15) is the FRONT half: its thin beam sits against the front of
# the connector, with the 3/4 pin and the two axles pointing back through the connector's
# holes. Step 17's half slides onto the axle ends from behind, and the frames meet.
# Sub-build origin = the front half's middle hole.
cab = model("Cab.ldr", [
    [ref(YEL, (0, 0, 0), I, "7944.dat"),
     push(FROM_BEHIND, ref(TAN, (0, 0, 5), rot(-Z, Y), "32002.dat"))],                           # 14
    [push(FROM_BEHIND, ref(BLK, (-20, 0, 15), SHAFT_Z, "32062.dat")),
     push(FROM_BEHIND, ref(BLK, (20, 0, 15), SHAFT_Z, "32062.dat"))],                            # 15
])
CAB_FRONT = (0, HOLE_Y, CONNECTOR_Z - 15)
CAB_REAR = (0, HOLE_Y, CONNECTOR_Z + 15)

# The L-beam lies along the truck on top of the split blocks: axle hole at its front end
# (over the pivot), then three pin holes; its short arm drops between the arms of the
# rearmost split block, where an axle through their upper holes holds it.
LBEAM_POS = (0, TOP, PIVOT_Z)
LBEAM_PIN_Z = PIVOT_Z + 60
# One side of the tipper bed: front panel, the axle joining it to the rear panel, and the
# hinge axle. The two sides face each other across the L-beam; each side's hinge axle goes
# through the beam (front hole for one side, rear hole for the other) into the other side.
bed_half = model("Tipper Bed Half.ldr", [
    [ref(YEL, (0, 0, 0), I, "7451.dat"),
     push(FROM_BEHIND, ref(BLK, (20, 0, 0), SHAFT_Z, "32062.dat"))],                             # 19
    [push(FROM_RIGHT, ref(YEL, (0, 0, -30), SHAFT_X, "4519.dat"))],                              # 20
    [push(FROM_BEHIND, ref(YEL, (0, 0, 0), I, "7450.dat"))],                                     # 21
])
BED_POS = (0, TOP, PIVOT_Z + 30)

WHEEL_X = 30                 # rims sit on the pin ends, which reach from x = 20 to 40
def wheel(side_x, z, part, colour):
    turn, way = (WHEEL_R, FROM_RIGHT) if side_x > 0 else (WHEEL_L, FROM_LEFT)
    return push(way, ref(colour, (side_x, AXLE_Y, z), turn, part))

main = model("42233-3 Dump Truck.ldr", rear + [
    [push(DOWN, ref(16, (0, 0, 0), I, "Front Unit.ldr"))],                                       # 13
    [push(FROM_FRONT, ref(16, CAB_FRONT, I, "Cab.ldr"))],                                        # 16 (after cab sub-build)
    [push(FROM_BEHIND, ref(YEL, CAB_REAR, BEHIND, "7944.dat"))],                                 # 17
    [push(DOWN, ref(YEL, LBEAM_POS, LBEAM, "32140.dat")),
     push(FROM_RIGHT, ref(BLK, (0, UPPER, LBEAM_PIN_Z), SHAFT_X, "32062.dat"))],                 # 18
    [push(FROM_RIGHT, ref(16, BED_POS, I, "Tipper Bed Half.ldr")),
     push(FROM_LEFT, ref(16, BED_POS, BEHIND, "Tipper Bed Half.ldr"))],                          # 22
    [wheel(x, z, part, colour) for part, colour in (("42610.dat", LBG), ("50951.dat", BLK))
     for x in (WHEEL_X, -WHEEL_X) for z in [FRONT_AXLE_Z] + REAR_WHEELS],                        # 23
])

# The main model references the cab after step 13 but its own steps (14-15) must come
# first, which the converter does automatically for first-time sub-models.
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "42233-3-dump-truck.mpd")
with open(out, "w") as fh:
    fh.write("\n".join(main + front_unit + cab + bed_half + files))
print(out)
