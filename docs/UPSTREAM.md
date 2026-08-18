# Upstream contributions

Bugs found while building this stack are reported to, and fixed in, the projects they belong to rather than only patched here. This page is the register: what has been sent where, what is still open, and what is prepared but not sent.

It exists for a practical reason as well as a tidy one. Work in this repository is spread across a vendored player, three patched npm packages, a forked media server and a browser bug or two, and without a single list it is genuinely easy to lose track of what has already been submitted and start drafting it twice.

Status is as of 2026-08-18. Nothing here is auto-generated, so re-check the links before quoting any of it.

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
| EnvelopSound/Earshot | [#70](https://github.com/EnvelopSound/Earshot/pull/70) | webtools: bump 13 dependencies to patched versions already inside their declared ranges (real CVEs/GHSAs per package, not a routine version chase). Caught two npm-registry-deprecated release traps (`lodash`/`lodash.template` 4.18.0) before they shipped as "fixes". Open alert count: 180 -> 114 across this PR and the 11 Dependabot PRs merged the same day. Five packages from the same alert sweep deliberately excluded - each cascades into further version conflicts and needs its own PR |
| EnvelopSound/Earshot | [#71](https://github.com/EnvelopSound/Earshot/pull/71) | `.gitattributes` had no `eol` rule for shell scripts, so a Windows checkout with the common `core.autocrlf=true` setting silently CRLF-converts `entrypoint.sh`, and Docker bakes the corrupted script into the image via `COPY`, crashing with `standard_init_linux.go:219: exec user process caused: no such file or directory`. Forces LF for all `*.sh` regardless of checkout platform. Closes [#28](https://github.com/EnvelopSound/Earshot/issues/28), open since 2021 |
| EnvelopSound/Earshot | [#72](https://github.com/EnvelopSound/Earshot/pull/72) | webtools: patch the 29 vulnerable packages Dependabot cannot auto-fix - transitive deps pinned by their requesters' ranges, fixed via 18 in-range lockfile bumps (a single in-range `express` 4.18.2 -> 4.22.2 carries five of its own sub-dependencies), 10 scoped yarn `resolutions`, and the one direct dep with an alert (`xml2js`). Open alert count 114 -> 58. The fix that matters beyond hygiene: `path-to-regexp`'s ReDoS was reachable client-side (react-router bundles it into the served app). Deliberately excluded and named in the PR: 23 packages needing major-version overrides into react-scripts' own tooling, and 3 with no patched version at all |
| EnvelopSound/Earshot | [#73](https://github.com/EnvelopSound/Earshot/pull/73) | webtools: the one package from #72's excluded "needs-care" bucket worth fixing on its own - `@babel/runtime` ships its helpers into whatever the transpiler emits, so its ReDoS advisory (inefficient RegExp complexity transpiling named capturing groups) isn't purely build-time like the rest of that bucket. `babel-preset-react-app` (react-scripts' own preset) exact-pins it to `7.9.0`, so the fix needed a `resolutions` override rather than an in-range bump |

## Open

| Project | PR | What |
|---|---|---|
| thomasdeppisch/videojs-xr | [#28](https://github.com/thomasdeppisch/videojs-xr/pull/28) | Mobile orientation controls, renderer sizing and a three.js deprecation: `Math.clamp` does not exist, `rotateLeft`/`rotateUp` are not exposed on the OrbitControls instance (which kills the render loop on any device with an orientation sensor), `Quaternion.inverse()` is deprecated, and the mono renderer is never resized after a zero-size init |
| thomasdeppisch/hoast360 | [#30](https://github.com/thomasdeppisch/hoast360/pull/30) | Resume the AudioContext on the combined-MPD path, which was silent on every browser enforcing the autoplay policy |
| thomasdeppisch/hoast360 | [#31](https://github.com/thomasdeppisch/hoast360/pull/31) | `HoastLoader.concatBuffers()` reads source channel 0 for every destination in a higher-order group, so 10 of 12 third-order filter channels load the wrong decoding filter. Measured in [aac-bitrate-test/RESULTS.md](../aac-bitrate-test/RESULTS.md) |
| thomasdeppisch/hoast360 | [#32](https://github.com/thomasdeppisch/hoast360/pull/32) | Replace the Opus support probe, which tests `canPlayType('audio/ogg; codecs="opus"')` for a container this player never streams, with a real `decodeAudioData` probe that also names the Chrome field trial (`DirectOpusAudioDecoding`) behind one failure mode it distinguishes. Independent of #30 and #31 |
| Dash-Industry-Forum/dash.js | [#5104](https://github.com/Dash-Industry-Forum/dash.js/pull/5104) | Guard three unguarded reads that crash on legitimate input: a `SegmentTimeline` that is absent or carries no `S` elements ([#3513](https://github.com/Dash-Industry-Forum/dash.js/issues/3513) and [#2708](https://github.com/Dash-Industry-Forum/dash.js/issues/2708) reported the class years ago, closed without a guard), and the ISOBMFF assumption in `BoxParser.getSamplesInfo` and the CEA-608 path, which WebM segments do not satisfy. Four unit tests, each failing on `development` without the change |

## Reported to browsers

| Where | What |
|---|---|
| [Chromium 537235698](https://issues.chromium.org/issues/537235698) | Chromium's MSE does not apply a video track's empty-edit (`elst`) presentation offset while Firefox does, so identical fMP4 bytes play in sync in one engine and ~1.7 s out in the other. Filed as an interoperability question. Minimal reproduction: [mse-edit-list-repro](https://github.com/mormegil6/mse-edit-list-repro) |
| [WebKit 319998](https://bugs.webkit.org/show_bug.cgi?id=319998) | The same MSE empty-edit divergence, filed against Safari/WebKit. Resolved as a duplicate of [316870](https://bugs.webkit.org/show_bug.cgi?id=316870); the fix landed in WebKit trunk 2026-07-07 (`316626@main`), but no shipping Safari carries it yet - 26.5.2 and 27.0 beta 1 both still drop the offset as measured |
| [Mozilla 2056945](https://bugzilla.mozilla.org/show_bug.cgi?id=2056945) | The mirror-image half of the same gap: Firefox already applies the empty-edit offset correctly under MSE (the common streaming case) but drops it on the plain, non-MSE `<video src>` path - filed separately since it is Gecko's own defect, not the Chromium/WebKit MSE-side one |
| [w3c/media-source#377](https://github.com/w3c/media-source/issues/377) | The same divergence raised against the MSE spec: empty-edit (`elst media_time = -1`) handling diverges across engines and from non-MSE playback in the same engine |
| [Chromium 547065816](https://issues.chromium.org/issues/547065816) | `DirectOpusAudioDecoding`, a field trial rolling out in Chrome 151, breaks every Opus decode above 2 channels in both `decodeAudioData` and MSE playback. Filed as a regression: multichannel Opus was deliberately enabled in M62 (issue 41292687) and this trial withdraws it. Brave and Edge fail identically when the feature is forced on, so it is Chromium code rather than Chrome packaging. Reproduction: [opus-multichannel-repro](https://github.com/mormegil6/opus-multichannel-repro) ([live check](https://mormegil6.github.io/opus-multichannel-repro/)). Reader-facing write-up: [CHROME-MULTICHANNEL-OPUS.md](CHROME-MULTICHANNEL-OPUS.md) |

## Prepared, not sent

Nothing at the moment.

## Not upstreamable

Some patches are specific to this deployment and are carried locally on purpose. The DVR seek clamp, the segment audio feed and the pixel-ratio rendering change all live in the [hoast360 fork](https://github.com/mormegil6/hoast360) rather than upstream, either because they encode choices another deployment should not inherit or because they depend on this fork's own modernised build.

The DASH quality-levels bridge belongs in that category too, for a reason worth writing down so it is not proposed again. Upstream hoast360 depends on the maintainer's own forks of `videojs-contrib-dash` and `videojs-http-source-selector`, which already handle this: `thomasdeppisch/videojs-contrib-dash@96baa2b` ("make it work with source selector for quality levels") and `thomasdeppisch/videojs-http-source-selector@f0d032d` ("set levels.selectedIndex_ properly"), both from 2020. This fork swapped those github dependencies for published npm releases because their prepublish step pulls node-sass 4 and will not install on Node 17 or newer. That trade bought installability and cost the integration, so the bridge rebuilds it here. Upstream has no gap to fix.
