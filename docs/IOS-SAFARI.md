# Safari and iOS: native multichannel Opus does not decode, and a WASM fallback does

Every route Safari offers for decoding audio, `decodeAudioData`, WebCodecs `AudioDecoder`, and MPEG-DASH via MediaSource, refuses this stream's 16-channel Opus, on both macOS and iOS. Unlike the Chrome field trial in [docs/CHROME-MULTICHANNEL-OPUS.md](CHROME-MULTICHANNEL-OPUS.md), this is not a regression with a fix in flight. It is measured as a structural gap in WebKit's audio pipeline, and nothing found while measuring it points at an upcoming change.

**Try it yourself, on a Mac, iPhone, or headset:** <https://stream.bmroz.eu/iphone-test/>. Three short pages, each runs itself and ends with a six-character ID; results also beacon back automatically. Real tester runs on both macOS Safari and iPhone Safari (iOS 26.6) are behind the numbers below.

## What is broken, measured

| | Chrome / Firefox / Brave | Safari (macOS 27) | Safari (iOS 26.6) |
|---|---|---|---|
| `decodeAudioData`, 16-ch Opus | works | fails | fails |
| WebCodecs `AudioDecoder`, 16-ch Opus | works | `isConfigSupported` false | `isConfigSupported` false |
| MSE, `audio/mp4; codecs="opus"` | works | not supported | not supported (`MediaSource` itself is absent; only `ManagedMediaSource` exists) |

A Meta Quest 3's own Chromium-based browser decodes this stream, 16 and 25 channels, with no fallback needed at all; see the capability shot in the main [README](../README.md) and [docs/AMBISONIC-ORDER.md](AMBISONIC-ORDER.md).

## What works instead, measured on real hardware

**Chosen: WASM decode of the stream this stack already serves.** [`opus-decoder`](https://github.com/eshaz/wasm-audio-decoders), built from source rather than its published bundle, which [silently discards its own multichannel options](https://github.com/eshaz/wasm-audio-decoders/issues/129) when minified. One stateful decoder fed the live DASH segments directly:

| | macOS Safari 27 | iPhone Safari (iOS 26.6) |
|---|---|---|
| Channels, order | 16, correct ACN order | 16, correct ACN order |
| Speed | 47-67x realtime across five runs | 47-88x realtime across six runs |
| Continuity across segment boundaries | gapless (junction metric 1.5, i.e. continuous) | gapless (junction metric 1.5) |
| Server changes needed | none | none |

**Fallback, also proven, weaker on iOS specifically: four parallel 4-channel AAC streams**, decoded natively (no WASM). AAC's LFE element low-passes full-band content, which rules out two 8-channel streams; four 4.0-layout streams (no LFE) is what survives that constraint.

| | macOS Safari 27 | iPhone Safari (iOS 26.6) |
|---|---|---|
| Per-chunk `decodeAudioData` | works, discontinuous at each 2s boundary | works, discontinuous (junction metric 42-62) |
| Stateful WebCodecs decode (the gapless path) | works | fails: `InternalAudioDecoderCocoa decoding failed` |

So the fallback is fully viable on macOS and loses its gapless half specifically on iOS, which is why the WASM route is the primary choice rather than a mild preference.

**Not yet settled:** whether `AudioWorkletNode` is genuinely unavailable on iOS Safari, which would be surprising given it has shipped there since 14.5. The first iPhone probe reported it absent by a bare `typeof` check; that check was rebuilt to actually construct a worklet (a `typeof`-only check already produced one false conclusion this same investigation, in the opus-decoder bundle above), and the rebuilt version passes on macOS Safari. It has not yet been re-run on an iPhone.

## What wiring this into the live player would cost

Not started. Rough shape of the remaining work, in roughly ascending cost:

- Feature-detect Safari and route to the fallback: small, the capability checks above already exist.
- Swap the demo's placeholder rotation for the real MagLS convolver chain: mostly free, the desktop player already has this code; it would take PCM from a different source, not a different processing graph.
- DeviceOrientation permission gating on iOS: small, well-understood pattern (a `requestPermission()` call tied to the existing play gesture).
- A continuous decode loop instead of "decode five known chunks once": a real piece of work, partially reusable from the segment-parsing code already written for this investigation.
- **Decouple Safari's audio from dash.js's MSE pipeline**, since dash.js expects to own and append both tracks: new code, likely by intercepting its fragment-loaded events and diverting audio bytes to the WASM decoder instead of letting them reach MSE.
- **Drift-lock the WASM audio clock against the video element's own clock**: the highest-risk piece, because it is a new synchronisation surface on exactly the subsystem that has already produced this project's most expensive bugs (an earlier A/V desync investigation, and separately an MSE empty-edit-list handling gap). Comparable prior work in this repo (the guest direct-to-DASH feature) was originally estimated at 2-3 days and cost more once built; sync work here has a track record of running over its first estimate.
- Its own verification harness, since nothing in this stack ships unproven: partially reusable from today's Chromium-vs-Safari validation pattern.

## Status

Not implemented; this document records what has been measured. It started from a mixed-container bug report by an external tester (see [docs/UPSTREAM.md](UPSTREAM.md)), not a request for iOS support.

