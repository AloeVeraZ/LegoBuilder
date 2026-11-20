// BuildLens for Windows / any desktop browser.
// Reads the same build package as the iPhone/Mac app (embedded by build.mjs as window.BUILD_DATA).
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const D = window.BUILD_DATA;
const pkg = D.build;
const geo = Uint8Array.from(atob(D.geometry), c => c.charCodeAt(0)).buffer;
const $ = id => document.getElementById(id);

// ---------------------------------------------------------------- data
const colours = new Map(pkg.colours.map(c => [c.code, c]));
const colour = code => colours.get(code) || { code, name: `Colour ${code}`, rgba: [0.6, 0.6, 0.6, 1], finish: 'plastic' };
const cleanName = s => s.replace(/^[~_=|]+/, '').replace(/\s+/g, ' ').trim();
const mat4 = a => new THREE.Matrix4().fromArray(a);
const instMatrix = pkg.instances.map(i => mat4(i.matrix));
const asmMatrix = pkg.assemblies.map(a => mat4(a.matrix));

const steps = [];
{
  const visibleBy = new Map();
  pkg.steps.forEach((s, index) => {
    const v = (visibleBy.get(s.assembly) || []).concat(s.added);
    visibleBy.set(s.assembly, v);
    const counts = new Map();
    for (const id of s.added) {
      const inst = pkg.instances[id];
      const key = `${inst.part}-${inst.colour}`;
      const e = counts.get(key) || { part: inst.part, colour: inst.colour, count: 0 };
      e.count++; counts.set(key, e);
    }
    const parts = [...counts.values()].map(e => ({ ...e, name: cleanName(pkg.parts[e.part].name), colourName: colour(e.colour).name }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
    steps.push({ index, assembly: pkg.assemblies[s.assembly], added: s.added, visible: v, parts });
  });
}

function spoken(i) {
  const s = steps[i];
  let t = `Step ${i + 1} of ${steps.length}. `;
  if (s.assembly.id !== 0) t += `Build the ${s.assembly.name}${s.assembly.uses > 1 ? `, you need ${s.assembly.uses} of these` : ''}. `;
  const lines = s.parts.slice(0, 4).map(p => `${p.count} ${p.colourName.toLowerCase()} ${p.name.toLowerCase().replace(/ x /g, ' by ')}`);
  if (lines.length) t += 'Add ' + lines.join(', ') + '.';
  if (s.parts.length > 4) t += ` And ${s.parts.length - 4} more.`;
  return t;
}

// ---------------------------------------------------------------- 3D scene
const canvasHost = $('stage');
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
canvasHost.appendChild(renderer.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0xeceef2);
const camera = new THREE.PerspectiveCamera(36, 1, 0.001, 50);
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.maxPolarAngle = Math.PI * 0.53;

scene.add(new THREE.HemisphereLight(0xffffff, 0x9aa0aa, 1.5));
const sun = new THREE.DirectionalLight(0xffffff, 2.4);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
sun.shadow.bias = -0.0005;
scene.add(sun);
const rim = new THREE.DirectionalLight(0xffffff, 0.7);
rim.position.set(1.5, 1, -2);
scene.add(rim);
const ground = new THREE.Mesh(new THREE.PlaneGeometry(10, 10), new THREE.ShadowMaterial({ opacity: 0.18 }));
ground.rotation.x = -Math.PI / 2;
ground.receiveShadow = true;
scene.add(ground);

const root = new THREE.Group();
const content = new THREE.Group();
root.add(content);
scene.add(root);

const materials = new Map();
function material(code, look) {
  const key = `${code}:${look}`;
  if (materials.has(key)) return materials.get(key);
  const c = colour(code);
  const col = new THREE.Color().setRGB(c.rgba[0], c.rgba[1], c.rgba[2], THREE.SRGBColorSpace);
  const m = new THREE.MeshPhysicalMaterial({
    color: col,
    roughness: c.finish === 'rubber' ? 0.85 : 0.32,
    metalness: c.finish === 'chrome' || c.finish === 'metal' ? 0.9 : 0,
    clearcoat: c.finish === 'rubber' ? 0 : 0.45,
    clearcoatRoughness: 0.2,
    transparent: c.rgba[3] < 0.99,
    opacity: c.rgba[3],
  });
  if (look === 'new') m.emissive = col.clone().multiplyScalar(0.35);
  if (look === 'dim') { m.color.lerp(new THREE.Color(1, 1, 1), 0.55); m.transparent = true; m.opacity = Math.min(m.opacity, 0.35); m.depthWrite = false; }
  materials.set(key, m);
  return m;
}

const partGeometry = pkg.parts.map(p => p.groups.map(g => {
  const bg = new THREE.BufferGeometry();
  bg.setAttribute('position', new THREE.BufferAttribute(new Float32Array(geo, g.positions, g.vertexCount * 3), 3));
  bg.setAttribute('normal', new THREE.BufferAttribute(new Float32Array(geo, g.normals, g.vertexCount * 3), 3));
  bg.setIndex(new THREE.BufferAttribute(new Uint32Array(geo, g.indices, g.indexCount), 1));
  bg.computeBoundingSphere();
  return { geometry: bg, colour: g.colour };
}));

const pieces = pkg.instances.map((inst, i) => {
  const group = new THREE.Group();
  group.matrixAutoUpdate = false;
  group.userData.meshes = partGeometry[inst.part].map(g => {
    const mesh = new THREE.Mesh(g.geometry, material(g.colour === 16 ? inst.colour : g.colour, 'normal'));
    mesh.castShadow = true;
    mesh.userData.code = g.colour === 16 ? inst.colour : g.colour;
    group.add(mesh);
    return mesh;
  });
  group.visible = false;
  content.add(group);
  return group;
});

function setLook(i, look) {
  for (const m of pieces[i].userData.meshes) m.material = material(m.userData.code, look);
}

// Arrows pointing down at the new pieces (one per piece, up to 8).
const arrowMat = new THREE.MeshBasicMaterial({ color: 0xffc700 });
const arrowCone = new THREE.ConeGeometry(0.32, 0.6, 24);
const arrowShaft = new THREE.CylinderGeometry(0.11, 0.11, 0.7, 16);
const arrows = Array.from({ length: 8 }, () => {
  const a = new THREE.Group();
  const cone = new THREE.Mesh(arrowCone, arrowMat);
  cone.rotation.x = Math.PI; cone.position.y = 0.3;
  const shaft = new THREE.Mesh(arrowShaft, arrowMat);
  shaft.position.y = 0.95;
  a.add(cone, shaft);
  a.visible = false;
  content.add(a);
  return a;
});

// ---------------------------------------------------------------- framing & animation
let framingRadius = 0.1;
const bounds = b => [new THREE.Vector3(...b[0]), new THREE.Vector3(...b[1])];

function frameAssembly(asm, moveCamera) {
  const [lo, hi] = bounds(asm.bounds);
  const c = lo.clone().add(hi).multiplyScalar(0.5);
  content.position.set(-c.x, -lo.y, -c.z);
  framingRadius = Math.max(hi.clone().sub(lo).length() / 2, 0.01);
  const target = new THREE.Vector3(0, (hi.y - lo.y) / 2, 0);
  sun.position.set(-0.6, 1.2, 0.8).multiplyScalar(framingRadius * 4);
  sun.shadow.camera.left = sun.shadow.camera.bottom = -framingRadius * 2;
  sun.shadow.camera.right = sun.shadow.camera.top = framingRadius * 2;
  sun.shadow.camera.near = 0.001; sun.shadow.camera.far = framingRadius * 12;
  sun.shadow.camera.updateProjectionMatrix();
  if (!moveCamera) return;
  const fov = THREE.MathUtils.degToRad(camera.fov);
  const fit = Math.min(fov, 2 * Math.atan(Math.tan(fov / 2) * camera.aspect));
  const dist = framingRadius * 1.25 / Math.sin(fit / 2);
  const dir = camera.position.clone().sub(controls.target);
  if (dir.lengthSq() < 1e-9) dir.set(0.55, 0.45, 0.75);
  dir.normalize();
  controls.target.copy(target);
  camera.position.copy(target).addScaledVector(dir, dist);
  camera.near = dist / 100; camera.far = dist * 40;
  camera.updateProjectionMatrix();
  controls.minDistance = framingRadius * 0.5;
  controls.maxDistance = framingRadius * 12;
}

function pieceBox(i, local) {
  const p = pkg.parts[pkg.instances[i].part];
  const box = new THREE.Box3(...bounds(p.bounds));
  return box.applyMatrix4(local.clone().multiply(instMatrix[i]));
}

let tweens = [];
const ease = t => 1 - Math.pow(1 - t, 3);

let current = -1, finished = false, lastAssembly = -1, dimPrevious = false;

function showStep(i, animate = true) {
  current = i; finished = false; spin = null;
  const s = steps[i];
  const local = asmMatrix[s.assembly.id].clone().invert();
  const added = new Set(s.added), visible = new Set(s.visible);
  tweens = [];
  pieces.forEach((p, id) => { p.visible = visible.has(id); });
  const before = s.visible.filter(id => !added.has(id));
  const centreBefore = new THREE.Vector3();
  before.forEach(id => centreBefore.add(pieceBox(id, local).getCenter(new THREE.Vector3())));
  if (before.length) centreBefore.divideScalar(before.length);
  const now = performance.now();
  for (const id of s.visible) {
    const m = local.clone().multiply(instMatrix[id]);
    pieces[id].matrix.copy(m);
    setLook(id, added.has(id) ? 'new' : (dimPrevious ? 'dim' : 'normal'));
  }
  if (animate) {
    s.added.forEach((id, n) => {
      let dir = new THREE.Vector3(0, 1, 0);
      if (before.length) {
        const d = pieceBox(id, local).getCenter(new THREE.Vector3()).sub(centreBefore);
        if (d.length() > 1e-5) {
          d.normalize();
          dir = d.y < -0.6 ? new THREE.Vector3(0, -1, 0) : new THREE.Vector3(d.x, Math.max(d.y, 0) + 0.6, d.z).normalize();
        }
      }
      const end = pieces[id].matrix.clone();
      const offset = dir.multiplyScalar(Math.max(framingRadius * 0.7, 0.03));
      tweens.push({ id, end, offset, start: now + 120 + Math.min(n, 12) * 70, dur: 550 });
      pieces[id].matrix.copy(end.clone().premultiply(new THREE.Matrix4().makeTranslation(offset.x, offset.y, offset.z)));
    });
  }
  // arrows: one above each new piece (pieces at the same spot share one)
  const size = Math.max(framingRadius * 0.09, 0.004);
  const spots = [];
  for (const id of s.added) {
    const b = pieceBox(id, local);
    const p = new THREE.Vector3((b.min.x + b.max.x) / 2, b.max.y + size * 0.4, (b.min.z + b.max.z) / 2);
    if (!spots.some(q => q.distanceTo(p) < size * 1.5)) spots.push(p);
  }
  arrows.forEach((a, k) => {
    a.visible = k < spots.length;
    if (a.visible) { a.userData.base = spots[k]; a.userData.size = size; a.scale.setScalar(size); }
  });
  frameAssembly(s.assembly, s.assembly.id !== lastAssembly);
  lastAssembly = s.assembly.id;
  updateUI();
  resize();
  if (readAloud) say(spoken(i));
}

function showFinished() {
  finished = true; tweens = [];
  pieces.forEach((p, id) => { p.visible = true; p.matrix.copy(instMatrix[id]); setLook(id, 'normal'); });
  arrows.forEach(a => { a.visible = false; });
  frameAssembly(pkg.assemblies[0], lastAssembly !== 0);
  lastAssembly = 0;
  spin = { start: performance.now(), dur: 1200 };
  updateUI();
}
let spin = null;

function resize() {
  const w = canvasHost.clientWidth, h = canvasHost.clientHeight;
  renderer.setSize(w, h, false);
  camera.aspect = w / Math.max(h, 1);
  // The bottom panel covers part of the screen: centre the model in the space above it.
  const covered = $('bottom').offsetHeight - $('top').offsetHeight;
  camera.setViewOffset(w, h, 0, Math.max(covered, 0) * 0.5, w, h);
  camera.updateProjectionMatrix();
}
window.addEventListener('resize', resize);

function loop(t) {
  requestAnimationFrame(loop);
  for (const tw of tweens) {
    const k = Math.min(Math.max((t - tw.start) / tw.dur, 0), 1);
    const e = 1 - ease(k);
    pieces[tw.id].matrix.copy(tw.end.clone().premultiply(new THREE.Matrix4().makeTranslation(tw.offset.x * e, tw.offset.y * e, tw.offset.z * e)));
  }
  for (const a of arrows) if (a.visible) {
    const b = a.userData.base;
    a.position.set(b.x, b.y + a.userData.size * 0.3 * (1 + Math.sin(t / 180)), b.z);
  }
  root.rotation.y = spin ? -Math.PI * 0.6 * (1 - ease(Math.min((t - spin.start) / spin.dur, 1))) : 0;
  controls.update();
  renderer.render(scene, camera);
}

// ---------------------------------------------------------------- UI
function updateUI() {
  const s = steps[current];
  $('stepLabel').textContent = finished ? 'Finished' : `Step ${current + 1} of ${steps.length}`;
  $('progress').style.width = `${finished ? 100 : ((current + 1) / steps.length) * 100}%`;
  $('slider').value = current;
  $('next').textContent = current + 1 === steps.length ? 'Finish ›' : 'Next ›';
  $('back').disabled = current === 0 && !finished;
  $('finishedCard').hidden = !finished;
  $('panel').hidden = finished;
  const sub = $('subassembly');
  sub.hidden = !s || s.assembly.id === 0 || finished;
  if (s && s.assembly.id !== 0) sub.textContent = `Sub-assembly: ${s.assembly.name}${s.assembly.uses > 1 ? ` · build ×${s.assembly.uses}` : ''}`;
  const strip = $('parts');
  strip.innerHTML = '';
  if (s && !finished) for (const p of s.parts) {
    const cell = document.createElement('div');
    cell.className = 'part';
    cell.title = `${p.count}× ${p.name} · ${p.colourName}`;
    const src = D.thumbs[`${p.part}-${p.colour}`];
    cell.innerHTML = `${src ? `<img src="${src}" alt="">` : '<div class="noimg">▣</div>'}<span class="count">${p.count}×</span><span class="pname">${p.name}<br><em>${p.colourName}</em></span>`;
    strip.appendChild(cell);
  }
  // glasses preview
  const hud = D.hud[current];
  $('hudImg').src = hud && !finished ? hud : '';
  $('hudImg').style.visibility = hud && !finished ? 'visible' : 'hidden';
  $('hudText').innerHTML = finished ? '<b>DONE ✓</b>' : `<b>STEP ${current + 1}/${steps.length}</b>` +
    (s.assembly.id !== 0 ? `<div>SUB: ${s.assembly.name.toUpperCase()}${s.assembly.uses > 1 ? ' ×' + s.assembly.uses : ''}</div>` : '') +
    `<div class="hudparts">${s.parts.slice(0, 4).map(p => `+${p.count} ${p.colourName.toUpperCase()} ${p.name.toUpperCase()}`).join('<br>')}${s.parts.length > 4 ? `<br>+${s.parts.length - 4} MORE` : ''}</div>`;
}

const next = () => { if (finished) return; if (current + 1 < steps.length) showStep(current + 1); else { showFinished(); if (readAloud) say(`You built the ${pkg.set.name}!`); } };
const back = () => { if (finished) showStep(current); else if (current > 0) showStep(current - 1); };
const replay = () => showStep(current);

$('next').onclick = next;
$('back').onclick = back;
$('replay').onclick = replay;
$('again').onclick = () => showStep(0);
$('lastStep').onclick = back;
$('slider').max = steps.length - 1;
$('slider').oninput = e => showStep(Number(e.target.value));
$('zoomIn').onclick = () => zoom(0.8);
$('zoomOut').onclick = () => zoom(1.25);
$('focus').onchange = e => { dimPrevious = e.target.checked; if (!finished) showStep(current, false); };
$('glassesToggle').onclick = () => { $('glasses').hidden = !$('glasses').hidden; };
$('home').onclick = () => { $('homeScreen').hidden = false; };

function zoom(f) {
  const dir = camera.position.clone().sub(controls.target).multiplyScalar(f);
  const len = THREE.MathUtils.clamp(dir.length(), controls.minDistance, controls.maxDistance);
  camera.position.copy(controls.target).addScaledVector(dir.normalize(), len);
}

window.addEventListener('keydown', e => {
  if (!$('homeScreen').hidden) { if (e.key === 'Enter' || e.key === ' ') start(); return; }
  if (e.key === 'ArrowRight' || e.key === ' ') { next(); e.preventDefault(); }
  else if (e.key === 'ArrowLeft') back();
  else if (e.key.toLowerCase() === 'r') replay();
  else if (e.key.toLowerCase() === 'g') $('glassesToggle').click();
  else if (e.key === '+' || e.key === '=') zoom(0.8);
  else if (e.key === '-') zoom(1.25);
});

// read aloud
let readAloud = false;
function say(text) {
  if (!('speechSynthesis' in window)) return;
  speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.lang = 'en-US';
  speechSynthesis.speak(u);
}
$('readAloud').onchange = e => { readAloud = e.target.checked; if (readAloud && !finished) say(spoken(current)); else speechSynthesis.cancel(); };

// voice commands (Chrome / Edge)
const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
let recognizer = null, listening = false;
const fired = new Set();
const commandFor = w => ({ next: next, forward: next, continue: next, back: back, previous: back, repeat: replay, again: replay, replay: replay, done: () => { if (!finished) showFinished(); }, finish: () => { if (!finished) showFinished(); } })[w];
$('voice').onclick = () => {
  if (!SR) { $('voiceStatus').textContent = 'Voice needs Chrome or Edge'; return; }
  if (listening) { listening = false; recognizer.stop(); $('voice').classList.remove('on'); $('voiceStatus').textContent = ''; return; }
  recognizer = new SR();
  recognizer.continuous = true;
  recognizer.interimResults = true;
  recognizer.lang = 'en-US';
  recognizer.onresult = e => {
    for (let r = e.resultIndex; r < e.results.length; r++) {
      const words = e.results[r][0].transcript.toLowerCase().split(/\s+/).filter(Boolean);
      words.slice(-2).forEach((raw, k) => {
        const w = raw.replace(/[^a-z]/g, '');
        const key = `${r}-${words.length - 2 + k}-${w}`;
        const cmd = commandFor(w);
        if (cmd && !fired.has(key)) { fired.add(key); $('voiceStatus').textContent = `“${w}”`; cmd(); }
      });
    }
  };
  recognizer.onend = () => { if (listening) { fired.clear(); recognizer.start(); } };
  recognizer.onerror = e => { $('voiceStatus').textContent = e.error === 'not-allowed' ? 'Microphone blocked' : `Voice: ${e.error}`; };
  listening = true;
  recognizer.start();
  $('voice').classList.add('on');
  $('voiceStatus').textContent = 'Say “next”, “back” or “repeat”';
};

// home screen
$('setName').textContent = pkg.set.name;
$('setStats').textContent = `${pkg.set.pieces} pieces · ${steps.length} steps · about ${Math.max(1, Math.round(steps.length * 0.6))} min`;
$('setId').textContent = pkg.set.id ? `Set ${pkg.set.id}` : '';
if (D.hero) $('hero').src = D.hero; else $('hero').hidden = true;
document.title = `BuildLens · ${pkg.set.name}`;
function start() {
  $('homeScreen').hidden = true;
  resize();
  if (current < 0) showStep(0); else if (!finished) showStep(current, false);
}
$('start').onclick = start;

resize();
requestAnimationFrame(loop);
window.BL = { showStep, next, back, steps };
