// parity.mjs — headless A/B of the webgl2 and webgpu engine bundles.
//
// Why this exists: the web engine ships TWO bundles from one shader/render
// source (one sokol backend baked into each — see build.zig `-Dgpu`). They are
// supposed to render the same scene the same way. With no automated check the
// webgpu path silently drifted behind webgl2; this is the regression guard.
//
// For every scene × {webgl2, webgpu} it boots the engine under headless
// Chromium with software WebGPU (Dawn/SwiftShader — no GPU needed), renders one
// static frame, and records: did the runtime init, did the WebGPU device get
// lost / abort / log an error, and a screenshot. It then compares each scene's
// two screenshots pixel-for-pixel and writes a report.
//
// Exit code: non-zero if webgpu errored where webgl2 didn't, or a scene's two
// renders differ by more than `MAX_DIFF_FRACTION`. Screenshots + report.json +
// report.md land in the output dir for eyeballing.
//
// Usage:  node parity.mjs --www <dir> --out <dir> [--scenes a.json,b.json]
//                         [--wait 4000] [--size 800x600] [--threshold 0.02]
// `--www` must contain engine/quine-{webgl2,webgpu}.{js,wasm}, harness.html, and
// the scene files referenced by --scenes. The driving shell script assembles it.

import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

function arg(name, def) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}

const WWW = path.resolve(arg('www', '.'));
const OUT = path.resolve(arg('out', '/tmp/quine-parity'));
// Defaults kept modest: the scene is static (autoplay off), so a couple seconds
// is plenty to boot + render a frame, and a small viewport keeps the SOFTWARE
// WebGPU/GL fragment cost (raymarch, bloom) low enough to run in a headless
// container. Bump --size / --wait for a higher-fidelity eyeball pass.
const WAIT = parseInt(arg('wait', '2500'), 10);
const [W, H] = arg('size', '512x384').split('x').map((n) => parseInt(n, 10));
const MAX_DIFF_FRACTION = parseFloat(arg('threshold', '0.02')); // 2% of pixels may differ
const PER_CHANNEL_TOL = 24; // 8-bit value tolerance per channel (sampler/rounding jitter)

let scenes = arg('scenes', '');
if (scenes) {
  scenes = scenes.split(',').map((s) => s.trim()).filter(Boolean);
} else {
  // default: every *.json directly under www/scenes
  const dir = path.join(WWW, 'scenes');
  scenes = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.json')).map((f) => 'scenes/' + f) : [];
}
if (scenes.length === 0) { console.error('no scenes to test (looked in', path.join(WWW, 'scenes') + ')'); process.exit(2); }

fs.mkdirSync(OUT, { recursive: true });

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json' };
const server = http.createServer((req, res) => {
  const u = decodeURIComponent(req.url.split('?')[0]);
  const fp = path.join(WWW, u === '/' ? 'harness.html' : u);
  if (!fp.startsWith(WWW)) { res.writeHead(403); res.end(); return; }
  fs.readFile(fp, (err, buf) => {
    if (err) { res.writeHead(404); res.end('not found: ' + u); return; }
    res.writeHead(200, {
      'content-type': MIME[path.extname(fp)] || 'application/octet-stream',
      // emscripten pthreads aren't used, but keep COOP/COEP clean for parity with prod.
      'cross-origin-opener-policy': 'same-origin',
      'cross-origin-embedder-policy': 'require-corp',
    });
    res.end(buf);
  });
});
await new Promise((r) => server.listen(0, r));
const port = server.address().port;

const browser = await chromium.launch({
  headless: true,
  args: [
    '--no-sandbox',
    '--enable-unsafe-webgpu',
    '--enable-features=Vulkan',
    '--use-angle=swiftshader',
    '--use-vulkan=swiftshader',
    '--enable-webgpu-developer-features',
    '--ignore-gpu-blocklist',
  ],
});

// Minimal PNG reader: returns {width,height,rgba} for a Chromium PNG screenshot.
function decodePng(buf) {
  let pos = 8, width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos);
    const type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      bitDepth = data[8]; colorType = data[9];
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    pos += 12 + len;
  }
  if (bitDepth !== 8 || (colorType !== 6 && colorType !== 2)) {
    throw new Error('unsupported PNG (bitDepth=' + bitDepth + ' colorType=' + colorType + ')');
  }
  const channels = colorType === 6 ? 4 : 3;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const rgba = Buffer.alloc(width * height * 4);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const cur = Buffer.alloc(stride);
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? cur[x - channels] : 0;
      const b = prev[x];
      const c = x >= channels ? prev[x - channels] : 0;
      let v = line[x];
      switch (filter) {
        case 0: break;
        case 1: v = (v + a) & 0xff; break;
        case 2: v = (v + b) & 0xff; break;
        case 3: v = (v + ((a + b) >> 1)) & 0xff; break;
        case 4: {
          const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          v = (v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 0xff; break;
        }
        default: throw new Error('bad PNG filter ' + filter);
      }
      cur[x] = v;
    }
    for (let x = 0; x < width; x++) {
      const si = x * channels, di = (y * width + x) * 4;
      rgba[di] = cur[si]; rgba[di + 1] = cur[si + 1]; rgba[di + 2] = cur[si + 2];
      rgba[di + 3] = channels === 4 ? cur[si + 3] : 255;
    }
    prev = cur;
  }
  return { width, height, rgba };
}

function diffFraction(a, b) {
  if (a.width !== b.width || a.height !== b.height) return 1;
  const n = a.width * a.height;
  let differing = 0;
  for (let i = 0; i < n; i++) {
    const o = i * 4;
    if (Math.abs(a.rgba[o] - b.rgba[o]) > PER_CHANNEL_TOL ||
        Math.abs(a.rgba[o + 1] - b.rgba[o + 1]) > PER_CHANNEL_TOL ||
        Math.abs(a.rgba[o + 2] - b.rgba[o + 2]) > PER_CHANNEL_TOL) differing++;
  }
  return differing / n;
}

async function runOne(backend, scene) {
  const page = await browser.newPage({ viewport: { width: W, height: H } });
  const url = `http://localhost:${port}/harness.html?render=${backend}&scene=${encodeURIComponent(scene)}`;
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(WAIT);
  const state = await page.evaluate(() => window.__quine || { log: ['no __quine'], ready: false });
  // CDP capture avoids Playwright's font-wait, which can hang under software GL.
  const cdp = await page.context().newCDPSession(page);
  const cap = await cdp.send('Page.captureScreenshot', { format: 'png' });
  const png = Buffer.from(cap.data, 'base64');
  const file = path.join(OUT, `${path.basename(scene).replace(/\.json$/, '')}.${backend}.png`);
  fs.writeFileSync(file, png);
  await page.close();
  const errors = state.log.filter((l) =>
    /engine\[err\]|window\.error|unhandledrejection|onAbort|DEVICE LOST|uncapturederror|failed|threw/.test(l));
  return { backend, scene, ready: state.ready, deviceLost: state.deviceLost, aborted: state.aborted, errors, log: state.log, file, png };
}

const results = [];
let failed = false;
for (const scene of scenes) {
  const gl = await runOne('webgl2', scene);
  const gpu = await runOne('webgpu', scene);
  let diff = null;
  try { diff = diffFraction(decodePng(gl.png), decodePng(gpu.png)); } catch (e) { diff = `decode error: ${e.message}`; }

  // webgpu is "behind" if it errored/aborted/lost-device where webgl2 was clean,
  // failed to become ready, or its render diverges beyond tolerance.
  const glClean = gl.ready && gl.errors.length === 0 && !gl.aborted;
  const gpuClean = gpu.ready && gpu.errors.length === 0 && !gpu.aborted && !gpu.deviceLost;
  const regressed = (glClean && !gpuClean) || (typeof diff === 'number' && diff > MAX_DIFF_FRACTION);
  if (regressed) failed = true;

  const name = path.basename(scene);
  console.log(`\n=== ${name} ===`);
  console.log(`  webgl2: ready=${gl.ready} errors=${gl.errors.length}`);
  console.log(`  webgpu: ready=${gpu.ready} deviceLost=${gpu.deviceLost} errors=${gpu.errors.length}`);
  console.log(`  pixel diff: ${typeof diff === 'number' ? (diff * 100).toFixed(2) + '%' : diff}  ${regressed ? 'FAIL' : 'ok'}`);
  if (gpu.errors.length) for (const e of gpu.errors) console.log('    webgpu! ' + e);

  results.push({
    scene: name, diff, regressed,
    webgl2: { ready: gl.ready, errors: gl.errors, file: path.basename(gl.file) },
    webgpu: { ready: gpu.ready, deviceLost: gpu.deviceLost, aborted: gpu.aborted, errors: gpu.errors, file: path.basename(gpu.file) },
  });
}

await browser.close();
server.close();

fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify({ size: `${W}x${H}`, threshold: MAX_DIFF_FRACTION, results }, null, 2));
const md = ['# quine backend parity — webgl2 vs webgpu', '',
  `viewport ${W}x${H}, diff threshold ${(MAX_DIFF_FRACTION * 100).toFixed(0)}% of pixels (±${PER_CHANNEL_TOL}/channel)`, '',
  '| scene | webgl2 | webgpu | pixel diff | verdict |', '|---|---|---|---|---|',
  ...results.map((r) => `| ${r.scene} | ${r.webgl2.ready ? 'ok' : 'FAIL'} | ${r.webgpu.deviceLost ? 'device-lost' : r.webgpu.ready ? 'ok' : 'FAIL'} | ${typeof r.diff === 'number' ? (r.diff * 100).toFixed(2) + '%' : r.diff} | ${r.regressed ? '❌ regressed' : '✅'} |`),
  '', 'Screenshots: `<scene>.webgl2.png` / `<scene>.webgpu.png` in this dir.', ''].join('\n');
fs.writeFileSync(path.join(OUT, 'report.md'), md);

console.log(`\nreport: ${path.join(OUT, 'report.md')}`);
console.log(failed ? '\nPARITY FAILED — webgpu is behind webgl2 (see above)' : '\nPARITY OK — webgpu matches webgl2');
process.exit(failed ? 1 : 0);
