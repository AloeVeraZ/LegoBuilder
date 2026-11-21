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
steps = []
for i, s in enumerate(pkg["steps"]):
    counts = {}
    for iid in s["added"]:
        inst = pkg["instances"][iid]
        k = (inst["part"], inst["colour"])
        counts[k] = counts.get(k, 0) + 1
    lines = sorted(counts.items(), key=lambda kv: -kv[1])
    asm = pkg["assemblies"][s["assembly"]]
    sub = "" if asm["id"] == 0 else f"SUB: {asm['name'].upper()}" + (f" x{asm['uses']}" if asm["uses"] > 1 else "")
    name = f"hud-step-{i + 1:03d}.png"
    shutil.copy(os.path.join(data, "hud", name), os.path.join(out, "hud", name))
    steps.append({"frame": f"hud/{name}", "sub": sub,
                  "parts": [f"+{n} {colours.get(c, '').upper()} {clean(pkg['parts'][p]['name']).upper()}" for (p, c), n in lines]})
json.dump({"name": pkg["set"]["name"], "steps": steps}, open(os.path.join(out, "steps.json"), "w"))
print(f"{len(steps)} steps -> {out}")
