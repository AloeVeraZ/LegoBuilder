#!/usr/bin/env python3
"""
ldraw2build.py - turn a digital brick model into a BuildLens "build package".

Input:  an LDraw model (.ldr / .mpd, "packed" or not) or a BrickLink Studio .io file.
Output: <out>/build.json    set info, colours, parts, instances, assemblies, steps
        <out>/geometry.bin  little-endian float32 positions + normals, uint32 indices

The output coordinate system is metres, +Y up, right-handed (same as RealityKit,
SceneKit and glTF), so the app can use transforms and vertices as they are.

How steps are built (mirrors how printed instructions work):
  * every "0 STEP" / "0 ROTSTEP" in a model file closes a step
  * the first time a sub-model (sub-assembly) is used, its own steps are emitted
    first, shown on their own; then the parent step attaches the finished
    sub-assembly. Later uses of the same sub-model are added in one go.

Usage:
  python3 ldraw2build.py MODEL --library /path/to/ldraw --out OUTDIR \
      [--set-id 77243-1] [--set-name "..."]
"""
from __future__ import annotations

import argparse
import datetime as _dt
import io
import json
import os
import sys
import zipfile
from dataclasses import dataclass, field

import numpy as np

LDU = 0.0004                      # metres per LDraw unit (1 LDU = 0.4 mm)
STUDIO_IO_PASSWORD = b"soho0909"  # BrickLink Studio .io files are zips with this password
SMOOTH_ANGLE_DEG = 35.0           # faces meeting at less than this angle are shaded smooth
MAX_DEPTH = 64

# LDraw is -Y up. Rotating 180 degrees about X gives +Y up and keeps handedness,
# so triangle winding (and therefore which side is the front face) is preserved.
FLIP = np.diag([1.0, -1.0, -1.0])
K = np.diag([LDU, -LDU, -LDU, 1.0])        # LDraw point -> output point
K_INV = np.linalg.inv(K)


def norm(name: str) -> str:
    return name.strip().replace("\\", "/").lower()


def log(*a):
    print(*a, file=sys.stderr)


# --------------------------------------------------------------------------- files

@dataclass
class SourceFile:
    name: str               # normalised key, e.g. "parts/3001.dat" or "wing.ldr"
    display: str            # name as written in the file
    lines: list
    origin: str             # "model" | "library"
    kind: str = ""          # "model" | "part" | "subpart" | "primitive" | "config"
    description: str = ""


def read_text(data: bytes) -> list:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def split_mpd(lines: list, origin: str) -> list:
    """Split an (M)PD into SourceFiles. Content before the first '0 FILE' that holds
    geometry or references is treated as the main model (three.js 'packed' files)."""
    files = []
    cur_name, cur_lines = None, []
    preamble = []

    def flush():
        if cur_name is not None:
            files.append(SourceFile(norm(cur_name), cur_name, cur_lines, origin))

    for raw in lines:
        s = raw.strip()
        if s.upper().startswith("0 FILE "):
            flush()
            cur_name, cur_lines = s[7:].strip(), []
            continue
        if s.upper().startswith("0 NOFILE"):
            flush()
            cur_name, cur_lines = None, []
            continue
        if cur_name is None:
            preamble.append(raw)
        else:
            cur_lines.append(raw)
    flush()

    has_content = any(l.strip()[:1] in ("1", "2", "3", "4", "5") for l in preamble)
    if has_content:
        files.insert(0, SourceFile("__main__.ldr", "Main model", preamble, origin))
    elif not files:
        files.append(SourceFile("__main__.ldr", "Main model", preamble, origin))
    # Colour definitions in a preamble (packed files start with LDConfig) still matter.
    elif any("!COLOUR" in l for l in preamble):
        files.insert(0, SourceFile("__config__.ldr", "LDConfig", preamble, origin))
    return files


def classify(sf: SourceFile) -> None:
    kind = ""
    for raw in sf.lines[:60]:
        s = raw.strip()
        toks = s.split()
        if len(toks) >= 3 and toks[0] == "0" and toks[1] in ("!LDRAW_ORG", "LDRAW_ORG"):
            typ = toks[2].lower().replace("unofficial_", "")
            if typ in ("part", "shortcut"):
                kind = "part"
            elif typ == "subpart":
                kind = "subpart"
            elif "primitive" in typ:
                kind = "primitive"
            elif typ in ("model", "submodel"):
                kind = "model"
            elif typ == "configuration":
                kind = "config"
            break
    if not kind:
        n = sf.name
        if n.startswith("parts/s/") or n.startswith("s/"):
            kind = "subpart"
        elif n.startswith("parts/"):
            kind = "part"
        elif n.startswith("p/"):
            kind = "primitive"
        else:
            kind = "model"
    sf.kind = kind
    for raw in sf.lines:
        s = raw.strip()
        if not s:
            continue
        if s.startswith("0 ") and not s.startswith("0 !") and not s.startswith("0 //") \
                and not s.upper().startswith("0 NAME:") and not s.upper().startswith("0 AUTHOR:") \
                and not s.upper().startswith("0 BFC"):
            sf.description = s[2:].strip()
        break


def model_description(sf: SourceFile) -> str:
    """Title of a model: the comment line right above its '0 Name:' line (skipping LDConfig)."""
    lines = [l.strip() for l in sf.lines]
    for i, l in enumerate(lines):
        if l.upper().startswith("0 NAME:") and "ldconfig" not in l.lower():
            for j in range(i - 1, -1, -1):
                c = lines[j]
                if c.startswith("0 ") and not c.startswith("0 !") and not c.startswith("0 //") and len(c) > 2:
                    return c[2:].strip()
                if c and not c.startswith("0"):
                    break
            break
    return sf.description


class Library:
    SEARCH_PREFIXES = ("", "parts/", "p/", "models/", "unofficial/parts/", "unofficial/p/")

    def __init__(self, roots):
        self.embedded = {}
        self.index = {}
        self.cache = {}
        self.missing = set()
        for root in roots:
            if not root:
                continue
            root = os.path.abspath(root)
            if not os.path.isdir(root):
                log(f"warning: library path {root} not found")
                continue
            for dirpath, _dirs, files in os.walk(root):
                for f in files:
                    full = os.path.join(dirpath, f)
                    rel = os.path.relpath(full, root).replace(os.sep, "/").lower()
                    self.index.setdefault(rel, full)

    def add_embedded(self, sf: SourceFile):
        classify(sf)
        if sf.name == "__main__.ldr":
            sf.kind = "model"
            sf.description = model_description(sf)
        self.embedded.setdefault(sf.name, sf)

    def find(self, ref: str):
        key = norm(ref)
        if key in self.cache:
            return self.cache[key]
        found = None
        for pre in self.SEARCH_PREFIXES:
            if pre + key in self.embedded:
                found = self.embedded[pre + key]
                break
        if found is None:
            for pre in self.SEARCH_PREFIXES:
                path = self.index.get(pre + key)
                if path:
                    with open(path, "rb") as fh:
                        found = SourceFile(pre + key, ref, read_text(fh.read()), "library")
                    classify(found)
                    break
        if found is None:
            self.missing.add(key)
        self.cache[key] = found
        return found


# --------------------------------------------------------------------------- colours

@dataclass
class Colour:
    code: int
    name: str
    rgba: tuple
    finish: str = "plastic"


def parse_colour_line(line: str):
    toks = line.split()
    if len(toks) < 4:
        return None
    name = toks[2].replace("_", " ")
    vals, finish, i = {}, "plastic", 3
    while i < len(toks):
        k = toks[i].upper()
        if k in ("CODE", "VALUE", "EDGE", "ALPHA", "LUMINANCE") and i + 1 < len(toks):
            vals[k] = toks[i + 1]
            i += 2
            continue
        if k in ("CHROME", "PEARLESCENT", "RUBBER", "MATTE_METALLIC", "METAL"):
            finish = k.lower()
        elif k == "MATERIAL":
            finish = "material"
            break
        i += 1
    if "CODE" not in vals or "VALUE" not in vals:
        return None
    try:
        code = int(vals["CODE"])
        v = vals["VALUE"].lstrip("#")
        if v.lower().startswith("0x2"):
            v = v[3:]
        r, g, b = int(v[0:2], 16) / 255, int(v[2:4], 16) / 255, int(v[4:6], 16) / 255
        a = int(vals.get("ALPHA", "255")) / 255
    except (ValueError, IndexError):
        return None
    return Colour(code, name, (round(r, 4), round(g, 4), round(b, 4), round(a, 4)), finish)


def parse_colour_code(tok: str) -> int:
    t = tok.strip()
    if t.lower().startswith("0x"):
        return int(t, 16)
    if t.startswith("#"):
        return 0x2000000 | int(t[1:], 16)
    return int(t)


def direct_colour(code: int):
    if 0x2000000 <= code <= 0x2FFFFFF:
        v = code & 0xFFFFFF
        return Colour(code, f"#{v:06X}", (((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255, 1.0))
    return None


# --------------------------------------------------------------------------- geometry

@dataclass
class Parsed:
    tris: np.ndarray
    colours: np.ndarray
    ccw: np.ndarray
    refs: list
    certified: bool


_parsed_cache = {}


def parse_geometry(sf: SourceFile) -> Parsed:
    key = (sf.origin, sf.name)
    if key in _parsed_cache:
        return _parsed_cache[key]
    tris, cols, ccw, refs = [], [], [], []
    certified, winding_ccw, invert_next = False, True, False
    for raw in sf.lines:
        toks = raw.split()
        if not toks:
            continue
        t = toks[0]
        if t == "0":
            if len(toks) >= 2 and toks[1].upper() == "BFC":
                opts = [o.upper() for o in toks[2:]]
                if "NOCERTIFY" in opts:
                    certified = False
                elif "CERTIFY" in opts:
                    certified = True
                if "CW" in opts:
                    winding_ccw = False
                if "CCW" in opts:
                    winding_ccw = True
                if "INVERTNEXT" in opts:
                    invert_next = True
            continue
        try:
            if t == "1" and len(toks) >= 15:
                c = parse_colour_code(toks[1])
                x, y, z, a, b, cc, d, e, f, g, h, i = map(float, toks[2:14])
                name = raw.strip().split(None, 14)[14].strip()
                m = np.array([[a, b, cc, x], [d, e, f, y], [g, h, i, z], [0, 0, 0, 1]], dtype=np.float64)
                refs.append((c, m, name, invert_next))
                invert_next = False
            elif t == "3" and len(toks) >= 11:
                c = parse_colour_code(toks[1])
                v = np.array(list(map(float, toks[2:11]))).reshape(3, 3)
                tris.append(v)
                cols.append(c)
                ccw.append(winding_ccw)
            elif t == "4" and len(toks) >= 14:
                c = parse_colour_code(toks[1])
                v = np.array(list(map(float, toks[2:14]))).reshape(4, 3)
                tris.append(v[[0, 1, 2]])
                tris.append(v[[0, 2, 3]])
                cols += [c, c]
                ccw += [winding_ccw, winding_ccw]
        except ValueError:
            continue
    p = Parsed(
        np.array(tris, dtype=np.float64).reshape(-1, 3, 3),
        np.array(cols, dtype=np.int64),
        np.array(ccw, dtype=bool),
        refs,
        certified,
    )
    _parsed_cache[key] = p
    return p


def flatten(lib: Library, sf: SourceFile, mirror: bool):
    """All triangles of a part in part-local LDraw space, wound counter-clockwise.
    Colour 16 (inherit) is kept as 16 so instances can apply their own colour."""
    out_v, out_c = [], []
    m0 = np.diag([-1.0, 1.0, 1.0, 1.0]) if mirror else np.eye(4)

    def rec(f, m, invert, cert_chain, ctx, depth):
        if depth > MAX_DEPTH:
            return
        p = parse_geometry(f)
        cert = cert_chain and p.certified
        if len(p.tris):
            v = p.tris @ m[:3, :3].T + m[:3, 3]
            cols = np.where((p.colours == 16) | (p.colours == 24), ctx, p.colours)
            if cert:
                flip = p.ccw == invert
                v = np.where(flip[:, None, None], v[:, ::-1, :], v)
                out_v.append(v)
                out_c.append(cols)
            else:  # winding unknown: emit both sides
                out_v.append(v)
                out_c.append(cols)
                out_v.append(v[:, ::-1, :])
                out_c.append(cols)
        for (c, mi, name, inv_next) in p.refs:
            child = lib.find(name)
            if child is None:
                continue
            child_ctx = ctx if c in (16, 24) else c
            det = np.linalg.det(mi[:3, :3])
            rec(child, m @ mi, invert ^ bool(det < 0) ^ inv_next, cert, child_ctx, depth + 1)

    rec(sf, m0, mirror, True, 16, 0)
    if not out_v:
        return np.zeros((0, 3, 3)), np.zeros((0,), dtype=np.int64)
    return np.concatenate(out_v), np.concatenate(out_c)


def smooth_normals(tris: np.ndarray, angle_deg: float):
    """Per-corner normals: average of neighbouring face normals within angle_deg."""
    e1 = tris[:, 1] - tris[:, 0]
    e2 = tris[:, 2] - tris[:, 0]
    cr = np.cross(e1, e2)
    area = np.linalg.norm(cr, axis=1)
    fn = cr / np.maximum(area, 1e-12)[:, None]
    m = len(tris)
    corners = tris.reshape(-1, 3)
    key = np.round(corners / 0.01).astype(np.int64)
    _, vid = np.unique(key, axis=0, return_inverse=True)
    vid = vid.reshape(-1)
    face_of = np.repeat(np.arange(m), 3)
    cos_t = np.cos(np.radians(angle_deg))
    order = np.argsort(vid, kind="stable")
    sv = vid[order]
    starts = np.flatnonzero(np.r_[True, sv[1:] != sv[:-1]])
    sizes = np.diff(np.r_[starts, len(order)])
    out = np.zeros((3 * m, 3))
    for k in np.unique(sizes):
        g = starts[sizes == k]
        idx = order[g[:, None] + np.arange(k)[None, :]]            # (G,k) corner ids
        n = fn[face_of[idx]]                                       # (G,k,3)
        w = n * area[face_of[idx]][..., None]
        if k == 1:
            out[idx[:, 0]] = n[:, 0]
            continue
        mask = (np.einsum("gid,gjd->gij", n, n) > cos_t).astype(np.float64)
        out[idx.reshape(-1)] = np.einsum("gij,gjd->gid", mask, w).reshape(-1, 3)
    ln = np.linalg.norm(out, axis=1)
    bad = ln < 1e-12
    out[bad] = fn[face_of[bad]]
    out[~bad] /= ln[~bad][:, None]
    return out.reshape(m, 3, 3)


@dataclass
class MeshGroup:
    colour: int
    positions: np.ndarray   # (n,3) float32, metres, +Y up
    normals: np.ndarray     # (n,3) float32
    indices: np.ndarray     # (3t,) uint32


def build_part_mesh(tris_ldu: np.ndarray, cols: np.ndarray):
    if len(tris_ldu) == 0:
        return []
    e1 = tris_ldu[:, 1] - tris_ldu[:, 0]
    e2 = tris_ldu[:, 2] - tris_ldu[:, 0]
    keep = np.linalg.norm(np.cross(e1, e2), axis=1) > 1e-6
    tris_ldu, cols = tris_ldu[keep], cols[keep]
    if len(tris_ldu) == 0:
        return []
    normals = smooth_normals(tris_ldu, SMOOTH_ANGLE_DEG)
    pos = (tris_ldu @ FLIP.T) * LDU
    nrm = normals @ FLIP.T
    groups = []
    for c in sorted(set(cols.tolist()), key=lambda c: (c != 16, c)):
        sel = cols == c
        p = pos[sel].reshape(-1, 3)
        n = nrm[sel].reshape(-1, 3)
        key = np.concatenate([np.round(p / 1e-6), np.round(n * 1000)], axis=1).astype(np.int64)
        uniq, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
        groups.append(MeshGroup(
            int(c),
            p[first].astype(np.float32),
            n[first].astype(np.float32),
            inv.reshape(-1).astype(np.uint32),
        ))
    return groups


# --------------------------------------------------------------------------- steps

@dataclass
class Instance:
    part: str                # part key (with "|m" suffix for mirrored variants)
    colour: int
    world: np.ndarray        # LDraw-space 4x4


@dataclass
class Assembly:
    id: int
    name: str
    file: str
    parent: int
    world: np.ndarray
    uses: int = 1
    members: list = field(default_factory=list)


class StepBuilder:
    def __init__(self, lib: Library):
        self.lib = lib
        self.instances = []
        self.assemblies = []
        self.steps = []
        self.built = set()
        self.use_count = {}
        self.part_files = {}

    def count_uses(self, f: SourceFile, mult: int, depth=0):
        if depth > MAX_DEPTH:
            return
        for raw in f.lines:
            toks = raw.split()
            if len(toks) >= 15 and toks[0] == "1":
                name = raw.strip().split(None, 14)[14].strip()
                child = self.lib.find(name)
                if child is not None and child.kind == "model":
                    self.use_count[child.name] = self.use_count.get(child.name, 0) + mult
                    self.count_uses(child, mult, depth + 1)

    def run(self, main: SourceFile, title: str):
        self.count_uses(main, 1)
        root = Assembly(0, title, main.name, -1, np.eye(4))
        self.assemblies.append(root)
        ids = self.process(main, np.eye(4), 16, 0, True, 0)
        root.members = ids

    def process(self, f: SourceFile, world, ctx, asm_id, emit, depth):
        if depth > MAX_DEPTH:
            return []
        all_ids, added = [], []
        for raw in f.lines:
            toks = raw.split()
            if not toks:
                continue
            if toks[0] == "0":
                if len(toks) >= 2 and toks[1].upper() in ("STEP", "ROTSTEP"):
                    if emit and added:
                        self.steps.append({"assembly": asm_id, "added": added})
                    added = []
                continue
            if toks[0] != "1" or len(toks) < 15:
                continue
            try:
                c = parse_colour_code(toks[1])
                x, y, z, a, b, cc, d, e, g_, h, i, j = map(float, toks[2:14])
            except ValueError:
                continue
            name = raw.strip().split(None, 14)[14].strip()
            m = world @ np.array([[a, b, cc, x], [d, e, g_, y], [h, i, j, z], [0, 0, 0, 1]], dtype=np.float64)
            col = ctx if c in (16, 24) else c
            child = self.lib.find(name)
            if child is not None and child.kind == "model":
                if emit and child.name not in self.built:
                    self.built.add(child.name)
                    sub = Assembly(len(self.assemblies), pretty_name(child), child.name, asm_id, m,
                                   uses=self.use_count.get(child.name, 1))
                    self.assemblies.append(sub)
                    ids = self.process(child, m, col, sub.id, True, depth + 1)
                    sub.members = ids
                else:
                    ids = self.process(child, m, col, asm_id, False, depth + 1)
            else:
                key = part_key(name)
                if child is not None:
                    self.part_files.setdefault(key, child)
                if np.linalg.det(m[:3, :3]) < 0:
                    key += "|m"
                    m = m @ np.diag([-1.0, 1.0, 1.0, 1.0])
                    if child is not None:
                        self.part_files.setdefault(key, child)
                self.instances.append(Instance(key, col, m))
                ids = [len(self.instances) - 1]
            added += ids
            all_ids += ids
        if emit and added:
            self.steps.append({"assembly": asm_id, "added": added})
        return all_ids


def part_key(name: str) -> str:
    k = norm(name)
    for pre in ("parts/", "p/"):
        if k.startswith(pre):
            k = k[len(pre):]
    if k.endswith(".dat"):
        k = k[:-4]
    return k


def pretty_name(sf: SourceFile) -> str:
    n = sf.display.replace("\\", "/").split("/")[-1]
    for ext in (".ldr", ".mpd", ".dat"):
        if n.lower().endswith(ext):
            n = n[: -len(ext)]
    if " - " in n and n.split(" - ")[0].replace("-", "").isdigit():
        n = n.split(" - ", 1)[1]
    return n.strip() or (sf.description or "Sub-assembly")


# --------------------------------------------------------------------------- io

def load_model(path: str):
    """Return (list of SourceFile, title)."""
    with open(path, "rb") as fh:
        data = fh.read()
    if path.lower().endswith(".io") or data[:2] == b"PK":
        z = zipfile.ZipFile(io.BytesIO(data))
        names = z.namelist()

        def rd(n):
            try:
                return z.read(n)
            except RuntimeError:
                return z.read(n, pwd=STUDIO_IO_PASSWORD)

        main = next((n for n in names if n.lower() == "model.ldr"), None) or \
            next((n for n in names if n.lower().endswith((".ldr", ".mpd"))), None)
        if main is None:
            raise SystemExit("no .ldr inside the .io file")
        files = split_mpd(read_text(rd(main)), "model")
        for n in names:  # custom parts shipped inside the .io
            ln = n.lower()
            if ln.endswith(".dat") and "customparts/" in ln:
                rel = ln.split("customparts/", 1)[1]
                files.append(SourceFile(norm(rel), n, read_text(rd(n)), "model"))
        return files, os.path.splitext(os.path.basename(path))[0]
    return split_mpd(read_text(data), "model"), os.path.splitext(os.path.basename(path))[0]


def column_major(m4: np.ndarray):
    return [round(float(v), 7) for v in m4.T.reshape(-1)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model")
    ap.add_argument("--library", action="append", default=[], help="LDraw library root (folder with parts/ and p/)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--set-id", default="")
    ap.add_argument("--set-name", default="")
    ap.add_argument("--theme", default="")
    ap.add_argument("--names", help="JSON file mapping part numbers to display names (e.g. the set's official parts list)")
    args = ap.parse_args()

    names = {}
    if args.names:
        with open(args.names) as fh:
            names = json.load(fh)
    files, base_title = load_model(args.model)
    lib = Library(args.library)
    for f in files:
        lib.add_embedded(f)

    # colours: library LDConfig first, then anything defined in the model file
    colours = {}
    cfg_paths = [lib.index.get("ldconfig.ldr")]
    for p in cfg_paths:
        if p:
            with open(p, "rb") as fh:
                for line in read_text(fh.read()):
                    if "!COLOUR" in line:
                        c = parse_colour_line(line.strip())
                        if c:
                            colours[c.code] = c
    for f in files:
        for line in f.lines:
            if "!COLOUR" in line:
                c = parse_colour_line(line.strip())
                if c:
                    colours[c.code] = c

    main_file = next((f for f in files if f.kind == "model"), None)
    if main_file is None:
        raise SystemExit("could not find a model in the input file")
    title = args.set_name or main_file.description or base_title

    sb = StepBuilder(lib)
    sb.run(main_file, title)
    if not sb.instances:
        raise SystemExit("model has no parts")

    # ---- geometry, one mesh per unique part key
    part_keys = sorted({i.part for i in sb.instances})
    part_index = {k: n for n, k in enumerate(part_keys)}
    blob = bytearray()
    parts_json, bounds_by_key, used_colours = [], {}, set()
    total_tris = 0
    for k in part_keys:
        sf = sb.part_files.get(k)
        groups = []
        if sf is not None:
            tris, cols = flatten(lib, sf, k.endswith("|m"))
            groups = build_part_mesh(tris, cols)
        if not groups:  # missing part: a small placeholder brick so the step still shows something
            log(f"warning: no geometry for {k}, using a placeholder")
            box = np.array([[-10, 0, -10], [10, 0, -10], [10, 0, 10], [-10, 0, 10],
                            [-10, 24, -10], [10, 24, -10], [10, 24, 10], [-10, 24, 10]], dtype=np.float64)
            quads = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
            t = []
            for q in quads:
                t.append(box[[q[0], q[1], q[2]]])
                t.append(box[[q[0], q[2], q[3]]])
            groups = build_part_mesh(np.array(t), np.full(len(t), 16))
        gj = []
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for g in groups:
            def put(arr):
                off = len(blob)
                blob.extend(arr.tobytes())
                return off
            po = put(g.positions.astype("<f4"))
            no = put(g.normals.astype("<f4"))
            io_ = put(g.indices.astype("<u4"))
            gj.append({"colour": g.colour, "vertexCount": int(len(g.positions)),
                       "indexCount": int(len(g.indices)), "positions": po, "normals": no, "indices": io_})
            lo = np.minimum(lo, g.positions.min(axis=0))
            hi = np.maximum(hi, g.positions.max(axis=0))
            if g.colour != 16:
                used_colours.add(g.colour)
            total_tris += len(g.indices) // 3
        bounds_by_key[k] = (lo, hi)
        base = k.split("|")[0]
        parts_json.append({
            "key": k,
            "number": base.split("/")[-1],
            "name": names.get(base.split("/")[-1]) or (sf.description if sf else f"Unknown part {base}") or base,
            "mirrored": k.endswith("|m"),
            "bounds": [[round(float(v), 6) for v in lo], [round(float(v), 6) for v in hi]],
            "groups": gj,
        })

    # ---- instances in output space
    def to_out(m):
        return K @ m @ K_INV

    inst_json = []
    for inst in sb.instances:
        used_colours.add(inst.colour)
        inst_json.append({"part": part_index[inst.part], "colour": inst.colour,
                          "matrix": column_major(to_out(inst.world))})

    # ---- assemblies: bounds of the finished assembly in its own space
    asm_json = []
    for a in sb.assemblies:
        inv = np.linalg.inv(to_out(a.world))
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for iid in a.members:
            inst = sb.instances[iid]
            blo, bhi = bounds_by_key[inst.part]
            corners = np.array([[x, y, z, 1.0] for x in (blo[0], bhi[0]) for y in (blo[1], bhi[1]) for z in (blo[2], bhi[2])])
            pts = (inv @ to_out(inst.world) @ corners.T).T[:, :3]
            lo, hi = np.minimum(lo, pts.min(axis=0)), np.maximum(hi, pts.max(axis=0))
        if not np.isfinite(lo).all():
            lo, hi = np.zeros(3), np.zeros(3)
        asm_json.append({"id": a.id, "name": a.name, "parent": a.parent, "uses": a.uses,
                         "matrix": column_major(to_out(a.world)),
                         "bounds": [[round(float(v), 6) for v in lo], [round(float(v), 6) for v in hi]]})

    # ---- colours actually used
    col_json = []
    default = colours.get(16) or Colour(16, "Main Colour", (0.6, 0.6, 0.6, 1.0))
    for code in sorted(used_colours):
        c = colours.get(code) or direct_colour(code)
        if c is None:
            log(f"warning: unknown colour {code}")
            c = Colour(code, f"Colour {code}", default.rgba)
        col_json.append({"code": code, "name": c.name, "rgba": list(c.rgba), "finish": c.finish})

    out = {
        "format": "buildlens.build/1",
        "set": {"id": args.set_id, "name": title, "theme": args.theme, "pieces": len(sb.instances)},
        "source": {"file": os.path.basename(args.model),
                   "generated": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
                   "missingFiles": sorted(lib.missing)},
        "units": "metres",
        "upAxis": "+Y",
        "geometry": "geometry.bin",
        "colours": col_json,
        "parts": parts_json,
        "instances": inst_json,
        "assemblies": asm_json,
        "steps": sb.steps,
    }
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "build.json"), "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    with open(os.path.join(args.out, "geometry.bin"), "wb") as fh:
        fh.write(bytes(blob))

    log(f"{title}: {len(sb.instances)} pieces, {len(part_keys)} unique parts, "
        f"{len(sb.steps)} steps, {len(sb.assemblies) - 1} sub-assemblies, "
        f"{total_tris:,} triangles (unique meshes), geometry {len(blob) / 1e6:.1f} MB")
    if lib.missing:
        log(f"missing files ({len(lib.missing)}): {', '.join(sorted(lib.missing)[:20])}")


if __name__ == "__main__":
    main()
