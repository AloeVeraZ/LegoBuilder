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
  for (const s of stepList) save(path.join(buildDir, 'previews'), `step-${String(s + 1).padStart(3, '0')}.png`, await page.evaluate(s => BL.step(s), s));
  console.log(`previews: ${stepList.length}`);
}
if (want('--hud')) {
  for (const s of stepList) save(path.join(buildDir, 'hud'), `step-${String(s + 1).padStart(3, '0')}.png`, await page.evaluate(s => BL.step(s, { w: 640, h: 480, mode: 'hud' }), s));
  console.log(`hud frames: ${stepList.length}`);
}
if (want('--hero')) {
  save(buildDir, 'hero.png', await page.evaluate(() => BL.finished()));
  console.log('hero: hero.png');
}
await browser.close();
server.close();
