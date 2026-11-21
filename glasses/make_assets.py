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
