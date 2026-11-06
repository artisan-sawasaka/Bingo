// Decodes the QR matrices dumped by tests/unit/test_qr_code.gd with jsQR
// (an independent decoder) and checks every payload round-trips.
// Usage: node tools/verify_qr.mjs <path-to-qr_dump.json> <path-to-jsQR.js>
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const [dumpPath, jsqrPath] = process.argv.slice(2);
const require = createRequire(import.meta.url);
const jsQR = require(jsqrPath);
const dump = JSON.parse(readFileSync(dumpPath, 'utf8'));

const SCALE = 6, BORDER = 4;
let fail = 0;
for (const item of dump) {
  const n = item.rows.length;
  const dim = (n + BORDER * 2) * SCALE;
  const px = new Uint8ClampedArray(dim * dim * 4).fill(255);
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
    if (item.rows[y][x] !== '1') continue;
    for (let sy = 0; sy < SCALE; sy++) for (let sx = 0; sx < SCALE; sx++) {
      const i = (((y + BORDER) * SCALE + sy) * dim + (x + BORDER) * SCALE + sx) * 4;
      px[i] = px[i + 1] = px[i + 2] = 0;
    }
  }
  const res = jsQR(px, dim, dim, { inversionAttempts: 'dontInvert' });
  const got = res ? res.data : null;
  const ok = got === item.text;
  if (!ok) fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'} v${item.version} mask${item.mask} ${JSON.stringify(item.text.slice(0, 40))}${ok ? '' : ' got=' + JSON.stringify(got)}`);
}
console.log(fail ? `QR VERIFY: ${fail} failed` : 'QR VERIFY: all decoded');
process.exit(fail ? 1 : 0);
