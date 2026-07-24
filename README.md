![Docker Compose](https://img.shields.io/badge/Docker-Compose-2496ED.svg?logo=docker&logoColor=white) ![FFmpeg](https://img.shields.io/badge/FFmpeg-16--ch%20Opus%20%2B%20VP9%2Fcopy-007808.svg?logo=ffmpeg&logoColor=white) ![MPEG-DASH](https://img.shields.io/badge/MPEG--DASH-live-F76935.svg) ![Ambisonics](https://img.shields.io/badge/Ambisonics-3rd%20order%2C%2016ch-8A2BE2.svg) ![Platform](https://img.shields.io/badge/platform-amd64%20%7C%20arm64-lightgrey.svg?logo=linux&logoColor=white) [![Live demo](https://img.shields.io/badge/live%20demo-bmroz.eu-1F6FEB.svg)](https://bmroz.eu/projects/360-livestream/) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

# hoa-360-stream: live 360 video and third-order Ambisonics over MPEG-DASH

Containerised toolchain for live streaming 360 video with third-order
Ambisonics (16-channel) audio: RTMP in, MPEG-DASH (16-ch Opus, WebM) out,
rendered binaurally in the browser by a patched [HOAST360](https://github.com/mormegil6/hoast360) player.

**Live demo:** <https://bmroz.eu/projects/360-livestream/>

## Architecture

<div align="center">
<img src="docs/architecture/architecture.png" width="80%" alt="HOA 360 stream architecture: OBS and loop-source feed rtmp-ingest, earshot transcodes to 16-channel Opus DASH into the dash-output volume, hoast-player serves it to the viewer browser, with shaka packager and telemetry attached to the volume">
</div>

<!-- Diagram source + generator: docs/architecture/ (edit architecture.mmd, run ./build.sh). -->


The RTMP contribution leg is H.264 + 16-channel AAC by protocol necessity
(legacy RTMP/FLV cannot carry VP9/Opus). From the earshot transcode onward the
audio is always 16-ch Opus and is never downmixed: 3rd-order Ambisonics,
ACN/SN3D, 16 channels end to end.

**Why 16 channels, and what it would take to go higher.** The ceiling sits on
the contribution leg, not on delivery or rendering. ffmpeg's AAC encoder refuses
a 25-channel (4th-order) input outright - 16 works only because `hexadecagonal`
is a *named* layout it accepts - and that leg has to be AAC because RTMP/FLV
cannot carry Opus. Everything downstream is already order-4 capable, verified
component by component: 25-channel Opus at `mapping_family 255` round-trips
intact, Shaka Packager carries `AudioChannelConfiguration value="25"` into the
manifest, and the player image ships the complete order-4 impulse-response set.

So **the on-demand path is 4th-order ready today** - it never touches AAC, and
the only hardcoded piece is the order argument the page passes to HOAST360
(`initialize(mpd, irs, 3)`). A 4th-order VOD clip needs a 4th-order master and
that argument changed, with no format, packaging or renderer work. It is not
claimed as a shipped feature because no 4th-order clip has been played end to
end yet; the components are proven, the integration is not. Raising the *live*
path is a different matter - it needs a contribution format that can carry 25
channels (a wider-layout AAC encoder, or moving ingest off RTMP to SRT/WebRTC
with Opus), which is architectural rather than configuration. See
[docs/PAPER-NOTES.md](docs/PAPER-NOTES.md) §15 for the measurements.

**Video codec.** `docker-compose.yml`'s `FFMPEG_FLAGS` default is the single
source of truth, and it is currently **H.264 passthrough** (`-c:v copy`) - so a
clone with no `.env` streams passthrough, and video segments are `.m4s`/`.mp4`
while audio stays Opus/WebM. VP9 (all-WebM) is the codec *policy* and ships as
a ready-to-uncomment line in `.env.example`; it is not the running default,
because the only VP9 configuration ever measured cost ~310 % CPU on the Mac
Mini even when scaled down. To check what a given host will actually do rather
than trusting this paragraph:

```bash
docker compose config | grep FFMPEG_FLAGS
```

**PCE** is AAC's Program Config Element. Sixteen channels is not one of AAC's
predefined layouts, so a stream carrying one has to spell the layout out in a
PCE rather than name it; stock ffmpeg will not write that, which is why earshot
vendors a patched, PCE-aware build. Without it the contribution leg could not
carry 16 channels over RTMP at all. `dash-output` is a Docker volume - the
shared filesystem earshot segments into and nginx serves from, nothing to do
with level.

| Service | Role | Host port |
|---|---|---|
| `rtmp-ingest` | public RTMP ingest; stream-key auth, relay to earshot | 1935 |
| `earshot` | transcode to 16-ch Opus + VP9, live DASH segmenting ([vendored Envelop Earshot](services/earshot/README.md), patched) | 8081 (dev monitor) |
| `loop-source` | demo contribution encoder: loops `content/demo.mp4` | - |
| `hoast-player` | viewer origin: patched HOAST360 player + `/dash/` | 8080 |
| `telemetry` | ops dashboard + breakage-only alerts + curated public status.json ([telemetry/](telemetry/README.md)) | 8090 (bind private) |
| `shaka` | Shaka Packager for VOD / lip-sync packaging; compose profile `tools`, manual runs only | - |

## Requirements

- Docker Engine with the compose plugin (`docker compose`), buildx for
  multi-arch builds
- ~2 GB of image builds on first `compose build` (earshot compiles its
  nginx-rtmp and ffmpeg fork from source)
- Only for the test and measurement scripts: host `ffmpeg`/`ffprobe`;
  Node.js (`npm ci`, then `npx playwright install chromium` for the two
  headless-browser scripts); `python3` + matplotlib for the trade-off plot

## Quick start

```bash
git clone https://git.pg.edu.pl/p829296/hoa-360-stream.git && cd hoa-360-stream
git submodule update --init
cp /path/to/demo.mp4 content/demo.mp4   # H.264 + 16-ch AAC; see .env.example
docker compose up -d --build
# then open http://localhost:8080 in your browser
# (Earshot monitor: http://localhost:8081/webtools)
```

Without `content/demo.mp4` the stack still runs and you can push to it live
(next section). `loop-source` checks for the file once at startup. If you
add `demo.mp4` later, run `docker compose restart loop-source`.

## Stream your own content

Use [OBS Studio Music Edition](https://github.com/pkviet/obs-studio/releases/)
(supports 16.0 AAC):

| Setting | Value |
|---|---|
| Server | `rtmp://<host>:1935/live` |
| Stream key | `hoast_demo` (or your `STREAM_KEY`) |
| Audio | 16 channels, AAC, AmbiX (ACN/SN3D) channel order |
| Video | H.264, keyframe interval that divides the segment duration (equality preferred: `-g 60` at 29.97/30 fps, `-g 50` at 25 fps, for the default 2 s segments; shorter intervals are valid but cost bitrate) |

The stream appears at `http://<host>:8080/dash/<DASH_NAME>.mpd` (default
`hoast_demo`), which is exactly what the bundled player page requests. The
manifest name is `DASH_NAME`, independent of `STREAM_KEY`: a custom stream key
no longer moves the manifest URL, so you can rotate the key without editing the
player. Only edit `services/hoast-player/index.html` if you set a custom
`DASH_NAME`.

## On-demand VOD clips

Besides the live stream, the player serves on-demand reference clips at `/vod/`
(`/vod/?clip=<name>`). Two are published as **release assets** - no media is
committed here, only the generators and the player wiring: `directions` (a 360
orientation test - the equirectangular test card from
`scripts/make-360-testcard.py`, an ambisonic energy-visualisation overlay,
and spoken front/right/left/top reads from an ambisonic recording, so only the
audio is not generated here) and `colortones` (colour-and-tone
A/V-sync pattern, fully generated by `scripts/make-colortones.sh`). Put the
masters in `content/vod/masters/` (gitignored);
`scripts/encode-vod-ladder.sh` builds the resolution ladder and
`scripts/package-vod-dash.sh` packages it into combined-MPD DASH under
`content/vod/dash/<clip>/`, served at `/vod-dash/`.

**360 test card.** `scripts/make-360-testcard.py` renders six flat broadcast
test screens and arranges them as the walls of a cube around the viewer, then
inverse-projects that into equirectangular. Each wall spans exactly 90°, so a
360 viewer at a normal field of view sees a flat, undistorted card: circles
stay round and straight lines stay straight, and any bend, softening or colour
shift is the pipeline's doing rather than the projection's. Each face carries
EBU 75 % colour bars, a grey staircase, PLUGE, a multiburst, a checkerboard,
a band-limited detail patch and a Siemens star, plus its own name and centre
bearing - so the picture reports resolution, gamma, range handling and
compression damage in whichever direction you happen to be looking. The poles
become ordinary ceiling and floor walls instead of smeared blobs. Drawing
directly in equirectangular cannot do this: the pattern is pre-distorted, so
nothing in it has a known shape by the time it reaches the eye.

```
scripts/make-360-testcard.py -o content/vod/masters/testcard-360_8k.png
scripts/make-360-testcard.py --pattern dummy --width 3072   # projection check
```

`--pattern dummy` swaps the artwork for deliberately asymmetric validation
faces, which is how the geometry is checked independently of the picture. The
mapping is the same one ffmpeg's `v360` filter implements, so
`v360=c6x1:e` over a `right,left,up,down,front,back` strip is an independent
cross-check (it agrees to 0.05/255). `scripts/make-orientation-card.py` remains
as the plain measurement graticule - degree ticks and cardinal labels, no
imaging targets.

The rendered 8K card ships as a **release asset** alongside the clip masters
and caption sidecars; only the generator is tracked here, so a fresh clone
reproduces the card rather than downloading it.

**Captions.** Each clip carries WebVTT subtitles beside its segments as
`captions_<lang>.vtt`, declared per clip in the `CLIPS` table in
`services/hoast-player/index.html`:

```js
captions: [
  { src: '/vod-dash/directions/captions_en.vtt', lang: 'en', label: 'English' },
  { src: '/vod-dash/directions/captions_pl.vtt', lang: 'pl', label: 'Polski' }
]
```

The `.vtt` files are not tracked here - like the clip masters they ship as
**release assets**, so a fresh `git clone` has the caption *config* but not the
caption *files*. `scripts/make-colortones.sh` emits the colortones pair as part
of generating that clip; `scripts/make-directions-captions.sh` (a flagged
clip-specific one-off, since `directions` is a recording rather than something
this repo generates) emits the directions pair.

The player side-loads these as native `<track>` elements rather than reading a
DASH `text` AdaptationSet, which renders unreliably through videojs-contrib-dash
(see [docs/PAPER-NOTES.md](docs/PAPER-NOTES.md) §14). `services/hoast-player/nginx.conf`
must therefore type `.vtt` as `text/vtt` in the `/vod-dash/` location; the
default `application/octet-stream` makes stricter browsers refuse the track.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `STREAM_KEY` | `hoast_demo` | Publish auth at rtmp-ingest: stream name or `?token=` must match |
| `DASH_NAME` | `hoast_demo` | Public DASH manifest filename served at `/dash/<DASH_NAME>.mpd`. Fixed and validated (`[A-Za-z0-9_-]+`) at earshot; decoupled from `STREAM_KEY` so the key is rotatable. Must match the name hardcoded in `services/hoast-player/index.html` |
| `FFMPEG_FLAGS` | VP9 realtime, 2 s segments | Video policy of the earshot transcode; audio is always 16-ch Opus. `-c:v copy` fallback documented in `.env.example` |

Copy `.env.example` to `.env` to override either.

Two things are deliberately *not* env-tunable: the audio policy (16-ch Opus,
hardcoded upstream in Earshot) and the live-edge distance. The earshot image
build patches ffmpeg's DASH muxer to floor `suggestedPresentationDelay` at
30 s (`DASH_SPD_FLOOR` build arg), so players join ~30 s behind the live edge
by design. That is the price of gap-free playback of a 16-channel live stream.

## Measurements: DASH segment duration

Does segment duration affect lip sync? Measured answer: **no**. The A/V
start offset is structurally 0 ms across 0.5/1/2/4 s variants (audio
stream-copied, video GOP the only variable; details in
[lip-sync-test/RESULTS.md](lip-sync-test/RESULTS.md)). Segment duration is
instead a bitrate/latency trade-off:

![Bitrate and buffer depth vs segment duration](lip-sync-test/segment-tradeoff.svg)

0.5 s segments force a keyframe every 15 frames and push realtime VP9 ~6×
past its bitrate target (with visible stalls); 4 s segments halve the
time-shift granularity for no gain. **2 s is the default** (`-g 60
-seg_duration 2` at 29.97/30 fps).

## Test and measurement scripts

| Script | Purpose |
|---|---|
| `scripts/test-pipeline.sh` | synthetic end-to-end test: 16 sine channels + test video pushed through ingest auth, asserts live 16-ch Opus/VP9 DASH appears; PASS/FAIL |
| `scripts/make-lipsync-scene.sh` | cut a GOP-matched, tv-range transient excerpt for by-ear lip-sync judging |
| `scripts/package-dash-variants.sh` | package a WebM master into 0.5/1/2/4 s DASH variants for the comparison page (`lip-sync-test/index.html`) |
| `scripts/measure-lipsync.js` | headless-Chromium A/V measurement over the packaged variants |
| `scripts/plot-segment-tradeoff.py` | regenerate the segment-duration trade-off figure |
| `scripts/smoke-hoast360.js` | headless-browser smoke test of the patched player |

`package-dash-variants.sh` drives Shaka Packager through the compose `tools`
profile. The pattern for manual runs is `docker compose run --rm shaka
<packager args>`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Relay `Connection refused` after recreating earshot | rtmp-ingest resolves earshot's address once, at startup | `docker compose restart rtmp-ingest` |
| Segments longer than `-seg_duration` (e.g. 3.34 s) | GOP duration does not divide the segment target, so no keyframe lands on the boundary and the muxer closes at the next one (`-g 50` at 29.97 fps is a 1.668 s GOP, so the first keyframe at or after 2 s falls at 3.336 s) | set `-g` so the segment duration is an integer multiple of the GOP (`-g 60` @ 29.97/30, `-g 50` @ 25); equality is the preferred default for the live encode |
| Browser loops `PIPELINE_ERROR_DECODE` | full-range (pc) VP9 source breaks the dash.js/MSE path | re-encode to limited range: `-vf scale=in_range=pc:out_range=tv -color_range tv` |
| `loop-source` idle although `demo.mp4` exists | file presence is checked once at startup | `docker compose restart loop-source` |
| Publisher dies seconds into a 4K push | RTMP message limit smaller than 4K keyframes | keep `max_message 10M` in the nginx-rtmp configs (already set here) |

## Deployment

**Local / lab (AMD64):** the quick start above. Validated on WSL2 Ubuntu and
Ubuntu Server 22.04.

**Azure Container Apps:** build and push images (`docker buildx build
--platform linux/amd64`), mount `dash-output` as ephemeral storage, expose
8080 (player) and 1935 (ingest, TCP). For events, point OBS at the ingress
and keep `FFMPEG_FLAGS` at the VP9 default.

**Raspberry Pi 5 (ARM64, experimental):** all base images are multi-arch and
earshot builds from source, so `docker buildx build --platform linux/arm64`
works; realtime VP9 encoding is the bottleneck. If the Pi cannot keep up, set
`FFMPEG_FLAGS` to the `-c:v copy` fallback (video segments become MP4,
audio stays Opus/WebM), or use a bigger machine; the Pi target is a
nice-to-have, not a requirement.

**Per-host overrides:** deployment-specific settings (bind the telemetry
dashboard to a private/Tailscale IP, mount host CPU-temp/disk for the telemetry
service, Telegram tokens, a branded landing page) go in
`docker-compose.override.yml`, which Compose loads automatically and which is
gitignored. Copy [docker-compose.override.yml.example](docker-compose.override.yml.example)
and adjust. The base stack runs without it.

## Documentation

- [docs/PAPER-NOTES.md](docs/PAPER-NOTES.md): measured results from the live path (transcode thermals, codec constraints, 360 complexity, AV1 viability)
- [docs/ENDPOINTS.md](docs/ENDPOINTS.md): every port/endpoint the stack exposes, public vs private, and what to monitor
- [telemetry/README.md](telemetry/README.md): monitoring service (dashboard + alerts + public status.json)
- [services/earshot/README.md](services/earshot/README.md): Earshot vendoring provenance and local patches
- [lip-sync-test/RESULTS.md](lip-sync-test/RESULTS.md): full segment-duration / lip-sync study
- [docs/NDI.md](docs/NDI.md): Quest 3 / Twinkle NDI output extension (design only)
- [docs/NDI-TEST.md](docs/NDI-TEST.md): hands-on NDI/Twinkle validation runbook
- [.env.example](.env.example): configuration reference, including how to prepare `content/demo.mp4`

## License

Compose files, service configs and scripts in this repository: **Apache 2.0**.
Bundled and built components keep their own licenses:

| Component | License |
|---|---|
| [HOAST360](https://github.com/mormegil6/hoast360) (patched fork, git submodule) | GPL-3.0-or-later |
| [Envelop Earshot](https://github.com/EnvelopSound/Earshot) (vendored in `services/earshot/src`, three documented patches) | GPL |
| Envelop/pkviet FFmpeg fork (built inside the earshot image) | GPL v3 (built with `--enable-gpl --enable-nonfree`; treat the built earshot image as non-redistributable and build it yourself) |
| [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module) | BSD-2-Clause |
| [Shaka Packager](https://github.com/shaka-project/shaka-packager) (official image) | BSD-3-Clause |
| nginx, Alpine packages | BSD-2-Clause / various |

## Citation

This repository is the containerised successor of the toolchain described in
the paper below. If you use this work in research, please cite it:

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

- Thomas Deppisch and Nils Meyer-Kahlen, [HOAST360](https://github.com/thomasdeppisch/hoast360),
  the higher-order Ambisonics 360 player this project patches and serves
- [Envelop](https://envelop.us), Earshot, the multichannel RTMP-to-DASH transcoder
- pkviet, OBS Studio Music Edition and the PCE-capable FFmpeg fork
- [Shaka project](https://github.com/shaka-project), Shaka Packager
- Gdańsk University of Technology, Department of Multimedia Systems

## Contact

Bartłomiej Mróz · bartlomiej.mroz@pg.edu.pl · Department of Multimedia Systems, Gdańsk University of Technology · [bmroz.eu](https://bmroz.eu)
