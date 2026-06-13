/* Phase 5 lip-sync / segment-duration measurement.
 *
 * Drives lip-sync-test/index.html in headless Chromium and measures, for each
 * DASH variant (0.5 s / 1 s / 2 s / 4 s segments):
 *   - startup latency (play() -> clock advancing)
 *   - playback ratio (video clock vs wall clock) and stall count
 *   - dropped/decoded frames
 *   - dash.js buffer levels per track and the audio-video buffer delta
 *
 * NOTE on "A/V offset": the variants are combined MPDs, so audio and video
 * play through ONE media element; MSE keeps them locked to the same clock,
 * and the lip-sync offset a viewer experiences is whatever timestamp offset
 * the packaging baked in. That part is measured statically with ffprobe by
 * scripts/package-dash-variants.sh's companion check in the Phase 5 report
 * (audio vs video start_time per variant); this script measures the dynamic
 * playback behaviour that the segment duration actually changes.
 *
 * Prerequisites: npm i -D playwright-core http-server (repo root), variants
 * packaged into lip-sync-test/dash_*s/ first.
 *
 * Run: node scripts/measure-lipsync.js
 */
const { chromium } = require('playwright-core');
const { spawn } = require('child_process');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'lip-sync-test');
const PORT = 8890;
const VARIANTS = ['0.5s', '1s', '2s', '4s'];
const SAMPLE_SECONDS = 20;

(async () => {
    // python3 http.server on purpose: it is the documented way to serve this
    // page and it does NOT support Range requests; packaging must therefore
    // use discrete segments (SegmentTemplate), never SegmentBase byte ranges.
    const server = spawn('python3', ['-m', 'http.server', String(PORT)], {
        cwd: ROOT, stdio: 'ignore'
    });
    await new Promise(r => setTimeout(r, 2000));

    const browser = await chromium.launch({
        headless: true,
        args: ['--autoplay-policy=user-gesture-required', '--mute-audio']
    });

    const results = [];
    const errors = [];
    try {
        for (const variant of VARIANTS) {
            // fresh page per variant: no reset() teardown noise, no cold-start
            // bias on the first tab, independent MSE state
            const page = await browser.newPage();
            page.on('console', m => { if (m.type() === 'error') errors.push(`[${variant}] ` + m.text()); });
            page.on('pageerror', e => errors.push(`[${variant}][pageerror] ` + e.message));
            await page.goto(`http://localhost:${PORT}/index.html`, { waitUntil: 'load', timeout: 30000 });
            await page.click(`#tabs button[data-variant="${variant}"]`);
            await page.waitForFunction(() => window.hoast360 && hoast360.audioSetupComplete === true,
                null, { timeout: 30000 });

            // fresh per-variant stall counter on the tech element
            await page.evaluate(() => {
                const v = document.querySelector('#hoast360-player video');
                window.__stalls = 0;
                v.addEventListener('waiting', () => { window.__stalls++; });
            });

            const t0 = Date.now();
            await page.evaluate(() => hoast360.videoPlayer.play());
            await page.waitForFunction(() => {
                const v = document.querySelector('#hoast360-player video');
                return v && v.currentTime > 0.1;
            }, null, { timeout: 30000 });
            const startupMs = Date.now() - t0;

            // sample clocks + buffers
            const s0 = await page.evaluate(() => {
                const v = document.querySelector('#hoast360-player video');
                const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
                return { video: v.currentTime, ctx: hoast360.context.currentTime,
                         dropped: q.droppedVideoFrames || 0, total: q.totalVideoFrames || 0,
                         wall: Date.now() };
            });
            const bufSamples = [];
            for (let i = 0; i < SAMPLE_SECONDS; i++) {
                await page.waitForTimeout(1000);
                bufSamples.push(await page.evaluate(() => {
                    let bv = NaN, ba = NaN;
                    try {
                        const mp = hoast360.videoPlayer.dash &&
                                   hoast360.videoPlayer.dash.mediaPlayer;
                        if (mp) { bv = mp.getBufferLength('video'); ba = mp.getBufferLength('audio'); }
                    } catch (e) { /* keep NaN */ }
                    const v = document.querySelector('#hoast360-player video');
                    return { t: v.currentTime, bv, ba };
                }));
            }
            const s1 = await page.evaluate(() => {
                const v = document.querySelector('#hoast360-player video');
                const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
                return { video: v.currentTime, ctx: hoast360.context.currentTime,
                         dropped: q.droppedVideoFrames || 0, total: q.totalVideoFrames || 0,
                         wall: Date.now(), stalls: window.__stalls };
            });

            const wall = (s1.wall - s0.wall) / 1000;
            const mean = a => a.length ? a.reduce((x, y) => x + y, 0) / a.length : NaN;
            const bvs = bufSamples.map(s => s.bv).filter(Number.isFinite);
            const bas = bufSamples.map(s => s.ba).filter(Number.isFinite);
            const deltas = bufSamples.filter(s => Number.isFinite(s.bv) && Number.isFinite(s.ba))
                                     .map(s => s.bv - s.ba);
            results.push({
                variant,
                startupMs,
                playbackRatio: +((s1.video - s0.video) / wall).toFixed(3),
                stalls: s1.stalls,
                droppedFrames: s1.dropped - s0.dropped,
                decodedFrames: s1.total - s0.total,
                bufVideoMean: +mean(bvs).toFixed(2),
                bufAudioMean: +mean(bas).toFixed(2),
                bufAVDeltaMean: +mean(deltas).toFixed(2)
            });
            console.log(JSON.stringify(results[results.length - 1]));
            await page.close();
        }

        console.log('\n=== summary ===');
        console.table ? console.table(results) : console.log(results);
        console.log('console errors:', errors.length);
        errors.slice(0, 10).forEach(e => console.log('  ' + e.slice(0, 160)));
        if (errors.length) process.exitCode = 1;
    } catch (e) {
        console.log('MEASUREMENT FAIL :', e.message);
        errors.slice(0, 10).forEach(x => console.log('  ' + x.slice(0, 160)));
        process.exitCode = 1;
    } finally {
        await browser.close();
        server.kill();
    }
})();
