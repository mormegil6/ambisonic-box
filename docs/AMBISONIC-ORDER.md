# Ambisonic order: why 16 channels, and what it would take to go higher

Where the ceiling actually sits, what is already verified above it, and the two routes past it. Summarised in three sentences in the [main README](../README.md#architecture); this is the whole argument.

## Why 16 channels

In practice: 1st order (4 ch) and 3rd order (16 ch) work end to end with no special handling, because `quad` and `hexadecagonal` are named AAC layouts; 2nd order (9 ch) must be zero-padded to 16 by the sender, because 9 is not one. The ceiling sits on the contribution leg, not on delivery or rendering. ffmpeg's AAC encoder refuses a 25-channel (4th-order) input outright - 16 works only because `hexadecagonal` is a *named* layout it accepts - and that leg has to be AAC because RTMP/FLV cannot carry Opus. Stock ffmpeg's AAC encoder can write that Program Config Element (PCE) for named layouts up to 22.2 (24 channels); earshot vendors a patched build so the image guarantees PCE support without depending on the host's ffmpeg version. Everything downstream is already order-4 capable, verified component by component: 25-channel Opus at `mapping_family 255` round-trips intact, Shaka Packager carries `AudioChannelConfiguration value="25"` into the manifest, and the player image ships the complete order-4 impulse-response set.

**PCE** is AAC's Program Config Element. Sixteen channels is not one of AAC's predefined layouts, so a stream carrying one has to spell the layout out in a PCE rather than name it. Without a PCE-capable encoder the contribution leg could not carry 16 channels over RTMP at all, which is why earshot vendors its own ffmpeg build rather than depending on the host's.

## The on-demand path is already 4th order

So **the on-demand path is 4th-order capable, verified end to end** - it never touches AAC, and the player reads the ambisonic order from the manifest, so a 25-channel clip plays as 4th order with no configuration. A synthetic 25-channel clip packaged by the same DASH tooling has been played through the full chain: auto-detected as order 4, rendered through the complete order-4 impulse-response set, audio and video clocks in sync. A real recording would sound different but exercise the identical code path, so nothing here is waiting on content.

## Raising the live path: two candidate routes

Raising the *live* path is a different matter, with two candidate routes. One stays on RTMP/AAC and gives up a channel. AAC's widest named layout is 22.2 (24 channels - encode, FLV mux and read-back verified on this stack's own ffmpeg), which fits if the 4th-order vertical harmonic (ACN 20) is dropped. Two Big Ears made the same perceptual trade in their 8-channel TBE format, whose published mapping simply does not carry the 2nd-order vertical harmonic (ACN 6) ([Farina's channel-by-channel conversion](https://www.angelofarina.it/TBE-conversion.htm)); here, the order 1-3 vertical components (ACN 2, 6, 12) all survive. The other moves contribution off RTMP to SRT carrying **Opus** in MPEG-TS, which would delete the AAC transcode and with it the ceiling. Note that the SRT ingest this stack now ships is *not* that: it carries AAC, and its gateway rejoins the tracks into the same 16-channel AAC-over-RTMP leg as before, precisely so the whole guest arbiter applies to it unchanged. So SRT is here, but the live ceiling is not lifted - that would need the gateway to hand Opus to earshot directly, bypassing the RTMP hop, and it is architectural rather than configuration.

The sender side has moved, though. Multitrack SRT already carries 16 channels from stock OBS as four 4-channel tracks, and OBS allows six tracks, so 4th order (25 ch) would fit as five tracks of 5.1, five usable channels each once the muted LFE slot is dropped, using five of those six tracks: **live 4th order is therefore theoretically reachable, but it is untested and nothing here claims it.** It needs two independent things - that wider sender layout, and a gateway that stops funnelling through 16-channel AAC over RTMP. See the measurement notes (listed under Documentation in the [main README](../README.md#documentation)) for the numbers behind this.

## Beyond 3rd order (sender side)

Noted, not built. The same per-track pattern extends past 3rd order. Six tracks of 5.1 (six channels each, five usable, so 30) comfortably covers 4th order (25 ch, with headroom); six tracks of 7.1 (eight each, seven usable, so 42) would cover 5th order (36 ch, `(5+1)^2`, with headroom - HOAST360's renderer is reportedly capable of it, though no impulse-response set for it ships in the publicly available version). The `.1`/LFE slot is never usable, which is why the counts above discount it: OBS mutes it outright, measured digital-silent on 7.1 (2026-07-31) and on 5.1 (2026-08-08, -90 dBFS on a real capture). There is no LFE-free surround layout to escape to either, stock OBS offering only Mono, Stereo, 2.1, 4.0, 4.1, 5.1 and 7.1 - and ambisonics has no channel that maps onto "LFE" anyway. Note this is the *sender* side only - the gateway still rejoins to 16-channel AAC over RTMP internally, so raising the live order needs that hop changed too. 4.0 stays the actual recipe for now. [docs/obs-macos.md](obs-macos.md) and [docs/obs-windows.md](obs-windows.md) cover how the per-track joining works today.

## Channel counts

The pipeline is order-flexible where the tools allow it. Earshot's transcode carries any channel count into `mapping_family 255` Opus, and the player reads the ambisonic order from the manifest's `AudioChannelConfiguration` (4 ch = 1st order, 16 ch = 3rd order; verified end to end for both). The hard limit sits in the RTMP contribution leg: ffmpeg's AAC encoder only accepts *named* channel layouts, so 4 (`quad`) and 16 (`hexadecagonal`) work while 9 (2nd order) and 25 (4th order) are refused outright; a 2nd-order source must be zero-padded to 16 channels by the sender (a valid 3rd-order signal with silent upper orders).

### Why 2nd order pads to 16 rather than to 10

A reasonable idea, once you know modern ffmpeg: send 2nd order as a 10-channel named layout such as `5.1.4` and waste one channel instead of seven. It does not work here, and the reason is the **vendored ffmpeg's age**, not the format.

Earshot pins its own ffmpeg fork (`FFMPEG_VERSION=earshot-v0.1`, a 4.3-era tree). Listing every named layout it accepts, from 6 channels up:

| Channels | Layouts this build has |
|---|---|
| 6, 7, 8 | `5.1`, `6.0`, `hexagonal`, `6.1`, `7.0`, `7.1`, `octagonal`, ... |
| 9 to 15 | **none at all** |
| 16 | `hexadecagonal` |
| 24 | `22.2` |

The table jumps straight from 8 to 16. There is no 9- or 10-channel name to land 2nd order in, so 9 channels must be zero-padded to 16: not a design preference, the only reachable layout.

Modern ffmpeg genuinely does have these. Version 8.1.2 lists `5.1.4` and `7.1.2` at 10 channels, `7.1.4` at 12, `9.1.4` at 14. So a layout table checked against a system ffmpeg will suggest options the transcoder cannot accept. Check inside the image before designing around one:

```bash
docker run --rm --entrypoint ffmpeg ambi-box-earshot:local -hide_banner -layouts
```

This also bounds what a re-vendor could buy: moving earshot to a current ffmpeg would put a 10-channel 2nd-order path within reach, though the player would then need to read 10 channels as 2nd order with one unused, rather than inferring order from the channel count alone.

**Over SRT, 1st and 3rd order both work, and the gateway picks between them for you.** `srt-gateway` buffers the start of the stream, asks ffprobe what is in it, and chooses: four 4-channel tracks are joined into one `hexadecagonal` stream (3rd order), while a single 4-channel track is already `quad` and passes straight through (1st order). Nothing is configured at either end. Anything else is refused within a few seconds with the reason, rather than being accepted and then producing no output. So a 1st-order microphone, which is what most ambisonic rigs are, works on the recommended route as one 4-channel track. A plain stereo or mono push produces no output at all and is auto-ended on the guest endpoint with that reason.

## Independent corroboration: a Quest 3 decodes both layouts

The `?dbg` capability probe on the VOD page (see the URL-flags note in [docs/ENDPOINTS.md](ENDPOINTS.md)) reports what a browser actually managed. On a Meta Quest 3 (2026-07-27):

<div align="center"> <img src="images/quest3-browser-capability.jpg" width="85%" alt="The VOD page open in a Meta Quest 3 browser at stream.bmroz.eu/vod/?dbg, showing the 360 test card rendered with the ambisonic energy overlay, and a diagnostic panel reporting that 2-, 16- and 25-channel Opus all decoded"> </div>

<p align="center"><em>The <code>?dbg</code> probe on a Meta Quest 3 (2026-07-27). The line that matters for order is <strong>25-channel Opus decoding on the headset itself</strong>: the delivery and playback end of a 4th-order chain is not the part that is missing. The same photograph appears in the <a href="../README.md#what-it-looks-like-running">main README</a>, where it stands for something simpler, that the stack runs on the device it is built for.</em></p>

```
Stereo Opus control (WebM):    DECODED (2 ch, 48000 Hz, 1 s)
16-channel (3OA) Opus (WebM):  DECODED (16 ch, 48000 Hz, 1 s)
25-channel (4OA) Opus (WebM):  DECODED (25 ch, 48000 Hz, 1 s)
```

Both the 3rd-order and the 4th-order layouts decode there, which is independent corroboration of the order-4 claim above from consumer hardware and a different browser engine (OculusBrowser 149) than the headless harness used for the end-to-end test. `AudioContext maxChannelCount: 2` in the same panel is the headset's *output* device being stereo, which is exactly right for binaural rendering; it is not a limit on what can be decoded.
