# Safari and iOS: native multichannel Opus does not decode, and a WASM fallback does

Every route Safari offers for decoding audio, `decodeAudioData`, WebCodecs `AudioDecoder`, and MPEG-DASH via MediaSource, refuses this stream's 16-channel Opus, on both macOS and iOS. Unlike the Chrome field trial in [docs/CHROME-MULTICHANNEL-OPUS.md](CHROME-MULTICHANNEL-OPUS.md), this is not a regression with a fix in flight. It is measured as a structural gap in WebKit's audio pipeline, and nothing found while measuring it points at an upcoming change.

**Try it yourself, on a Mac, iPhone, or headset:** <https://stream.bmroz.eu/iphone-test/>. Three short pages, each runs itself and ends with a six-character ID; results also beacon back automatically. Real tester runs on both macOS Safari and iPhone Safari (iOS 26.6) are behind the numbers below.

## What is broken, measured

| | Chrome / Firefox / Brave | Safari (macOS 27) | Safari (iOS 26.6) |
|---|---|---|---|
| `decodeAudioData`, 16-ch Opus | works | fails | fails |
| `decodeAudioData`, 2-ch Opus | works | works in WebM AND in MP4 | works in WebM (MP4 not re-measured) |
| WebCodecs `AudioDecoder`, 16-ch Opus | works | `isConfigSupported` false | `isConfigSupported` false |
| MSE, `audio/mp4; codecs="opus"` | works | not supported | not supported (`MediaSource` itself is absent; only `ManagedMediaSource` exists) |
| `decodeAudioData`, 4-ch and 8-ch AAC | works | works, channels distinct | not re-measured |
| `decodeAudioData`, 16-ch AAC | n/a | not tested; CoreAudio has no layout tag for it (see below) | n/a |

Read that table one row at a time rather than as a verdict on a codec. Safari's four decode surfaces disagree with each other, and WebKit has a documented history of it: in Safari 27, `MediaSource.isTypeSupported('audio/mp4; codecs="opus"')` returns false while `decodeAudioData` decodes the same stereo Opus-in-MP4 file, and `canPlayType` returns the empty string for it. Measure the surface the code actually uses. An earlier revision of this document reported stereo Opus-in-MP4 as failing, on the strength of the wrong surface.

The AAC ceiling here is Apple's, not WebKit's, and it is not a browser bug to file. `afinfo` and `afconvert` refuse a 16-channel AAC file outside any browser, `CoreAudioBaseTypes.h` defines no AAC channel layout tag above 8, and Apple's own encoder fails at 9 channels and up. Read that as a ceiling on Apple platforms, not on the format and not on ffmpeg: the contribution leg produces 16-channel AAC with a PCE every day, and Apple simply has no layout tag able to describe it. No ffmpeg change touches this one, including the master fix in [docs/AMBISONIC-ORDER.md](AMBISONIC-ORDER.md). Even `kAudioChannelLayoutTag_HOA_ACN_SN3D` gives no route through AAC. Treat 8 channels as a permanent ceiling for planning: 1st order (4 channels) has a fully native AAC path on Safari, 3rd order has none.

A Meta Quest 3's own Chromium-based browser decodes this stream, 16 and 25 channels, with no fallback needed at all; see the capability shot in the main [README](../README.md) and [docs/AMBISONIC-ORDER.md](AMBISONIC-ORDER.md).

## What works instead, measured on real hardware

**Chosen: WASM decode of the stream this stack already serves.** [`opus-decoder`](https://github.com/eshaz/wasm-audio-decoders), built from source rather than its published bundle, which [silently discards its own multichannel options](https://github.com/eshaz/wasm-audio-decoders/issues/129) when minified. One stateful decoder fed the live DASH segments directly:

| | macOS Safari 27 | iPhone Safari (iOS 26.6) |
|---|---|---|
| Channels, order | 16, correct ACN order | 16, correct ACN order |
| Speed | 47-67x realtime across five runs | 35-88x realtime, two iPhones |
| Continuity across segment boundaries | gapless (junction metric 1.5, i.e. continuous) | gapless (junction metric 1.5) |
| Server changes needed | none | none |

Web Audio itself is not a constraint: a 16-channel graph routes correctly on the iPhone (channel 13 carries its 1500 Hz tone, channel 6 its 800 Hz), while `AudioContext.destination` reports `maxChannelCount` 2. Sixteen channels in, binaural stereo out, is exactly the shape the player needs.

**Fallback, also proven, weaker on iOS specifically: four parallel 4-channel AAC streams**, decoded natively (no WASM). AAC's LFE element low-passes full-band content, which rules out two 8-channel streams; four 4.0-layout streams (no LFE) is what survives that constraint. An 8-channel 7.1 file gives a second reason: it decodes, but arrives with its channels permuted. The four 4-channel streams also arrive permuted relative to fetch order, so a decoder has to read the order rather than assume it.

| | macOS Safari 27 | iPhone Safari (iOS 26.6) |
|---|---|---|
| Per-chunk `decodeAudioData` | works, discontinuous at each 2s boundary | works, discontinuous (junction metric 42-62) |
| Stateful WebCodecs decode (the gapless path) | works | fails: `InternalAudioDecoderCocoa decoding failed` |

So the fallback is fully viable on macOS and loses its gapless half specifically on iOS, which is why the WASM route is the primary choice rather than a mild preference.

Raw runs behind the iPhone columns: `yw5mzd` (capability probe), `3ihvtx` (WASM multistream on the box's own DASH), `3612nb` (the 4x4 AAC fallback, both decode paths). Each page beacons its full report to `hoast-player`'s access log; `scratch/ios-probe/harvest-beacons.sh` reassembles them by id, which is how the figures here can be rechecked without the tester repeating anything.

**Settled:** `AudioWorkletNode` is available on iOS Safari, which matters because a continuous WASM decode loop needs a low-latency path into Web Audio and this project does not use the deprecated `ScriptProcessorNode`. Two iPhone probes reported it absent, the first by a bare `typeof` and the second by the rebuilt check that actually constructs a worklet (a `typeof`-only check had already produced one false conclusion in this same investigation, in the opus-decoder bundle above). Both were served over plain HTTP. `AudioWorklet` is gated on a secure context, so on an insecure origin `ctx.audioWorklet` is undefined and the rebuilt check fails with `undefined is not an object (evaluating 'wctx.audioWorklet.addModule')`, which is indistinguishable from the platform not shipping it; the macOS run that contradicted them passed on `localhost`, which counts as secure. Re-run over HTTPS, the same check constructs and connects a worklet. The HTTPS run came from a second phone on iOS 18.7 rather than the 26.6 one that failed, so scheme and OS version changed together and this is not a single-variable comparison. The secure-context gate accounts for the failure exactly, and every other result on the older phone matched the 26.6 runs, so the older OS reads as coverage rather than as an alternative explanation. The probe now records `isSecureContext` and `location.protocol`, so a future run cannot leave this ambiguous.

## Keeping the audio alive when the window is not visible

Moving the Safari window to another macOS Space stopped the audio within about two seconds, and it took one to two seconds to resume on return. YouTube and the dash.js reference player are unaffected in the same browser, which made it look like our bug, and it was, though not in the way either obvious theory predicted. The AudioContext never suspended and no timer starved. The `<video>` element itself paused, three seconds before `document.hidden` even flipped, and our audio is slaved to that element's clock.

WebKit suspends a backgrounded video element unless it has a decodable audio track AND is unmuted. A three-way control page settled it, three trials each:

| element | while hidden |
|---|---|
| muted, no audio track (what we shipped) | suspends immediately |
| unmuted, no audio track | suspends immediately |
| unmuted, silent AAC track | keeps decoding |

Two consequences. Unmuting alone is not enough, so this cannot be fixed with a one-line property change. And the policy is per-element, not per-page: the surviving element was in the same document as the two that died, so the familiar trick of parking a silent `<audio>` on the page does nothing here.

The fix is a silent stereo AAC AdaptationSet in the manifest, at 8 kbit/s, which the element plays while the feed carries the real 16-channel audio. It has to be AAC: Safari's MSE reports no support for Opus-in-MP4, and that is the surface dash.js asks. On the VP9/WebM path Opus-in-WebM is supported by both MSE and ManagedMediaSource and would serve instead. Unmuting is gated on a real user gesture, because WebKit pauses an unmuted element that did not start from one, which breaks muted autoplay outright.

It costs a constant 0.37 s later start, measured: an element carrying an audio track begins that much later than one without. Constant offset, not drift, so sync is unaffected.

## What has been built

The player now does this end to end, verified by a human in real Safari on macOS: 16-channel Opus decoded through libopus-in-WASM in a worker, scheduled against the video clock, surviving both segment junctions and a switch to another Space.

- Decode runs in a worker rather than on the main thread, which is what removed the choppy video and the audible startup ramp.
- Audio does not start until the real HRIRs are loaded. Before that gate it started on `resetFilters`'s cardioid placeholders, heard as a quiet tone that suddenly got louder about a second later.
- The first segment junction crossfades like every other one. It used to take a forced fade instead, an amplitude notch heard as a drop about two seconds in.
- `play` and `playing` both reach the resume path and it is now idempotent; the second used to tear down the chain the first had just built, roughly 0.7 s into playback.
- Master gain changes ramp over 15 ms. Four sites assigned `.gain.value` directly, which steps within a single sample and was audible as a pop just before playback started.
- The feed selects its audio AdaptationSet by codec rather than by document order, so a second audio set in the manifest cannot divert AAC bytes into the Opus decoder.

Still to do, and the live path is the bulk of it:

- **earshot does not emit the keep-alive track.** Everything above is proven on static fixtures only. Adding a silent AAC rendition alongside the 16-channel Opus in a live manifest is a real encoder change and the most likely place for this to bite.
- `scripts/test-pipeline.sh` has no assertion for the keep-alive set.
- An AAC hop handed a literal 8-channel layout gets 7.1 treatment, and the LFE low-pass silently destroys an ambisonic component. The 4x4 split avoids this by construction but nothing enforces it. Facebook documented hitting exactly this in 2016.
- The iOS `videojs-contrib-dash` gate is still what blocks iPhone specifically.

## What the industry does, and what it declined to do

Worth recording, because the workarounds here look improvised until you see the prior art.

Facebook's browser delivery for its 8-channel TBE format was a 10-channel Opus track using **channel mapping family 255**, with the layout carried in the streaming manifest, because "Opus allows for an undefined channel mapping family (family 255) ... We transmit channel layout information in the streaming manifest" ([Meta engineering, 2017](https://engineering.fb.com/2017/02/22/virtual-reality/spatial-audio-bringing-realistic-sound-to-360-video/)). That is the same three decisions this stack made independently. The same post documents the AAC constraints that produced our 4x4 contribution split, including the 7.1 LFE hazard above.

Facebook never supported Safari for spatial audio at all. Their published platform list was the iOS app, the Android app, Chrome on desktop, and Gear VR. Google's Omnitone, the reference ambisonic renderer for Web Audio, has no Safari path either and declares codec compatibility out of scope; its own HOA example loads two 8-channel WAV files rather than anything compressed.

YouTube does use a standard where one exists: its ambisonic Opus is **mapping family 2** (RFC 8486), not 255, measured directly from the delivered OpusHead. Family 2 signals ACN/SN3D order in the bitstream itself and covers 16 channels as 3rd order, so streams describe themselves instead of relying on manifest metadata. `ffmpeg` encodes it here at 16 channels and `ffprobe` reads back `ambisonic 3`. No browser decodes multichannel family 2 today, so this buys standards conformance and future decoder support rather than any playback that works now.

## Status

Implemented in the player and verified by hand in macOS Safari; NOT wired into the live pipeline, which still emits no keep-alive track. Multichannel Opus decoding landed in WebKit on 2026-03-05 for mapping family 1 on the WebM path, capped at 8 channels, so it does not reach this stream, but the gap is no longer static and is worth re-measuring per Safari release. Requested directly, in the same week two related Opus problems surfaced: a mixed-container stutter fixed upstream ([EnvelopSound/Earshot#81](https://github.com/EnvelopSound/Earshot/pull/81)), and a Chrome regression breaking multichannel decode above 2 channels ([Chromium 547065816](https://issues.chromium.org/issues/547065816)); both are catalogued in [docs/UPSTREAM.md](UPSTREAM.md). Neither caused this investigation: Safari's gap, described here, is a structural limitation rather than a regression.

