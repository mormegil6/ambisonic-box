(function () {
  // On-screen substitute for the mobile console: capture errors + sample the
  // player's OWN live <video> element into a WebGL overlay, so we can see whether
  // the real live video is sampleable while the sphere is black.
  var errors = [];
  function logErr(m) { errors.push(m); if (errors.length > 12) errors.shift(); }
  window.addEventListener('error', function (e) {
    logErr('ERR ' + (e.message || e.type) + (e.filename ? ' @' + String(e.filename).split('/').pop() + ':' + e.lineno : ''));
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason; logErr('REJECT ' + ((r && (r.message || r)) || 'unknown'));
  });
  var _ce = console.error;
  console.error = function () {
    try { logErr('console.error ' + Array.prototype.map.call(arguments, String).join(' ').slice(0, 220)); } catch (_) {}
    return _ce.apply(console, arguments);
  };

  var box = document.createElement('div');
  box.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:99999;background:rgba(0,0,0,.88);color:#eee;'
    + 'font:12px/1.4 ui-monospace,monospace;padding:8px 10px;max-height:60vh;overflow:auto;border-bottom:2px solid #0a4';
  var mycanvas = document.createElement('canvas'); mycanvas.width = 96; mycanvas.height = 48;
  mycanvas.style.cssText = 'width:128px;height:64px;border:1px solid #0a4;float:right;margin:0 0 6px 8px;background:#000';
  var cap = document.createElement('div'); cap.textContent = 'my GL sample'; cap.style.cssText = 'float:right;clear:right;font-size:10px;color:#888;width:128px;text-align:center';
  box.appendChild(mycanvas); box.appendChild(cap);
  var txt = document.createElement('div'); box.appendChild(txt);
  function attach() { if (document.body && !box.parentNode) document.body.appendChild(box); }
  document.addEventListener('DOMContentLoaded', attach); attach();

  var gl = mycanvas.getContext('webgl', { preserveDrawingBuffer: true }), tex;
  if (gl) {
    var sh = function (t, s) { var o = gl.createShader(t); gl.shaderSource(o, s); gl.compileShader(o); return o; };
    var prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, 'attribute vec2 p;varying vec2 uv;void main(){uv=vec2((p.x+1.0)/2.0,1.0-(p.y+1.0)/2.0);gl_Position=vec4(p,0.0,1.0);}'));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, 'precision mediump float;varying vec2 uv;uniform sampler2D t;void main(){gl_FragColor=texture2D(t,uv);}'));
    gl.linkProgram(prog); gl.useProgram(prog);
    var b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,1,1]), gl.STATIC_DRAW);
    var loc = gl.getAttribLocation(prog, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  }
  var myMax = 0;
  function sampleVideo(v) {
    if (!gl || !v || v.readyState < 2 || !v.videoWidth) return null;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    try { gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, v); }
    catch (e) { return 'texImage2D THREW: ' + (e.name || e); }
    gl.viewport(0, 0, 96, 48); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    var e2 = gl.getError(); if (e2) return 'glError ' + e2;
    var px = new Uint8Array(96 * 48 * 4); gl.readPixels(0, 0, 96, 48, gl.RGBA, gl.UNSIGNED_BYTE, px);
    var s = 0; for (var i = 0; i < px.length; i += 4) s += 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
    var l = s / (96 * 48); if (l > myMax) myMax = l; return l;
  }

  var c2 = document.createElement('canvas'); c2.width = 96; c2.height = 48; var ctx2 = c2.getContext('2d');
  var pcMax = 0;
  function canvasLuma(cv) {
    if (!cv || !ctx2) return null;
    try {
      ctx2.drawImage(cv, 0, 0, 96, 48);
      var d = ctx2.getImageData(0, 0, 96, 48).data; var s = 0;
      for (var i = 0; i < d.length; i += 4) s += 0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2];
      var l = s / (96 * 48); if (l > pcMax) pcMax = l; return l;
    } catch (e) { return 'draw ' + (e.name || e); }
  }

  function tick() {
    var v = document.getElementById('hoast360-player_html5_api') || document.querySelector('.video-js video') || document.querySelector('video');
    var cv = null, cs = document.querySelectorAll('canvas');
    for (var i = 0; i < cs.length; i++) { if (cs[i] !== mycanvas) { cv = cs[i]; break; } }
    var L = [];
    if (v) {
      var l = sampleVideo(v);
      L.push('video ' + v.videoWidth + 'x' + v.videoHeight + ' t=' + (v.currentTime || 0).toFixed(1) + ' rs=' + v.readyState + ' paused=' + v.paused + (v.error ? ' MediaErr' + v.error.code : ''));
      L.push('MY GL sample luma ' + (typeof l === 'number' ? l.toFixed(1) : l) + '  (max ' + myMax.toFixed(1) + ')' + (myMax >= 8 ? '  <-- video IS sampleable' : ''));
    } else {
      L.push('player video: NOT FOUND yet - start the stream & wait');
    }
    if (cv) {
      var pl = canvasLuma(cv);
      L.push('player canvas ' + cv.width + 'x' + cv.height + ' css ' + cv.clientWidth + 'x' + cv.clientHeight + ' luma ' + (typeof pl === 'number' ? pl.toFixed(1) : pl) + ' (max ' + pcMax.toFixed(1) + ')');
    } else {
      L.push('player canvas: none yet');
    }
    L.push('errors(' + errors.length + '): ' + (errors.slice(-6).join('  |  ') || 'none'));
    txt.innerHTML = L.map(function (s) { return String(s).replace(/</g, '&lt;'); }).join('<br>');
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
})();
