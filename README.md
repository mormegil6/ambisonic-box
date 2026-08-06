[![Docker Compose](https://img.shields.io/badge/Docker-Compose-2496ED.svg?logo=docker&logoColor=white)](docker-compose.yml) [![FFmpeg](https://img.shields.io/badge/FFmpeg-16--ch%20Opus%20%2B%20VP9%2Fcopy-007808.svg?logo=ffmpeg&logoColor=white)](services/earshot/README.md) [![MPEG-DASH](https://img.shields.io/badge/MPEG--DASH-live-F76935.svg)](docs/ENDPOINTS.md) [![Ambisonics](https://img.shields.io/badge/Ambisonics-3rd%20order%2C%2016ch-8A2BE2.svg)](docs/AMBISONIC-ORDER.md) [![Platform](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-lightgrey.svg?logo=linux&logoColor=white)](.env.example) [![Live demo](https://img.shields.io/badge/live%20demo-stream.bmroz.eu-1F6FEB.svg)](https://stream.bmroz.eu/) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

# hoa-360-stream: live 360 video and third-order Ambisonics over MPEG-DASH

Containerised toolchain for live streaming 360 video with Higher-Order Ambisonics audio, 1st to 3rd order (3OA, 16ch is the canonical configuration): RTMP in, MPEG-DASH (multichannel Opus, WebM) out, rendered binaurally in the browser by a patched [HOAST360](https://github.com/mormegil6/hoast360) player that picks the ambisonic order up from the stream.

**Live demo:** <https://stream.bmroz.eu/> · **Project page:** <https://bmroz.eu/projects/360-livestream/>

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

## Requirements

- Docker Engine with the compose plugin (`docker compose`), buildx for multi-arch builds
- ~2 GB of image builds on first `compose build` (earshot compiles its nginx-rtmp and ffmpeg fork from source)
- Only for the test and measurement scripts: host `ffmpeg`/`ffprobe`; Node.js (`npm ci`, then `npx playwright install chromium` for the two headless-browser scripts); `python3` + matplotlib for the trade-off plot

## Architecture

<div align="center"> <img src="docs/architecture/architecture.png" width="80%" alt="HOA 360 stream architecture: OBS and loop-source feed rtmp-ingest, earshot transcodes to 16-channel Opus DASH into the dash-output volume, hoast-player serves it to the viewer browser, with shaka packager and telemetry attached to the volume"> </div>

<p align="center"><em>The data path only. Control and monitoring edges are deliberately omitted; <a href="docs/architecture/README.md">docs/architecture/</a> lists exactly what the diagram simplifies.</em></p>

<!-- Diagram source + generator: docs/architecture/ (edit architecture.mmd, run ./build.sh). -->

**Contribution is H.264 + 16-channel AAC on both routes.** Over RTMP that is protocol necessity, since legacy RTMP/FLV cannot carry VP9 or Opus. Over SRT the sender is free of it (OBS sends four separate 4-channel AAC tracks in MPEG-TS), but the gateway rejoins those tracks and republishes them as one 16-channel AAC stream over RTMP into the same ingest, deliberately, so that every piece of guest arbitration applies to SRT unchanged. From the earshot transcode onward the audio is always 16-ch Opus and is never downmixed: 3rd-order Ambisonics, ACN/SN3D, 16 channels end to end.

**Why 16 and not 25, and what would lift it.** ffmpeg's AAC encoder accepts only *named* channel layouts, so 4 (`quad`) and 16 (`hexadecagonal`) pass while 9 and 25 are refused outright. That is a limit on the AAC hop, not on delivery or rendering: the on-demand path never touches AAC and is **4th-order verified end to end** (a 25-channel clip auto-detected as order 4, rendered through the full order-4 impulse-response set). Live 4th order is therefore **theoretically reachable but untested, and nothing here claims it**. Reaching it needs two independent things: a wider sender layout, which multitrack SRT already makes possible (25 channels would fit as six 5-channel tracks, each individually a layout AAC accepts), and a gateway that stops funnelling through 16-channel AAC over RTMP, which is architectural rather than configuration. The full argument, the two candidate routes past the ceiling, and the sender-side arithmetic beyond 3rd order are in [docs/AMBISONIC-ORDER.md](docs/AMBISONIC-ORDER.md).

**Video codec.** `docker-compose.yml`'s `FFMPEG_FLAGS` default is the single source of truth, and it is currently **H.264 passthrough** (`-c:v copy`) - so a clone with no `.env` streams passthrough, and video segments are `.m4s`/`.mp4` while audio stays Opus/WebM. VP9 (all-WebM) is the codec *policy* and ships as a ready-to-uncomment line in `.env.example`; it is not the running default: on the 2012 Mac Mini (quad-core i7) deployment host VP9 has been measured twice, scaled down and at the unscaled 4K this line would actually run, and the unscaled encode fell below realtime - so passthrough is the default. To check what a given host will actually do rather than trusting this paragraph:

```bash
docker compose config | grep FFMPEG_FLAGS
```

`dash-output` in the diagram is a Docker volume - the shared filesystem earshot segments into and nginx serves from, nothing to do with level.

| Service | Role | Host port |
|---|---|---|
| `rtmp-ingest` | public RTMP ingest; stream-key auth, relay to earshot | 1935 |
| `srt-gateway` | SRT contribution ingest (native OBS multitrack); joins 4x4 to 16-ch, republishes into the guest arbiter. Privilege-separated. See `SRT_ENABLED` / `GUEST_ENABLED` | 8890/udp |
| `earshot` | transcode to 16-ch Opus + video per `FFMPEG_FLAGS` (H.264 passthrough default, VP9 opt-in), live DASH segmenting ([vendored Envelop Earshot](services/earshot/README.md), patched) | 8081 (dev monitor) |
| `loop-source` | demo contribution encoder: loops `content/demo.mp4` | - |
| `hoast-player` | viewer origin: patched HOAST360 player + `/dash/` | 8080 |
| `telemetry` | ops dashboard + breakage-only alerts + curated public status.json ([telemetry/](telemetry/README.md)) | 8090 (bind private) |
| `shaka` | Shaka Packager, offline only, never in the live path. Main job: `scripts/package-vod-dash.sh` runs the image standalone to package the on-demand clips into `content/vod/dash/` (the compose `tools` profile additionally drives the optional A/V-sync variant packaging, `scripts/package-dash-variants.sh`) | - |

### What it looks like running

<div align="center"> <img src="docs/images/telemetry-dashboard.png" width="88%" alt="The telemetry dashboard: a services row showing srt-gateway, rtmp-ingest, earshot, hoast-player and telemetry all healthy; reachability chips for the tunnel, the VOD origin and the backup; stream detail (resolution, bitrate, egress, RTMP links, segment age); host load, memory, disk and uptime; and three-hour history sparklines for viewers, CPU temperature and stream liveness."> </div>

<p align="center"><em>The private telemetry dashboard on :8090 - service health, reachability, stream detail and host state. Details in <a href="telemetry/README.md">telemetry/README.md</a>.</em></p>

<div align="center"> <img src="docs/images/quest3-browser-capability.jpg" width="85%" alt="The VOD page open in a Meta Quest 3 browser at stream.bmroz.eu/vod/?dbg, showing the 360 test card rendered with the ambisonic energy overlay, and a diagnostic panel reporting that 2-, 16- and 25-channel Opus all decoded"> </div>

<p align="center"><em>A Meta Quest 3 browser playing the stream at stream.bmroz.eu, with the <code>?dbg</code> capability probe reporting that 2-, 16- and 25-channel Opus all decoded on the headset itself. What that probe implies about ambisonic order is in <a href="docs/AMBISONIC-ORDER.md">docs/AMBISONIC-ORDER.md</a>.</em></p>

## Stream your own content

Two ways in. **SRT is the recommended one**: stock OBS, no patched fork, the same recipe on macOS and Windows, all 16 channels live.

| | SRT (recommended) | RTMP (legacy) |
|---|---|---|
| Sender | stock OBS, macOS or Windows | OBS Studio Music Edition, Windows only |
| Audio | 4 tracks x 4 channels, joined to 16 by `srt-gateway` | one 16-channel AAC track |
| Enabled | on by default (`SRT_ENABLED=0` unbinds the port), but the gateway republishes into the guest application, so it admits nobody until `GUEST_ENABLED=1` | always |

Both carry H.264 video with a keyframe interval that divides the segment duration (equality preferred: `-g 60` at 29.97/30 fps, `-g 50` at 25 fps, for the default 2 s segments; shorter intervals are valid but cost bitrate). Both land in the same place and obey the same guest session rules.

### Stock OBS over SRT

These settings are the same on macOS and Windows - only the audio routing differs, which is what the per-OS guides below cover.

| Setting | Value |
|---|---|
| Settings > Audio > Channels | **`4.0`** |
| Settings > Output > Output Mode | **Advanced**, then the **Recording** tab |
| Type | **Custom Output (FFmpeg)** |
| FFmpeg Output Type | **Output to URL** |
| File path or URL | `srt://<host>:8890?streamid=<your-name>&latency=2000000&pkt_size=1128` |
| Container Format | **mpegts** |
| Audio Encoder | plain **`aac`** - tick **"Show all codecs"** if hidden |
| Audio Track | tick **1, 2, 3, 4** |
| Muxer Settings | leave empty |
| Bitrates | audio 384 kbit/s per track, video against your uplink, see [docs/BITRATE.md](docs/BITRATE.md) |
| Start it with | **Start Recording** (not Start Streaming - see below) |

Custom Output (FFmpeg) is a **Recording**-tab output in OBS, even though it is streaming to a URL, so **Start Recording** is the button that pushes. Nothing appears under Start Streaming.

Feed those four tracks from four 4-channel sources - device channels 1-4, 5-8, 9-12, 13-16, downmixing off - assigned one per track in Advanced Audio Properties. The join is strictly positional (track 1 becomes channels 1-4, and so on, never a downmix), so AmbiX order survives end to end.

**Channel counts, sender side:** 4 channels (1st order) and 16 (3rd order) pass through as they are, but a 2nd-order source must be zero-padded to 16 channels by the sender (a valid 3rd-order signal with silent upper orders), and a plain stereo or mono push produces no output at all - on the guest endpoint it is auto-ended with that reason. Six tracks would fit 4th order on the sender side, but the gateway still rejoins to 16-channel AAC over RTMP, so the live ceiling does not move: [docs/AMBISONIC-ORDER.md](docs/AMBISONIC-ORDER.md).

Four of those values are exact rather than indicative. Each was established by pushing a per-channel tone ladder through real hardware and reading back what arrived, because each obvious-looking alternative fails **without any error**:

- **`4.0`, never `7.1`** - OBS's 7.1 path mutes the LFE slot outright, which for ambisonics erases ACN 3, the X axis.
- **plain `aac`, never `mp2` or `aac_at`** - `mp2` is the container default and refuses more than 2 channels; `aac_at` (CoreAudio, macOS) scrambles channel order within every track.
- **`latency` is in MICROSECONDS** - 2 s is `2000000`, not `2000`.
- **`pkt_size=1128` through a tunnel** - SRT's default packet is about 1316 bytes and a WireGuard or Tailscale tunnel carries a 1280-byte MTU, so every packet fragments; under load a large share of the fragments never reassemble and the picture arrives shredded while SRT still reports the link up. Harmless on an ordinary 1500-byte path, essential on a tunnelled one.

#### Bitrate

Audio is paid once on the uplink, so the contribution rule is generous: 96 kbit/s per channel, which is where the 384 kbit/s for four tracks in the recipes above comes from. Video is the opposite trade, paid per viewer, and this deployment's 6.5 Mbit/s at 4096x2048 is a deliberate egress choice rather than a quality recommendation. The published anchors behind both, and the honest caveat that no transparency measurement exists for AAC-coded ambisonics, are in [docs/BITRATE.md](docs/BITRATE.md).

**Per-OS routing, step by step:**

- **[docs/obs-macos.md](docs/obs-macos.md)** - a multichannel Core Audio device ([BlackHole](https://github.com/ExistentialAudio/BlackHole))
- **[docs/obs-windows.md](docs/obs-windows.md)** - ASIO, via REAPER's ReaRoute and the atkAudio plugin

### Legacy: RTMP

RTMP carries exactly one audio track, so 16 channels over it need [OBS Studio Music Edition](https://github.com/pkviet/obs-studio/releases/), a Windows-only patched fork. It stays fully supported - the demo loop uses this path - but new setups should start with SRT above.

| Setting | Value |
|---|---|
| Server | `rtmp://<host>:1935/live` |
| Stream key | `hoast_demo` (or your `STREAM_KEY`) |
| Audio | 16 channels, AAC, AmbiX (ACN/SN3D) channel order |

The stream appears at `http://<host>:8080/dash/<DASH_NAME>.mpd` (default `hoast_demo`), which is exactly what the bundled player page requests. The manifest name is `DASH_NAME`, independent of `STREAM_KEY`: a custom stream key no longer moves the manifest URL, so you can rotate the key without editing the player. A custom `DASH_NAME` needs no player edit either: the page asks telemetry (`/api/live`) which manifest the box is writing and falls back to `hoast_demo.mpd` only when telemetry is absent.

## Guest test endpoint (the `guest` application)

Anyone with an ambisonic microphone rig and OBS can test their stream against this stack without standing up their own server: a keyless application that borrows the whole pipeline for the duration of a session.

> **UNDER CONSTRUCTION on the public demo at [stream.bmroz.eu](https://stream.bmroz.eu/).** The endpoint is fully implemented and works today over a LAN or a VPN, but it is **not yet reachable from the public internet on the reference deployment**: guests are the only thing that needs an inbound port opened, and that request is still with university IT administration. Nothing else is affected, because the player egresses through an outbound tunnel and the operator's own contribution path rides the VPN. If you are running your own instance this does not apply to you: open the port on your own host and the endpoint is reachable immediately.

**Disabled by default.** Most deployments are a single private publisher and should never expose a keyless application; set `GUEST_ENABLED=1` to opt in. Off, the `guest` application does not exist in the ingest config and the status pages carry no trace of it.

| Setting | Value |
|---|---|
| Server (SRT, recommended) | `srt://<host>:8890?streamid=<name>&latency=2000000&pkt_size=1128` |
| Server (RTMP) | `rtmp://<host>:1935/guest` |
| Stream key / streamid | anything you like (it names your session in the status pages) |
| Audio / video | same requirements as the `live` application [above](#stream-your-own-content) |

The four rules that decide whether a session works:

- **One publisher at a time, first come first served.** A second concurrent push is rejected outright, not queued.
- **Reconnect grace** of `GUEST_GRACE_S` (default 120 s): reconnect inside it and the session continues.
- **Session cap** of `GUEST_MAX_S` (default 3 h), then a `GUEST_COOLDOWN_S` cooldown (default 300 s) after any forced end, so an auto-reconnecting encoder cannot re-claim the slot instantly.
- **Optional resource guard** (`GUEST_MAX_TEMP_C`, `GUEST_MAX_MBPS`, both off by default): temperature is the one to trust, bitrate is a coarse pre-filter. Set both from a measurement of your own host.

**Network prerequisite:** the RTMP guest endpoint is exactly as public as TCP port 1935; the SRT endpoint (if enabled) is exactly as public as UDP 8890. If your host sits behind a firewall or NAT, the one thing to arrange is inbound access to whichever port(s) you use; everything else ships in this compose file.

Everything else - bans, reporting, the privacy notice, the session log and its retention, owner preemption, stalled-transcode auto-end, fail-closed behaviour, and the separate `SRT_MODE=owner` route for the operator's own SRT pushes - is in [docs/GUEST-ENDPOINT.md](docs/GUEST-ENDPOINT.md).

## On-demand VOD clips

**Off by default:** the stack's purpose is live streaming, VOD is opt-in. Set `VOD_ENABLED=1` to serve the on-demand page at `/vod/`; disabled, the `/vod/` and `/vod-dash/` routes return 404.

Two reference clips are published: `directions` (a 360 orientation test, spoken direction reads panned in third-order Ambisonics under an energy-visualisation overlay that shows where each read is supposed to come from, so a listener can hear whether the delivered audio still agrees with the picture) and `colortones` (a colour-and-tone A/V-sync pattern). No media is committed here - the masters, the 8K test card and the caption sidecars ship as [release assets](https://github.com/mormegil6/hoa-360-stream/releases/tag/vod-clips), and only the generators and the player wiring are tracked.

Generation, packaging, the 360 test card and its projection check, captions, headset playback and serving VOD from object storage: [docs/VOD.md](docs/VOD.md).

<div align="center"> <img src="docs/images/directions-energy-frame.png" width="70%" alt="A frame of the directions reference clip: the equirectangular 360 test card with a bright energy-visualisation glow sitting over the wall labelled RIGHT, at the moment the word right is spoken"> </div>

<p align="center"><em>One frame of the <code>directions</code> reference clip. The glow was rendered from the ambisonic stem before encoding and is baked into the picture, so it cannot move: together with the wall label it is a fixed reference for where the sound is supposed to be. What is under test is the audio. Here the word being spoken is <em>right</em>, so it should be heard from the right; if it arrives from anywhere else, the delivery chain has scrambled the channels while the picture stayed put.</em></p>

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `STREAM_KEY` | `hoast_demo` | Publish auth at rtmp-ingest: stream name or `?token=` must match |
| `DASH_NAME` | `hoast_demo` | Public DASH manifest filename served at `/dash/<DASH_NAME>.mpd`. Fixed and validated (`[A-Za-z0-9_-]+`) at earshot; decoupled from `STREAM_KEY` so the key is rotatable. The player discovers the manifest via telemetry (`/api/live`) and only falls back to the literal `hoast_demo.mpd` without it |
| `FFMPEG_FLAGS` | the `docker-compose.yml` fallback (single source of truth) | Video policy of the earshot transcode; audio is always 16-ch Opus. Check the effective value with `docker compose config \| grep FFMPEG_FLAGS`; a VP9 opt-in line ships commented in `.env.example` |
| `DEMO_CONTENT` | `1` | Self-provisioning demo at loop-source start: synthesise the spherical placeholder when `content/demo.mp4` is missing, fetch the VOD masters from the pinned release when absent (~373 MB once, SHA-256-verified, fail-soft). `0` = neither; see Quick start |
| `VOD_ENABLED` | `0` | On-demand VOD page + packaged clips, off by default: the stack's purpose is live streaming, VOD is opt-in. `0` serves no VOD route and suppresses the reference-master fetch even with `DEMO_CONTENT=1`; the packaging scripts stay in the repo, inert until run |
| `SRT_ENABLED` | `1` | SRT contribution ingest (`srt-gateway`), the recommended path. On by default; it still admits nobody unless `GUEST_ENABLED=1`. `0` leaves UDP 8890 unbound |
| `GUEST_ENABLED` | `0` | Keyless guest test endpoint, off by default; see the Guest test endpoint section. Timing knobs (`GUEST_GRACE_S`, `GUEST_MAX_S`, `GUEST_COOLDOWN_S`, `GUEST_RETENTION_DAYS`, `GUEST_BAN_DAYS`) and the resource guard (`GUEST_MAX_TEMP_C`, `GUEST_MAX_MBPS`, `GUEST_LIMIT_STRIKES`) are documented in `.env.example` |
| `SRT_MODE` | `guest` | What `srt-gateway` does with a caller: `guest` republishes into the arbitrated `guest` application; `owner` republishes into the token-authed `live` application with `STREAM_KEY` and bypasses the arbiter entirely. Not set by the shipped compose file; `owner` is for a private/VPN-only bind and refuses to start without `SRT_PASSPHRASE` and `STREAM_KEY`. See [docs/GUEST-ENDPOINT.md](docs/GUEST-ENDPOINT.md#the-owner-srt-route-srt_modeowner) |
| `SRT_OWNER_MAX_S` | `86400` | Owner-mode session ceiling (24 h), ending a session on purpose before the MPEG-TS 33-bit timestamp wrap at ~26.5 h, whose behaviour through this chain is unverified. Reconnect continues. `0` disables; guest mode never reads it |
| `ENABLE_NONFREE` | `0` | earshot ffmpeg licence stamp: the stack builds WITHOUT `--enable-nonfree` so images are redistributable; `1` restores the stock upstream configure line (`services/earshot/README.md` section 7) |

Copy `.env.example` to `.env` to override either.

Two things are deliberately *not* env-tunable: the audio policy (16-ch Opus, hardcoded upstream in Earshot) and the live-edge distance. The earshot image build patches ffmpeg's DASH muxer to floor `suggestedPresentationDelay` at 30 s (`DASH_SPD_FLOOR` build arg), so players join ~30 s behind the live edge by design. That is the price of gap-free playback of a 16-channel live stream.

## Test and measurement scripts

| Script | Purpose |
|---|---|
| `scripts/test-pipeline.sh` | synthetic end-to-end test: 16 sine channels + test video pushed through ingest auth, asserts live 16-ch Opus DASH appears with the video codec the effective `FFMPEG_FLAGS` implies; also guards that README, `.env.example` and the compose fallback agree. PASS/FAIL |
| `scripts/make-lipsync-scene.sh` | cut a GOP-matched, tv-range transient excerpt for by-ear lip-sync judging |
| `scripts/package-dash-variants.sh` | package a WebM master into 0.5/1/2/4 s DASH variants for the comparison page (`lip-sync-test/index.html`) |
| `scripts/measure-lipsync.js` | headless-Chromium A/V measurement over the packaged variants |
| `scripts/plot-segment-tradeoff.py` | regenerate the segment-duration trade-off figure |
| `scripts/smoke-hoast360.js` | headless-browser smoke test of the patched player |

`package-dash-variants.sh` drives Shaka Packager through the compose `tools` profile. The pattern for manual runs is `docker compose run --rm shaka <packager args>`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Relay `Connection refused` after recreating earshot | rtmp-ingest resolves earshot's address once, at startup | `docker compose restart rtmp-ingest` |
| Segments longer than `-seg_duration` (e.g. 3.34 s) | GOP duration does not divide the segment target, so no keyframe lands on the boundary and the muxer closes at the next one (`-g 50` at 29.97 fps is a 1.668 s GOP, so the first keyframe at or after 2 s falls at 3.336 s) | set `-g` so the segment duration is an integer multiple of the GOP (`-g 60` @ 29.97/30, `-g 50` @ 25); equality is the preferred default for the live encode |
| Browser loops `PIPELINE_ERROR_DECODE` | full-range (pc) VP9 source breaks the dash.js/MSE path | re-encode to limited range: `-vf scale=in_range=pc:out_range=tv -color_range tv` |
| `loop-source` idle although `demo.mp4` exists | file presence is checked once at startup | `docker compose restart loop-source` |
| Publisher dies seconds into a 4K push | RTMP message limit smaller than 4K keyframes | keep `max_message 10M` in the nginx-rtmp configs (already set here) |

## Working directories: `output/` and `scratch/`

Two gitignored directories at the repo root, with opposite guarantees.

`output/` is **earshot's** working directory: the DASH volume is bind-backed by it, and earshot's entrypoint clears that directory on every container start so each run begins a fresh timeline. Anything you leave in `output/` is deleted by the next `docker compose up`. That is intended for segments, and a trap for everything else.

`scratch/` is mounted alongside at `/opt/data/scratch` and is never touched by earshot, which only ever clears `.../dash`. Put anything that has to survive a restart here: test harnesses, probe captures written from inside the container, one-off files. Because it sits inside the repo, Node also resolves the root `node_modules` from it, so browser-based harnesses run without extra path setup.

## Deployment

**Local / lab (AMD64):** the quick start above. Validated on WSL2 Ubuntu and Ubuntu Server 22.04.

**Planned, not yet validated end to end:** Azure (for one-off events; raw TCP ingress for 1935 is the constraint to solve there) and Raspberry Pi. All base images are multi-arch and `docker buildx build --platform linux/arm64` compiles. A **Pi 4** (the slower of the two supported boards, so read the figure as a lower bound) has since been measured directly on the committed default workload - H.264 passthrough plus the 16-channel Opus encode, sustained - and sat at ~9 % CPU and 65 C with no thermal throttling, so headroom is not the question; Docker's UDP source-address preservation (which the SRT guest attribution depends on) also checks out on arm64 there. What is still unproven is the whole compose stack running on a Pi and serving a real stream, so treat the platform as measured rather than deployed. Treat both as directions, not documented paths; this section will grow real instructions when a real deployment produces them.

**Per-host overrides:** deployment-specific settings (bind the dashboard (:8090) to a private/Tailscale IP, mount host CPU-temp/disk for the telemetry service, Telegram tokens, a branded landing page) go in `docker-compose.override.yml`, which Compose loads automatically and which is gitignored. Copy [docker-compose.override.yml.example](docker-compose.override.yml.example) and adjust. The base stack runs without it.

## Documentation

- Measurement notes: the detailed measured results behind this README (transcode thermals, codec constraints, segment-duration trade-offs, A/V-sync mechanism, AV1 viability) are being written up for publication and are deliberately not in the repo. This README will carry the citation and the tagged commit once the papers are out.
- [docs/AMBISONIC-ORDER.md](docs/AMBISONIC-ORDER.md): why the live path stops at 16 channels, what is already 4th-order verified, and the two routes past the AAC ceiling
- [docs/BITRATE.md](docs/BITRATE.md): contribution bitrate, audio and video, with the published anchors
- [docs/GUEST-ENDPOINT.md](docs/GUEST-ENDPOINT.md): the guest session rules in full, and the `SRT_MODE=owner` route
- [docs/VOD.md](docs/VOD.md): on-demand clips, the 360 test card, captions, headset playback, object-storage delivery
- [docs/obs-macos.md](docs/obs-macos.md) / [docs/obs-windows.md](docs/obs-windows.md): the per-OS sender recipes, step by step
- [docs/ENDPOINTS.md](docs/ENDPOINTS.md): every port/endpoint the stack exposes, public vs private, and what to monitor
- [telemetry/README.md](telemetry/README.md): monitoring service (dashboard + alerts + public status.json)
- [services/earshot/README.md](services/earshot/README.md): Earshot vendoring provenance and local patches
- [lip-sync-test/RESULTS.md](lip-sync-test/RESULTS.md): the segment-duration study - measured across 0.5/1/2/4 s variants. Segment duration turns out **not** to affect A/V sync (a structural 0 ms offset at every duration); it is a bitrate and buffer-depth trade-off, which is why 2 s is the default
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
- The [OBS Project](https://obsproject.com/), OBS Studio - the recommended sender needs no fork at all
- pkviet, [OBS Studio Music Edition](https://github.com/pkviet/obs-studio) and the PCE-capable FFmpeg fork, which carried the 16-channel RTMP path before that
- Existential Audio, [BlackHole](https://github.com/ExistentialAudio/BlackHole), the macOS multichannel loopback driver the macOS recipe routes through
- atkAudio, [its OBS plugin](https://obsproject.com/forum/resources/atkaudio-plugin.2099/), which is what gets ASIO into OBS on Windows
- [Shaka project](https://github.com/shaka-project), Shaka Packager
- [AmbisonicEnergyRenderer](https://github.com/mormegil6/AmbisonicEnergyRenderer), which renders the directional-energy overlay in the `directions` clip from the raw ACN/SN3D signal (spherical-harmonic decode onto a t-design, k-NN inverse-distance gridding, streamed straight into ffmpeg)
- Gdańsk University of Technology, [Department of Multimedia Systems](https://multimed.org/index_en.html)

## Contact

Bartłomiej Mróz · bartlomiej.mroz@pg.edu.pl · Department of Multimedia Systems, Gdańsk University of Technology · [bmroz.eu](https://bmroz.eu)
