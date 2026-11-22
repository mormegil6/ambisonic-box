// WebDriver variant for Firefox and Safari. usage: node measure-wd.mjs <tag> <firefox|safari> <nob|ctrl|trim|live|elst>   env: BUNDLE=/path DUR=40 BASE=https://stream.bmroz.eu DEVICE='BlackHole 2ch' FIREFOX_BIN=/path/to/firefox (default: the installed Firefox)
import { spawn } from 'child_process'; import fs from 'fs'; import path from 'path'; import { createRequire } from 'module';
import { startProxy } from './proxy.mjs';
const require = createRequire(import.meta.url); const { CLICKS } = require('./page-probes.cjs');
const [tag, browser, clip] = process.argv.slice(2);
const dur = +(process.env.DUR || 40), bundle = process.env.BUNDLE || '';
const DEVICE = process.env.DEVICE || 'BlackHole 2ch';
const here = path.dirname(new URL(import.meta.url).pathname);
const outDir = path.join(here, 'runs'); fs.mkdirSync(outDir, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const PORT = browser === 'firefox' ? 4450 : 4451, PROXY = 8770;
const caps = browser === 'firefox'
  ? { browserName: 'firefox', 'moz:firefoxOptions': { ...(process.env.FIREFOX_BIN ? { binary: process.env.FIREFOX_BIN } : {}), prefs: { 'media.autoplay.default': 0, 'media.autoplay.blocking_policy': 0 } } }
  : { browserName: 'safari', 'webkit:alwaysAllowAutoplay': true };
const driver = spawn(browser === 'firefox' ? 'geckodriver' : 'safaridriver', ['-p', String(PORT)].concat(browser === 'firefox' ? [] : []), { stdio: 'ignore' });
const base = `http://127.0.0.1:${PORT}`;
async function call(method, p, body) {
  const r = await fetch(base + p, { method, headers: { 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json(); if (j.value && j.value.error) throw new Error(j.value.error + ': ' + (j.value.message || '').slice(0, 200)); return j.value;
}
(async () => {
  const proxy = await startProxy({ port: PROXY, clip, bundle, base: process.env.BASE });
  for (let i = 0; i < 40; i++) { try { await fetch(base + '/status'); break; } catch { await sleep(250); } }
  const wav = path.join(outDir, tag + '.wav');
  const rec = spawn(path.join(here, 'cap'), [DEVICE, wav], { stdio: ['pipe', 'ignore', 'inherit'] });
  await sleep(1500);
  const s = await call('POST', '/session', { capabilities: { alwaysMatch: caps } }); const id = s.sessionId;
  const exec = (script, args = []) => call('POST', `/session/${id}/execute/sync`, { script, args });
  const execAsync = (script, args = []) => call('POST', `/session/${id}/execute/async`, { script, args });
  const errs = [];
  try {
    await call('POST', `/session/${id}/url`, { url: `http://127.0.0.1:${PROXY}/vod/?clip=colortones` });
    for (let i = 0; i < 120; i++) { let ok = false; try { ok = await exec('return !!document.querySelector("video")'); } catch (e) { /* page still loading */ } if (ok) break; await sleep(250); }
    await sleep(6000);
    const clicks = await execAsync(`const done = arguments[arguments.length - 1]; ${CLICKS}.then(done, e => done({ error: String(e) }));`);
    if (clicks.error) errs.push('clicks: ' + clicks.error);
    // a real pointer click on the player canvas (not on a link) gives Safari its user gesture
    if (browser === 'safari') {
      try {
        const el = await call('POST', `/session/${id}/element`, { using: 'css selector', value: 'canvas' });
        const eid = el['element-6066-11e4-a52e-4f735466cecf'];
        await call('POST', `/session/${id}/actions`, { actions: [{ type: 'pointer', id: 'm', parameters: { pointerType: 'mouse' }, actions: [{ type: 'pointerMove', x: 0, y: 0, origin: { 'element-6066-11e4-a52e-4f735466cecf': eid } }, { type: 'pointerDown', button: 0 }, { type: 'pointerUp', button: 0 }] }] });
      } catch (e) { errs.push('click: ' + e.message.slice(0, 80)); }
    }
    const pl = await execAsync('const done = arguments[arguments.length - 1]; const v = document.querySelector("video"); Promise.resolve(v.play()).then(() => done("ok"), e => done("play failed: " + e));');
    if (pl !== 'ok') errs.push(String(pl));
    await sleep(dur * 1000);
    const resJson = await exec(`const f = window.__hoastAudioFeed && window.__hoastAudioFeed(); const v = document.querySelector('video');
      return JSON.stringify({ lum: window.__lum, lumErr: window.__lumErr || null, timeOrigin: performance.timeOrigin, ct: v.currentTime, ua: navigator.userAgent,
        feed: f ? { state: f.state, N: f.N, decoded: f.decoded, drift: f.drift, shiftMs: f.presentationShiftMs, elstEdit: f.elstEdit, engineEdit: f.engineEdit } : null });`);
    const res = JSON.parse(resJson);
    const version = (res.ua.match(/(Firefox\/[\d.]+|Version\/[\d.]+)/) || [''])[0];
    rec.stdin.write('q\n'); await new Promise(r => rec.on('close', r));
    fs.writeFileSync(path.join(outDir, tag + '.json'), JSON.stringify({ tag, exe: browser, version, clip, args: [], bundle: bundle || 'deployed', served: null, clicks, ...res, errs }));
    console.log(tag, version, 'frames=' + res.lum.length, 'ct=' + res.ct.toFixed(1), JSON.stringify(res.feed), errs.length ? 'ERRS ' + errs.join(' | ') : '');
  } finally { try { await call('DELETE', `/session/${id}`); } catch {} proxy.close(); driver.kill(); try { rec.kill(); } catch {} }
})().catch(e => { console.error('FAILED', e.stack.split('\n').slice(0,4).join(' | ')); try { driver.kill(); } catch {} process.exit(1); });
