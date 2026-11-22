// Local reverse proxy: serves the production VOD page, with the colortones fixtures (and optionally another player bundle) substituted.
import http from 'http'; import fs from 'fs'; import path from 'path'; import { createRequire } from 'module';
const require = createRequire(import.meta.url); const { INSTRUMENT } = require('./page-probes.cjs');
const here = path.dirname(new URL(import.meta.url).pathname);
export function startProxy({ port, clip, bundle, base = 'https://stream.bmroz.eu' }) {
  const fx = path.join(here, 'fx-' + clip);
  const server = http.createServer(async (req, res) => {
    try {
      const u = new URL(req.url, 'http://x');
      const iso = { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-store' };
      if (u.pathname.startsWith('/vod-dash/colortones/') && !u.pathname.endsWith('.vtt')) {
        const name = u.pathname.split('/').pop(); const f = path.join(fx, name === 'colortones.mpd' ? 'vod.mpd' : name);
        if (!fs.existsSync(f)) { res.writeHead(404, iso); return res.end(); }
        const buf = fs.readFileSync(f);
        res.writeHead(200, { ...iso, 'Content-Type': f.endsWith('.mpd') ? 'application/dash+xml' : 'video/mp4', 'Content-Length': buf.length, 'Accept-Ranges': 'none' });
        return res.end(req.method === 'HEAD' ? undefined : buf);
      }
      if (bundle && u.pathname === '/dist/hoast360.bundle.js') {
        const buf = fs.readFileSync(bundle);
        res.writeHead(200, { ...iso, 'Content-Type': 'application/javascript', 'Content-Length': buf.length }); return res.end(buf);
      }
      const headers = {}; for (const h of ['accept', 'accept-language', 'range', 'user-agent']) if (req.headers[h]) headers[h] = req.headers[h];
      const r = await fetch((base || 'https://stream.bmroz.eu') + req.url, { method: req.method, headers, redirect: 'manual' });
      const out = {}; r.headers.forEach((v, k) => { if (!['content-encoding', 'content-length', 'transfer-encoding', 'connection', 'strict-transport-security'].includes(k)) out[k] = v; });
      let body = Buffer.from(await r.arrayBuffer());
      if (u.pathname === '/brand.json') {   // keep VOD same-origin (production offloads it to vod.bmroz.eu) and send no analytics beacon
        try { const j = JSON.parse(body.toString('utf8')); delete j.vodBase; delete j.webAnalyticsToken; body = Buffer.from(JSON.stringify(j)); } catch (_) {}
      }
      if (u.pathname.startsWith('/vod') && (r.headers.get('content-type') || '').includes('text/html')) {
        body = Buffer.from(body.toString('utf8').replace('<head>', '<head><script>' + INSTRUMENT + '</script>'));
      }
      res.writeHead(r.status, { ...out, 'Content-Length': body.length }); res.end(req.method === 'HEAD' ? undefined : body);
    } catch (e) { res.writeHead(502); res.end(String(e)); }
  });
  return new Promise(ok => server.listen(port, '127.0.0.1', () => ok(server)));
}
