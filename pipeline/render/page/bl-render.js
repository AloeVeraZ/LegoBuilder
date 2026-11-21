// Renders a BuildLens build package (build.json + geometry.bin) with three.js.
// Used headless by render.mjs to make part thumbnails, step previews and
// glasses-HUD frames, and handy in a browser for checking a converted model.
import * as THREE from '../node_modules/three/build/three.module.js';

const BL = {};
window.BL = BL;

let pkg, geo, renderer, scene, camera, root;
const meshesByPart = [];   // part index -> [{geometry, colour}]
const materials = new Map();
const edgeCache = new Map();

function srgb(c) { return new THREE.Color().setRGB(c[0], c[1], c[2], THREE.SRGBColorSpace); }

function colourInfo(code) {
  return pkg.colours.find(c => c.code === code) || { code, rgba: [0.6, 0.6, 0.6, 1], finish: 'plastic', name: `Colour ${code}` };
}

function material(code, mode = 'normal') {
  const key = `${code}:${mode}`;
  if (materials.has(key)) return materials.get(key);
  const c = colourInfo(code);
  const m = new THREE.MeshPhysicalMaterial({
    color: srgb(c.rgba),
    roughness: c.finish === 'rubber' ? 0.85 : 0.32,
    metalness: (c.finish === 'chrome' || c.finish === 'metal') ? 0.9 : 0.0,
    clearcoat: c.finish === 'rubber' ? 0 : 0.4,
    clearcoatRoughness: 0.25,
    transparent: c.rgba[3] < 0.99,
    opacity: c.rgba[3],
  });
  if (mode === 'new') { m.emissive = srgb(c.rgba).multiplyScalar(0.35); }
  if (mode === 'dim') { m.color.lerp(new THREE.Color(1, 1, 1), 0.65); m.transparent = true; m.opacity = 0.45; }
  if (mode === 'hud-old') { m.color.set(0x03140a); m.clearcoat = 0; }
  if (mode === 'hud-new') { m.color.set(0x1c7a35); m.emissive = new THREE.Color(0x0c4d1f); m.clearcoat = 0; }
  materials.set(key, m);
  return m;
}

function buildGeometry() {
  pkg.parts.forEach((p, i) => {
    meshesByPart[i] = p.groups.map(g => {
      const bg = new THREE.BufferGeometry();
      bg.setAttribute('position', new THREE.BufferAttribute(new Float32Array(geo, g.positions, g.vertexCount * 3), 3));
      bg.setAttribute('normal', new THREE.BufferAttribute(new Float32Array(geo, g.normals, g.vertexCount * 3), 3));
      bg.setIndex(new THREE.BufferAttribute(new Uint32Array(geo, g.indices, g.indexCount), 1));
      bg.computeBoundingSphere();
      return { geometry: bg, colour: g.colour };
    });
  });
}

function edgesFor(partIndex, gi) {
  const key = `${partIndex}:${gi}`;
  if (!edgeCache.has(key)) edgeCache.set(key, new THREE.EdgesGeometry(meshesByPart[partIndex][gi].geometry, 28));
  return edgeCache.get(key);
}

BL.load = async function (base) {
  pkg = await (await fetch(`${base}/build.json`)).json();
  geo = await (await fetch(`${base}/${pkg.geometry}`)).arrayBuffer();
  buildGeometry();
  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  document.body.appendChild(renderer.domElement);
  camera = new THREE.PerspectiveCamera(30, 1, 0.001, 100);
  return { name: pkg.set.name, steps: pkg.steps.length, parts: pkg.parts.length, pieces: pkg.instances.length };
};

function makeScene(hud) {
  scene = new THREE.Scene();
  if (hud) {
    scene.add(new THREE.AmbientLight(0xffffff, 1.4));
    const d = new THREE.DirectionalLight(0xffffff, 1.0); d.position.set(1, 2, 1.5); scene.add(d);
  } else {
    scene.add(new THREE.HemisphereLight(0xffffff, 0x8a8f99, 1.6));
    const key = new THREE.DirectionalLight(0xffffff, 2.2); key.position.set(-1.2, 2.5, 1.8); scene.add(key);
    const rim = new THREE.DirectionalLight(0xffffff, 0.8); rim.position.set(1.5, 1, -2); scene.add(rim);
  }
  root = new THREE.Group();
  scene.add(root);
}

const mat4 = a => new THREE.Matrix4().fromArray(a);

function cumulative(stepIndex) {
  const s = pkg.steps[stepIndex];
  const visible = new Set();
  for (let i = 0; i <= stepIndex; i++) {
    if (pkg.steps[i].assembly === s.assembly) pkg.steps[i].added.forEach(id => visible.add(id));
  }
  return { asm: pkg.assemblies[s.assembly], added: new Set(s.added), visible };
}

function addInstance(id, mode, local, edges, edgeColour) {
  const inst = pkg.instances[id];
  const m = local.clone().multiply(mat4(inst.matrix));
  meshesByPart[inst.part].forEach((g, gi) => {
    const code = g.colour === 16 ? inst.colour : g.colour;
    const mesh = new THREE.Mesh(g.geometry, material(code, mode));
    mesh.matrixAutoUpdate = false; mesh.matrix.copy(m);
    root.add(mesh);
    if (edges) {
      const lines = new THREE.LineSegments(edgesFor(inst.part, gi), new THREE.LineBasicMaterial({ color: edgeColour }));
      lines.matrixAutoUpdate = false; lines.matrix.copy(m);
      root.add(lines);
    }
  });
}

function frame(bounds, w, h, dir = [1.0, 0.85, 1.45], margin = 1.12) {
  const lo = new THREE.Vector3(...bounds[0]), hi = new THREE.Vector3(...bounds[1]);
  const c = lo.clone().add(hi).multiplyScalar(0.5);
  const r = Math.max(hi.clone().sub(lo).length() / 2, 0.004);
  camera.aspect = w / h;
  const fov = THREE.MathUtils.degToRad(camera.fov);
  const fit = Math.min(fov, 2 * Math.atan(Math.tan(fov / 2) * camera.aspect));
  const dist = (r * margin) / Math.sin(fit / 2);
  camera.position.copy(c).add(new THREE.Vector3(...dir).normalize().multiplyScalar(dist));
  camera.near = dist / 50; camera.far = dist * 10;
  camera.lookAt(c);
  camera.updateProjectionMatrix();
}

function snap(w, h, bg) {
  renderer.setSize(w, h, false);
  renderer.setClearColor(bg ?? 0x000000, bg === undefined ? 0 : 1);
  renderer.render(scene, camera);
  return renderer.domElement.toDataURL('image/png');
}

// How far off its place a new piece waits (same rule as the app).
function waitingGap() {
  const [lo, hi] = pkg.assemblies[0].bounds;
  return Math.max(Math.hypot(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]) / 2 * 0.28, 0.012);
}

// Bounds of some pieces in the shown assembly's axes.
function boundsOf(ids, local) {
  const box = new THREE.Box3();
  for (const id of ids) {
    const inst = pkg.instances[id];
    const [lo, hi] = pkg.parts[inst.part].bounds;
    box.union(new THREE.Box3(new THREE.Vector3(...lo), new THREE.Vector3(...hi)).applyMatrix4(local.clone().multiply(mat4(inst.matrix))));
  }
  return box;
}

// Arrow whose tip sits just outside the waiting pieces, pointing the way they are pushed.
function addArrow(box, push, size, pressed, colour) {
  const half = box.getSize(new THREE.Vector3()).multiplyScalar(0.5);
  const reach = Math.abs(push.x) * half.x + Math.abs(push.y) * half.y + Math.abs(push.z) * half.z;
  const tip = box.getCenter(new THREE.Vector3()).addScaledVector(push, -(reach + size * (pressed ? 0.25 : 0.7)));
  const mat = new THREE.MeshBasicMaterial({ color: colour });
  const arrow = new THREE.Group();
  const head = new THREE.Mesh(new THREE.ConeGeometry(0.3 * size, 0.6 * size, 24), mat);
  head.rotation.x = Math.PI; head.position.y = 0.3 * size;
  const shaft = new THREE.Mesh(new THREE.CylinderGeometry(0.1 * size, 0.1 * size, 0.8 * size, 16), mat);
  shaft.position.y = size;
  arrow.add(head, shaft);
  arrow.quaternion.setFromUnitVectors(new THREE.Vector3(0, -1, 0), push);
  arrow.position.copy(tip);
  root.add(arrow);
  return tip;
}

// Bounds to frame for each step: steps are grouped into runs that end when the build is
// nearly twice the size it was at the run's start; a run is framed on how it looks at its end.
let stageCache = null;
function stageBounds(stepIndex) {
  if (!stageCache) {
    stageCache = [];
    const whole = (() => { const [lo, hi] = pkg.assemblies[0].bounds; return Math.hypot(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]) / 2; })();
    const byAssembly = new Map();
    pkg.steps.forEach((st, k) => { if (!byAssembly.has(st.assembly)) byAssembly.set(st.assembly, []); byAssembly.get(st.assembly).push(k); });
    for (const [asmId, ks] of byAssembly) {
      const local = mat4(pkg.assemblies[asmId].matrix).invert();
      const seen = [];
      const boxes = ks.map(k => { seen.push(...pkg.steps[k].added); return boundsOf(seen, local); });
      const radius = n => boxes[n].getSize(new THREE.Vector3()).length() / 2;
      for (let start = 0; start < ks.length;) {
        const limit = Math.max(radius(start), whole * 0.3) * 1.8;
        let end = start;
        while (end + 1 < ks.length && radius(end + 1) <= limit) end++;
        const b = [boxes[end].min.toArray(), boxes[end].max.toArray()];
        for (let n = start; n <= end; n++) stageCache[ks[n]] = b;
        start = end + 1;
      }
    }
  }
  return stageCache[stepIndex];
}

// One build step. mode: 'preview' (colour, new parts glow) or 'hud' (green-on-black for the glasses).
// lift: 1 = the new pieces wait off their place with an arrow (how a step is shown),
// 0 = seated, anything between = part-way in. pressed: the arrow at the low point of its bounce.
BL.step = function (stepIndex, { w = 900, h = 700, mode = 'preview', lift = 0, pressed = false } = {}) {
  const hud = mode === 'hud';
  makeScene(hud);
  const { asm, added, visible } = cumulative(stepIndex);
  const local = mat4(asm.matrix).invert();
  const gap = waitingGap();
  const offset = new Map();           // piece id -> how far it is from its seat
  const moves = (pkg.steps[stepIndex].moves || []).map(m => ({ pieces: m.pieces, push: new THREE.Vector3(...m.push).normalize() }));
  if (lift > 0) for (const m of moves) for (const id of m.pieces) offset.set(id, m.push.clone().multiplyScalar(-gap * lift));
  for (const id of visible) {
    const isNew = added.has(id);
    const at = offset.has(id) ? new THREE.Matrix4().makeTranslation(offset.get(id)).multiply(local) : local;
    if (hud) addInstance(id, isNew ? 'hud-new' : 'hud-old', at, true, isNew ? 0xb6ffc8 : 0x1f9c3c);
    else addInstance(id, isNew ? 'new' : 'normal', at, false);
  }
  // The camera stays put for a run of steps and only pulls back when the build has
  // outgrown the view (same rule as the app); the frame leaves room for waiting pieces.
  const view = hud ? stageBounds(stepIndex) : asm.bounds;
  const lo = view[0].map(v => v - gap), hi = view[1].map(v => v + gap);
  if (lift >= 1) {
    const size = Math.hypot(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]) / 2 * 0.13;
    const tips = [];
    for (const m of moves) {
      const box = boundsOf(m.pieces, local).translate(m.push.clone().multiplyScalar(-gap));
      const centre = box.getCenter(new THREE.Vector3());
      if (tips.some(t => t.distanceTo(centre) < size * 1.5)) continue;     // rim and tyre share one arrow
      tips.push(centre);
      addArrow(box, m.push, size, pressed, hud ? 0xd9ffe2 : 0xdb1f26);
    }
  }
  frame([lo, hi], w, h, undefined, hud ? 0.98 : 1.12);
  return snap(w, h, hud ? 0x000000 : 0xf3f4f6);
};

// Thumbnail of one part in one colour, transparent background, instruction-style outline.
BL.part = function (partIndex, colour, { size = 192 } = {}) {
  makeScene(false);
  const p = pkg.parts[partIndex];
  meshesByPart[partIndex].forEach((g, gi) => {
    const code = g.colour === 16 ? colour : g.colour;
    root.add(new THREE.Mesh(g.geometry, material(code)));
    const dark = colourInfo(code).rgba.slice(0, 3).reduce((a, b) => a + b, 0) < 0.35;
    root.add(new THREE.LineSegments(edgesFor(partIndex, gi), new THREE.LineBasicMaterial({ color: dark ? 0x5a5a5a : 0x1b1b1b, transparent: true, opacity: 0.55 })));
  });
  frame(p.bounds, size, size, [1.0, 0.95, 1.3], 1.02);
  return snap(size, size);
};

// The finished model (all pieces, final positions), transparent background.
BL.finished = function ({ w = 1200, h = 900 } = {}) {
  makeScene(false);
  pkg.instances.forEach((_, id) => addInstance(id, 'normal', new THREE.Matrix4(), false));
  frame(pkg.assemblies[0].bounds, w, h, [1.0, 0.7, 1.5], 0.98);
  return snap(w, h);
};

// Every (part, colour) pair the model uses.
BL.partColours = function () {
  const seen = new Map();
  pkg.instances.forEach(i => seen.set(`${i.part}-${i.colour}`, [i.part, i.colour]));
  return [...seen.values()];
};
