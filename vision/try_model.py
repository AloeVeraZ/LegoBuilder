#!/usr/bin/env python3
"""Try a vision model on the step question, several ways of asking, on the same 12 pictures.

Steps 2, 6, 9, 13, 17 and 22, before and after each, as made-up camera pictures (see
eval_synthetic.py). Quicker than the full test, for deciding whether a model or a prompt is
worth a full run.

    python3 vision/try_model.py qwen3-vl:8b --styles words,crop2
    python3 vision/try_model.py qwen3-vl:8b --styles think --size 448

Styles:
  letter  stepvision.check_step as it is (one letter, A/B)
  words   one word, "first" / "second", with the step's pieces named
  reason  two sentences, then "Answer: first/second"
  crop2   the picture cut down to the model (what the table marker would give), no piece
          names, asked both ways round and averaged (cancels a leaning towards one position)
  think   for thinking models: let it reason, then read its one-word verdict; the picture is
          cut down to the model and the two renders alternate places from picture to picture

"right" counts answers on the correct side of 0.5; "after>before" counts steps whose after
picture scored higher than its before picture (does the model see any difference at all).
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
import urllib.request
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eval_synthetic as ev  # noqa: E402
import stepvision as sv  # noqa: E402

STEPS = [2, 6, 9, 13, 17, 22]
CROP_PROMPT = ("The first two pictures are renders of the same small LEGO Technic model at two moments of building it; "
               "they differ by a few pieces. The last picture is a photo of a real model, possibly from another angle and "
               "on a different background. {extra}Which of the first two pictures shows the same model as the last picture? "
               "Reply with one word: first or second.")


def make_cases(seed: int = 3):
    ev.render_shots()
    rng = random.Random(seed)
    out = []
    for n in STEPS:
        for st in ('after', 'before'):
            yi, e = rng.randrange(4), rng.choice([45, 70])
            src = ev.SHOTS / f'step-{n:03d}-{st}-y{yi}-e{e}.png'
            photo = ev.camera_picture(src, rng)
            rgba = Image.open(src).convert('RGBA')
            bx = rgba.split()[-1].getbbox() or (0, 0, rgba.width, rgba.height)
            table = Image.new('RGBA', rgba.size, (200, 170, 130, 255))
            table.alpha_composite(rgba)
            crop = table.crop((max(0, bx[0] - 40), max(0, bx[1] - 40), min(rgba.width, bx[2] + 40),
                               min(rgba.height, bx[3] + 40))).convert('RGB')
            out.append({'step': n, 'state': st, 'photo': photo, 'crop': crop})
    return out


class Asker:
    def __init__(self, model: str, size: int):
        self.model, self.size, self.build = model, size, sv.Build()

    def refs(self, n):
        v = self.build.view(n)
        return sv.encode(sv.ref_path(n, 'before', v), self.size), sv.encode(sv.ref_path(n, 'after', v), self.size)

    def chat(self, imgs, prompt, npred, think=False):
        body = {'model': self.model, 'stream': False, 'keep_alive': '10m',
                'messages': [{'role': 'user', 'content': prompt, 'images': imgs}],
                'options': {'temperature': 0, 'seed': 0, 'num_predict': npred}, 'logprobs': True, 'top_logprobs': 10}
        if not think:
            body['think'] = False
        req = urllib.request.Request(sv.OLLAMA + '/api/chat', data=json.dumps(body).encode(),
                                     headers={'Content-Type': 'application/json'})
        return json.loads(urllib.request.urlopen(req, timeout=1200).read())

    @staticmethod
    def p_second(cands):
        ps = pf = 0.0
        for c in cands:
            t = c['token'].strip().lower()
            if t and 'second'.startswith(t):
                ps += math.exp(c['logprob'])
            elif t and 'first'.startswith(t):
                pf += math.exp(c['logprob'])
        return ps / (ps + pf) if ps + pf else None

    def first_word_p(self, r):
        """P(second) at the first real answer token; None when the model never answered."""
        for t in r.get('logprobs') or []:
            if t['token'].strip() in ('', '**', '"', "'", '.'):
                continue
            if t['token'].strip().startswith('<'):            # <think> and friends: not an answer
                return None
            return self.p_second(t.get('top_logprobs') or [t])
        return None

    # Each style returns (p_done or None, note).
    def letter(self, c):
        r = sv.check_step(c['photo'], c['step'], build=self.build, model=self.model, size=self.size)
        return r['p_done'], ''

    def words(self, c):
        n = c['step']
        bef, aft = self.refs(n)
        prompt = (f"The first two pictures are renders of a small LEGO Technic model. The first is BEFORE step {n}, the second "
                  f"is AFTER step {n}, which adds {self.build.adds(n)}. The last picture is a real photo of someone's model "
                  "from some angle. Which of the first two pictures does the model in the last picture match? "
                  "Reply with one word: first or second.")
        r = self.chat([bef, aft, sv.encode(c['photo'], self.size)], prompt, 3)
        return self.first_word_p(r), r['message'].get('content', '').strip()[:20]

    def reason(self, c):
        n = c['step']
        bef, aft = self.refs(n)
        prompt = (f"The first two pictures are renders of a small LEGO Technic model. The first is BEFORE step {n}, the second "
                  f"is AFTER step {n}, which adds {self.build.adds(n)}. The last picture is a real photo of someone's model, "
                  "maybe from another angle and on another background.\nIn one or two short sentences, say what differs "
                  "between the first two pictures and whether the last picture shows it. Then finish with exactly "
                  "'Answer: first' if the last picture matches the first (step not done) or 'Answer: second' if it matches "
                  "the second (step done).")
        r = self.chat([bef, aft, sv.encode(c['photo'], self.size)], prompt, 200)
        lps = r.get('logprobs') or []
        for i, t in enumerate(lps):
            if 'answer' in t['token'].lower():
                for j in range(i + 1, min(i + 5, len(lps))):
                    if lps[j]['token'].strip().lower() in (':', '', '**'):
                        continue
                    return self.p_second(lps[j].get('top_logprobs') or [lps[j]]), r['message']['content'][:120]
        return None, r['message'].get('content', '')[:120]

    def crop2(self, c):
        bef, aft = self.refs(c['step'])
        ph = sv.encode(c['crop'], self.size)
        prompt = CROP_PROMPT.format(extra='Look at the shapes and colours of the model in each picture. ')
        p1 = self.first_word_p(self.chat([bef, aft, ph], prompt, 3))
        p2 = self.first_word_p(self.chat([aft, bef, ph], prompt, 3))
        if p1 is None or p2 is None:
            return None, f'orders {p1}/{p2}'
        return (p1 + (1 - p2)) / 2, f'orders {p1:.2f}/{1 - p2:.2f}'

    def think(self, c, i, budget):
        bef, aft = self.refs(c['step'])
        # Flip the order per step, not per picture: pictures go after, before, after, before...
        # so flipping per picture would make "second" right every time.
        before_first = (i // 2) % 2 == 0
        imgs = [bef, aft] if before_first else [aft, bef]
        prompt = CROP_PROMPT.format(extra='Work out which pieces differ between the first two pictures, then check whether '
                                          'the model in the last picture has them. ')
        r = self.chat(imgs + [sv.encode(c['crop'], self.size)], prompt, budget, think=True)
        ans = r['message'].get('content', '').strip().lower()
        second, first = 'second' in ans, 'first' in ans
        if second == first:
            return None, f'no verdict ({r.get("eval_count")} tokens)'
        picked_after = second if before_first else first
        return (1.0 if picked_after else 0.0), f'{ans[:12]!r}, {r.get("eval_count")} tokens'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('model')
    ap.add_argument('--styles', default='words,crop2')
    ap.add_argument('--size', type=int, default=512, help='longest side of every picture sent, in pixels')
    ap.add_argument('--think-budget', type=int, default=1500, help='most tokens a thinking model may use')
    a = ap.parse_args(argv)
    asker = Asker(a.model, a.size)
    cases = make_cases()
    lines = []
    for style in a.styles.split(','):
        t0, right, scores = time.time(), 0, {}
        for i, c in enumerate(cases):
            t1 = time.time()
            if style == 'think':
                p, note = asker.think(c, i, a.think_budget)
            else:
                p, note = getattr(asker, style)(c)
            ok = p is not None and (p >= 0.5) == (c['state'] == 'after')
            right += ok
            scores[(c['step'], c['state'])] = p
            shown = '  -  ' if p is None else f'{p:.2f}'
            print(f"{style:6} step {c['step']:2} {c['state']:6} p_done={shown} {'ok ' if ok else 'BAD'} {time.time() - t1:5.1f}s {note}", flush=True)
        pairs = sum((scores[(n, 'after')] or 0) > (scores[(n, 'before')] or 0) for n in STEPS)
        no_answer = sum(v is None for v in scores.values())
        line = (f"{a.model} {style} @{a.size}px: {right}/{len(cases)} right, after>before {pairs}/{len(STEPS)}, "
                f"{no_answer} without an answer, {(time.time() - t0) / len(cases):.1f}s per picture")
        lines.append(line)
        print('== ' + line + '\n', flush=True)
    print('\n'.join(lines))


if __name__ == '__main__':
    sys.exit(main())
