#!/usr/bin/env python3
"""Step finder: has the user finished step N on their real build yet?

A local vision model (Ollama, default gemma4) compares a camera picture of the real build
with two rendered pictures of the step: the build before it and after it. The model answers
with one letter, and the letter's probability is read back, so callers get a number they can
put a threshold on (and average over a few frames) instead of a yes/no guess.

    python3 vision/stepvision.py photo.jpg --step 7
    python3 vision/stepvision.py photo.jpg --step 7 --view 1 --json

The reference pictures come from the model package: vision/make_refs.sh renders them into
vision/refs (not committed). Ollama must be running with a vision model pulled.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import math
import os
import sys
import time
import urllib.request
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
BUILD_DATA = REPO / 'app/BuildLens/Resources/BuildData'
REFS = HERE / 'refs'
OLLAMA = os.environ.get('OLLAMA_HOST', 'http://localhost:11434').rstrip('/')
if not OLLAMA.startswith('http'):
    OLLAMA = 'http://' + OLLAMA
MODEL = os.environ.get('BL_VISION_MODEL', 'gemma4')
DEFAULT_ELEV = 55          # degrees above the table: about how glasses look down at a build


class Build:
    """The steps of the model package, in words a vision model can use."""

    def __init__(self, data_dir: Path = BUILD_DATA):
        d = json.loads((Path(data_dir) / 'build.json').read_text())
        self.steps = d['steps']
        self.instances = d['instances']
        self.parts = d['parts']
        self.assemblies = d['assemblies']
        self.colour_names = {c['code']: c['name'] for c in d['colours']}
        self.first_step = {}                     # piece id -> 1-based step that first adds it
        for n, st in enumerate(self.steps, 1):
            for pid in st['added']:
                self.first_step.setdefault(pid, n)

    def __len__(self):
        return len(self.steps)

    def step(self, n: int) -> dict:
        if not 1 <= n <= len(self.steps):
            raise ValueError(f'step {n} is not between 1 and {len(self.steps)}')
        return self.steps[n - 1]

    def view(self, n: int) -> int:
        """The side the app shows step n from (0..3), the same index as the refs' y0..y3."""
        return self.step(n).get('view', 0)

    def assembly_name(self, n: int) -> str:
        return self.assemblies[self.step(n)['assembly']]['name']

    def previous(self, n: int) -> int:
        """The last earlier step on the same assembly, or 0 when step n starts a sub-build."""
        asm = self.step(n)['assembly']
        for p in range(n - 1, 0, -1):
            if self.steps[p - 1]['assembly'] == asm:
                return p
        return 0

    def piece_name(self, pid: int) -> str:
        inst = self.instances[pid]
        part = self.parts[inst['part']]
        name = ' '.join(part.get('name', 'piece').split())
        return f"{self.colour_names.get(inst['colour'], 'coloured')} {name}"

    def adds(self, n: int) -> str:
        """What step n adds, e.g. '2 x Tan Technic Pin 3/4' or 'the Cab sub-build'."""
        st = self.step(n)
        copies, one_copy, loose = Counter(), {}, Counter()
        for pid in st['added']:
            first = self.first_step.get(pid, n)
            if first != n:                       # built earlier as a sub-build, attached now
                name = self.assemblies[self.steps[first - 1]['assembly']]['name']
                copies[name] = 1
                one_copy.setdefault(name, Counter())[self.piece_name(pid)] += 1
            else:
                loose[self.piece_name(pid)] += 1
        # A sub-build that is used twice (the two tipper-bed halves): the second copy's pieces
        # are first added in this step, so they count as another copy, not as loose pieces.
        for name, one in one_copy.items():
            while all(loose[k] >= v for k, v in one.items()):
                loose -= one
                copies[name] += 1
        words = [f"{'the' if c == 1 else f'{c} copies of the'} {s} sub-build (built in the earlier steps)"
                 for s, c in copies.items()]
        words += [f'{c} x {name}' for name, c in loose.items()]
        return '; '.join(words)


def ref_path(n: int, which: str, view: int, elev: int = DEFAULT_ELEV, refs: Path = REFS) -> Path:
    return Path(refs) / f'step-{n:03d}-{which}-y{view}-e{elev}.png'


def encode(image, size: int = 768) -> str:
    """A picture (path, bytes or PIL image) as base64 JPEG, longest side at most `size`."""
    from PIL import Image, ImageOps
    if isinstance(image, (str, Path)):
        im = Image.open(image)
    elif isinstance(image, (bytes, bytearray)):
        im = Image.open(io.BytesIO(image))
    else:
        im = image
    im = ImageOps.exif_transpose(im)
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGBA')
        flat = Image.new('RGB', im.size, (243, 244, 246))
        flat.paste(im, mask=im.split()[-1])
        im = flat
    im = im.convert('RGB')
    im.thumbnail((size, size))
    buf = io.BytesIO()
    im.save(buf, 'JPEG', quality=90)
    return base64.b64encode(buf.getvalue()).decode()


PROMPT = """You are checking someone's progress on a small LEGO Technic model.

Picture 1 and picture 2 are computer renders of the model. Picture 3 is a real camera photo of the person's model, possibly from another angle, with a different background, hands or loose pieces around it.

The difference between the two renders is step {step}: it adds {adds}.

{options}

Look only at pieces that are attached to the model in picture 3; ignore loose pieces lying next to it.
Which render does the real model in picture 3 match? Answer with one letter: A or B."""


def _options(before_first: bool) -> str:
    if before_first:
        return ('A = picture 1: the model BEFORE step {step} (those pieces not attached yet).\n'
                'B = picture 2: the model AFTER step {step} (those pieces attached).')
    return ('A = picture 1: the model AFTER step {step} (those pieces attached).\n'
            'B = picture 2: the model BEFORE step {step} (those pieces not attached yet).')


def _letter_probs(resp: dict) -> dict:
    """P(A), P(B) from the first answer token's top log-probabilities (normalised over A+B)."""
    probs = {'A': 0.0, 'B': 0.0}
    lp = resp.get('logprobs') or []
    if lp:
        for cand in lp[0].get('top_logprobs') or [lp[0]]:
            tok = cand.get('token', '').strip().upper()
            if tok in probs:
                probs[tok] += math.exp(cand.get('logprob', -99))
    if probs['A'] + probs['B'] == 0:            # no log-probabilities: take the text at face value
        text = resp.get('message', {}).get('content', '').strip().upper()
        if text[:1] in probs:
            probs[text[:1]] = 1.0
    total = probs['A'] + probs['B']
    return {k: (v / total if total else 0.5) for k, v in probs.items()}


def ask(images_b64: list[str], prompt: str, model: str = MODEL, host: str = OLLAMA, timeout: float = 600) -> dict:
    # Long timeout: the first call loads the model, minutes from a slow (USB) disk; Ollama
    # drops the load if the caller gives up first.
    body = {
        'model': model,
        'stream': False,
        'think': False,
        'keep_alive': '30m',
        'messages': [{'role': 'user', 'content': prompt, 'images': images_b64}],
        'options': {'temperature': 0, 'seed': 0, 'num_predict': 1},
        'logprobs': True,
        'top_logprobs': 10,
    }
    req = urllib.request.Request(f'{host}/api/chat', data=json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def check_step(photo, n: int, build: Build | None = None, view: int | None = None,
               elev: int = DEFAULT_ELEV, both_orders: bool = False, model: str = MODEL,
               refs: Path = REFS, size: int = 768) -> dict:
    """How likely it is that step n is done on the real build in `photo`.

    Returns {'step', 'p_done', 'done', 'seconds', ...}. p_done is 0..1. both_orders asks a
    second time with the two renders swapped and averages, which cancels the model's
    leaning towards one letter at the cost of twice the time.
    """
    build = build or Build()
    view = build.view(n) if view is None else view
    before, after = ref_path(n, 'before', view, elev, refs), ref_path(n, 'after', view, elev, refs)
    for p in (before, after):
        if not p.exists():
            raise FileNotFoundError(f'{p} is missing: run vision/make_refs.sh first')
    photo_b64 = encode(photo, size)
    before_b64, after_b64 = encode(before, size), encode(after, size)
    t0 = time.time()
    p_done, answers = [], []
    for before_first in ([True, False] if both_orders else [True]):
        opts = _options(before_first).format(step=n)
        prompt = PROMPT.format(step=n, adds=build.adds(n), options=opts)
        imgs = [before_b64, after_b64, photo_b64] if before_first else [after_b64, before_b64, photo_b64]
        probs = _letter_probs(ask(imgs, prompt, model=model))
        p_done.append(probs['B'] if before_first else probs['A'])
        answers.append(max(probs, key=probs.get))
    p = sum(p_done) / len(p_done)
    return {
        'step': n, 'p_done': round(p, 4), 'done': p >= 0.5, 'seconds': round(time.time() - t0, 2),
        'view': view, 'elev': elev, 'model': model, 'answers': answers, 'adds': build.adds(n),
    }


class Follower:
    """Turns single checks into "move on now": the step counts as done only after `needed`
    checks in a row reach `threshold`, so one lucky frame does not skip a step."""

    def __init__(self, threshold: float = 0.8, needed: int = 2):
        self.threshold, self.needed = threshold, needed
        self.step, self.streak = None, 0

    def update(self, step: int, p_done: float) -> bool:
        if step != self.step:
            self.step, self.streak = step, 0
        self.streak = self.streak + 1 if p_done >= self.threshold else 0
        if self.streak >= self.needed:
            self.streak = 0
            return True
        return False


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('photo', help='camera picture of the real build (jpg/png)')
    ap.add_argument('--step', type=int, required=True, help='the step to check (1-based)')
    ap.add_argument('--view', type=int, help='which side to compare with, 0-3 (default: the step\'s own)')
    ap.add_argument('--elev', type=int, default=DEFAULT_ELEV, help='reference camera height in degrees')
    ap.add_argument('--both-orders', action='store_true', help='ask twice with the renders swapped')
    ap.add_argument('--model', default=MODEL)
    ap.add_argument('--refs', type=Path, default=REFS)
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args(argv)
    r = check_step(a.photo, a.step, view=a.view, elev=a.elev, both_orders=a.both_orders, model=a.model, refs=a.refs)
    if a.json:
        print(json.dumps(r))
    else:
        verdict = 'done' if r['done'] else 'not done yet'
        print(f"step {r['step']}: {verdict}  (p={r['p_done']:.2f}, {r['seconds']:.1f}s, {r['model']})")
        print(f"  step adds: {r['adds']}")


if __name__ == '__main__':
    sys.exit(main())
