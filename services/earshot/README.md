# earshot - vendored Envelop Earshot

`src/` is a vendored subset of [EnvelopSound/Earshot](https://github.com/EnvelopSound/Earshot)
at commit `a9b351facfd3097bd4cd1c260ed5fe05a7babd7a` (master, 2022-08-25), GPL
licensed (see `src/LICENSE`). Only what the Docker image needs is vendored:
`Dockerfile`, `nginx-transcoder/`, `webtools/` - the upstream `tester/`,
CloudFormation templates and Git-LFS binaries are not required for the image
and are omitted.

## Local modifications

Two deviations from upstream:

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
