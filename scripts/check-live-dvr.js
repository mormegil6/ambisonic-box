#!/usr/bin/env node
//
// Behavioural check on the LIVE DVR window: seek to the very back of the
// advertised seekable range and assert the player recovers.
//
// WHY. On 2026-08-08 the back of the scrub bar was a trap. The dash muxer had
// no -seg_duration, so it targeted its 5 s default: Opus cut at exactly 5.000 s
// while video under -c:v copy could only close on a keyframe, giving 6.006 s
// video segments against the 2.002 s contribution GOP. -window_size counts
// SEGMENTS, not seconds, so the retained windows were 600.6 s of video and
// 499.4 s of audio. dash.js derives video.seekable from the video timeline, so
// roughly 100 s of the bar advertised time whose audio segments had already
// been pruned. Seeking there killed playback: readyState 1, buffered empty,
// currentTime frozen, paused false, video.error NULL, and no failed request.
// Nothing surfaced. A config review cannot see this; only a seek can.
//
// WHAT IT ASSERTS. Seek near seekable.start, then require that currentTime
// advances and readyState climbs back. It deliberately does NOT assert on
// segment durations or manifest contents: those are the current mechanism, and
// a check written against a mechanism stops finding the bug the day the
// mechanism changes. The failure mode is "the player wedges", so that is what
// is measured.
//
// Usage:  node scripts/check-live-dvr.js [url] [--verbose]
// Exits non-zero on failure, so it drops straight into CI.
//
// NOTE the live stream must actually be publishing, and the DVR window needs
// time to fill: telemetry idles the demo loop out after 10 minutes with no
// viewers, and a freshly started stream has only a few seconds of history. The
// check reports SKIP (exit 0) rather than failing if there is too little window
// to seek into, because "nothing was streaming" is not the same as "broken".

const { chromium } = require('playwright-core');

const URL = process.argv[2] && !process.argv[2].startsWith('--')
  ? process.argv[2] : 'http://127.0.0.1:8080/';
const VERBOSE = process.argv.includes('--verbose');

const SETTLE_MS = 40000;   // live source + manifest + first buffer
const MIN_WINDOW_S = 45;   // below this there is nothing meaningful to seek into
const RECOVER_MS = 25000;  // generous: a DVR seek refills from the edge

const log = (...a) => console.log('  ' + a.join(' '));

(async () => {
    const browser = await chromium.launch();
    const page = await browser.newPage();
    await page.goto(`${URL}?cb=${Date.now()}`, { waitUntil: 'load', timeout: 60000 });
    await page.waitForTimeout(SETTLE_MS);

    const probe = () => page.evaluate(() => {
        const el = document.querySelector('.video-js');
        const p = el && el.player;
        if (!p) return { err: 'no player' };
        const v = p.el().querySelector('video');
        const sk = [];
        if (v) for (let i = 0; i < v.seekable.length; i++) sk.push([v.seekable.start(i), v.seekable.end(i)]);
        const buf = [];
        if (v) for (let i = 0; i < v.buffered.length; i++) buf.push([v.buffered.start(i), v.buffered.end(i)]);
        return {
            t: v ? +v.currentTime.toFixed(2) : null,
            readyState: v ? v.readyState : null,
            paused: v ? v.paused : null,
            error: v && v.error ? v.error.code : null,
            seekable: sk, buffered: buf,
        };
    });

    const before = await probe();
    if (before.err) { log('FAIL: ' + before.err); await browser.close(); process.exit(1); }
    if (!before.seekable.length) {
        log('SKIP: nothing seekable - is the live source publishing?');
        await browser.close(); process.exit(0);
    }
    const [start, end] = before.seekable[0];
    const windowS = end - start;
    log(`seekable: ${start.toFixed(1)}s .. ${end.toFixed(1)}s  (window ${windowS.toFixed(1)}s), currentTime ${before.t}`);
    if (windowS < MIN_WINDOW_S) {
        log(`SKIP: DVR window is only ${windowS.toFixed(1)}s, need >= ${MIN_WINDOW_S}s to test the far end`);
        log('      let the stream run a few minutes and retry');
        await browser.close(); process.exit(0);
    }

    // The old bug lived at the very back of the window, so aim there: a few
    // seconds in, to stay clear of the segment currently being pruned.
    const target = start + 5;
    log(`seeking to ${target.toFixed(1)}s (${(end - target).toFixed(0)}s behind the live edge)`);
    await page.evaluate((t) => {
        const v = document.querySelector('.video-js').player.el().querySelector('video');
        v.currentTime = t;
        const pr = v.play(); if (pr && pr.catch) pr.catch(() => {});
    }, target);

    let recovered = false, last = null;
    const deadline = Date.now() + RECOVER_MS;
    while (Date.now() < deadline) {
        await page.waitForTimeout(2500);
        const s = await probe();
        if (VERBOSE) log(`  t=${s.t} rs=${s.readyState} buffered=${JSON.stringify(s.buffered)}`);
        // Recovery means the clock is moving AND the pipeline has data.
        if (last !== null && s.t > last + 0.5 && s.readyState >= 3) { recovered = true; last = s.t; break; }
        last = s.t;
    }

    const after = await probe();
    log(`after seek: t=${after.t} readyState=${after.readyState} paused=${after.paused} error=${after.error} buffered=${JSON.stringify(after.buffered)}`);

    if (recovered) {
        log('PASS - playback resumed after seeking to the back of the DVR window');
        await browser.close(); process.exit(0);
    }
    log('FAIL - player did not recover. This is the 2026-08-08 audio/video DVR');
    log('       window mismatch: check that FFMPEG_FLAGS still carries -seg_duration,');
    log('       and compare the two SegmentTimeline durations in the live manifest.');
    await browser.close(); process.exit(1);
})().catch(e => { console.log('  ERROR ' + e.message); process.exit(1); });
