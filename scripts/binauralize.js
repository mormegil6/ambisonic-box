// Drives scripts/binauralize.html to render every 16-channel study WAV to
// binaural stereo through HOAST360's own (corrected) decoder, for BAM-Q.
//
// BAM-Q needs stereo; the study material is 16-channel ambisonic. Rendering
// through the player's real decoder - rather than a generic ambisonic-to-
// binaural tool - makes the fixed renderer a controlled constant AND keeps the
// measurement about the system that actually ships.
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const WORK = process.env.WORK || 'aac-bitrate-test/work';
const OUT = process.env.OUTDIR || 'aac-bitrate-test/binaural';
const ITEMS = (process.env.ITEMS || 'piano orchestra deusexmachina carnival quarry').split(/\s+/);
const CONDS = (process.env.CONDS || 'ref aac96 aac128 casc96 casc128').split(/\s+/);
// 'buggy' renders reproduce upstream's decode so the defect can be measured.
// Only the pristine reference needs it: comparing ref-fixed against ref-buggy
// isolates the decoder bug with no codec confound in the way.
const MODES = (process.env.MODES || 'fixed').split(/\s+/);
const BUGGY_CONDS = (process.env.BUGGY_CONDS || 'ref').split(/\s+/);

function writeWav(file, left, right, sampleRate) {
    const n = left.length;
    const buf = Buffer.alloc(44 + n * 4);           // 16-bit stereo
    buf.write('RIFF', 0); buf.writeUInt32LE(36 + n * 4, 4); buf.write('WAVE', 8);
    buf.write('fmt ', 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
    buf.writeUInt16LE(2, 22); buf.writeUInt32LE(sampleRate, 24);
    buf.writeUInt32LE(sampleRate * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34);
    buf.write('data', 36); buf.writeUInt32LE(n * 4, 40);
    let o = 44, clipped = 0;
    for (let i = 0; i < n; i++) {
        for (const v of [left[i], right[i]]) {
            let s = Math.max(-1, Math.min(1, v));
            if (v > 1 || v < -1) clipped++;
            buf.writeInt16LE(Math.round(s * 32767), o); o += 2;
        }
    }
    fs.writeFileSync(file, buf);
    return clipped;
}

(async () => {
    fs.mkdirSync(OUT, { recursive: true });
    const browser = await chromium.launch();
    const page = await browser.newPage();
    page.on('pageerror', e => console.log('  [pageerror]', e.message));
    await page.goto((process.env.BASE || 'http://127.0.0.1:8099') + '/scripts/binauralize.html',
                    { waitUntil: 'domcontentloaded' });

    // HEADROOM, applied per item across all of its conditions at once.
    // The binaural render can exceed full scale on loud material, and clipping
    // is a nonlinear distortion baked into the 16-bit file that no later
    // rescaling undoes - BAM-Q would then be scoring clipping rather than the
    // codec. One scale factor per ITEM, never per file: the whole measurement
    // is a comparison between an item's conditions, so they must all be moved
    // by the same amount. (This surfaced when the study's excerpts were fixed
    // to be content-selected rather than cut at offset 0; the old excerpts were
    // quiet enough never to reach full scale, so the harness never clipped.)
    let totalClipped = 0;
    for (const item of ITEMS) {
        const rendered = [];
        for (const mode of MODES) {
            const conds = mode === 'buggy' ? BUGGY_CONDS : CONDS;
            for (const cond of conds) {
                const src = `${WORK}/${item}_${cond}.wav`;
                if (!fs.existsSync(src)) { console.log(`  MISSING ${src}`); continue; }
                const url = `${process.env.BASE || 'http://127.0.0.1:8099'}/${src}`;
                const r = await page.evaluate(([u, m]) => window.binauralize(u, m), [url, mode]);
                rendered.push({ cond, mode, r });
            }
        }
        let peak = 0;
        for (const { r } of rendered)
            for (const ch of [r.left, r.right])
                for (const v of ch) { const a = Math.abs(v); if (a > peak) peak = a; }
        const scale = peak > 0.99 ? 0.99 / peak : 1;
        if (scale !== 1)
            console.log(`  ${item.padEnd(14)} peak ${peak.toFixed(3)} -> scaling all conditions by ${scale.toFixed(4)} (${(20 * Math.log10(scale)).toFixed(2)} dB)`);
        for (const { cond, mode, r } of rendered) {
            const suffix = mode === 'fixed' ? '' : '_buggy';
            const dst = path.join(OUT, `${item}_${cond}${suffix}_binaural.wav`);
            const L = scale === 1 ? r.left : r.left.map(v => v * scale);
            const R = scale === 1 ? r.right : r.right.map(v => v * scale);
            const clipped = writeWav(dst, L, R, r.sampleRate);
            totalClipped += clipped;
            console.log(`  ${item.padEnd(14)} ${(cond + '/' + mode).padEnd(14)} -> ` +
                        `${path.basename(dst).padEnd(38)} ${r.length} @ ${r.sampleRate}` +
                        `${clipped ? `  CLIPPED ${clipped}` : ''}`);
        }
    }
    if (totalClipped) console.log(`\n  WARNING: ${totalClipped} clipped samples total`);
    else console.log('\n  no clipping');
    await browser.close();
})();
