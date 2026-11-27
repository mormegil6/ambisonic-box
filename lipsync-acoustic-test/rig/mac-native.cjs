// The browser's own A/V sync, for comparison: a plain progressive MP4 (H.264 + AAC, flash and beep together at
// 2.7 + 4k s) played unmuted by the <video> element itself, with the video box where the player's is.
// usage: node rig/mac-native.cjs <tag>   env: EXE (Chromium executable)   then: python3 analyze-rig.py <tag>
const { chromium } = require('playwright-core'); const { execFileSync, spawn } = require('child_process'); const path = require('path'); const http = require('http'); const fs = require('fs');
const tag = process.argv[2]; const PI = process.env.PI || 'pi-hole', CARD = process.env.PI_CARD || 'hw:3,0';
const exe = process.env.EXE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'; const out = path.join(__dirname, '../runs');
(async () => {
  const srv = http.createServer((q, r) => { const f = path.join(__dirname, 'www', q.url.split('?')[0].slice(1)); if (!fs.existsSync(f)) { r.writeHead(404); return r.end(); }
    const buf = fs.readFileSync(f); r.writeHead(200, { 'Content-Type': f.endsWith('.mp4') ? 'video/mp4' : 'text/html', 'Content-Length': buf.length }); r.end(buf); }).listen(8771, '127.0.0.1');
  const rec = spawn('ssh', [PI, `arecord -q -D ${CARD} -c 4 -r 48000 -f S16_LE -d 55 /tmp/${tag}.wav`], { stdio: 'inherit' }); const done = new Promise(r => rec.on('close', r));
  await new Promise(r => setTimeout(r, 1500));
  const b = await chromium.launch({ executablePath: exe, headless: false, args: ['--window-position=80,60', '--autoplay-policy=no-user-gesture-required'] });
  const p = await (await b.newContext({ viewport: { width: 1100, height: 700 } })).newPage(); await p.bringToFront();
  await p.goto('http://127.0.0.1:8771/native.html'); await p.waitForTimeout(1500);
  console.log(tag, await p.evaluate(() => document.querySelector('video').play().then(() => 'playing', e => 'play failed ' + e)));
  await p.waitForTimeout(43000); await b.close(); await done;
  execFileSync('scp', ['-q', `${PI}:/tmp/${tag}.wav`, path.join(out, tag + '.rig.wav')]); srv.close(); process.exit(0);
})().catch(e => { console.error('FAILED', e.message); process.exit(1); });
