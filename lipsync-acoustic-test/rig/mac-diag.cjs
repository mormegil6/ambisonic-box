// Display-path check on this Mac: rig/www/diag.html in desktop Chrome at the rig's window position, while the Pi
// records light and sound. usage: node rig/mac-diag.cjs <tag> <ol|ts>   then: python3 analyze-rig.py <tag>
const { chromium } = require('playwright-core'); const { execFileSync, spawn } = require('child_process'); const path = require('path'); const http = require('http'); const fs = require('fs');
const [tag, mode] = process.argv.slice(2); const PI = process.env.PI || 'pi-hole', CARD = process.env.PI_CARD || 'hw:3,0';
const exe = process.env.EXE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const out = path.join(__dirname, '../runs');
(async () => {
  const srv = http.createServer((q, r) => { r.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' }); r.end(fs.readFileSync(path.join(__dirname, 'www/diag.html'))); }).listen(8771, '127.0.0.1');
  const rec = spawn('ssh', [PI, `arecord -q -D ${CARD} -c 4 -r 48000 -f S16_LE -d 55 /tmp/${tag}.wav`], { stdio: 'inherit' }); const done = new Promise(r => rec.on('close', r));
  await new Promise(r => setTimeout(r, 1500));
  const b = await chromium.launch({ executablePath: exe, headless: false, args: ['--window-position=80,60', '--autoplay-policy=no-user-gesture-required'] });
  const p = await (await b.newContext({ viewport: { width: 1100, height: 700 } })).newPage(); await p.bringToFront();
  await p.goto(`http://127.0.0.1:8771/diag.html?mode=${mode}`); await p.waitForTimeout(1000);
  await p.mouse.click(500, 400);
  await p.waitForFunction(() => window.__done, null, { timeout: 70000, polling: 500 });
  const log = await p.evaluate(() => window.__log); await b.close();
  await done; execFileSync('scp', ['-q', `${PI}:/tmp/${tag}.wav`, path.join(out, tag + '.rig.wav')]);
  fs.writeFileSync(path.join(out, tag + '.json'), JSON.stringify({ tag, version: 'mac-diag-' + mode, clip: 'diag', log }));
  console.log(tag, 'OL ms', log[0] && (log[0].ol * 1000).toFixed(1), 'raf-minus-due', log.map(l => (l.rafT - l.due).toFixed(1)).join(' '));
  srv.close(); process.exit(0);
})().catch(e => { console.error('FAILED', e.message); process.exit(1); });
