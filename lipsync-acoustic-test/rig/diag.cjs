// Display-path check: runs www/diag.html on the phone (a Web Audio beep and a page-painted white flash, due at the same
// moment by Chrome's own clocks) while the Pi records light and sound. usage: node rig/diag.cjs <tag> <ol|ts>, then
// python3 analyze-rig.py <tag>. env: ADB_SERIAL, PI, PI_CARD as in measure-android.mjs
const { chromium } = require('playwright-core'); const { execFileSync, spawn } = require('child_process'); const path = require('path'); const http = require('http'); const fs = require('fs');
const [tag, mode] = process.argv.slice(2); const S = process.env.ADB_SERIAL ? ['-s', process.env.ADB_SERIAL] : [];  const PI = process.env.PI || 'pi-hole', CARD = process.env.PI_CARD || 'hw:3,0';
const out = path.join(__dirname, '../runs');
(async () => {
  const srv = http.createServer((q, r) => { r.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' }); r.end(fs.readFileSync(path.join(__dirname, 'www/diag.html'))); }).listen(8771, '127.0.0.1');
  execFileSync('adb', [...S, 'reverse', 'tcp:8771', 'tcp:8771']); execFileSync('adb', [...S, 'forward', 'tcp:9222', 'localabstract:chrome_devtools_remote']);
  const rec = spawn('ssh', [PI, `arecord -q -D ${CARD} -c 4 -r 48000 -f S16_LE -d 52 /tmp/${tag}.wav`], { stdio: 'inherit' }); const done = new Promise(r => rec.on('close', r));
  await new Promise(r => setTimeout(r, 1500));
  const b = await chromium.connectOverCDP('http://127.0.0.1:9222'); const ctx = b.contexts()[0]; const p = ctx.pages()[0];
  await p.goto(`http://127.0.0.1:8771/diag.html?mode=${mode}&t=${Date.now()}`); await p.waitForTimeout(1000);
  const s = await ctx.newCDPSession(p);
  await s.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 200, y: 400 }] }); await s.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await p.waitForFunction(() => window.__done, null, { timeout: 70000, polling: 500 });
  const log = await p.evaluate(() => window.__log);
  await done; execFileSync('scp', ['-q', `${PI}:/tmp/${tag}.wav`, path.join(out, tag + '.rig.wav')]);
  fs.writeFileSync(path.join(out, tag + '.json'), JSON.stringify({ tag, version: 'diag-' + mode, clip: 'diag', log }));
  const late = log.map(l => (l.rafT - l.due).toFixed(1)); console.log(tag, 'OL', log[0] && (log[0].ol * 1000).toFixed(1), 'raf-minus-due', late.join(' '));
  srv.close(); process.exit(0);
})().catch(e => { console.error('FAILED', e.message); process.exit(1); });
