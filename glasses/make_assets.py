#!/usr/bin/env python3
"""Copies the glasses frames and a compact steps.json from the app's build package into assets/."""
import json, os, re, shutil
here = os.path.dirname(os.path.abspath(__file__))
data = os.path.join(here, "..", "app", "BuildLens", "Resources", "BuildData")
out = os.path.join(here, "assets")
shutil.rmtree(out, ignore_errors=True)
os.makedirs(os.path.join(out, "hud"))
pkg = json.load(open(os.path.join(data, "build.json")))
clean = lambda s: re.sub(r"\s+", " ", s.lstrip("~_=|")).strip()
colours = {c["code"]: c["name"] for c in pkg["colours"]}
# The pieces each sub-build is made of, to tell "attach what you built" from "add these".
built_in_sub = {}
for s in pkg["steps"]:
    if s["assembly"] != 0:
        built_in_sub.setdefault(s["assembly"], set()).update(s["added"])
steps = []
for i, s in enumerate(pkg["steps"]):
    counts = {}
    attached = [pkg["assemblies"][a] for a, pieces in sorted(built_in_sub.items())
                if a != s["assembly"] and pieces <= set(s["added"])]
    loose = set(s["added"])
    for a in attached:
        full = len(built_in_sub[a["id"]]) * max(a["uses"], 1) >= len(s["added"])
        loose = set() if full else loose - built_in_sub[a["id"]]
    for iid in s["added"]:
        if iid not in loose:
            continue
        inst = pkg["instances"][iid]
        k = (inst["part"], inst["colour"])
        counts[k] = counts.get(k, 0) + 1
    lines = sorted(counts.items(), key=lambda kv: -kv[1])
    asm = pkg["assemblies"][s["assembly"]]
    sub = "" if asm["id"] == 0 else f"SUB: {asm['name'].upper()}" + (f" x{asm['uses']}" if asm["uses"] > 1 else "")
    name = f"hud-step-{i + 1:03d}"
    # Every picture of the step: four sides (q0..q3), each waiting / arrow down (-w) /
    # part-way in (-a) / seated (-b), plus the turning frames (-r1..) where there are any.
    turns = 0
    for f in sorted(os.listdir(os.path.join(data, "hud"))):
        if f.startswith(name + "-"):
            shutil.copy(os.path.join(data, "hud", f), os.path.join(out, "hud", f))
            turns += "-r" in f
    # The "good job" moment when this step ends a part of the build (same words as the phone).
    done = None
    if i + 1 < len(pkg["steps"]) and pkg["steps"][i + 1]["assembly"] != s["assembly"]:
        coming = pkg["assemblies"][pkg["steps"][i + 1]["assembly"]]
        if asm["id"] != 0:
            done = [f"{asm['name'].upper()} DONE!",
                    f"MAKE {asm['uses']} OF THESE" if asm["uses"] > 1 else "NOW IT GOES ON THE TRUCK"]
        else:
            done = ["GOOD JOB!", f"NEXT: THE {coming['name'].upper()}"]
    attach_lines = [("ATTACH " + (f"{a['uses']}x " if a["uses"] > 1 else "THE ") + a["name"].upper()) for a in attached]
    steps.append({"frame": f"hud/{name}", "view": s.get("view", 0), "turns": turns, "done": done, "sub": sub,
                  "parts": attach_lines + [f"+{n} {colours.get(c, '').upper()} {clean(pkg['parts'][p]['name']).upper()}" for (p, c), n in lines]})
# The finished truck turning once round, for the celebration at the end.
finish = sorted(f for f in os.listdir(os.path.join(data, "hud")) if f.startswith("hud-finish-"))
for f in finish:
    shutil.copy(os.path.join(data, "hud", f), os.path.join(out, "hud", f))
json.dump({"name": pkg["set"]["name"], "finish": len(finish), "steps": steps}, open(os.path.join(out, "steps.json"), "w"))
print(f"{len(steps)} steps -> {out}")

# ---------------------------------------------------------------- the ghost
# For drawing each step's pieces in green onto the real table (GhostRenderer.java): every
# part's shape as plain triangles, slimmed down (corners closer than half a millimetre are
# merged), and for every step where each piece stands and which way it goes in. The same
# placing as the phone's ghost (AssistView.swift): the step's assembly in its own axes,
# centred, standing on its own ground.
import struct
import numpy as np


def ghost():
    geometry = open(os.path.join(data, pkg["geometry"]), "rb").read()
    blob = bytearray()
    parts = []
    for part in pkg["parts"]:
        tris = []
        for g in part["groups"]:
            v = np.frombuffer(geometry, "<f4", g["vertexCount"] * 3, g["positions"]).reshape(-1, 3)
            i = np.frombuffer(geometry, "<u4", g["indexCount"], g["indices"]).reshape(-1, 3)
            tris.append(v[i])
        t = np.concatenate(tris)                                   # (n, 3 corners, xyz)
        cell = 0.0005
        q = np.round(t.reshape(-1, 3) / cell).astype(np.int64)
        keys, inverse = np.unique(q, axis=0, return_inverse=True)
        idx = inverse.reshape(-1, 3)
        ok = (idx[:, 0] != idx[:, 1]) & (idx[:, 1] != idx[:, 2]) & (idx[:, 0] != idx[:, 2])
        idx = idx[ok]
        _, first = np.unique(np.sort(idx, axis=1), axis=0, return_index=True)
        idx = idx[np.sort(first)]                                  # keeps each triangle's winding
        shape = (keys[idx] * cell).astype("<f4")
        parts.append({"offset": len(blob), "count": len(shape)})
        blob += shape.tobytes()

    def mat(m):      # column-major list -> numpy 4x4
        return np.array(m, dtype=np.float64).reshape(4, 4).T

    inst = [mat(i["matrix"]) for i in pkg["instances"]]
    asm = [mat(a["matrix"]) for a in pkg["assemblies"]]
    flo, fhi = np.array(pkg["assemblies"][0]["bounds"][0]), np.array(pkg["assemblies"][0]["bounds"][1])
    usual_gap = max(np.linalg.norm(fhi - flo) / 2 * 0.28, 0.012)
    visible_by = {}
    steps = []
    for s in pkg["steps"]:
        a = s["assembly"]
        visible_by.setdefault(a, []).extend(s["added"])
        lo, hi = np.array(pkg["assemblies"][a]["bounds"][0]), np.array(pkg["assemblies"][a]["bounds"][1])
        centre = (lo + hi) / 2
        place = np.eye(4)
        place[:3, 3] = [-centre[0], -lo[1], -centre[2]]
        local = place @ np.linalg.inv(asm[a])

        def where(i):
            return [round(float(x), 6) for x in (local @ inst[i]).T.reshape(-1)]

        added = set(s["added"])
        built = [{"part": pkg["instances"][i]["part"], "m": where(i)} for i in visible_by[a] if i not in added]
        fresh, turn_of, moved = [], {}, set()
        for n, move in enumerate(s.get("moves") or []):
            if len(move["push"]) != 3:
                continue
            key = f"order {move['order']}" if move.get("order") is not None else f"move {n}"
            turn = turn_of.setdefault(key, len(turn_of))
            push = np.array(move["push"], dtype=np.float64)
            push = push / np.linalg.norm(push)
            for i in move["pieces"]:
                if i in added:
                    moved.add(i)
                    fresh.append({"part": pkg["instances"][i]["part"], "m": where(i), "push": [round(float(x), 4) for x in push],
                                  "gap": round(float(move.get("gap") or usual_gap), 5), "turn": turn})
        # A piece with no direction is the one everything else goes onto: simply shown in place.
        for i in s["added"]:
            if i not in moved:
                fresh.append({"part": pkg["instances"][i]["part"], "m": where(i), "push": [0, 1, 0], "gap": 0, "turn": 0})
        steps.append({"radius": round(max(float(np.hypot(hi[0] - lo[0], hi[2] - lo[2])) / 2 * 1.15, 0.03), 5),
                      "turns": max(len(turn_of), 1), "built": built, "fresh": fresh})
    open(os.path.join(out, "ghost.bin"), "wb").write(blob)
    json.dump({"parts": parts, "steps": steps}, open(os.path.join(out, "ghost.json"), "w"), separators=(",", ":"))
    print(f"ghost: {sum(p['count'] for p in parts)} triangles in {len(parts)} parts, {len(blob) // 1024} KB")


ghost()
