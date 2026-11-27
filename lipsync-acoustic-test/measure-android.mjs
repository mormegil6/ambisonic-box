// One run on an Android phone, timed by the photodiode rig: Chrome on the phone plays the test clip, and a Raspberry Pi
// records the phone's sound and a photodiode taped to its screen on one sound card, so the offset comes from the
// recording alone and nothing the browser reports is used.
// usage: node measure-android.mjs <tag> <nob|ctrl|trim|live|elst>
// env:   ADB_SERIAL (the phone, as `adb devices` lists it)  PI=pi-hole (ssh host)  PI_CARD=hw:3,0  PI_CH=4  DUR=40
//        BUNDLE=/path/to/hoast360.bundle.js  BASE=https://stream.bmroz.eu
// Needs: adb connected to the phone (wireless debugging, since its USB port carries the audio adapter), Chrome open on
// the phone, and the Pi's card wired as: input 1 phone right, input 2 phone left, input 3 photodiode.
import { execFileSync, spawn } from 'child_process'; import fs from 'fs'; import path from 'path';
import { createRequire } from 'module'; import { startProxy } from './proxy.mjs';
const require = createRequire(import.meta.url); const { chromium } = require('playwright-core');
const [tag, clip] = process.argv.slice(2);
if (!tag || !clip) { console.error('usage: node measure-android.mjs <tag> <clip>'); process.exit(2); }
const dur = +(process.env.DUR || 40), PI = process.env.PI || 'pi-hole', CARD = process.env.PI_CARD || 'hw:3,0', CH = process.env.PI_CH || '4';
const serial = process.env.ADB_SERIAL ? ['-s', process.env.ADB_SERIAL] : [];
const here = path.dirname(new URL(import.meta.url).pathname), outDir = path.join(here, 'runs'); fs.mkdirSync(outDir, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const adb = (...a) => execFileSync('adb', [...serial, ...a], { encoding: 'utf8' });
const PROXY = 8770, CDP = 9222;

(async () => {
  const proxy = await startProxy({ port: PROXY, clip, bundle: process.env.BUNDLE || '', base: process.env.BASE });
  adb('reverse', `tcp:${PROXY}`, `tcp:${PROXY}`);              // the phone's 127.0.0.1:8770 is this Mac's proxy
  adb('forward', `tcp:${CDP}`, 'localabstract:chrome_devtools_remote');
  const remote = `/tmp/${tag}.wav`, secs = dur + 25;
  const rec = spawn('ssh', [PI, `arecord -q -D ${CARD} -c ${CH} -r 48000 -f S16_LE -d ${secs} ${remote}`], { stdio: 'inherit' });
  const recDone = new Promise(r => rec.on('close', r));   // set up now: the recording can end before playback does
  await sleep(1500);
  const b = await chromium.connectOverCDP(`http://127.0.0.1:${CDP}`);
  const ctx = b.contexts()[0]; const p = ctx.pages()[0] || await ctx.newPage();
  const errs = [];
  try {
    await p.goto(`http://127.0.0.1:${PROXY}/vod/?clip=colortones`, { waitUntil: 'domcontentloaded' });
    await p.waitForFunction(() => document.querySelector('video'), null, { timeout: 30000 });
    await sleep(6000);
    // A real touch on the player gives the page its user gesture, which unmuted Web Audio needs on Android.
    const box = await p.evaluate(() => { const c = document.querySelector('canvas') || document.querySelector('video'); const r = c.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; });
    const s = await ctx.newCDPSession(p);
    await s.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [box] });
    await s.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    const pl = await p.evaluate(() => Promise.race([document.querySelector('video').play().then(() => 'ok', e => 'play failed: ' + e), new Promise(r => setTimeout(() => r('play() did not settle in 5 s'), 5000))]));
    if (pl !== 'ok') errs.push(pl);
    await sleep(8000);
    console.log('after 8 s:', await p.evaluate(() => { const v = document.querySelector('video'); const f = window.__hoastAudioFeed && window.__hoastAudioFeed();
      return JSON.stringify({ paused: v.paused, ct: +v.currentTime.toFixed(2), feed: f ? { state: f.state, decoded: f.decoded, outputLatencyMs: f.outputLatency, shiftMs: f.presentationShiftMs } : null }); }));
    await sleep(dur * 1000 - 8000);
    const res = await p.evaluate(() => {
      const f = window.__hoastAudioFeed && window.__hoastAudioFeed(); const v = document.querySelector('video');
      return { lum: window.__lum, timeOrigin: performance.timeOrigin, ct: v.currentTime, paused: v.paused, ua: navigator.userAgent,
        feed: f ? { state: f.state, N: f.N, decoded: f.decoded, drift: f.drift, outputLatencyMs: f.outputLatency, shiftMs: f.presentationShiftMs, elstEdit: f.elstEdit, engineEdit: f.engineEdit } : null };
    });
    await p.evaluate(() => document.querySelector('video').pause()).catch(() => {});
    await recDone;
    execFileSync('scp', ['-q', `${PI}:${remote}`, path.join(outDir, tag + '.rig.wav')]);
    const version = (res.ua.match(/Chrome\/[\d.]+/) || [''])[0];
    fs.writeFileSync(path.join(outDir, tag + '.json'), JSON.stringify({ tag, exe: 'android-chrome', version, clip, bundle: process.env.BUNDLE || 'deployed', ...res, errs }));
    console.log(tag, version, 'ct=' + res.ct.toFixed(1), JSON.stringify(res.feed), errs.length ? 'ERRS ' + errs.join(' | ') : '');
  } finally { proxy.close(); try { await b.close(); } catch {} }
})().catch(e => { console.error('FAILED', e.stack.split('\n').slice(0, 3).join(' | ')); process.exit(1); });
