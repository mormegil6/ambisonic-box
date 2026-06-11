# hoa-360-stream

Containerised toolchain for live streaming 360° video with third-order
Ambisonics (16-channel) audio; RTMP in, MPEG-DASH (VP9 + Opus, WebM) out,
rendered binaurally in the browser by a patched [HOAST360](https://github.com/mormegil6/hoast360) player.

**Live demo:** <https://bmroz.eu/projects/360-livestream/>

## Citation

This repository is the containerised successor of the toolchain described in:

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

## Architecture

```
 OBS Music Edition                    ┌─────────────────────────────────────┐
 (or loop-source:                     │ docker compose                      │
  ffmpeg loop of                      │                                     │
  content/demo.mp4)                   │  ┌─────────────┐    ┌────────────┐  │
        │                             │  │ rtmp-ingest │    │  earshot   │  │
        │  RTMP :1935                 │  │ nginx-rtmp  │───▶│ nginx-rtmp │  │
        └────────────────────────────────▶ stream-key  │RTMP│ + ffmpeg   │  │
           H.264 + 16-ch AAC (PCE)    │  │ auth, relay │    │ (PCE fork) │  │
                                      │  └─────────────┘    └─────┬──────┘  │
                                      │                           │ 16-ch   │
                                      │                           │ Opus +  │
                                      │                           │ VP9     │
                                      │                           ▼ DASH    │
                                      │  ┌──────────────┐   ╔════════════╗  │
   viewer ◀───────────────────────────│──│ hoast-player │◀──║ dash-output║  │
   browser     HTTP :8080             │  │ nginx +      │   ║ volume     ║  │
   (HOAST360, binaural HOA)           │  │ HOAST360     │   ╚════════════╝  │
                                      │  └──────────────┘         ▲         │
                                      │  ┌──────────────┐         │         │
                                      │  │ shaka        │─────────┘         │
                                      │  │ (profile:    │  VOD / lip-sync   │
                                      │  │  tools only) │  packaging        │
                                      │  └──────────────┘                   │
                                      └─────────────────────────────────────┘
```

The RTMP contribution leg is H.264 + 16-channel AAC by protocol necessity
(legacy RTMP/FLV cannot carry VP9/Opus). Everything from the earshot
transcode onward is VP9 + 16-ch Opus in WebM. Audio is never downmixed:
3rd-order Ambisonics, ACN/SN3D, 16 channels end to end.

## Requirements

- Docker Engine with the compose plugin (`docker compose`), buildx for
  multi-arch builds
- ffmpeg/ffprobe on the host (only for the test and measurement scripts)
- ~2 GB of image builds on first `compose build` (earshot compiles its
  nginx-rtmp and ffmpeg fork from source)

## Quick start

```bash
git clone https://github.com/mormegil6/hoa-360-stream.git && cd hoa-360-stream
git submodule update --init
cp /path/to/demo.mp4 content/demo.mp4   # H.264 + 16-ch AAC; see .env.example
docker compose up -d --build
# then open http://localhost:8080 in your browser
# (Earshot monitor: http://localhost:8081/webtools)
```

Without `content/demo.mp4` the stack still runs; `loop-source` idles until
the file exists, and you can push to it live instead (next section).

## Stream your own content

Use [OBS Studio Music Edition](https://github.com/pkviet/obs-studio/releases/)
(supports 16.0 AAC):

| Setting | Value |
|---|---|
| Server | `rtmp://<host>:1935/live` |
| Stream key | `hoast_demo` (or your `STREAM_KEY`) |
| Audio | 16 channels, AAC, AmbiX (ACN/SN3D) channel order |
| Video | H.264, GOP = segment duration × fps |

The stream appears at `http://<host>:8080/dash/<stream-key>.mpd`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `STREAM_KEY` | `hoast_demo` | Publish auth at rtmp-ingest: stream name or `?token=` must match |
| `FFMPEG_FLAGS` | VP9 realtime, 2 s segments | Video policy of the earshot transcode; audio is always 16-ch Opus. `-c:v copy` fallback documented in `.env.example` |

Copy `.env.example` to `.env` to override either.

## Test and measurement scripts

| Script | Purpose |
|---|---|
| `scripts/test-pipeline.sh` | synthetic end-to-end pipeline test (16 sine channels) |
| `scripts/package-dash-variants.sh` | package a WebM master into 0.5/1/2/4 s DASH variants for the lip-sync comparison (`lip-sync-test/index.html`) |
| `scripts/smoke-hoast360.js` | headless-browser smoke test of the patched player |

## Deployment

**Local / lab (AMD64):** the quick start above. Validated on WSL2 Ubuntu and
Ubuntu Server 22.04.

**Azure Container Apps:** build and push images (`docker buildx build
--platform linux/amd64`), mount `dash-output` as ephemeral storage, expose
8080 (player) and 1935 (ingest, TCP). For events, point OBS at the ingress
and keep `FFMPEG_FLAGS` at the VP9 default.

**Raspberry Pi 5 (ARM64, experimental):** all base images are multi-arch and
earshot builds from source, so `docker buildx build --platform linux/arm64`
works; realtime VP9 encoding is the bottleneck. If the Pi can't keep up, set
`FFMPEG_FLAGS` to the `-c:v copy` fallback (video segments become MP4,
audio stays Opus/WebM): or use a bigger machine; the Pi target is a
nice-to-have, not a requirement.

## License

Compose files, service configs and scripts in this repository: **Apache 2.0**.
Bundled and built components keep their own licenses:

| Component | License |
|---|---|
| [HOAST360](https://github.com/mormegil6/hoast360) (patched fork, git submodule) | GPL-3.0-or-later |
| [Envelop Earshot](https://github.com/EnvelopSound/Earshot) (vendored in `services/earshot/src`, two documented patches) | GPL |
| Envelop/pkviet FFmpeg fork (built inside the earshot image) | GPL v3 (built with `--enable-gpl --enable-nonfree`; treat the built earshot image as non-redistributable and build it yourself) |
| [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module) | BSD-2-Clause |
| [Shaka Packager](https://github.com/shaka-project/shaka-packager) (official image) | BSD-3-Clause |
| nginx, Alpine packages | BSD-2-Clause / various |

## Acknowledgements

- Thomas Deppisch & Nils Meyer-Kahlen; [HOAST360](https://github.com/thomasdeppisch/hoast360),
  the higher-order Ambisonics 360° player this project patches and serves
- [Envelop](https://envelop.us): Earshot, the multichannel RTMP→DASH transcoder
- pkviet; OBS Studio Music Edition and the PCE-capable FFmpeg fork
- [Shaka project](https://github.com/shaka-project): Shaka Packager
- Gdańsk University of Technology, Department of Multimedia Systems
