// Made-up glasses camera pictures for testing the set-down check (glasses/tools/test_check.sh).
// Usage: node scenes.mjs <buildDir> <outDir> [--count 92] [--seed 1] [--fov 62] [--spread 180]
// Writes <outDir>/scene-NNN.png and <outDir>/scenes.json with what is really in each picture:
// the step, whether its new pieces are on, how the build was put down, and the camera's pose.
// Every step appears with its new pieces on and off, in turn, at random turns, tables and light.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const buildDir = path.resolve(args[0]);
const outDir = path.resolve(args[1]);
const opt = (name, fallback) => args.includes(name) ? Number(args[args.indexOf(name) + 1]) : fallback;
const COUNT = opt('--count', 92), FOV = opt('--fov', 62);
// --spread: how far (degrees) from the ghost's turn the build is put down; 180 = any way at all.
const SPREAD = opt('--spread', 180);
let seed = opt('--seed', 1);
const rand = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
const between = (a, b) => a + (b - a) * rand();

// The marker exactly as the glasses look for it (QrFinder.PICTURE).
const finder = fs.readFileSync(path.join(here, '../../glasses/src/com/buildlens/glasses/QrFinder.java'), 'utf8');
const marker = [...finder.split('PICTURE = {')[1].split('};')[0].matchAll(/"([.#]+)"/g)].map(m => m[1]);

const types = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.bin': 'application/octet-stream' };
const server = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  const file = url.startsWith('/data/') ? path.join(buildDir, url.slice(6)) : path.join(here, url);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}).listen(0);
const browser = await chromium.launch({ executablePath: process.env.BL_CHROMIUM || undefined,
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const page = await browser.newPage();
page.on('pageerror', e => console.error('page error:', e.message));
await page.goto(`http://localhost:${server.address().port}/page/index.html`);
await page.waitForFunction(() => window.BL);
const info = await page.evaluate(() => BL.load('/data'));

// Camera from marker, column-major: the eye at `eye` looking at `target`, turned `roll` about its view.
function lookAt(eye, target, roll) {
  const sub = (a, b) => a.map((v, i) => v - b[i]);
  const norm = a => { const l = Math.hypot(...a); return a.map(v => v / l); };
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const f = norm(sub(target, eye));
  let r = norm(cross(f, [0, 0, 1]));
  let d = cross(f, r);
  const c = Math.cos(roll), s = Math.sin(roll);
  [r, d] = [r.map((v, i) => c * v + s * d[i]), d.map((v, i) => -s * r[i] + c * v)];
  const R = [r, d, f];
  const t = R.map(row => -(row[0] * eye[0] + row[1] * eye[1] + row[2] * eye[2]));
  return [R[0][0], R[1][0], R[2][0], 0, R[0][1], R[1][1], R[2][1], 0, R[0][2], R[1][2], R[2][2], 0, t[0], t[1], t[2], 1];
}

const TABLES = [0xb48a5e, 0x7a5638, 0xe6e2da, 0x8c9096, 0x3a3d42, 0x2f6b4f, 0xc9b79c];
const w = 1280, h = 960, fx = w / (2 * Math.tan(FOV * Math.PI / 360));
fs.mkdirSync(outDir, { recursive: true });
const scenes = [];
for (let n = 0; n < COUNT; n++) {
  const step = Math.floor(n / 2) % info.steps;
  const fresh = n % 2 === 0;
  // Seated in front of the table, looking down at the phone and the build.
  const dist = between(0.38, 0.55), elev = between(35, 70) * Math.PI / 180, az = between(-35, 35) * Math.PI / 180;
  const target = [between(0.05, 0.10), between(-0.02, 0.02), -0.008];
  const eye = [target[0] + dist * Math.cos(elev) * Math.sin(az), target[1] - dist * Math.cos(elev) * Math.cos(az), target[2] + dist * Math.sin(elev)];
  const pose = lookAt(eye, target, between(-6, 6) * Math.PI / 180);
  const turn = SPREAD >= 180 ? between(0, 2 * Math.PI) : between(-SPREAD, SPREAD) * Math.PI / 180, shift = [between(-0.012, 0.012), between(-0.012, 0.012)];
  const loose = !fresh && rand() < 0.5 ? [between(0.15, 0.18), between(-0.05, 0.05), between(0, 6.28)] : null;
  const opts = {
    cam: { w, h, fx, fy: fx, cx: (w - 1) / 2, cy: (h - 1) / 2, pose }, step, fresh, turn, shift, marker, loose,
    table: TABLES[Math.floor(rand() * TABLES.length)], sun: [between(-1, 1), between(-1, 1), between(0.6, 1.4)],
    sunPower: between(1.4, 3), sky: between(0.8, 1.8),
  };
  const file = `scene-${String(n).padStart(3, '0')}.png`;
  const url = await page.evaluate(o => BL.scene(o), opts);
  fs.writeFileSync(path.join(outDir, file), Buffer.from(url.split(',')[1], 'base64'));
  scenes.push({ file, step: step + 1, fresh, turn, shift, loose, table: opts.table, lens: opts.cam, pose });
}
fs.writeFileSync(path.join(outDir, 'scenes.json'), JSON.stringify(scenes, null, 1));
// The same as plain lines for Java (glasses/tools/CheckTest.java): file step fresh(0/1) loose(0/1)
// turn shiftX shiftZ w h fx fy cx cy pose(16, column-major)
fs.writeFileSync(path.join(outDir, 'scenes.txt'), scenes.map(s => [s.file, s.step, +s.fresh, +!!s.loose, s.turn, ...s.shift,
  s.lens.w, s.lens.h, s.lens.fx, s.lens.fy, s.lens.cx, s.lens.cy, ...s.pose].join(' ')).join('\n') + '\n');
console.log(`scenes: ${scenes.length} in ${outDir}`);
await browser.close();
server.close();
