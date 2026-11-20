// Builds dist/BuildLens.html: one self-contained file (app + three.js + the model data).
// Double-click it on Windows to open in Chrome or Edge. No server or install needed.
import { build } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.resolve(process.argv[2] || path.join(here, '../app/BuildLens/Resources/BuildData'));
const png = f => `data:image/png;base64,${fs.readFileSync(f).toString('base64')}`;

const buildJson = JSON.parse(fs.readFileSync(path.join(dataDir, 'build.json'), 'utf8'));
const thumbs = {};
const thumbDir = path.join(dataDir, 'thumbs');
for (const f of fs.existsSync(thumbDir) ? fs.readdirSync(thumbDir) : []) {
  const m = f.match(/^thumb-(\d+-\d+)\.png$/);
  if (m) thumbs[m[1]] = png(path.join(thumbDir, f));
}
const hud = [];
const hudDir = path.join(dataDir, 'hud');
for (const f of fs.existsSync(hudDir) ? fs.readdirSync(hudDir) : []) {
  const m = f.match(/^hud-step-(\d+)\.png$/);
  if (m) hud[Number(m[1]) - 1] = png(path.join(hudDir, f));
}
const heroFile = path.join(dataDir, 'build-hero.png');
const data = {
  build: buildJson,
  geometry: fs.readFileSync(path.join(dataDir, buildJson.geometry)).toString('base64'),
  thumbs,
  hud,
  hero: fs.existsSync(heroFile) ? png(heroFile) : null,
};

const result = await build({
  entryPoints: [path.join(here, 'src/app.js')],
  bundle: true, minify: true, format: 'iife', write: false, target: 'es2020',
});
const js = result.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
const html = fs.readFileSync(path.join(here, 'src/index.html'), 'utf8')
  .replace('/*BUILD_DATA*/null', () => JSON.stringify(data))
  .replace('/*APP_JS*/', () => js);
fs.mkdirSync(path.join(here, 'dist'), { recursive: true });
const out = path.join(here, 'dist/BuildLens.html');
fs.writeFileSync(out, html);
console.log(`${out}  (${(html.length / 1e6).toFixed(1)} MB, ${buildJson.steps.length} steps)`);
