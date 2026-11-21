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
    name = f"hud-step-{i + 1:03d}.png"
    # The step's picture (piece waiting, arrow up), the arrow at the bottom of its bounce,
    # then part-way in and seated for when the wearer moves on.
    for suffix in ("", "-w", "-a", "-b"):
        variant = name.replace(".png", suffix + ".png")
        shutil.copy(os.path.join(data, "hud", variant), os.path.join(out, "hud", variant))
    attach_lines = [("ATTACH " + (f"{a['uses']}x " if a["uses"] > 1 else "THE ") + a["name"].upper()) for a in attached]
    steps.append({"frame": f"hud/{name}", "sub": sub,
                  "parts": attach_lines + [f"+{n} {colours.get(c, '').upper()} {clean(pkg['parts'][p]['name']).upper()}" for (p, c), n in lines]})
json.dump({"name": pkg["set"]["name"], "steps": steps}, open(os.path.join(out, "steps.json"), "w"))
print(f"{len(steps)} steps -> {out}")
