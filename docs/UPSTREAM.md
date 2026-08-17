# Upstream contributions

Bugs found while building this stack are reported to, and fixed in, the projects they belong to rather than only patched here. This page is the register: what has been sent where, what is still open, and what is prepared but not sent.

It exists for a practical reason as well as a tidy one. Work in this repository is spread across a vendored player, three patched npm packages, a forked media server and a browser bug or two, and without a single list it is genuinely easy to lose track of what has already been submitted and start drafting it twice.

Status is as of 2026-08-17. Nothing here is auto-generated, so re-check the links before quoting any of it.

## Merged

| Project | PR | What |
|---|---|---|
| EnvelopSound/Earshot | [#53](https://github.com/EnvelopSound/Earshot/pull/53) | Align track starts at the relay so DASH output carries no video edit list. This is the server-side half of the A/V desync investigation; see `docs/PAPER-NOTES.md` 12 |
| EnvelopSound/Earshot | [#54](https://github.com/EnvelopSound/Earshot/pull/54) | Enable libvpx in ffmpeg so VP9 is actually available |
| EnvelopSound/Earshot | [#55](https://github.com/EnvelopSound/Earshot/pull/55) | Clear the DASH directory contents instead of `rm -rf` on the `/opt/data` mount |
| EnvelopSound/Earshot | [#56](https://github.com/EnvelopSound/Earshot/pull/56) | nginx: emit relative redirects so a mapped host port survives directory redirects |
| EnvelopSound/Earshot | [#57](https://github.com/EnvelopSound/Earshot/pull/57) | Allow building without `--enable-nonfree` for a redistributable image |
| EnvelopSound/Earshot | [#61](https://github.com/EnvelopSound/Earshot/pull/61) | Raise the yarn network timeout so slower hosts can build the webtools image |
| EnvelopSound/Earshot | [#62](https://github.com/EnvelopSound/Earshot/pull/62) | CI: make the workflows run again (actions v4, Compose v2, failure diagnostics). Restored the pipeline but left `test` red on a pre-existing, unrelated mismatch: the bundled test source is audio-only and the shipped default (`-c:v copy`) needs video. See #63 |
| EnvelopSound/Earshot | [#63](https://github.com/EnvelopSound/Earshot/pull/63) | Test: push a real video track, matching the default `-c:v copy` path, so CI's `test` job goes green again after #62 |
| EnvelopSound/Earshot | [#64](https://github.com/EnvelopSound/Earshot/pull/64) | Resume the AudioContext from the gain slider's `onChange` (a real user gesture) instead of a `window` click listener. Supersedes [#26](https://github.com/EnvelopSound/Earshot/pull/26) (closed), which diagnosed the bug correctly in 2021 but leaked a listener on every re-render. Closes [#13](https://github.com/EnvelopSound/Earshot/issues/13) ("No audio playback in Chrome"), open since 2021 and previously misdiagnosed in that thread as an HTTPS/CDN problem |
| EnvelopSound/Earshot | [#58](https://github.com/EnvelopSound/Earshot/pull/58) | Floor DASH `suggestedPresentationDelay` to avoid live-join gap-jumps |
| EnvelopSound/Earshot | [#59](https://github.com/EnvelopSound/Earshot/pull/59) | Decouple the DASH manifest filename from the RTMP stream key |
| EnvelopSound/Earshot | [#60](https://github.com/EnvelopSound/Earshot/pull/60) | Raise RTMP `max_message` so 4K keyframes are not dropped |

## Open

| Project | PR | What |
|---|---|---|
| thomasdeppisch/videojs-xr | [#28](https://github.com/thomasdeppisch/videojs-xr/pull/28) | Mobile orientation controls, renderer sizing and a three.js deprecation: `Math.clamp` does not exist, `rotateLeft`/`rotateUp` are not exposed on the OrbitControls instance (which kills the render loop on any device with an orientation sensor), `Quaternion.inverse()` is deprecated, and the mono renderer is never resized after a zero-size init |
| thomasdeppisch/hoast360 | [#30](https://github.com/thomasdeppisch/hoast360/pull/30) | Resume the AudioContext on the combined-MPD path, which was silent on every browser enforcing the autoplay policy |
| thomasdeppisch/hoast360 | [#31](https://github.com/thomasdeppisch/hoast360/pull/31) | `HoastLoader.concatBuffers()` reads source channel 0 for every destination in a higher-order group, so 10 of 12 third-order filter channels load the wrong decoding filter. Measured in [aac-bitrate-test/RESULTS.md](../aac-bitrate-test/RESULTS.md) |

## Reported to browsers

| Where | What |
|---|---|
| [Chromium 537235698](https://issues.chromium.org/issues/537235698) | Chromium's MSE does not apply a video track's empty-edit (`elst`) presentation offset while Firefox does, so identical fMP4 bytes play in sync in one engine and ~1.7 s out in the other. Filed as an interoperability question. Minimal reproduction: [mse-edit-list-repro](https://github.com/mormegil6/mse-edit-list-repro) |
| [w3c/media-source#377](https://github.com/w3c/media-source/issues/377) | The same divergence raised against the MSE spec: empty-edit (`elst media_time = -1`) handling diverges across engines and from non-MSE playback in the same engine |
| [Chromium 547065816](https://issues.chromium.org/issues/547065816) | `DirectOpusAudioDecoding`, a field trial rolling out in Chrome 151, breaks every Opus decode above 2 channels in both `decodeAudioData` and MSE playback. Filed as a regression: multichannel Opus was deliberately enabled in M62 (issue 41292687) and this trial withdraws it. Brave and Edge fail identically when the feature is forced on, so it is Chromium code rather than Chrome packaging. Reproduction: [opus-multichannel-repro](https://github.com/mormegil6/opus-multichannel-repro) ([live check](https://mormegil6.github.io/opus-multichannel-repro/)). Reader-facing write-up: [CHROME-MULTICHANNEL-OPUS.md](CHROME-MULTICHANNEL-OPUS.md) |

## Prepared, not sent

| Target | What | Blocked on |
|---|---|---|
| thomasdeppisch/hoast360 | Replace the Opus support probe, which tests `canPlayType('audio/ogg; codecs="opus"')` for a container this player never streams, with a real decode probe that also distinguishes the Chrome field-trial failure from a browser that genuinely cannot decode Opus | The Chromium filing above, so the browser-specific advice can cite a tracked issue |
| Dash-Industry-Forum/dash.js | Two crash guards: `TimelineSegmentsGetter` reads a `SegmentTimeline` that may carry no `S` elements, and the embedded-caption path assumes ISOBMFF and crashes on WebM segments when a CEA-608 descriptor is present. Written against current `development` with four unit tests that fail without the change; branch [`guard-live-timeline-and-non-isobmff`](https://github.com/mormegil6/dash.js/tree/guard-live-timeline-and-non-isobmff) | The DASH-IF Feedback Agreement, which their contributing guide requires before review |

## Not upstreamable

Some patches are specific to this deployment and are carried locally on purpose. The DVR seek clamp, the segment audio feed and the pixel-ratio rendering change all live in the [hoast360 fork](https://github.com/mormegil6/hoast360) rather than upstream, either because they encode choices another deployment should not inherit or because they depend on this fork's own modernised build.

The DASH quality-levels bridge belongs in that category too, for a reason worth writing down so it is not proposed again. Upstream hoast360 depends on the maintainer's own forks of `videojs-contrib-dash` and `videojs-http-source-selector`, which already handle this: `thomasdeppisch/videojs-contrib-dash@96baa2b` ("make it work with source selector for quality levels") and `thomasdeppisch/videojs-http-source-selector@f0d032d` ("set levels.selectedIndex_ properly"), both from 2020. This fork swapped those github dependencies for published npm releases because their prepublish step pulls node-sass 4 and will not install on Node 17 or newer. That trade bought installability and cost the integration, so the bridge rebuilds it here. Upstream has no gap to fix.
