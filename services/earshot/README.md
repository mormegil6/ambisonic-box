# earshot - vendored Envelop Earshot

`src/` is a vendored subset of [EnvelopSound/Earshot](https://github.com/EnvelopSound/Earshot)
at commit `a9b351facfd3097bd4cd1c260ed5fe05a7babd7a` (master, 2022-08-25), GPL
licensed (see `src/LICENSE`). Only what the Docker image needs is vendored:
`Dockerfile`, `nginx-transcoder/`, `webtools/` - the upstream `tester/`,
CloudFormation templates and Git-LFS binaries are not required for the image
and are omitted.

## Local modifications

Four deviations from the vendored commit. They are deviations from the pinned
2022 snapshot, not necessarily from upstream today - two have since been
accepted upstream and will disappear the next time `src/` is re-vendored from a
newer commit:

| # | change | upstream |
|---|---|---|
| 1 | `--enable-libvpx` | **merged**, [#54](https://github.com/EnvelopSound/Earshot/pull/54) (`b03d8bc`, 2026-07-23) |
| 2 | volume-safe entrypoint | open, [#55](https://github.com/EnvelopSound/Earshot/pull/55) |
| 3 | `suggestedPresentationDelay` floor | not proposed - too specific to this stack |
| 4 | `wait_key` / `wait_video` at the relay | **merged**, [#53](https://github.com/EnvelopSound/Earshot/pull/53) (`d8039a2`, 2026-07-22) |

### 1. `src/Dockerfile`: `--enable-libvpx` added to the ffmpeg configure

Upstream installs `libvpx-dev` in the build stage and `libvpx` in the runtime
stage but never enables it in ffmpeg's configure, so the shipped ffmpeg cannot
encode VP9 (`Unrecognized option 'deadline'`). This stack's default
`FFMPEG_FLAGS` transcode video to VP9 for all-WebM DASH output, which requires
it.

### 2. `src/nginx-transcoder/entrypoint.sh`: volume-safe startup

```
- rm -rf /opt/data && mkdir -p /opt/data/dash && ...
+ mkdir -p /opt/data/dash && (find /opt/data/dash -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true) && ...
```

(`.gitkeep` is spared because the dev compose backs the volume with the
repo's `./output` bind mount.)


Upstream wipes `/opt/data` at startup, which fails on a busy mountpoint when a
Docker volume is mounted at `/opt/data/dash` (the `&&` chain then breaks and
nginx starts unconfigured). The patched version clears stale segments without
removing the mountpoint itself.

### 4. `src/nginx-transcoder/nginx*.conf`: `wait_key` / `wait_video` on the relay

The transcoder is an nginx-rtmp `exec` ffmpeg that *subscribes* to the internal
relay, and a subscriber joining a live stream gets audio immediately but no
decodable video until the next keyframe - up to a full GOP later. The DASH muxer
records that skew as a leading empty edit (`elst media_time = -1`) on the video
track, which Firefox honours and Chromium's MSE does not, so Chromium paints
video early by the same amount. These two directives start the relayed video at
a keyframe and hold audio until video flows, so the tracks start together and no
edit box is written at all. Measured: empty edits on 10/10 joins without them,
`elst [(0,0)]` and tracks aligned within 3 ms on 20/20 with them. See
`docs/PAPER-NOTES.md` §12.

### 3. `src/Dockerfile`: `suggestedPresentationDelay` floor patched into ffmpeg

A guarded `sed` on `libavformat/dashenc.c` at image build floors the MPD's
`suggestedPresentationDelay` at `DASH_SPD_FLOOR` seconds (build arg, default
30). No ffmpeg flag can set SPD for WebM DASH (`-target_latency` is
force-zeroed outside LL-DASH mode) and upstream hardcodes it to the last
segment duration, which makes players join right at the live edge and
gap-jump.

## What this service does in the stack

nginx-rtmp accepts the relayed stream from `rtmp-ingest` on :1935 (internal
only) and `exec`s Envelop's PCE-aware ffmpeg fork per published stream:

```
ffmpeg -analyzeduration 10M -i rtmp://127.0.0.1/live/$name \
  -strict -2 -c:a libopus -mapping_family 255 ${FFMPEG_FLAGS} \
  -f dash /opt/data/dash/$name.mpd
```

16-channel Opus is hardcoded upstream; the video codec policy comes from the
`FFMPEG_FLAGS` env var (see `.env.example` at the repo root - VP9 realtime by
default, `-c:v copy` fallback documented). The live MPEG-DASH segmentation
happens *here*, not in the shaka service (shaka cannot ingest a 16-channel
live stream and is a `tools`-profile utility for VOD packaging only).

HTTP :80 (mapped to host :8081 in dev) serves the webtools monitoring UI at
`/webtools`, `rtmp_stat` at `/stat`, a health endpoint at `/` and the raw DASH
output at `/dash` (the player normally serves it from the shared volume
instead).
