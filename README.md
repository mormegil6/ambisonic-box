[![Docker Compose](https://img.shields.io/badge/Docker-Compose-2496ED.svg?logo=docker&logoColor=white)](docker-compose.yml) [![FFmpeg](https://img.shields.io/badge/FFmpeg-16--ch%20Opus%20%2B%20VP9%2Fcopy-007808.svg?logo=ffmpeg&logoColor=white)](services/earshot/README.md) [![MPEG-DASH](https://img.shields.io/badge/MPEG--DASH-live-F76935.svg)](docs/ENDPOINTS.md) [![Ambisonics](https://img.shields.io/badge/Ambisonics-3rd%20order%2C%2016ch-8A2BE2.svg)](README.md#hoa-pipeline) [![Platform](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-lightgrey.svg?logo=linux&logoColor=white)](.env.example) [![Live demo](https://img.shields.io/badge/live%20demo-stream.bmroz.eu-1F6FEB.svg)](https://stream.bmroz.eu/) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

# hoa-360-stream: live 360 video and third-order Ambisonics over MPEG-DASH

Containerised toolchain for live streaming 360 video with Higher-Order Ambisonics audio, 1st to 3rd order (3OA, 16ch is the canonical configuration): RTMP in, MPEG-DASH (multichannel Opus, WebM) out, rendered binaurally in the browser by a patched [HOAST360](https://github.com/mormegil6/hoast360) player that picks the ambisonic order up from the stream.

**Live demo:** <https://stream.bmroz.eu/> · **Project page:** <https://bmroz.eu/projects/360-livestream/>

## Architecture

<div align="center"> <img src="docs/architecture/architecture.png" width="80%" alt="HOA 360 stream architecture: OBS and loop-source feed rtmp-ingest, earshot transcodes to 16-channel Opus DASH into the dash-output volume, hoast-player serves it to the viewer browser, with shaka packager and telemetry attached to the volume"> </div>

<p align="center"><em>The data path only. Control and monitoring edges are deliberately omitted; <a href="docs/architecture/README.md">docs/architecture/</a> lists exactly what the diagram simplifies.</em></p>

<!-- Diagram source + generator: docs/architecture/ (edit architecture.mmd, run ./build.sh). -->


The RTMP contribution leg is H.264 + 16-channel AAC by protocol necessity (legacy RTMP/FLV cannot carry VP9/Opus). From the earshot transcode onward the audio is always 16-ch Opus and is never downmixed: 3rd-order Ambisonics, ACN/SN3D, 16 channels end to end.

**Why 16 channels, and what it would take to go higher.** In practice: 1st order (4 ch) and 3rd order (16 ch) work end to end with no special handling, because `quad` and `hexadecagonal` are named AAC layouts; 2nd order (9 ch) must be zero-padded to 16 by the sender, because 9 is not one. The ceiling sits on the contribution leg, not on delivery or rendering. ffmpeg's AAC encoder refuses a 25-channel (4th-order) input outright - 16 works only because `hexadecagonal` is a *named* layout it accepts - and that leg has to be AAC because RTMP/FLV cannot carry Opus. Stock ffmpeg's AAC encoder can write that PCE for named layouts up to 22.2 (24 channels); earshot vendors a patched build so the image guarantees PCE support without depending on the host's ffmpeg version. Everything downstream is already order-4 capable, verified component by component: 25-channel Opus at `mapping_family 255` round-trips intact, Shaka Packager carries `AudioChannelConfiguration value="25"` into the manifest, and the player image ships the complete order-4 impulse-response set.

So **the on-demand path is 4th-order capable, verified end to end** - it never touches AAC, and the player reads the ambisonic order from the manifest, so a 25-channel clip plays as 4th order with no configuration. A synthetic 25-channel clip packaged by the same DASH tooling has been played through the full chain: auto-detected as order 4, rendered through the complete order-4 impulse-response set, audio and video clocks in sync. A real recording would sound different but exercise the identical code path, so nothing here is waiting on content. Raising the *live* path is a different matter, with two candidate routes. One stays on RTMP/AAC and gives up a channel: AAC's widest named layout is 22.2 (24 channels - encode, FLV mux and read-back verified on this stack's own ffmpeg), so dropping the 4th-order vertical harmonic (ACN 20) fits, the same perceptual trade Two Big Ears made when their 8-channel format dropped the 2nd-order vertical harmonic (ACN 6) - and here the order 1-3 vertical components (ACN 2, 6, 12) all survive. The other moves contribution off RTMP to SRT carrying Opus in MPEG-TS, which deletes the AAC transcode - and with it the ceiling - entirely, but turns the sender into a custom ffmpeg command (OBS tops out at 8 audio channels, the Music Edition fork at 16) and needs ingest auth rebuilt for SRT. Either way it is architectural rather than configuration. See the measurement notes (below, Documentation) for the numbers behind this.

**Video codec.** `docker-compose.yml`'s `FFMPEG_FLAGS` default is the single source of truth, and it is currently **H.264 passthrough** (`-c:v copy`) - so a clone with no `.env` streams passthrough, and video segments are `.m4s`/`.mp4` while audio stays Opus/WebM. VP9 (all-WebM) is the codec *policy* and ships as a ready-to-uncomment line in `.env.example`; it is not the running default: on the 2012 Mac Mini (quad-core i7) deployment host VP9 has been measured twice, scaled down and at the unscaled 4K this line would actually run, and the unscaled encode fell below realtime - so passthrough is the default. To check what a given host will actually do rather than trusting this paragraph:

```bash
docker compose config | grep FFMPEG_FLAGS
```

**PCE** is AAC's Program Config Element. Sixteen channels is not one of AAC's predefined layouts, so a stream carrying one has to spell the layout out in a PCE rather than name it. Stock ffmpeg does emit a PCE for named layouts like `hexadecagonal`; earshot vendors its own build so the image guarantees that regardless of the host's ffmpeg version. Without a PCE-capable encoder the contribution leg could not carry 16 channels over RTMP at all. `dash-output` is a Docker volume - the shared filesystem earshot segments into and nginx serves from, nothing to do with level.

| Service | Role | Host port |
|---|---|---|
| `rtmp-ingest` | public RTMP ingest; stream-key auth, relay to earshot | 1935 |
| `earshot` | transcode to 16-ch Opus + video per `FFMPEG_FLAGS` (H.264 passthrough default, VP9 opt-in), live DASH segmenting ([vendored Envelop Earshot](services/earshot/README.md), patched) | 8081 (dev monitor) |
| `loop-source` | demo contribution encoder: loops `content/demo.mp4` | - |
| `hoast-player` | viewer origin: patched HOAST360 player + `/dash/` | 8080 |
| `telemetry` | ops dashboard + breakage-only alerts + curated public status.json ([telemetry/](telemetry/README.md)) | 8090 (bind private) |
| `shaka` | Shaka Packager, offline only, never in the live path. Main job: `scripts/package-vod-dash.sh` runs the image standalone to package the on-demand clips into `content/vod/dash/` (the compose `tools` profile additionally drives the optional A/V-sync variant packaging, `scripts/package-dash-variants.sh`) | - |

## Requirements

- Docker Engine with the compose plugin (`docker compose`), buildx for multi-arch builds
- ~2 GB of image builds on first `compose build` (earshot compiles its nginx-rtmp and ffmpeg fork from source)
- Only for the test and measurement scripts: host `ffmpeg`/`ffprobe`; Node.js (`npm ci`, then `npx playwright install chromium` for the two headless-browser scripts); `python3` + matplotlib for the trade-off plot

## Quick start

```bash
git clone https://github.com/mormegil6/hoa-360-stream.git && cd hoa-360-stream
git submodule update --init
cp /path/to/demo.mp4 content/demo.mp4   # H.264 + 16-ch AAC; see .env.example
docker compose up -d --build
# then open http://localhost:8080 in your browser
# (Earshot monitor: http://localhost:8081/webtools)
```

Without `content/demo.mp4` the stack still demos itself: on first start loop-source synthesises a spherical placeholder in-container (black sphere with a test-pattern screen at the front, and a 440 Hz source orbiting the listener in 3rd-order Ambisonics, so looking around audibly works). With `VOD_ENABLED=1` it also fetches the two `/vod/` reference masters from the pinned `vod-clips` release (~373 MB once, background, SHA-256 verified, fail-soft). Set `DEMO_CONTENT=0` to skip the synthesis, or replace `content/demo.mp4` with a real master any time (`docker compose restart loop-source` picks it up).

## Stream your own content (the `live` application)

Use [OBS Studio Music Edition](https://github.com/pkviet/obs-studio/releases/) (supports 16.0 AAC):

| Setting | Value |
|---|---|
| Server | `rtmp://<host>:1935/live` |
| Stream key | `hoast_demo` (or your `STREAM_KEY`) |
| Audio | 16 channels, AAC, AmbiX (ACN/SN3D) channel order |
| Video | H.264, keyframe interval that divides the segment duration (equality preferred: `-g 60` at 29.97/30 fps, `-g 50` at 25 fps, for the default 2 s segments; shorter intervals are valid but cost bitrate) |

The stream appears at `http://<host>:8080/dash/<DASH_NAME>.mpd` (default `hoast_demo`), which is exactly what the bundled player page requests. The manifest name is `DASH_NAME`, independent of `STREAM_KEY`: a custom stream key no longer moves the manifest URL, so you can rotate the key without editing the player. A custom `DASH_NAME` needs no player edit either: the page asks telemetry (`/api/live`) which manifest the box is writing and falls back to `hoast_demo.mpd` only when telemetry is absent.

### Stock OBS on macOS: record multitrack, merge, push

Live 16-channel contribution needs OBS Music Edition (stock OBS caps a stream at one 8-channel track). But **stock OBS on macOS can still feed this stack** in a record-then-push flow, because its per-track ceiling is the only ceiling: with a multichannel Core Audio device (a BlackHole 16/64ch loopback, or an aggregate of your interface) and Preferences > Audio > Channels set to **7.1**, each OBS audio track records 8 fully discrete channels via CoreAudio AAC with input order preserved (verified per-tone, 2026-07-27). Six tracks are available, so 16 channels fit on two: route capture channels 1-8 to track 1 and 9-16 to track 2, enable both tracks in the recording output, and record.

The recording then needs one step, because OBS neither merges its own tracks nor tags them usefully (each says "7.1 surround", which is meaningless for ambisonics):

```bash
# sanity-check the capture shape first: expect 2 tracks x 8 channels
./scripts/merge-obs-tracks.sh --check recording.mkv

# a) one 16-channel PCM master (archival, VOD packaging input) ...
./scripts/merge-obs-tracks.sh recording.mkv master.mov --channels 16

# b) ... or push straight to the ingest (video copied, audio re-encoded
#    to 16-ch AAC with the PCE the RTMP leg needs, realtime-paced)
./scripts/merge-obs-tracks.sh recording.mkv --channels 16 \
    --push "rtmp://<host>:1935/live/<name>?token=<STREAM_KEY>"
```

The merge is strictly positional (track 1 becomes channels 1-8, track 2 becomes 9-16, never a downmix), so AmbiX channel order survives if the capture device carried it. `scripts/test-obs-merge.sh` proves this with a per-channel tone ladder, offline and (with `--e2e` and the stack up) through ingest and transcode to the emitted DASH Opus. Keep the OBS video settings from the table above; the push copies video untouched.


**Channel counts:** the pipeline is order-flexible where the tools allow it. Earshot's transcode carries any channel count into `mapping_family 255` Opus, and the player reads the ambisonic order from the manifest's `AudioChannelConfiguration` (4 ch = 1st order, 16 ch = 3rd order; verified end to end for both). The hard limit sits in the RTMP contribution leg: ffmpeg's AAC encoder only accepts *named* channel layouts, so 4 (`quad`) and 16 (`hexadecagonal`) work while 9 (2nd order) and 25 (4th order) are refused outright; a 2nd-order source must be zero-padded to 16 channels by the sender (a valid 3rd-order signal with silent upper orders). A plain stereo or mono push produces no output at all and is auto-ended on the guest endpoint with that reason.

## Guest test endpoint (the `guest` application)

Anyone with an ambisonic microphone rig and OBS Music Edition can test their stream against this stack without standing up their own server: a keyless RTMP application that borrows the whole pipeline for the duration of a session.

**Disabled by default.** Most deployments are a single private publisher and should never expose a keyless application; set `GUEST_ENABLED=1` to opt in. Off, the `guest` application does not exist in the ingest config and the status pages carry no trace of it.

| Setting | Value |
|---|---|
| Server | `rtmp://<host>:1935/guest` |
| Stream key | anything you like (it names your session in the status pages) |
| Audio / video | same requirements as the `live` application [above](#stream-your-own-content-the-live-application) |

How it behaves:

- **First come, first served, one publisher at a time.** A second concurrent push is rejected outright (OBS shows "Failed to connect"), not queued. There is deliberately no reservation or key system; contention shows up in the telemetry history instead.
- While a guest publishes, the demo loop pauses and the public player page serves the guest's stream: watching your own test is just the normal player URL, shareable as-is.
- **Reconnect window:** if the publisher disconnects, the slot is held for `GUEST_GRACE_S` (default 120 s). Reconnect within it and the session continues; otherwise the session ends and the demo loop returns to its normal on-demand behaviour.
- **Session cap:** an actively publishing guest may run `GUEST_MAX_S` (default 3 h, long enough for a rehearsal or a real event). The cap is enforced within one liveness-ping interval (~10 s), so it is soft by up to that much. Reconnecting does not reset the clock.
- **Cooldown after a forced end:** when a session is ended by the cap or by the dashboard's End session button (not by a natural stop), guest publishes are refused for `GUEST_COOLDOWN_S` (default 300 s; OBS's default auto-reconnect keeps retrying for roughly 3 hours with exponential backoff, so the cooldown spaces out reclaim attempts rather than outlasting them). Without it, an auto-reconnecting encoder would re-claim the freed slot in seconds, turning the cap into a duty cycle and the kill button into a two-second blip.
- The `:8090` dashboard shows the session (name, source address, time left) and has an **End session** button; the public player page shows only endpoint state, sanitised name and time left.
- **Session log:** anonymised statistics (timestamp, name, country, duration, end reason) are kept indefinitely; the source IP is truncated to its network prefix (a.b.c.x, v6 /48) after `GUEST_RETENTION_DAYS` (default 30), keeping repeat-network patterns visible without keeping the address. Country comes from a local DB-IP lookup; guest IPs are never sent to an online service.
- **Privacy notice:** while a session is active the player shows a collapsible bilingual notice (EN default, PL switch) stating the cap, logging, retention, reporting and ban rules, with the numbers interpolated from the running config. A built-in generic text ships in the page, so the notice works with no brand.json; a deployment's `brand.json guestDisclaimer` replaces the wording wholesale.
- **Reporting:** the player page shows a report button while a guest session is active. Reports are rate-limited (per reporter IP at nginx and in the arbiter) and alert the operator; reporter IPs live under the same `GUEST_RETENTION_DAYS` redaction as everything else.
- **Bans:** the dashboard's End + ban button blocks the session's source IP for `GUEST_BAN_DAYS` (default 30, clamped to the retention window: ban expiry and IP redaction are deliberately the same event). Bans can be lifted early from the dashboard. This is a SPEED BUMP, not enforcement: dynamic IPs, CGNAT and VPNs all defeat an IP ban. It exists to make casual misuse inconvenient, nothing more.
- **Stalled transcodes:** a guest pushing the wrong audio layout (plain stereo/mono is the classic mistake) produces no playable output; the session is ended automatically after ~45 s and the reason is shown on the player page, with no cooldown so a corrected retry works immediately.
- **Fail-closed:** if telemetry is down, guest publishes are rejected while the token-authed `live` application and the demo loop keep working.
- The owner path is unaffected: pushing with the stream key to `/live` does not consult the arbiter. Do not do both at once; check the dashboard (or press End session) before an owner broadcast.

**Network prerequisite:** the guest endpoint is exactly as public as TCP port 1935. If your host sits behind a firewall or NAT, the one thing to arrange is inbound TCP 1935; everything else ships in this compose file.

## On-demand VOD clips

**Off by default.** Set `VOD_ENABLED=1` to serve the on-demand page; disabled, the `/vod/` and `/vod-dash/` routes return 404, the Live|VOD nav pill is removed, and loop-source skips the reference-master fetch. The two flags are independent: `DEMO_CONTENT` governs the live verification loop (placeholder synthesis), `VOD_ENABLED` governs the on-demand clips, and `VOD_ENABLED=0` suppresses the clip fetch even with `DEMO_CONTENT=1`.

When enabled, the player serves on-demand reference clips at `/vod/` (`/vod/?clip=<name>`). Delivery location is a `brand.json` choice: `vodBase` empty or absent serves the clips from this host's `/vod-dash/` route; setting it to a URL serves them from an external host that mirrors the `vod-dash/` tree (see "Optional: serving VOD from object storage" below for the CORS requirements). The player reads the key at clip start, so switching needs no rebuild. Two are published as [release assets](https://github.com/mormegil6/hoa-360-stream/releases/tag/vod-clips) - no media is committed here, only the generators and the player wiring: `directions` (a 360 orientation test - the equirectangular test card from `scripts/make-360-testcard.py`, an ambisonic energy-visualisation overlay, and spoken front/right/left/top reads from an ambisonic recording, so only the audio is not generated here) and `colortones` (colour-and-tone A/V-sync pattern, fully generated by `scripts/make-colortones.sh`). Put the masters in `content/vod/masters/` (gitignored); `scripts/encode-vod-ladder.sh` builds the resolution ladder and `scripts/package-vod-dash.sh` packages it into combined-MPD DASH under `content/vod/dash/<clip>/`, served at `/vod-dash/`.

**360 test card.** `scripts/make-360-testcard.py` renders six flat broadcast test screens and arranges them as the walls of a cube around the viewer, then inverse-projects that into equirectangular. Each wall spans exactly 90°, so a 360 viewer at a normal field of view sees a flat, undistorted card: circles stay round and straight lines stay straight, and any bend, softening or colour shift is the pipeline's doing rather than the projection's. Each face carries EBU 75 % colour bars, a grey staircase, PLUGE, a multiburst, a checkerboard, a band-limited detail patch and a Siemens star, plus its own name and centre bearing - so the picture reports resolution, gamma, range handling and compression damage in whichever direction you happen to be looking. The poles become ordinary ceiling and floor walls instead of smeared blobs. Drawing directly in equirectangular cannot do this: the pattern is pre-distorted, so nothing in it has a known shape by the time it reaches the eye.

```
scripts/make-360-testcard.py -o content/vod/masters/testcard-360_8k.png
scripts/make-360-testcard.py --pattern dummy --width 3072   # projection check
```

`--pattern dummy` swaps the artwork for deliberately asymmetric validation faces, which is how the geometry is checked independently of the picture. The mapping is the same one ffmpeg's `v360` filter implements, so `v360=c6x1:e` over a `right,left,up,down,front,back` strip is an independent cross-check (it agrees to 0.05/255). `scripts/make-orientation-card.py` remains as the plain measurement graticule - degree ticks and cardinal labels, no imaging targets.

The rendered 8K card ships as a **release asset** alongside the clip masters and caption sidecars; only the generator is tracked here, so a fresh clone reproduces the card rather than downloading it.

**Captions.** Each clip carries WebVTT subtitles beside its segments as `captions_<lang>.vtt`, declared per clip in the `CLIPS` table in `services/hoast-player/index.html`:

```js
captions: [
  { src: '/vod-dash/directions/captions_en.vtt', lang: 'en', label: 'English' },
  { src: '/vod-dash/directions/captions_pl.vtt', lang: 'pl', label: 'Polski' }
]
```

The `.vtt` files are not tracked here - like the clip masters they ship as [release assets](https://github.com/mormegil6/hoa-360-stream/releases/tag/vod-clips), so a fresh `git clone` has the caption *config* but not the caption *files*. `scripts/make-colortones.sh` emits the colortones pair as part of generating that clip; `scripts/make-directions-captions.sh` (a flagged clip-specific one-off, since `directions` is a recording rather than something this repo generates) emits the directions pair.

The player side-loads these as native `<track>` elements rather than reading a DASH `text` AdaptationSet, which renders unreliably through videojs-contrib-dash (measured; see the note on the measurement notes under Documentation). `services/hoast-player/vod-locations.conf` must therefore type `.vtt` as `text/vtt` in the `/vod-dash/` location: it's the registered, spec-correct MIME type, and current browsers key on the `WEBVTT` file signature regardless, but there's no reason to serve it as anything else.

### Playing it on a standalone headset

The clips play in a Meta Quest 3's own browser, with no app to install and nothing to configure: open the page and drag to look around. The headset's browser decodes the multichannel Opus directly and the page renders the sound field binaurally, head-tracked, the same as on desktop.

<div align="center"> <img src="docs/images/quest3-browser-capability.jpg" width="85%" alt="The VOD page open in a Meta Quest 3 browser at stream.bmroz.eu/vod/?dbg, showing the 360 test card rendered with the ambisonic energy overlay, and a diagnostic panel reporting that 2-, 16- and 25-channel Opus all decoded"> </div>

The panel in that shot is the `?dbg` capability probe (see the URL-flags note in [docs/ENDPOINTS.md](docs/ENDPOINTS.md)), reporting what the headset's browser actually managed:

```
Stereo Opus control (WebM):    DECODED (2 ch, 48000 Hz, 1 s)
16-channel (3OA) Opus (WebM):  DECODED (16 ch, 48000 Hz, 1 s)
25-channel (4OA) Opus (WebM):  DECODED (25 ch, 48000 Hz, 1 s)
```

Both the 3rd-order and the 4th-order layouts decode there, which is independent corroboration of the order-4 claim above from consumer hardware and a different browser engine (OculusBrowser 149) than the headless harness used for the end-to-end test. `AudioContext maxChannelCount: 2` in the same panel is the headset's *output* device being stereo, which is exactly right for binaural rendering; it is not a limit on what can be decoded.

## Optional: serving VOD from object storage

By default the stack serves the on-demand clips itself (`/vod-dash/` out of `content/vod/dash`). If you front the player with a CDN, check its terms before leaving large video on that path: Cloudflare, for example, restricts serving large non-Cloudflare-hosted video through their proxy, offloading VOD to an object-storage origin (Cloudflare R2, for example) avoids this.

To do the same: upload `content/vod/dash/` to a bucket under a `vod-dash/` prefix, attach a custom domain, allow CORS from your player origin including the `range` request header (DASH SegmentBase addresses by byte range), and set `vodBase` in `brand.json` to that domain. Removing the key falls back to box-served VOD instantly; the local copy and route stay in place either way.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `STREAM_KEY` | `hoast_demo` | Publish auth at rtmp-ingest: stream name or `?token=` must match |
| `DASH_NAME` | `hoast_demo` | Public DASH manifest filename served at `/dash/<DASH_NAME>.mpd`. Fixed and validated (`[A-Za-z0-9_-]+`) at earshot; decoupled from `STREAM_KEY` so the key is rotatable. The player discovers the manifest via telemetry (`/api/live`) and only falls back to the literal `hoast_demo.mpd` without it |
| `FFMPEG_FLAGS` | the `docker-compose.yml` fallback (single source of truth) | Video policy of the earshot transcode; audio is always 16-ch Opus. Check the effective value with `docker compose config \| grep FFMPEG_FLAGS`; a VP9 opt-in line ships commented in `.env.example` |
| `DEMO_CONTENT` | `1` | Self-provisioning demo at loop-source start: synthesise the spherical placeholder when `content/demo.mp4` is missing, fetch the VOD masters from the pinned release when absent (~373 MB once, SHA-256-verified, fail-soft). `0` = neither; see Quick start |
| `VOD_ENABLED` | `0` | On-demand VOD page + packaged clips, off by default: the stack's purpose is live streaming, VOD is opt-in. `0` serves no VOD route and suppresses the reference-master fetch even with `DEMO_CONTENT=1`; the packaging scripts stay in the repo, inert until run |
| `GUEST_ENABLED` | `0` | Keyless guest test endpoint, off by default; see the Guest test endpoint section. Timing knobs (`GUEST_GRACE_S`, `GUEST_MAX_S`, `GUEST_COOLDOWN_S`, `GUEST_RETENTION_DAYS`, `GUEST_BAN_DAYS`) are documented in `.env.example` |
| `ENABLE_NONFREE` | `0` | earshot ffmpeg licence stamp: the stack builds WITHOUT `--enable-nonfree` so images are redistributable; `1` restores the stock upstream configure line (`services/earshot/README.md` section 7) |

Copy `.env.example` to `.env` to override either.

Two things are deliberately *not* env-tunable: the audio policy (16-ch Opus, hardcoded upstream in Earshot) and the live-edge distance. The earshot image build patches ffmpeg's DASH muxer to floor `suggestedPresentationDelay` at 30 s (`DASH_SPD_FLOOR` build arg), so players join ~30 s behind the live edge by design. That is the price of gap-free playback of a 16-channel live stream.

## Measurements: DASH segment duration

Does segment duration affect lip sync? Measured answer: **no**. The A/V start offset is structurally 0 ms across 0.5/1/2/4 s variants (audio stream-copied, video GOP the only variable; details in [lip-sync-test/RESULTS.md](lip-sync-test/RESULTS.md)). Segment duration is instead a bitrate/latency trade-off:

![Bitrate and buffer depth vs segment duration](lip-sync-test/segment-tradeoff.svg)

0.5 s segments force a keyframe every 15 frames and push realtime VP9 ~10x past its bitrate target (~6x the 2 s variant's bitrate), with visible stalls; 4 s segments halve the time-shift granularity for no gain. **2 s is the default** (`-g 60 -seg_duration 2` at 29.97/30 fps).

## Test and measurement scripts

| Script | Purpose |
|---|---|
| `scripts/test-pipeline.sh` | synthetic end-to-end test: 16 sine channels + test video pushed through ingest auth, asserts live 16-ch Opus/VP9 DASH appears; PASS/FAIL |
| `scripts/make-lipsync-scene.sh` | cut a GOP-matched, tv-range transient excerpt for by-ear lip-sync judging |
| `scripts/package-dash-variants.sh` | package a WebM master into 0.5/1/2/4 s DASH variants for the comparison page (`lip-sync-test/index.html`) |
| `scripts/measure-lipsync.js` | headless-Chromium A/V measurement over the packaged variants |
| `scripts/plot-segment-tradeoff.py` | regenerate the segment-duration trade-off figure |
| `scripts/smoke-hoast360.js` | headless-browser smoke test of the patched player |

`package-dash-variants.sh` drives Shaka Packager through the compose `tools` profile. The pattern for manual runs is `docker compose run --rm shaka <packager args>`.

## Working directories: `output/` and `scratch/`

Two gitignored directories at the repo root, with opposite guarantees.

`output/` is **earshot's** working directory: the DASH volume is bind-backed by it, and earshot's entrypoint clears that directory on every container start so each run begins a fresh timeline. Anything you leave in `output/` is deleted by the next `docker compose up`. That is intended for segments, and a trap for everything else.

`scratch/` is mounted alongside at `/opt/data/scratch` and is never touched by earshot, which only ever clears `.../dash`. Put anything that has to survive a restart here: test harnesses, probe captures written from inside the container, one-off files. Because it sits inside the repo, Node also resolves the root `node_modules` from it, so browser-based harnesses run without extra path setup.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Relay `Connection refused` after recreating earshot | rtmp-ingest resolves earshot's address once, at startup | `docker compose restart rtmp-ingest` |
| Segments longer than `-seg_duration` (e.g. 3.34 s) | GOP duration does not divide the segment target, so no keyframe lands on the boundary and the muxer closes at the next one (`-g 50` at 29.97 fps is a 1.668 s GOP, so the first keyframe at or after 2 s falls at 3.336 s) | set `-g` so the segment duration is an integer multiple of the GOP (`-g 60` @ 29.97/30, `-g 50` @ 25); equality is the preferred default for the live encode |
| Browser loops `PIPELINE_ERROR_DECODE` | full-range (pc) VP9 source breaks the dash.js/MSE path | re-encode to limited range: `-vf scale=in_range=pc:out_range=tv -color_range tv` |
| `loop-source` idle although `demo.mp4` exists | file presence is checked once at startup | `docker compose restart loop-source` |
| Publisher dies seconds into a 4K push | RTMP message limit smaller than 4K keyframes | keep `max_message 10M` in the nginx-rtmp configs (already set here) |

## Deployment

**Local / lab (AMD64):** the quick start above. Validated on WSL2 Ubuntu and Ubuntu Server 22.04.

**Planned, not yet validated end to end:** Azure (for one-off events; raw TCP ingress for 1935 is the constraint to solve there) and Raspberry Pi 5 (all base images are multi-arch and `docker buildx build --platform linux/arm64` compiles, but no Pi has run a real stream yet). Treat both as directions, not documented paths; this section will grow real instructions when a real deployment produces them.

**Per-host overrides:** deployment-specific settings (bind the dashboard (:8090) to a private/Tailscale IP, mount host CPU-temp/disk for the telemetry service, Telegram tokens, a branded landing page) go in `docker-compose.override.yml`, which Compose loads automatically and which is gitignored. Copy [docker-compose.override.yml.example](docker-compose.override.yml.example) and adjust. The base stack runs without it.

## Documentation

- Measurement notes: the detailed measured results behind this README (transcode thermals, codec constraints, segment-duration trade-offs, A/V-sync mechanism, AV1 viability) are being written up for publication and are deliberately not in the repo. This README will carry the citation and the tagged commit once the papers are out.
- [docs/ENDPOINTS.md](docs/ENDPOINTS.md): every port/endpoint the stack exposes, public vs private, and what to monitor
- [telemetry/README.md](telemetry/README.md): monitoring service (dashboard + alerts + public status.json)
- [services/earshot/README.md](services/earshot/README.md): Earshot vendoring provenance and local patches
- [lip-sync-test/RESULTS.md](lip-sync-test/RESULTS.md): full segment-duration / lip-sync study
- [.env.example](.env.example): configuration reference, including how to prepare `content/demo.mp4`

## License

Compose files, service configs and scripts in this repository: **Apache 2.0**. Bundled and built components keep their own licenses:

| Component | License |
|---|---|
| [HOAST360](https://github.com/mormegil6/hoast360) (patched fork, git submodule) | GPL-3.0-or-later |
| [Envelop Earshot](https://github.com/EnvelopSound/Earshot) (vendored in `services/earshot/src`, three documented patches) | GPL |
| Envelop/pkviet FFmpeg fork (built inside the earshot image) | GPL v3 (built with `--enable-gpl`; the default build (`ENABLE_NONFREE=0`) is redistributable, and only an explicit `ENABLE_NONFREE=1` build carries the non-redistributable `--enable-nonfree` stamp (services/earshot/README.md section 7)) |
| [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module) | BSD-2-Clause |
| [Shaka Packager](https://github.com/shaka-project/shaka-packager) (official image) | BSD-3-Clause |
| nginx, Alpine packages | BSD-2-Clause / various |

## Citation

This repository is the containerised successor of the toolchain described in the paper below. If you use this work in research, please cite it:

```bibtex
@inproceedings{mroz2023toolchain,
  title     = {A Commonly-Accessible Toolchain for Live Streaming Music Events
               with Higher-Order Ambisonic Audio and 4K 360 Vision},
  author    = {Mr{\'o}z, Bart{\l}omiej and Odya, Piotr and Danowski,
               Przemys{\l}aw and Kabaci{\'n}ski, Marek},
  booktitle = {Proceedings of the AES International Conference on Spatial and
               Immersive Audio},
  publisher = {Audio Engineering Society},
  month     = aug,
  year      = {2023},
  url       = {https://www.aes.org/e-lib/browse.cfm?elib=22204}
}
```

## Acknowledgments

- Thomas Deppisch and Nils Meyer-Kahlen, [HOAST360](https://github.com/thomasdeppisch/hoast360), the higher-order Ambisonics 360 player this project patches and serves
- [Envelop](https://envelop.us), Earshot, the multichannel RTMP-to-DASH transcoder
- pkviet, [OBS Studio Music Edition](https://github.com/pkviet/obs-studio) and the PCE-capable FFmpeg fork
- [Shaka project](https://github.com/shaka-project), Shaka Packager
- Gdańsk University of Technology, [Department of Multimedia Systems](https://multimed.org/index_en.html)

## Contact

Bartłomiej Mróz · bartlomiej.mroz@pg.edu.pl · Department of Multimedia Systems, Gdańsk University of Technology · [bmroz.eu](https://bmroz.eu)
