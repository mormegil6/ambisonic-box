// Audible A/V offset of the VOD player, measured at the system output (BlackHole 2ch) and at the video element. Chromium family.
// usage: node measure.cjs <tag> <browser executable> <nob|ctrl|trim|live|elst>
// env:   ARGS=a,b (browser flags)  BUNDLE=/path/to/hoast360.bundle.js (replace the player)  DUR=40 (seconds)  BASE=https://stream.bmroz.eu  DEVICE='BlackHole 2ch'
const { chromium } = require('playwright-core');
const { spawn } = require('child_process');
const fs = require('fs'), path = require('path');
const [, , tag, exe, clip] = process.argv;
const extraArgs = (process.env.ARGS || '').split(',').filter(Boolean);
const bundle = process.env.BUNDLE || '';
const dur = +(process.env.DUR || 40);
const BASE = process.env.BASE || 'https://stream.bmroz.eu', DEVICE = process.env.DEVICE || 'BlackHole 2ch';
const outDir = path.join(__dirname, 'runs'); fs.mkdirSync(outDir, { recursive: true });
const fxDir = path.join(__dirname, 'fx-' + clip);
const sleep = ms => new Promise(r => setTimeout(r, ms));

const { INSTRUMENT, CLICKS } = require('./page-probes.cjs');

(async () => {
  const wav = path.join(outDir, tag + '.wav');
  const rec = spawn(path.join(__dirname, 'cap'), [DEVICE, wav], { stdio: ['pipe', 'ignore', 'inherit'] });
  await sleep(1500);
  const b = await chromium.launch({ executablePath: exe, headless: false, args: ['--autoplay-policy=no-user-gesture-required', ...extraArgs] });
  const ctx = await b.newContext({ viewport: { width: 1100, height: 700 } });
  const p = await ctx.newPage();
  await p.bringToFront();   // screen-check.sh records the screen, so the window must be in front
  const errs = []; p.on('pageerror', e => errs.push(e.message.slice(0, 160)));
  await p.addInitScript(INSTRUMENT);
  let served = 0;
  await p.route('**/vod-dash/colortones/**', route => {
    const name = new URL(route.request().url()).pathname.split('/').pop();
    if (name.endsWith('.vtt')) return route.continue();
    const f = path.join(fxDir, name === 'colortones.mpd' ? 'vod.mpd' : name);
    if (!fs.existsSync(f)) return route.fulfill({ status: 404, body: '' });
    served++;
    const type = f.endsWith('.mpd') ? 'application/dash+xml' : 'video/mp4';
    route.fulfill({ path: f, contentType: type, headers: { 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-store' } });
  });
  if (bundle) await p.route('**/dist/hoast360.bundle.js*', r => r.fulfill({ path: bundle, contentType: 'application/javascript' }));
  await p.goto(BASE + '/vod/?clip=colortones', { waitUntil: 'domcontentloaded' });
  await p.waitForFunction(() => document.querySelector('video'), null, { timeout: 30000 });
  await sleep(6000);
  const clicks = await p.evaluate(CLICKS);
  await p.evaluate(() => { const v = document.querySelector('video'); return v.play(); }).catch(e => errs.push('play: ' + e.message.slice(0, 100)));
  await sleep(dur * 1000);
  const res = await p.evaluate(() => {
    const f = window.__hoastAudioFeed && window.__hoastAudioFeed(); const v = document.querySelector('video');
    return { lum: window.__lum, lumErr: window.__lumErr || null, timeOrigin: performance.timeOrigin, ct: v.currentTime,
      feed: f ? { state: f.state, N: f.N, decoded: f.decoded, drift: f.drift, shiftMs: f.presentationShiftMs, elstEdit: f.elstEdit, engineEdit: f.engineEdit } : null };
  });
  const version = b.version();
  await b.close();
  rec.stdin.write('q\n'); await new Promise(r => rec.on('close', r));
  fs.writeFileSync(path.join(outDir, tag + '.json'), JSON.stringify({ tag, exe: path.basename(exe), version, clip, args: extraArgs, bundle: bundle || 'deployed', served, clicks, ...res, errs }));
  console.log(tag, version, 'served=' + served, 'frames=' + res.lum.length, 'ct=' + res.ct.toFixed(1), JSON.stringify(res.feed), errs.length ? 'ERRS ' + errs.join(' | ') : '');
})().catch(e => { console.error('FAILED', e.message); try { rec.kill(); } catch (_) {} process.exit(1); });
