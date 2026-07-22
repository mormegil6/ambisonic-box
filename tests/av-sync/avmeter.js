(function () {
  // Frequency-identified A/V offset meter, alias-free.
  //
  // For each beep heard at masterGain: measure its dominant frequency F, then
  // locate the onset of tone F inside the DECODED audio segment content around
  // the playhead (segments fetched + decoded independently, content times from
  // WebM cluster timestamps). offset = el.currentTime(at detection) - t_content.
  // No video sampling, no periodic-event aliasing: F identifies the beep.
  var panel = document.createElement('div');
  panel.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:99999;background:rgba(0,0,0,.92);color:#eee;'
    + 'font:13px/1.5 ui-monospace,monospace;padding:8px 12px;border-bottom:2px solid #09f;white-space:pre-wrap';
  function attach(){ if (document.body && !panel.parentNode) document.body.appendChild(panel); }
  document.addEventListener('DOMContentLoaded', attach); attach();

  var pad5 = function (n) { return String(n).padStart(5, '0'); };
  var segUrl = function (n) { return '/dash/chunk-stream1-' + pad5(n) + '.webm'; };
  function videoEl() {
    return document.getElementById('hoast360-player_html5_api') || document.querySelector('video');
  }

  // ---- EBML helpers (same logic as the feed) ----
  function timecodeScale(bytes) {
    bytes = new Uint8Array(bytes);
    for (var i = 0; i < bytes.length - 4; i++)
      if (bytes[i] === 0x2A && bytes[i+1] === 0xD7 && bytes[i+2] === 0xB1) {
        var size = bytes[i+3] & 0x7F;
        if ((bytes[i+3] & 0x80) && size >= 1 && size <= 4) {
          var v = 0; for (var j = 0; j < size; j++) v = v * 256 + bytes[i+4+j];
          if (v > 0) return v;
        }
      }
    return 1000000;
  }
  function clusterTS(bytes, tc) {
    bytes = new Uint8Array(bytes);
    for (var i = 0; i < bytes.length - 8; i++)
      if (bytes[i] === 0x1F && bytes[i+1] === 0x43 && bytes[i+2] === 0xB6 && bytes[i+3] === 0x75) {
        var first = bytes[i+4], l = 1, m = 0x80;
        while (m > 0 && !(first & m)) { m >>= 1; l++; }
        var p = i + 4 + l;
        if (bytes[p] === 0xE7) {
          var sf = bytes[p+1], sl = 1, sm = 0x80;
          while (sm > 0 && !(sf & sm)) { sm >>= 1; sl++; }
          if (sl <= 2) {
            var size = sf & (0xFF >> sl);
            for (var j = 1; j < sl; j++) size = size * 256 + bytes[p+1+j];
            var v = 0; for (var k = 0; k < size; k++) v = v * 256 + bytes[p+1+sl+k];
            return v * tc / 1e9;
          }
        }
        return null;
      }
    return null;
  }

  // ---- segment content cache ----
  var dctx = null, initBuf = null, tcScale = 1000000;
  var mpdInfo = null;   // { startNumber, t0, segdur }
  var segCache = new Map();  // n -> { t: contentStartS, data: Float32Array(ch0), sr } | 'pending' | 'failed'
  var results = [];     // { f, tContent, elT, offset }
  var status = 'boot';

  async function loadMpdInfo() {
    var mpd = await fetch('/dash/hoast_demo.mpd', { cache: 'no-store' }).then(function (r) { return r.text(); });
    var audio = (mpd.match(/<AdaptationSet[^>]*contentType="audio"[\s\S]*?<\/AdaptationSet>/) || [''])[0];
    var sn = +((audio.match(/startNumber="(\d+)"/) || [0, 1])[1]);
    var ts = +((audio.match(/timescale="(\d+)"/) || [0, 1000])[1]);
    var tm = audio.match(/<S t="(\d+)" d="(\d+)"/);
    mpdInfo = { startNumber: sn, t0: tm ? (+tm[1]) / ts : 0, segdur: tm ? (+tm[2]) / ts : 5 };
  }

  async function ensureInit() {
    if (initBuf) return;
    initBuf = await fetch('/dash/init-stream1.webm', { cache: 'no-store' }).then(function (r) { return r.arrayBuffer(); });
    tcScale = timecodeScale(initBuf);
  }

  function concat(a, b) {
    var u = new Uint8Array(a.byteLength + b.byteLength);
    u.set(new Uint8Array(a), 0); u.set(new Uint8Array(b), a.byteLength);
    return u.buffer;
  }

  async function ensureSegAround(mediaT) {
    if (!mpdInfo) return;
    var n0 = Math.round(mpdInfo.startNumber + (mediaT - mpdInfo.t0) / mpdInfo.segdur);
    for (var n = n0 - 1; n <= n0 + 1; n++) {
      if (n < 1 || segCache.has(n)) continue;
      segCache.set(n, 'pending');
      (async function (num) {
        try {
          await ensureInit();
          var seg = await fetch(segUrl(num), { cache: 'no-store' }).then(function (r) {
            if (!r.ok) throw new Error('404'); return r.arrayBuffer();
          });
          var t = clusterTS(seg, tcScale);
          if (!dctx) dctx = new (window.AudioContext || window.webkitAudioContext)();
          var ab = await dctx.decodeAudioData(concat(initBuf, seg));
          segCache.set(num, { t: (t != null ? t : NaN), data: ab.getChannelData(0).slice(0), sr: ab.sampleRate });
        } catch (e) { segCache.set(num, 'failed'); }
      })(n);
    }
    // prune far entries
    segCache.forEach(function (v, k) {
      if (v && v !== 'pending' && v !== 'failed' && Math.abs(v.t - mediaT) > 30) segCache.delete(k);
    });
  }

  // Goertzel power of frequency f over data[off..off+len)
  function goertzel(data, off, len, f, sr) {
    var w = 2 * Math.PI * f / sr, c = 2 * Math.cos(w), s0 = 0, s1 = 0, s2 = 0;
    for (var i = 0; i < len; i++) { s0 = data[off + i] + c * s1 - s2; s2 = s1; s1 = s0; }
    return s1 * s1 + s2 * s2 - c * s1 * s2;
  }

  // find the onset of tone f in the cached content near mediaT; returns absolute content time or null
  function locateTone(f, mediaT) {
    var best = null;
    segCache.forEach(function (v) {
      if (!v || v === 'pending' || v === 'failed' || isNaN(v.t)) return;
      if (v.t > mediaT + 6 || v.t + v.data.length / v.sr < mediaT - 6) return;
      var win = Math.round(0.046 * v.sr), hop = Math.round(0.023 * v.sr);
      var powers = [];
      for (var off = 0; off + win < v.data.length; off += hop) powers.push(goertzel(v.data, off, win, f, v.sr));
      var max = Math.max.apply(null, powers);
      if (max <= 0) return;
      var th = max * 0.25;
      for (var i = 1; i < powers.length; i++) {
        if (powers[i] > th && powers[i - 1] <= th) {
          var t = v.t + (i * hop) / v.sr;
          if (Math.abs(t - mediaT) < 6 && (best === null || Math.abs(t - mediaT) < Math.abs(best - mediaT)))
            best = t;
          break; // first onset in this segment
        }
      }
    });
    return best;
  }

  // ---- analyser: onset + frequency ----
  var analyser = null, freqBuf = null, timeBuf = null, aQuiet = true, lastOn = 0, tap = 'waiting';
  function tryTap() {
    if (analyser) return;
    var h = window.hoast360;
    if (!h || !h.context || !h.masterGain || typeof h.masterGain.connect !== 'function') return;
    analyser = h.context.createAnalyser();
    analyser.fftSize = 4096;
    analyser.smoothingTimeConstant = 0;
    timeBuf = new Float32Array(analyser.fftSize);
    freqBuf = new Float32Array(analyser.frequencyBinCount);
    h.masterGain.connect(analyser);
    tap = 'masterGain';
  }
  setInterval(tryTap, 500);

  var pendingBeep = null; // { elT, at }
  function tick() {
    var v = videoEl();
    if (analyser && v) {
      analyser.getFloatTimeDomainData(timeBuf);
      var s = 0;
      for (var i = 0; i < timeBuf.length; i += 4) s += timeBuf[i] * timeBuf[i];
      var rms = Math.sqrt(s / (timeBuf.length / 4));
      var now = performance.now();
      if (aQuiet && rms > 0.02 && now - lastOn > 400) {
        aQuiet = false; lastOn = now;
        pendingBeep = { elT: v.currentTime, at: now };  // el clock captured AT onset
      }
      if (rms < 0.006) aQuiet = true;
      // 150 ms after onset the tone is steady: read its frequency, resolve content time
      if (pendingBeep && now - pendingBeep.at > 150) {
        var pb = pendingBeep; pendingBeep = null;
        analyser.getFloatFrequencyData(freqBuf);
        var sr = window.hoast360.context.sampleRate;
        var lo = Math.round(200 / (sr / analyser.fftSize)), hi = Math.round(4000 / (sr / analyser.fftSize));
        var bi = lo;
        for (var b = lo; b <= hi; b++) if (freqBuf[b] > freqBuf[bi]) bi = b;
        var f = bi * sr / analyser.fftSize;
        var tc = locateTone(f, pb.elT);
        if (tc != null) {
          var off = pb.elT - tc; // positive: audio late
          results.push({ f: Math.round(f), tContent: Math.round(tc * 100) / 100, elT: Math.round(pb.elT * 100) / 100, offsetMs: Math.round(off * 1000), wall: Math.round(pb.at) });
          if (results.length > 40) results.shift();
        } else {
          results.push({ f: Math.round(f), tContent: null, elT: Math.round(pb.elT * 100) / 100, offsetMs: null });
          if (results.length > 40) results.shift();
        }
      }
      ensureSegAround(v.currentTime);
    }
    render(v);
    requestAnimationFrame(tick);
  }

  function median(arr) {
    if (!arr.length) return null;
    var s = arr.slice().sort(function (a, b) { return a - b; });
    return s[Math.floor(s.length / 2)];
  }

  window.__avmeter2 = function () {
    var ok = results.filter(function (r) { return r.offsetMs != null; });
    var feed = null;
    try { feed = window.__hoastAudioFeed ? window.__hoastAudioFeed() : null; } catch (e) {}
    return {
      medianOffsetMs: median(ok.map(function (r) { return r.offsetMs; })),
      n: ok.length, unresolved: results.length - ok.length,
      recent: results.slice(-6), tap: tap,
      segsCached: segCache.size, feed: feed,
    };
  };

  function render(v) {
    var m = window.__avmeter2();
    panel.textContent =
      'FREQ-METER  t=' + (v ? v.currentTime.toFixed(1) : '?') + '  tap=' + tap + '  segs=' + m.segsCached + '\n'
      + 'offset (audio late, content-identified): ' + (m.medianOffsetMs != null ? m.medianOffsetMs + ' ms  (n=' + m.n + ', unresolved=' + m.unresolved + ')' : 'measuring...') + '\n'
      + 'recent: ' + m.recent.map(function (r) { return r.f + 'Hz->' + (r.offsetMs != null ? r.offsetMs + 'ms' : '?'); }).join('  ') + '\n'
      + 'feed: ' + (m.feed ? m.feed.state + ' drift=' + (m.feed.drift != null ? Math.round(m.feed.drift * 1000) : '?') + 'ms ahead=' + Math.round((m.feed.scheduledAheadSec || 0) * 10) / 10 + 's resyncs=' + m.feed.counters.resyncs : 'none');
  }

  loadMpdInfo().catch(function () {});
  requestAnimationFrame(tick);
})();
