# tests/av-sync/ - browser A/V-sync measurement tools

Console-pasted instruments built during the DASH A/V-desync investigation, whose findings are in [lip-sync-test/RESULTS.md](../../lip-sync-test/RESULTS.md) and [docs/UPSTREAM.md](../../docs/UPSTREAM.md). Open the HOAST360 player page and paste one of these into the browser console. They need the colour+tone A/V-sync clip (generate it with [`scripts/make-colortones.sh`](../../scripts/make-colortones.sh)) playing.

- **[avmeter.js](avmeter.js)**: frequency-identified A/V-offset meter. Taps the HOAST360 `masterGain`, identifies each beep's dominant frequency, then locates that tone inside the independently fetched + decoded DASH audio segments (Goertzel) and reports the median offset (positive = audio late). Alias-free: the *frequency*, not the event period, identifies each beep, so it cannot be fooled by a delay that equals the flash interval. Exposes `window.__avmeter2()`.

- **[ratelab.js](ratelab.js)**: "rate-lab" probe of whether element `playbackRate` (`preservesPitch=false`) can drain the then-suspected Chromium `MediaElementSource`+MSE audio delay (it cannot; the offset was later traced to an ignored video edit list, not a fixed decode-path delay - see [lip-sync-test/RESULTS.md](../../lip-sync-test/RESULTS.md) and [Chromium 537235698](https://issues.chromium.org/issues/537235698)), with a live A/V-offset readout from the flash/beep onset train.

- **[inspect.js](inspect.js)**: on-screen mobile console. Captures errors/rejections and samples the player's live `<video>` element into a WebGL overlay, for debugging on mobile where there is no console and the sphere may render black.

These three are the canonical tools.
