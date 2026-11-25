// node Warcamp/test/assets.test.mjs
// Every file the page and the offline cache ask for must exist in the checkout. (A folder that
// .gitignore swallows exists on the author's disk but not here, and not on the published site.)
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const want = new Set();
const sw = readFileSync(join(root, 'sw.js'), 'utf8');
for (const m of sw.slice(sw.indexOf('ASSETS'), sw.indexOf('];')).matchAll(/'([^']+)'/g)) if (m[1] !== './') want.add(m[1]);
const html = readFileSync(join(root, 'index.html'), 'utf8');
for (const m of html.matchAll(/(?:src|href)="([^"#:]+)"/g)) want.add(m[1]);
for (const m of readFileSync(join(root, 'manifest.webmanifest'), 'utf8').matchAll(/"src":\s*"([^"]+)"/g)) want.add(m[1]);
for (const f of ['main', 'sim', 'ai', 'render', 'net']) {
  for (const m of readFileSync(join(root, 'js', f + '.js'), 'utf8').matchAll(/from '\.\/([^']+)'/g)) want.add('js/' + m[1]);
}
const missing = [...want].filter(f => !existsSync(join(root, f)));
for (const f of missing) console.error('MISSING', f);
if (missing.length) process.exit(1);
console.log(`all ${want.size} files the game loads are present`);
