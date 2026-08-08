#!/usr/bin/env node
//
// Behavioural check on the player's resolution menu. Loads a /vod/ page for real
// and drives the menu, because the failure this exists to catch is invisible to
// every cheaper check.
//
// WHY. On 2026-08-08 a regex edit applied across the four copies of
// videojs-http-source-selector that patch-package maintains (src/ plus three
// rolled-up dist/ builds) landed in the wrong function in one of them. It threw
// inside createItems() and took the resolution selector off the control bar on
// the live site. Nothing failed loudly: the bundle built, the size was right,
// and the patched identifier was present in the source. Only loading the page
// and looking at the menu finds this.
//
// TWO TRAPS, both of which cost real time and are the reason this file is
// written the way it is:
//
//   1. Find the menu by CONTENT, never by class. `vjs-http-source-selector` is
//      a class video.js puts on the <video-js> ROOT element, not on the menu, so
//      a harness scoped to `.vjs-http-source-selector .vjs-menu-item` silently
//      reports the CAPTIONS menu instead and prints confident nonsense.
//   2. Do not verify a minified bundle by grepping for your own identifiers -
//      terser renames them. Assert on emitted code shape.
//
// Usage:  node scripts/check-quality-menu.js [url]        default: the local stack
// Exits non-zero on failure, so it drops straight into CI.

const { chromium } = require('playwright-core');

const URL = process.argv[2] || 'http://127.0.0.1:8080/vod/';
const SETTLE_MS = 11000;   // ABR needs to have parsed the manifest and built the list
const CLICK_MS = 2500;

// Locate the quality menu by what is IN it. Runs in page context.
const findMenu = () => {
    const menus = [...document.querySelectorAll('.vjs-menu')];
    return menus.find(m => [...m.querySelectorAll('.vjs-menu-item')]
        .some(i => /^(Auto|\d+p)\b/.test(i.textContent.trim()))) || null;
};

const readItems = () => {
    const menus = [...document.querySelectorAll('.vjs-menu')];
    const m = menus.find(x => [...x.querySelectorAll('.vjs-menu-item')]
        .some(i => /^(Auto|\d+p)\b/.test(i.textContent.trim())));
    if (!m) return null;
    return [...m.querySelectorAll('.vjs-menu-item')].map(i => ({
        label: i.textContent.trim().split(',')[0],
        selected: i.classList.contains('vjs-selected'),
    }));
};

const fmt = items => items.map(i => (i.selected ? `[${i.label}]` : i.label)).join('  ');
const selectedLabels = items => items.filter(i => i.selected).map(i => i.label);

(async () => {
    const browser = await chromium.launch();
    const page = await browser.newPage();
    const pageErrors = [];
    page.on('pageerror', e => pageErrors.push(e.message));

    // Cache-bust: a stale bundle passing this check is the worst possible outcome.
    await page.goto(`${URL}?cb=${Date.now()}`, { waitUntil: 'load', timeout: 60000 });
    await page.waitForTimeout(SETTLE_MS);

    const failures = [];
    const note = m => { failures.push(m); console.log(`  FAIL  ${m}`); };

    const present = await page.evaluate(findMenu);
    if (!present) {
        note('no quality menu on the page at all (this is the createItems() throw)');
        if (pageErrors.length) console.log(`  page errors: ${pageErrors.join(' | ').slice(0, 300)}`);
        await browser.close();
        process.exit(1);
    }

    let items = await page.evaluate(readItems);
    console.log(`  on load      : ${fmt(items)}`);

    if (items.length < 2) note(`only ${items.length} entry in the menu, expected several rungs plus Auto`);
    if (!items.some(i => i.label === 'Auto')) note('no Auto entry');

    // The 2026-08-08 ask: the menu must open with Auto ticked, not with nothing ticked.
    const onLoad = selectedLabels(items);
    if (onLoad.length !== 1 || onLoad[0] !== 'Auto') {
        note(`on load expected exactly [Auto], got [${onLoad.join(', ')}]`);
    }

    // Pick two real rungs off the page rather than hardcoding a ladder that changes.
    const rungs = items.filter(i => /^\d+p$/.test(i.label)).map(i => i.label);
    const probes = [rungs[Math.floor(rungs.length / 3)], rungs[Math.floor((2 * rungs.length) / 3)], 'Auto']
        .filter(Boolean);

    for (const label of probes) {
        const clicked = await page.evaluate((l) => {
            const menus = [...document.querySelectorAll('.vjs-menu')];
            const m = menus.find(x => [...x.querySelectorAll('.vjs-menu-item')]
                .some(i => /^(Auto|\d+p)\b/.test(i.textContent.trim())));
            const it = [...m.querySelectorAll('.vjs-menu-item')]
                .find(i => i.textContent.trim().startsWith(l));
            if (!it) return false;
            it.click();
            return true;
        }, label);
        if (!clicked) { note(`could not click ${label}`); continue; }

        await page.waitForTimeout(CLICK_MS);
        items = await page.evaluate(readItems);
        console.log(`  after ${label.padEnd(8)}: ${fmt(items)}`);

        // The original bug: every rung ever clicked stayed ticked.
        const sel = selectedLabels(items);
        if (sel.length !== 1) note(`after clicking ${label}, ${sel.length} items are selected (expected 1): [${sel.join(', ')}]`);
        else if (sel[0] !== label) note(`after clicking ${label}, [${sel[0]}] is selected instead`);
    }

    if (pageErrors.length) console.log(`  page errors: ${pageErrors.join(' | ').slice(0, 300)}`);
    await browser.close();

    console.log(failures.length ? `\n  ${failures.length} failure(s)` : '\n  PASS');
    process.exit(failures.length ? 1 : 0);
})().catch(e => { console.log(`  ERROR ${e.message}`); process.exit(1); });
