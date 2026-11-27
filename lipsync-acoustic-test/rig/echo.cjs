// Audio round trip on the phone: the Pi plays clicks into the phone's mic (Maya out 1+2) and into Maya in 4 as the
// reference (out 4 -> in 4); the page echoes mic to output; the echo returns on Maya in 1/2. usage: node rig/echo.cjs <tag>
// env: ADB_SERIAL, PI, PI_CARD, LEVEL (click amplitude, default 0.03). The Maya's Master playback must be up
// (amixer -c 3 sset Master 255); its Line playback switches must stay off, or the inputs loop to the outputs.
const { chromium } = require('playwright-core'); const { execFileSync, spawn } = require('child_process'); const path = require('path'); const http = require('http'); const fs = require('fs');
const tag = process.argv[2]; const S = process.env.ADB_SERIAL ? ['-s', process.env.ADB_SERIAL] : [];  const PI = process.env.PI || 'pi-hole', CARD = process.env.PI_CARD || 'hw:3,0';
const out = path.join(__dirname, '../runs'); const LEVEL = +(process.env.LEVEL || 0.03);
(async () => {
  const srv = http.createServer((q, r) => { r.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'no-store' }); r.end(fs.readFileSync(path.join(__dirname, 'www/echo.html'))); }).listen(8771, '127.0.0.1');
  execFileSync('adb', [...S, 'reverse', 'tcp:8771', 'tcp:8771']); execFileSync('adb', [...S, 'forward', 'tcp:9222', 'localabstract:chrome_devtools_remote']);
  const b = await chromium.connectOverCDP('http://127.0.0.1:9222'); const ctx = b.contexts()[0]; const p = ctx.pages()[0];
  const bs = await b.newBrowserCDPSession(); await bs.send('Browser.grantPermissions', { origin: 'http://127.0.0.1:8771', permissions: ['audioCapture'] });
  await p.goto(`http://127.0.0.1:8771/echo.html?t=${Date.now()}`); await p.waitForTimeout(800);
  const s = await ctx.newCDPSession(p);
  await s.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 200, y: 400 }] }); await s.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await p.waitForFunction(() => window.__echo, null, { timeout: 15000 });
  const info = await p.evaluate(() => window.__echo);
  // On the Pi: 4-channel click file (clicks on out 1, 2 and 4), recorded while it plays.
  execFileSync('ssh', [PI, `python3 - <<'PY'
import wave, struct, math
sr=48000; n=sr*14; L=${LEVEL}; frames=bytearray()
for i in range(n):
    t=i/sr; k=int(t); ph=t-k; v=0
    if 2<=k<12 and ph<0.01: v=L*math.sin(2*math.pi*3000*ph)*math.sin(math.pi*ph/0.01)
    s=int(v*32767); frames+=struct.pack('<4h', s, s, 0, s)
w=wave.open('/tmp/clicks.wav','wb'); w.setnchannels(4); w.setsampwidth(2); w.setframerate(sr); w.writeframes(bytes(frames)); w.close()
PY
arecord -q -D ${CARD} -c 4 -r 48000 -f S16_LE -d 16 /tmp/${tag}.wav & sleep 0.5; aplay -q -D ${CARD} /tmp/clicks.wav; wait`]);
  execFileSync('scp', ['-q', `${PI}:/tmp/${tag}.wav`, path.join(out, tag + '.rig.wav')]);
  fs.writeFileSync(path.join(out, tag + '.json'), JSON.stringify({ tag, info }));
  console.log(tag, JSON.stringify(info));
  await p.goto('about:blank'); srv.close(); process.exit(0);
})().catch(e => { console.error('FAILED', e.message); process.exit(1); });
