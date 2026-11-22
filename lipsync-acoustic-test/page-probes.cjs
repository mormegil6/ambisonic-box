// Page-side probes shared by both drivers: INSTRUMENT records the luma of every painted video frame, CLICKS plays three calibration clicks that tie the capture clock to the page clock.
const INSTRUMENT = `(() => {
  window.__lum = [];
  const poll = setInterval(() => {
    const v = document.querySelector('video');
    if (!v || v.__hooked) return;
    v.__hooked = true; clearInterval(poll);
    const c = document.createElement('canvas'); c.width = 16; c.height = 8;
    const x = c.getContext('2d', { willReadFrequently: true });
    const cb = (now, md) => {
      try {
        x.drawImage(v, 0, 0, 16, 8);
        const d = x.getImageData(0, 0, 16, 8).data; let s = 0;
        for (let i = 0; i < d.length; i += 4) s += d[i] + d[i + 1] + d[i + 2];
        window.__lum.push([now, md.expectedDisplayTime, md.mediaTime, s / (d.length / 4 * 3 * 255)]);
      } catch (e) { window.__lumErr = String(e); }
      v.requestVideoFrameCallback(cb);
    };
    v.requestVideoFrameCallback(cb);
  }, 100);
})();`;

const CLICKS = `(async () => {
  const ctx = new AudioContext(); await ctx.resume();
  const sr = ctx.sampleRate, n = Math.round(sr * 0.01);
  const buf = ctx.createBuffer(1, n, sr), ch = buf.getChannelData(0);
  for (let i = 0; i < n; i++) ch[i] = Math.sin(2 * Math.PI * 3000 * i / sr) * Math.sin(Math.PI * i / n);
  const warm = ctx.createBufferSource(); warm.buffer = ctx.createBuffer(1, sr, sr); warm.connect(ctx.destination); warm.start();
  let ts = ctx.getOutputTimestamp();
  for (let i = 0; i < 40 && !(ts.contextTime > 0 && ts.performanceTime > 0); i++) { await new Promise(r => setTimeout(r, 50)); ts = ctx.getOutputTimestamp(); }
  if (!(ts.contextTime > 0)) throw new Error('no output timestamp');
  const out = [];
  const base = ctx.currentTime + 1.0;
  for (let k = 0; k < 3; k++) {
    const when = base + k * 0.7;
    const s = ctx.createBufferSource(); s.buffer = buf; s.connect(ctx.destination); s.start(when);
    out.push(performance.timeOrigin + ts.performanceTime + (when - ts.contextTime) * 1000);
  }
  await new Promise(r => setTimeout(r, 3500));
  return { epochMs: out, ts: { ctx: ts.contextTime, perf: ts.performanceTime }, latency: { base: ctx.baseLatency, out: ctx.outputLatency } };
})()`;
module.exports = { INSTRUMENT, CLICKS };
