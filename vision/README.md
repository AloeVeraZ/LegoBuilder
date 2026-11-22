# Step finder (local vision model)

Works out which step the builder is on by looking at their real build: "is step N done yet?"
It runs on the Mac with a local vision model (Ollama), so frames from the glasses or the phone
never leave the table.

**Outcome: tried and dropped.** The local vision models that fit a 16 GB Mac (gemma4 e4b,
qwen3-vl 8b) could not tell "before step N" from "after step N" (results below). The glasses
now check the step themselves, without a model: `PieceCheck` / `SetDown` in `glasses/src`,
described in `glasses/README.md` ("The set-down check"). This folder is kept as the record,
and its scripts still work for trying another model (`BL_VISION_MODEL`).

## How it works

The model is too small and the steps too alike (most add one pin or beam) to ask a 7B vision
model "which of 23 steps is this?". So it is asked something it can answer:

1. The app knows the current step N.
2. For step N there are two rendered pictures from the model package: the build **before** N
   and **after** N, from the same side and framed alike, so only the new pieces differ.
3. The model gets both renders, the camera picture and the words for what N adds
   ("1 x Tan Technic Axle Pin"), and answers one letter: like the before render or the after one.
4. That letter's probability comes back as `p_done` (0..1). `Follower` moves on only after
   two checks in a row reach 0.8, so one lucky frame does not skip a step.

Sub-builds are handled: step 7's "before" is an empty table (the front unit starts from nothing),
and step 13's "before" is the chassis after step 6, with the finished front unit attached as "after".

## Run it

```bash
# 1. Ollama with a vision model, guarded so it cannot take the Mac down (see "Memory" below).
#    The models on this Mac are on the NYCFIRST drive; the script points Ollama there.
vision/ollama_safe.sh

# 2. Reference pictures (once, and after the model package changes). ~10 s.
cd pipeline/render && npm install && cd ../..
vision/make_refs.sh

# 3. Check a photo
python3 vision/stepvision.py photo.jpg --step 7

# 4. Test on made-up camera pictures: quick (12 pictures, several prompts) or full (46 pictures)
python3 vision/try_model.py gemma4 --styles words,crop2
python3 vision/eval_synthetic.py

# 5. Serve it for the glasses / phone
python3 vision/serve.py --lan
curl -X POST 'http://<mac>:8765/check?step=7' --data-binary @photo.jpg
```

If Playwright says a browser is missing, point it at one already downloaded instead of
downloading again: `export BL_CHROMIUM=~/Library/Caches/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell`.

`BL_VISION_MODEL` picks another Ollama model (default `gemma4`).

## Results so far

**gemma4 (e4b, 7.5B, Q4) cannot do this.** 12 made-up camera pictures (steps 2, 6, 9, 13, 17,
22, before and after each), M4 Mac with 16 GB:

| Prompt | Right | Time per check |
|---|---|---|
| One letter, A = before / B = after | always "B" | 2.7 s |
| One word, "first" / "second" | 6 / 12 (always "second") | 4.2 s |
| Two sentences of reasoning, then the answer | 7 / 12 | 7.6 s |
| Picture cut down to the model, no hint text, asked both ways round | 0.5 on every picture | 2 × 2.7 s |

Asked both ways round, it picks whichever render comes second about 85% of the time,
whatever the photo shows. Telling it what the step adds makes it worse: it then "sees" the
piece (step 22 without the tipper bed was called done). Asked to describe the three pictures
freely, it does see all three, in order. It just cannot compare them reliably.

Other things learned:
- Ollama returns log-probabilities for gemma4, so `p_done` works for any model that answers well.
- Loading the model from the NYCFIRST drive (USB, ~35 MB/s) takes about 3¾ minutes; after
  that a check is 2.7 s. Load it before a demo, or keep the model store on the internal disk.
- Qwen on this Mac is `Qwen3-4B` for llama.cpp: text only, no vision.

Everything here is written so the model is one setting (`BL_VISION_MODEL`), so a stronger
vision model can be tried with the same references, test and service.

**qwen3-vl:8b** (8.2B, Q4, the thinking build: it always reasons first, `think: false` is
ignored, so one-word prompts get no answer and only the `think` style of `try_model.py` means
anything). Each 768 px picture costs it ~700 tokens (~22 s to read three); at 448 px ~256.

**It cannot do this either.** `try_model.py qwen3-vl:8b --styles think --size 448
--think-budget 2000`, pictures cut down to the model, the two renders swapping places from step
to step (21 Nov, after freeing 14 GB of disk; swap peaked at 3.6 GB, no crash):

| Right | after > before | No answer (ran out of 2,000 tokens) | Time per picture |
|---|---|---|---|
| 4 / 12 | 1 / 6 | 5 / 12 | 2 min (53-175 s) |

Every one of its 7 answers was "second", whichever render was second. Like gemma4, it reasons
at length and then falls back on a position. Even if it were right, 2 minutes a check is far
too slow to follow someone building.

**Conclusion so far:** the 4B-8B vision models that fit this Mac cannot tell "before step N"
from "after step N", even on clean rendered pictures cropped to the model (the easy case;
real photos are harder). Asking a general vision model is not the way to follow the build here.
The marker-guided check under "Not done yet" is the next thing to try.

## Memory: this can crash a 16 GB Mac

Running qwen3-vl:8b on the 16 GB MacBook Air restarted it (kernel watchdog panic, 21 Nov
10:54): `llama-server` held 8.7 GB, 9.3 GB was wired for the GPU, free memory was ~14 MB and
the internal disk had only ~7 GB free, so macOS could not swap. An earlier restart at 09:43
came while gemma4 was loading. So:

- Start Ollama with `vision/ollama_safe.sh`: one model at a time, 4k context, and it stops
  Ollama itself when free disk drops under 3 GB or memory runs out. (It did, once, at 3.0 GB.)
- Keep 15+ GB free on the internal disk and close Chrome before running an 8B model. Swap can
  only live on the internal disk; an external SSD does not help with it.
- The SanDisk SSD showed "Up to 480 Mb/s" (USB 2) on a short angled USB-C cable, hence the
  ~4 minute model loads. A 10 Gb/s cable (the one from the SanDisk box) makes that seconds.

## If a vision model is tried again

- Every number above is from rendered pictures; photos of the real set at each step are the
  real test.
- Give it the build cropped tightly (the table marker says where it stands) and seen from the
  side it is really on (the marker pose says that too); both are what the glasses' own check
  uses now.
- It would have to run on the Mac (the glasses can't), so frames would go over Wi-Fi to
  `serve.py`; at 2.7 s a check that is fine for set-down checks, but not live.
