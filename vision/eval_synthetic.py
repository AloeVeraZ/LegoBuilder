#!/usr/bin/env python3
"""How well does the step finder work? A test on made-up camera pictures.

For every step it renders the build before and after the step from sides and heights the
references do not use, puts it on a random table-like background, blurs, tilts, adds noise
and JPEG loss, then asks stepvision.check_step whether the step is done. Two ways of choosing
the reference side are compared:

  own   the step's own side (what the app shows); the photo can be from any side
  near  the reference side nearest the photo's real side (what knowing the camera's pose,
        e.g. from the table marker, would give)

    python3 vision/eval_synthetic.py                 # all steps, both ways
    python3 vision/eval_synthetic.py --steps 2,6,13 --modes near --both-orders

Real photos are the real test; this one shows whether the idea works at all and gives a
number to compare models and prompts with. Results go to vision/results/.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import random
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import stepvision as sv  # noqa: E402

HERE = sv.HERE
SHOTS = HERE / 'testshots'
RESULTS = HERE / 'results'
# Sides and heights for the test pictures: none of them is one the references use.
PHOTO_YAWS = [0.25, -1.05, 2.75, -2.2]
PHOTO_ELEVS = [45, 70]
REF_YAWS = [0.65, -0.65, math.pi - 0.65, -(math.pi - 0.65)]


def render_shots():
    if (SHOTS / 'refs.json').exists():
        return
    print('rendering test pictures...', flush=True)
    subprocess.run(['node', str(sv.REPO / 'pipeline/render/render.mjs'), str(sv.BUILD_DATA), '--refs', str(SHOTS),
                    '--yaws', ','.join(map(str, PHOTO_YAWS)), '--elevs', ','.join(map(str, PHOTO_ELEVS)),
                    '--bg', 'none'], check=True)


def nearest_ref_side(yaw: float) -> int:
    def gap(a, b):
        return abs((a - b + math.pi) % (2 * math.pi) - math.pi)
    return min(range(len(REF_YAWS)), key=lambda i: gap(yaw, REF_YAWS[i]))


def table(rng: random.Random, size: int) -> Image.Image:
    """A plain or wood-ish table top with some grain and a light falloff."""
    base = rng.choice([(196, 160, 118), (222, 214, 200), (120, 92, 66), (238, 238, 236), (70, 74, 80), (180, 190, 200)])
    im = Image.new('RGB', (size, size), base)
    px = im.load()
    grain = rng.uniform(4, 18)
    freq = rng.uniform(0.02, 0.09)
    phase = rng.uniform(0, 6.28)
    for y in range(size):
        g = math.sin(y * freq + phase + 3 * math.sin(y * freq * 0.13)) * grain
        for x in range(0, size, 2):
            n = rng.uniform(-6, 6) + g
            c = tuple(max(0, min(255, int(v + n))) for v in base)
            px[x, y] = c
            if x + 1 < size:
                px[x + 1, y] = c
    return im.filter(ImageFilter.GaussianBlur(0.8))


def camera_picture(path: Path, rng: random.Random, size: int = 768) -> Image.Image:
    """The rendered build as if a camera took it: on a table, smaller, tilted, soft, noisy."""
    model = Image.open(path).convert('RGBA')
    scene = table(rng, size)
    scale = rng.uniform(0.45, 0.85)
    m = model.resize((int(size * scale), int(size * scale)), Image.LANCZOS).rotate(rng.uniform(-15, 15), Image.BICUBIC, expand=True)
    x = rng.randint(0, max(0, size - m.width))
    y = rng.randint(0, max(0, size - m.height))
    shadow = Image.new('RGBA', m.size, (0, 0, 0, 0))
    shadow.putalpha(m.split()[-1].point(lambda a: int(a * 0.35)))
    scene.paste(shadow.filter(ImageFilter.GaussianBlur(10)), (x + 8, y + 10), shadow.filter(ImageFilter.GaussianBlur(10)))
    scene.paste(m, (x, y), m)
    scene = ImageEnhance.Brightness(scene).enhance(rng.uniform(0.75, 1.2))
    scene = ImageEnhance.Contrast(scene).enhance(rng.uniform(0.8, 1.15))
    scene = ImageEnhance.Color(scene).enhance(rng.uniform(0.8, 1.2))
    r, g, b = scene.split()                       # white balance off a little
    warm = rng.uniform(-12, 12)
    scene = Image.merge('RGB', (r.point(lambda v: max(0, min(255, v + warm))), g, b.point(lambda v: max(0, min(255, v - warm)))))
    scene = scene.filter(ImageFilter.GaussianBlur(rng.uniform(0, 1.4)))
    noise = Image.effect_noise(scene.size, rng.uniform(6, 18)).convert('RGB')
    scene = Image.blend(scene, noise, 0.06)
    from io import BytesIO
    buf = BytesIO()
    scene.save(buf, 'JPEG', quality=rng.randint(55, 85))
    return Image.open(BytesIO(buf.getvalue())).convert('RGB')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--steps', help='comma list of steps (default: all)')
    ap.add_argument('--modes', default='own,near')
    ap.add_argument('--both-orders', action='store_true')
    ap.add_argument('--model', default=sv.MODEL)
    ap.add_argument('--seed', type=int, default=7)
    a = ap.parse_args(argv)

    render_shots()
    build = sv.Build()
    steps = [int(s) for s in a.steps.split(',')] if a.steps else list(range(1, len(build) + 1))
    modes = a.modes.split(',')
    rng = random.Random(a.seed)
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / 'pictures').mkdir(exist_ok=True)

    # One made-up picture per step and state, shared by every mode so the modes are compared fairly.
    cases = []
    for n in steps:
        for state in ('after', 'before'):
            yi, ei = rng.randrange(len(PHOTO_YAWS)), rng.randrange(len(PHOTO_ELEVS))
            src = SHOTS / f'step-{n:03d}-{state}-y{yi}-e{PHOTO_ELEVS[ei]}.png'
            pic = camera_picture(src, rng)
            name = f'step-{n:03d}-{state}.jpg'
            pic.save(RESULTS / 'pictures' / name, quality=92)
            cases.append({'step': n, 'state': state, 'done': state == 'after', 'photo_yaw': PHOTO_YAWS[yi],
                          'photo_elev': PHOTO_ELEVS[ei], 'picture': name, 'image': pic})

    rows = []
    t_start = time.time()
    for mode in modes:
        for c in cases:
            view = build.view(c['step']) if mode == 'own' else nearest_ref_side(c['photo_yaw'])
            r = sv.check_step(c['image'], c['step'], build=build, view=view, both_orders=a.both_orders, model=a.model)
            ok = r['done'] == c['done']
            rows.append({k: v for k, v in c.items() if k != 'image'} | {'mode': mode, 'view': view, 'p_done': r['p_done'],
                                                                       'correct': ok, 'seconds': r['seconds']})
            print(f"{mode:4} step {c['step']:2} {c['state']:6} p_done={r['p_done']:.2f} {'ok ' if ok else 'BAD'} {r['seconds']:.1f}s", flush=True)

    print('\n== summary ==')
    summary = {}
    for mode in modes:
        rs = [r for r in rows if r['mode'] == mode]
        acc = sum(r['correct'] for r in rs) / len(rs)
        pos = [r['p_done'] for r in rs if r['done']]
        neg = [r['p_done'] for r in rs if not r['done']]
        # How often a done picture scores above a not-done picture of the same step (pairwise).
        pairs = [(r1['p_done'], r2['p_done']) for r1 in rs if r1['done'] for r2 in rs if not r2['done'] and r2['step'] == r1['step']]
        pair_acc = sum(p > q for p, q in pairs) / len(pairs) if pairs else float('nan')
        secs = sorted(r['seconds'] for r in rs)
        summary[mode] = {'accuracy': round(acc, 3), 'pair_accuracy': round(pair_acc, 3),
                         'mean_p_done_when_done': round(sum(pos) / len(pos), 3), 'mean_p_done_when_not': round(sum(neg) / len(neg), 3),
                         'median_seconds': secs[len(secs) // 2], 'n': len(rs)}
        s = summary[mode]
        print(f"{mode:4}: {s['accuracy']:.0%} right at 0.5 ({s['n']} pictures); done>not-done for the same step {s['pair_accuracy']:.0%}; "
              f"mean p_done {s['mean_p_done_when_done']:.2f} when done vs {s['mean_p_done_when_not']:.2f} when not; "
              f"{s['median_seconds']:.1f}s per check")
    out = RESULTS / f"eval-{time.strftime('%Y%m%d-%H%M%S')}-{a.model.replace(':', '_')}{'-both' if a.both_orders else ''}.json"
    out.write_text(json.dumps({'model': a.model, 'both_orders': a.both_orders, 'seed': a.seed, 'summary': summary,
                               'minutes': round((time.time() - t_start) / 60, 1), 'rows': rows}, indent=1))
    print(f'\nwrote {out}')


if __name__ == '__main__':
    sys.exit(main())
