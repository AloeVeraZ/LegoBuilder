#!/usr/bin/env python3
"""Writes what the app says out loud, the way a person would say it, and records it.

  pipeline/make_voice.py [BuildData folder]

From build.json it writes voice/voice.json (every line, by key) and one recording per line
(voice/voice-<key>.m4a). The app plays the recording, and falls back to the phone's own
voice with the same words if a recording is missing.

Recording uses the Kokoro voice model if it is installed (see VOICE_HOME below); without
it the words are still written and recordings already in pipeline/voice-cache are reused,
so the package can be rebuilt on a machine that has no model.
"""
import hashlib, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "app", "BuildLens", "Resources", "BuildData")
CACHE = os.path.join(HERE, "voice-cache")
VOICE_HOME = os.environ.get("BUILDLENS_VOICE", os.path.expanduser("~/Library/Caches/buildlens-voice"))
VOICE, SPEED = "af_heart", 1.0

# What people call the parts, not what the catalogue calls them.
NAMES = {
    "32002": ("short", "pin"), "32062": ("short", "axle"), "32140": ("", "L-shaped beam"), "32184": ("", "cross block"),
    "3673": ("", "pin"), "3749": ("", "axle pin"), "42610": ("", "wheel"), "4519": ("", "axle"), "50951": ("", "tyre"),
    "63869": ("", "triple connector"), "7450": ("", "bed panel"), "7451": ("", "bed panel"), "7944": ("", "cab frame"),
    "92907": ("", "split block"),
}
# Pieces that go into a hole rather than onto something.
GO_IN = {"pin", "axle", "axle pin"}
COLOURS = {"Light Bluish Grey": "light grey", "Dark Bluish Grey": "dark grey", "Rubber Black": "black"}
NUMBERS = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]


def plural(name):
    if name.endswith("half"): return name[:-4] + "halves"
    return name + ("es" if name.endswith(("s", "x", "ch")) else "s")


def article(word):
    return "an" if word[0] in "aeiou" or word.startswith("L-") else "a"


def lines(pkg):
    colours = {c["code"]: COLOURS.get(c["name"], c["name"].lower()) for c in pkg["colours"]}
    asms, steps = pkg["assemblies"], pkg["steps"]
    built_in_sub = {}
    for s in steps:
        if s["assembly"] != 0:
            built_in_sub.setdefault(s["assembly"], set()).update(s["added"])

    def noun(i):
        return NAMES.get(pkg["parts"][pkg["instances"][i]["part"]]["number"], ("", "piece"))[1]

    def things(ids):
        """'a tan axle pin', 'two short black axles', ... for these pieces."""
        counts = {}
        for i in ids:
            inst = pkg["instances"][i]
            size, name = NAMES.get(pkg["parts"][inst["part"]]["number"], ("", "piece"))
            key = (size, colours.get(inst["colour"], ""), name)
            counts[key] = counts.get(key, 0) + 1
        out = []
        for (size, colour, name), n in counts.items():
            one = " ".join(w for w in (size, colour, name) if w)
            many = " ".join(w for w in (size, colour, plural(name)) if w)
            out.append(f"{article(one)} {one}" if n == 1 else f"{NUMBERS[n] if n < len(NUMBERS) else n} {many}")
        return out

    def join(parts):
        return parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + " and " + parts[-1]

    def way(push):
        x, y, z = push
        if abs(y) >= max(abs(x), abs(z)): return "above"
        if abs(x) >= abs(z): return "the side"
        return "the front" if z < 0 else "the back"

    def phrase(where, what, goes_in):
        if where == "above": return f"press {what} in from above" if goes_in else f"drop {what} on from above"
        if where == "the side": return f"push {what} in from the side" if goes_in else f"push {what} on from the side"
        return f"slide {what} in from {where}" if goes_in else f"slide {what} on from {where}"

    out = {}
    seen_sub = set()
    previous = None
    for i, s in enumerate(steps):
        asm = asms[s["assembly"]]
        added = set(s["added"])
        attached = [a for a, pieces in sorted(built_in_sub.items()) if a != s["assembly"] and pieces <= added]
        in_subs = set().union(*(built_in_sub[a] for a in attached)) if attached else set()
        said = []
        if asm["id"] != 0 and asm["id"] not in seen_sub:
            seen_sub.add(asm["id"])
            said.append(f"Now let's build the {asm['name'].lower()}.")
        names_here = {noun(p) for p in added}
        if {"wheel", "tyre"} <= names_here:
            n = sum(1 for p in added if noun(p) == "wheel")
            said.append(f"Last step. Press the {NUMBERS[n]} tyres onto the {NUMBERS[n]} wheels, then push each wheel onto its pin.")
            out[f"step-{i + 1:03d}"] = " ".join(said)
            continue
        clauses = []
        # Sub-builds first: "slide the cab on from the front".
        for a in attached:
            # Every copy of a sub-build comes in together: then nothing in the step is loose.
            if len(built_in_sub[a]) * max(asms[a]["uses"], 1) >= len(added):
                in_subs = set(added)
            move = next((m for m in s.get("moves", []) if set(m["pieces"]) & built_in_sub[a]), None)
            name = asms[a]["name"].lower()
            what = f"both {plural(name)}" if asms[a]["uses"] > 1 else f"the {name}"
            clauses.append(phrase(way(move["push"]), what, False) if move else f"attach {what}")
        loose_moves = [m for m in s.get("moves", []) if not set(m["pieces"]) <= in_subs]
        base = [p for p in s["added"] if p not in in_subs and not any(p in m["pieces"] for m in loose_moves)]
        if base:
            clauses.append(f"start with {join(things(base))}")
        # Pieces that go the same way are said together.
        ways = {}
        for m in loose_moves:
            ways.setdefault(way(m["push"]), []).extend(p for p in m["pieces"] if p not in in_subs)
        for where, ids in ways.items():
            clauses.append(phrase(where, join(things(ids)), all(noun(p) in GO_IN for p in ids)))
        text = ", then ".join(clauses)
        text = text[:1].upper() + text[1:] + "."
        # The same thing again is the matching piece on the other side.
        if previous == text and "from the side" in text:
            said.append(text.replace("from the side", "from the other side"))
        else:
            said.append(text)
        previous = text
        out[f"step-{i + 1:03d}"] = " ".join(said)

        # The "good job" between parts of the build (same moments as the app's card).
        if i + 1 < len(steps) and steps[i + 1]["assembly"] != s["assembly"]:
            coming = asms[steps[i + 1]["assembly"]]
            if asm["id"] != 0:
                out[f"done-{i + 1:03d}"] = (f"Nice. That's one {asm['name'].lower()}. You need {NUMBERS[asm['uses']]} of these."
                                            if asm["uses"] > 1 else f"Nice, the {asm['name'].lower()} is done. Now it goes on the truck.")
            else:
                out[f"done-{i + 1:03d}"] = f"Good job. Next up, the {coming['name'].lower()}."
    name = pkg["set"]["name"].lower()
    out["finish"] = f"That's it. You built the {name}!"
    out["found"] = f"Found your {name}. {pkg['set']['pieces']} pieces, {len(steps)} steps. Let's build."
    return out


def record(texts):
    """Records any line that is not in the cache yet. Returns False if there is no voice model."""
    os.makedirs(CACHE, exist_ok=True)
    key = lambda t: hashlib.sha1(f"{VOICE}|{SPEED}|{t}".encode()).hexdigest()[:16]
    missing = [t for t in texts.values() if not os.path.exists(os.path.join(CACHE, key(t) + ".m4a"))]
    if missing:
        python = os.path.join(VOICE_HOME, "venv", "bin", "python")
        model = os.path.join(VOICE_HOME, "model")
        if not os.path.exists(python) or not os.path.exists(os.path.join(model, "kokoro-v1.0.onnx")):
            print(f"voice: no model at {VOICE_HOME}; {len(missing)} lines have no recording and will use the phone's voice")
            return key
        with tempfile.TemporaryDirectory() as tmp:
            job = os.path.join(tmp, "job.json")
            json.dump([{"text": t, "wav": os.path.join(tmp, key(t) + ".wav")} for t in missing], open(job, "w"))
            speak = ("import json,sys,soundfile\nfrom kokoro_onnx import Kokoro\n"
                     "k=Kokoro(sys.argv[2]+'/kokoro-v1.0.onnx',sys.argv[2]+'/voices-v1.0.bin')\n"
                     "for j in json.load(open(sys.argv[1])):\n"
                     f"    a,sr=k.create(j['text'],voice='{VOICE}',speed={SPEED},lang='en-us')\n"
                     "    soundfile.write(j['wav'],a,sr)\n")
            script = os.path.join(tmp, "speak.py")
            open(script, "w").write(speak)
            subprocess.run([python, "-I", script, job, model], check=True)
            for t in missing:
                wav = os.path.join(tmp, key(t) + ".wav")
                subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", wav, os.path.join(CACHE, key(t) + ".m4a")], check=True)
        print(f"voice: recorded {len(missing)} new lines")
    return key


def main():
    pkg = json.load(open(os.path.join(DATA, "build.json")))
    texts = lines(pkg)
    key = record(texts)
    out = os.path.join(DATA, "voice")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    json.dump(texts, open(os.path.join(out, "voice.json"), "w"), indent=1)
    copied = 0
    for name, text in texts.items():
        clip = os.path.join(CACHE, key(text) + ".m4a")
        if os.path.exists(clip):
            shutil.copy(clip, os.path.join(out, f"voice-{name}.m4a"))
            copied += 1
    print(f"voice: {len(texts)} lines, {copied} recordings -> {out}")
    for name, text in texts.items():
        print(f"  {name}: {text}")


if __name__ == "__main__":
    main()
