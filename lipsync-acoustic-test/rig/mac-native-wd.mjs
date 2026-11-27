// The browser's own A/V sync in Safari or Firefox: rig/www/native.html (plain MP4, unmuted <video>) with its video box
// moved onto the sensor, while the Pi records. usage: node rig/mac-native-wd.mjs <tag> <safari|firefox>
import { spawn, execFileSync } from 'child_process'; import http from 'http'; import fs from 'fs'; import path from 'path';
const [tag, browser] = process.argv.slice(2); const PI = process.env.PI || 'pi-hole', CARD = process.env.PI_CARD || 'hw:3,0';
const here = path.dirname(new URL(import.meta.url).pathname), out = path.join(here, '../runs');
const sleep = ms => new Promise(r => setTimeout(r, ms)); const PORT = browser === 'firefox' ? 4450 : 4451;
const srv = http.createServer((q, r) => { const f = path.join(here, 'www', q.url.split('?')[0].slice(1)); if (!fs.existsSync(f)) { r.writeHead(404); return r.end(); }
  const buf = fs.readFileSync(f); r.writeHead(200, { 'Content-Type': f.endsWith('.mp4') ? 'video/mp4' : 'text/html', 'Content-Length': buf.length }); r.end(buf); }).listen(8771, '127.0.0.1');
const driver = spawn(browser === 'firefox' ? 'geckodriver' : 'safaridriver', ['-p', String(PORT)], { stdio: 'ignore' });
const base = `http://127.0.0.1:${PORT}`;
const call = async (m, p, b) => { const r = await fetch(base + p, { method: m, headers: { 'content-type': 'application/json' }, body: b ? JSON.stringify(b) : undefined }); const j = await r.json(); if (j.value && j.value.error) throw new Error(j.value.message); return j.value; };
for (let i = 0; i < 40; i++) { try { await fetch(base + '/status'); break; } catch { await sleep(250); } }
const caps = browser === 'firefox' ? { browserName: 'firefox', 'moz:firefoxOptions': { prefs: { 'media.autoplay.default': 0, 'media.autoplay.blocking_policy': 0 } } } : { browserName: 'safari', 'webkit:alwaysAllowAutoplay': true };
const { sessionId: id } = await call('POST', '/session', { capabilities: { alwaysMatch: caps } });
const exec = s => call('POST', `/session/${id}/execute/sync`, { script: s, args: [] });
try {
  await call('POST', `/session/${id}/window/rect`, { x: 80, y: 60, width: 1100, height: 800 });
  await call('POST', `/session/${id}/url`, { url: 'http://127.0.0.1:8771/native.html' }); await sleep(1500);
  for (let k = 0; k < 2; k++) {
    const g = await exec(`const r = document.querySelector('video').getBoundingClientRect(); return { x: r.x, y: r.y, top: window.outerHeight - window.innerHeight, side: window.outerWidth - window.innerWidth }`);
    const rect = await call('GET', `/session/${id}/window/rect`);
    await call('POST', `/session/${id}/window/rect`, { x: Math.round(202 - g.x - g.side / 2), y: Math.round(326 - g.y - g.top), width: rect.width, height: rect.height }); await sleep(800);
  }
  const rec = spawn('ssh', [PI, `arecord -q -D ${CARD} -c 4 -r 48000 -f S16_LE -d 52 /tmp/${tag}.wav`], { stdio: 'inherit' }); const done = new Promise(r => rec.on('close', r));
  await sleep(1500);
  console.log(tag, await call('POST', `/session/${id}/execute/async`, { script: 'const d = arguments[arguments.length - 1]; document.querySelector("video").play().then(() => d("playing"), e => d("play failed " + e));', args: [] }));
  await done; execFileSync('scp', ['-q', `${PI}:/tmp/${tag}.wav`, path.join(out, tag + '.rig.wav')]);
} finally { try { await call('DELETE', `/session/${id}`); } catch {} driver.kill(); srv.close(); }
