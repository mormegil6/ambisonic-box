# earshot - vendored Envelop Earshot

`src/` is a vendored subset of [EnvelopSound/Earshot](https://github.com/EnvelopSound/Earshot)
at commit `a9b351facfd3097bd4cd1c260ed5fe05a7babd7a` (master, 2022-08-25), GPL
licensed (see `src/LICENSE`). Only what the Docker image needs is vendored:
`Dockerfile`, `nginx-transcoder/`, `webtools/` - the upstream `tester/`,
CloudFormation templates and Git-LFS binaries are not required for the image
and are omitted.

## Relationship to upstream

The pinned commit above is a 2022 snapshot, but this tree is **not** four years
behind. Upstream has made exactly eight commits since (four merged pull
requests), all of which touch what we vendor - and all four are changes
contributed *from here* and merged in July 2026:

| change | upstream |
|---|---|
| `wait_key` / `wait_video` at the relay | **merged**, [#53](https://github.com/EnvelopSound/Earshot/pull/53) (`d8039a2`) |
| `--enable-libvpx` | **merged**, [#54](https://github.com/EnvelopSound/Earshot/pull/54) (`b03d8bc`) |
| volume-safe entrypoint | **merged**, [#55](https://github.com/EnvelopSound/Earshot/pull/55) (`389da2d`) |
| relative redirects (`absolute_redirect off`) | **merged**, [#56](https://github.com/EnvelopSound/Earshot/pull/56) (`ac1dda7`) |

A fifth change, the `ENABLE_NONFREE` build ARG (section 7 below), is
contributed upstream as [#57](https://github.com/EnvelopSound/Earshot/pull/57)
and not yet merged.

So `src/` is content-equivalent to upstream master `ac1dda7` plus the local
extras below - that master head includes `absolute_redirect off`
([#56](https://github.com/EnvelopSound/Earshot/pull/56), §6 below), contributed
from here and merged upstream on 2026-07-24. Verified by diff against master:
**nothing upstream carries is missing
here**, and the ffmpeg, nginx and nginx-rtmp versions are byte-identical
(`earshot-v0.1` / `1.15.1` / `1.2.1` - upstream never moved them).

Re-vendoring would therefore be pure bookkeeping: it gains no code, because the
reason upstream changed is that upstream adopted these changes. The only thing
it would buy is a less misleading pin. Worth doing when convenient, not urgent,
and the local extras below would all have to be re-applied afterwards anyway.

## Local modifications

Sections 1, 2, 4 and 6 below are the changes now merged upstream - kept
documented because they are still deviations from the *pinned* commit, and
because sections 2 and 5 build on them. Section 7 is contributed but not yet
merged (#57). Sections 3 and 5, plus the refinement noted in 2, are the only
things still genuinely ours.

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

### 3. `src/Dockerfile`: `suggestedPresentationDelay` floor patched into ffmpeg

A guarded `sed` on `libavformat/dashenc.c` at image build floors the MPD's
`suggestedPresentationDelay` at `DASH_SPD_FLOOR` seconds (build arg, default
30). No ffmpeg flag can set SPD for WebM DASH (`-target_latency` is
force-zeroed outside LL-DASH mode) and upstream hardcodes it to the last
segment duration, which makes players join right at the live edge and
gap-jump.

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
the measurement notes being written up for publication (see the top-level README, Documentation).

### 5. `entrypoint.sh` + both nginx confs: `DASH_NAME` default and validation

Upstream names the DASH manifest after the RTMP stream key (`$name.mpd`), which
ties the player's manifest URL to the stream key: rotating the key moves the
manifest and breaks the page. Here the manifest name is its own variable, so the
key can be rotated freely.

`DASH_NAME` is defaulted and validated in `entrypoint.sh` before nginx starts
and before either `envsubst` call, and it is exported - the `envsubst` whitelist
is derived from `env`, so an unexported value would leave a literal
`${DASH_NAME}` in the rendered config and ffmpeg would write a file the player
never fetches. It is read only from the container environment, never from the
network, and rejecting `.` and `/` makes `..` and absolute paths
unrepresentable.

### 6. `src/nginx-transcoder/nginx*.conf`: `absolute_redirect off` on the HTTP server

nginx builds directory redirects (e.g. `/webtools` -> `/webtools/`) as absolute
URLs from its internal listen port, which drops the external mapped port behind a
Docker or Tailscale bind: `http://host:8081/webtools` 301s to
`http://host/webtools/` (port 80), the wrong service. `absolute_redirect off` at
the HTTP server level makes the redirect relative, so the browser resolves it
against the request URL and keeps the port. Contributed upstream as
[#56](https://github.com/EnvelopSound/Earshot/pull/56) and merged on 2026-07-24
(`ac1dda7`); applied here ahead of that merge.

### 7. `src/Dockerfile`: `ENABLE_NONFREE` build ARG

ffmpeg's `--enable-nonfree` marks the binary non-redistributable, but this
build links no nonfree library (only libx264/libopus/libvpx), so the flag is
a no-op licence stamp that blocks publishing a pre-built image. The ARG
defaults to 1 in the Dockerfile (stock build unchanged), but the stack's
docker-compose.yml passes 0 by default so its images are redistributable;
export ENABLE_NONFREE=1 to restore the stock build. Verified equivalent end to end
(16-ch Opus hexadecagonal + VP9, full pipeline test). Contributed upstream as
[#57](https://github.com/EnvelopSound/Earshot/pull/57) (open).

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
