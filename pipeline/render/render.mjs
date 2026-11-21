// Usage: node render.mjs <buildDir> [--thumbs] [--previews] [--hud] [--hero] [--steps 0,5,10]
// Writes into <buildDir>/thumbs, <buildDir>/previews, <buildDir>/hud.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const buildDir = path.resolve(args[0] || '.');
const want = f => args.includes(f);
const stepsArg = args.includes('--steps') ? args[args.indexOf('--steps') + 1] : null;

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
const port = server.address().port;

const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const page = await browser.newPage();
page.on('console', m => { if (m.type() === 'error') console.error('page:', m.text()); });
page.on('pageerror', e => console.error('page error:', e.message));
await page.goto(`http://localhost:${port}/page/index.html`);
await page.waitForFunction(() => window.BL);
const info = await page.evaluate(() => BL.load('/data'));
console.log(`${info.name}: ${info.pieces} pieces, ${info.steps} steps, ${info.parts} parts`);

const save = (dir, name, dataUrl) => {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, name), Buffer.from(dataUrl.split(',')[1], 'base64'));
};
const stepList = stepsArg ? stepsArg.split(',').map(Number) : [...Array(info.steps).keys()];

if (want('--thumbs')) {
  const pairs = await page.evaluate(() => BL.partColours());
  for (const [p, c] of pairs) save(path.join(buildDir, 'thumbs'), `${p}-${c}.png`, await page.evaluate(([p, c]) => BL.part(p, c), [p, c]));
  console.log(`thumbs: ${pairs.length}`);
}
if (want('--previews')) {
  for (const s of stepList) save(path.join(buildDir, 'previews'), `step-${String(s + 1).padStart(3, '0')}.png`, await page.evaluate(s => BL.step(s, { lift: 1 }), s));
  console.log(`previews: ${stepList.length}`);
}
if (want('--hud')) {
  // The glasses only show pictures, so every picture they could need is drawn here.
  // Per step, from each of the four sides (q0..q3): the piece waiting with its arrow, the
  // arrow at the bottom of its bounce (-w), part-way in (-a) and seated (-b).
  // Where the next step is looked at from another side, four frames (-r1..-r4) of the
  // finished step turning round to it.
  // -c, -a, -d are the piece on its way in (three quarters, half, a quarter of the way out).
  const variants = [['', { lift: 1 }], ['-w', { lift: 1, pressed: true }], ['-c', { lift: 0.74 }], ['-a', { lift: 0.45 }], ['-d', { lift: 0.18 }], ['-b', { lift: 0 }]];
  const views = await page.evaluate(() => BL.stepViews());
  const shot = async (name, s, opts) => save(path.join(buildDir, 'hud'), name,
    await page.evaluate(([s, opts]) => BL.step(s, { w: 640, h: 480, mode: 'hud', ...opts }), [s, opts]));
  let count = 0;
  for (const s of stepList) {
    const id = String(s + 1).padStart(3, '0');
    for (let q = 0; q < 4; q++) {
      for (const [suffix, opts] of variants) { await shot(`step-${id}-q${q}${suffix}.png`, s, { ...opts, view: q }); count++; }
    }
    // The next step of the same assembly, if it is seen from a different side.
    const next = views.findIndex((v, k) => k > s && v.assembly === views[s].assembly);
    if (next === s + 1 && views[next].view !== views[s].view) {
      const [from, to] = await page.evaluate(([a, b]) => [BL.viewYaw(a), BL.viewYaw(b)], [views[s].view, views[next].view]);
      let turn = to - from;
      if (turn > Math.PI) turn -= 2 * Math.PI;          // the short way round
      if (turn < -Math.PI) turn += 2 * Math.PI;
      for (let j = 1; j <= 4; j++) { await shot(`step-${id}-r${j}.png`, s, { lift: 0, yaw: from + turn * j / 5 }); count++; }
    }
  }
  // The finish: the completed truck turning once round, from the last step's own side.
  // The glasses play these twice over, quickly at first and slowing to a stop.
  const last = views.length - 1;
  if (stepList.includes(last)) {
    const base = await page.evaluate(v => BL.viewYaw(v), views[last].view);
    for (let j = 1; j <= 24; j++) { await shot(`finish-${String(j).padStart(2, '0')}.png`, last, { lift: 0, yaw: base + 2 * Math.PI * j / 24 }); count++; }
  }
  console.log(`hud frames: ${count}`);
}
if (want('--hero')) {
  save(buildDir, 'hero.png', await page.evaluate(() => BL.finished()));
  console.log('hero: hero.png');
}
await browser.close();
server.close();
