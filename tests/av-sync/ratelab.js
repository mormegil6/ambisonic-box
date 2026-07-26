(function () {
  // Rate-lab: probe whether element playbackRate (preservesPitch=false) can
  // drain the then-suspected Chromium MediaElementSource+MSE audio delay (it
  // cannot; the offset was later traced to an ignored video edit list, not a
  // fixed decode-path delay). Panel shows a live A/V offset estimate from
  // flash/beep onset trains (color+tone test clip).
  var panel = document.createElement('div');
  panel.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:99999;background:rgba(0,0,0,.9);color:#eee;'
    + 'font:13px/1.5 ui-monospace,monospace;padding:8px 12px;border-bottom:2px solid #0a4';
  var readout = document.createElement('div');
  var btns = document.createElement('div');
  btns.style.cssText = 'margin-top:6px;display:flex;gap:6px;flex-wrap:wrap';
  panel.appendChild(readout); panel.appendChild(btns);
  function attach(){ if (document.body && !panel.parentNode) document.body.appendChild(panel); }
  document.addEventListener('DOMContentLoaded', attach); attach();

  function videoEl() {
    return document.getElementById('hoast360-player_html5_api') || document.querySelector('.video-js video') || document.querySelector('video');
  }

  // --- controls ---
  var burstTimer = null;
  function setRate(r) {
    var v = videoEl(); if (!v) return;
    if (burstTimer) { clearTimeout(burstTimer); burstTimer = null; }
    v.playbackRate = r;
  }
  function burst(rate, secs) {
    var v = videoEl(); if (!v) return;
    if (burstTimer) clearTimeout(burstTimer);
    v.playbackRate = rate;
    burstTimer = setTimeout(function () { var v2 = videoEl(); if (v2) v2.playbackRate = 1.0; burstTimer = null; }, secs * 1000);
  }
  [['0.95x', function(){setRate(0.95);}],
   ['1.00x', function(){setRate(1.0);}],
   ['1.02x', function(){setRate(1.02);}],
   ['1.05x', function(){setRate(1.05);}],
   ['1.10x', function(){setRate(1.10);}],
   ['Burst 1.25x/8s', function(){burst(1.25, 8);}],
   ['Burst 1.5x/4s', function(){burst(1.5, 4);}],
   ['reset events', function(){ vOn.length = 0; aOn.length = 0; best = null; }]
  ].forEach(function (b) {
    var el = document.createElement('button');
    el.textContent = b[0];
    el.style.cssText = 'font:12px ui-monospace,monospace;padding:4px 10px;border-radius:5px;border:1px solid #0a4;background:#123;color:#eee;cursor:pointer';
    el.addEventListener('click', b[1]);
    btns.appendChild(el);
  });

  // --- keep preservesPitch=false, always ---
  function pinPitch() {
    var v = videoEl(); if (!v) return;
    try { v.preservesPitch = false; } catch (e) {}
    try { v.webkitPreservesPitch = false; } catch (e) {}
  }
  setInterval(pinPitch, 1000);
  document.addEventListener('ratechange', pinPitch, true);

  // --- video flash onsets: mean frame color deltas ---
  var vc = document.createElement('canvas'); vc.width = 16; vc.height = 8;
  var vctx = vc.getContext('2d', { willReadFrequently: true });
  var lastRGB = null, vOn = [], lastVOn = 0;

  // --- audio beep onsets: analyser on hoast360.masterGain ---
  var analyser = null, aOn = [], lastAOn = 0, aQuiet = true, aBuf = null, tapNote = 'waiting for graph';
  function tryTapAudio() {
    if (analyser) return;
    var h = window.hoast360;
    if (!h || !h.context || !h.masterGain || typeof h.masterGain.connect !== 'function') return;
    analyser = h.context.createAnalyser();
    analyser.fftSize = 2048;
    aBuf = new Float32Array(analyser.fftSize);
    h.masterGain.connect(analyser);   // parallel tap, does not affect output
    tapNote = 'masterGain';
  }
  setInterval(tryTapAudio, 500);

  // --- best-lag search over onset trains ---
  var best = null;
  function estimate() {
    var now = performance.now();
    while (vOn.length && now - vOn[0] > 60000) vOn.shift();
    while (aOn.length && now - aOn[0] > 60000) aOn.shift();
    if (vOn.length < 3 || aOn.length < 3) { best = null; return; }
    var bestLag = null, bestScore = -1;
    for (var lag = -1000; lag <= 4000; lag += 20) {
      var score = 0;
      for (var i = 0; i < aOn.length; i++) {
        var target = aOn[i] - lag;
        for (var j = 0; j < vOn.length; j++) {
          if (Math.abs(vOn[j] - target) <= 120) { score++; break; }
        }
      }
      if (score > bestScore) { bestScore = score; bestLag = lag; }
    }
    best = { lag: bestLag, matched: bestScore, of: aOn.length };
  }
  setInterval(estimate, 3000);

  function tick() {
    var v = videoEl();
    if (v && v.videoWidth && v.readyState >= 2) {
      try {
        vctx.drawImage(v, 0, 0, 16, 8);
        var d = vctx.getImageData(0, 0, 16, 8).data;
        var r = 0, g = 0, b = 0, n = d.length / 4;
        for (var i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2]; }
        r /= n; g /= n; b /= n;
        if (lastRGB) {
          var delta = Math.abs(r - lastRGB[0]) + Math.abs(g - lastRGB[1]) + Math.abs(b - lastRGB[2]);
          var now = performance.now();
          if (delta > 60 && now - lastVOn > 300) { vOn.push(now); lastVOn = now; }
        }
        lastRGB = [r, g, b];
      } catch (e) {}
    }
    if (analyser) {
      analyser.getFloatTimeDomainData(aBuf);
      var s = 0;
      for (var k = 0; k < aBuf.length; k++) s += aBuf[k] * aBuf[k];
      var rms = Math.sqrt(s / aBuf.length);
      var now2 = performance.now();
      if (aQuiet && rms > 0.02 && now2 - lastAOn > 300) { aOn.push(now2); lastAOn = now2; aQuiet = false; }
      if (rms < 0.006) aQuiet = true;
    }
    render(v);
    requestAnimationFrame(tick);
  }

  function render(v) {
    var edge = '?';
    try {
      if (v && v.seekable && v.seekable.length) edge = (v.seekable.end(v.seekable.length - 1) - v.currentTime).toFixed(1) + 's';
    } catch (e) {}
    var pp = v ? String(v.preservesPitch !== undefined ? v.preservesPitch : v.webkitPreservesPitch) : '?';
    var lines = [
      'RATE-LAB  rate=' + (v ? v.playbackRate.toFixed(2) : '?')
        + '  preservesPitch=' + pp
        + '  t=' + (v ? v.currentTime.toFixed(1) : '?')
        + '  to-edge=' + edge
        + (burstTimer ? '  [BURST ACTIVE]' : ''),
      'A/V offset (audio late): ' + (best
        ? '~' + best.lag + ' ms  (matched ' + best.matched + '/' + best.of + ' beeps over 60s)'
        : 'measuring... flashes=' + vOn.length + ' beeps=' + aOn.length)
        + '   audio tap: ' + tapNote,
    ];
    readout.innerHTML = lines.map(function (s) { return String(s).replace(/</g, '&lt;'); }).join('<br>');
  }
  requestAnimationFrame(tick);
})();
