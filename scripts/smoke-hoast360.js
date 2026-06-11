/* Headless smoke test for the modernised HOAST360 player (Phase 1 verification).
 *
 * Serves hoast360/ with http-server, loads index.html in headless Chromium with
 * real autoplay policy (--autoplay-policy=user-gesture-required), starts the
 * committed order-4 demo and verifies:
 *   - no console/page errors,
 *   - AudioContext is 'running' after the play gesture (audit issue C1),
 *   - audio and video clocks both advance (dashjs 4.7.4 + contrib-dash path),
 *   - mouse drag on the canvas updates the HOA rotation matrix,
 *   - stop/load reset cycle survives.
 *
 * Prerequisites (one-time):
 *   cd hoa-360-stream && npm init -y && npm i -D playwright-core@^1.60
 *   npx playwright install chromium
 *   sudo npx playwright install-deps chromium   # system libs (libnspr4, libnss3, ...)
 *
 * Run: node scripts/smoke-hoast360.js
 */
const { chromium } = require('playwright-core');
const { spawn } = require('child_process');
const path = require('path');

const ROOT = path.join(__dirname, '..', 'hoast360');
const PORT = 8889;

(async () => {
    const server = spawn('npx', ['http-server', ROOT, '-p', String(PORT), '-s', '--cors'], {
        cwd: ROOT, stdio: 'ignore'
    });
    await new Promise(r => setTimeout(r, 2000));

    const browser = await chromium.launch({
        headless: true,
        args: ['--autoplay-policy=user-gesture-required', '--mute-audio']
    });
    const page = await browser.newPage();

    const errors = [];
    const warnings = [];
    page.on('console', msg => {
        if (msg.type() === 'error') errors.push('[console.error] ' + msg.text());
        if (msg.type() === 'warning') warnings.push('[console.warn] ' + msg.text());
    });
    page.on('pageerror', err => errors.push('[pageerror] ' + err.message));
    page.on('requestfailed', req => {
        if (!req.url().includes('favicon')) errors.push('[requestfailed] ' + req.url() + ' ' + req.failure().errorText);
    });

    try {
        await page.goto(`http://localhost:${PORT}/index.html`, { waitUntil: 'load', timeout: 30000 });

        const support = await page.evaluate(() => ({
            opusMp4: MediaSource.isTypeSupported('audio/mp4; codecs="opus"'),
            opusWebm: MediaSource.isTypeSupported('audio/webm; codecs="opus"'),
            global: typeof HOAST360,
            ctxState: hoast360.context.state,
            opusSupport: hoast360.opusSupport
        }));
        console.log('page loaded:', JSON.stringify(support));

        await page.click('button:has-text("load")');
        await page.waitForFunction(() => window.hoast360 && hoast360.audioSetupComplete === true, null, { timeout: 30000 });
        console.log('xr initialized, audio graph set up');

        const graph = await page.evaluate(() => ({
            ctxStateBeforePlay: hoast360.context.state,
            order: hoast360.order,
            numCh: hoast360.numCh,
            convolvers: hoast360.decoder.decFilterNodes.length,
            zoomEnabled: hoast360.zoomEnabled
        }));
        console.log('graph:', JSON.stringify(graph));

        // wait for PlaybackEventHandler to declare readiness (big play button shown)
        await page.waitForFunction(() =>
            document.querySelector('.vjs-big-vr-play-button') &&
            getComputedStyle(document.querySelector('.vjs-big-vr-play-button')).display !== 'none',
            null, { timeout: 60000 });
        await page.click('.vjs-big-vr-play-button');
        console.log('clicked play');

        await page.waitForFunction(() => hoast360.context.state === 'running', null, { timeout: 15000 });
        console.log('AudioContext running after play gesture');

        await page.waitForFunction(() => {
            const v = document.querySelector('video');
            return v && v.currentTime > 0.5 && hoast360.audioElement.currentTime > 0.5;
        }, null, { timeout: 30000 });
        const clocks = await page.evaluate(() => ({
            video: document.querySelector('video').currentTime,
            audio: hoast360.audioElement.currentTime
        }));
        console.log('A/V clocks advancing:', JSON.stringify(clocks));

        // drag on the three.js canvas → camera change → rotator matrix update
        const canvas = await page.$('.video-js canvas');
        const box = await canvas.boundingBox();
        const before = await page.evaluate(() => JSON.stringify(hoast360.rotator.rotMtx[1]));
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.down();
        await page.mouse.move(box.x + box.width / 2 + 120, box.y + box.height / 2 + 40, { steps: 10 });
        await page.mouse.up();
        await page.waitForTimeout(500);
        const after = await page.evaluate(() => JSON.stringify(hoast360.rotator.rotMtx[1]));
        console.log('rotator matrix changed after drag:', before !== after);

        // stop/reset cycle
        await page.click('button:has-text("stop")');
        await page.waitForTimeout(1000);
        console.log('reset OK');

        console.log('\n=== console errors:', errors.length);
        errors.forEach(e => console.log('  ' + e));
        console.log('=== console warnings:', warnings.length);
        warnings.slice(0, 10).forEach(w => console.log('  ' + w));

        if (errors.length === 0 && before !== after) {
            console.log('\nSMOKE TEST: PASS');
        } else {
            console.log('\nSMOKE TEST: ' + (errors.length ? 'ERRORS LOGGED (see above)' : 'ROTATOR DID NOT UPDATE'));
            process.exitCode = 1;
        }
    } catch (e) {
        console.log('SMOKE TEST: FAIL :', e.message);
        errors.forEach(er => console.log('  ' + er));
        process.exitCode = 1;
    } finally {
        await browser.close();
        server.kill();
    }
})();
