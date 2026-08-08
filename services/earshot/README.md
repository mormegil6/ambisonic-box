# earshot - vendored Envelop Earshot

`src/` is a vendored subset of [EnvelopSound/Earshot](https://github.com/EnvelopSound/Earshot) at commit `e765fdbc321f911608f998cdaf45979c2d725c55` (master, 2026-07-27), GPL licensed (see `src/LICENSE`). Only what the Docker image needs is vendored: `Dockerfile`, `nginx-transcoder/`, `webtools/` - the upstream `tester/`, CloudFormation templates and Git-LFS binaries are not required for the image and are omitted.

## Relationship to upstream

The pin above is upstream's own current tip (re-vendored 2026-08-06 from the previous `a9b351f` / 2022-08-25 snapshot). Getting there took five pull requests, all merged in July 2026, all changes contributed *from here*:

| change | upstream |
|---|---|
| `wait_key` / `wait_video` at the relay | [#53](https://github.com/EnvelopSound/Earshot/pull/53) (`d8039a2`) |
| `--enable-libvpx` | [#54](https://github.com/EnvelopSound/Earshot/pull/54) (`b03d8bc`) |
| volume-safe entrypoint | [#55](https://github.com/EnvelopSound/Earshot/pull/55) (`389da2d`) |
| relative redirects (`absolute_redirect off`) | [#56](https://github.com/EnvelopSound/Earshot/pull/56) (`ac1dda7`) |
| `ENABLE_NONFREE` build ARG (section 7 below) | [#57](https://github.com/EnvelopSound/Earshot/pull/57) (`e765fdb`) |

The ffmpeg, nginx and nginx-rtmp versions are unchanged from the previous pin (`earshot-v0.1` / `1.15.1` / `1.2.1`); upstream never moved them, so this re-vendor is a pin move and a documentation refresh, not a rebuild of anything downstream.

## Local modifications

Sections 1, 2, 4, 6 and 7 below are now identical to the pinned commit - kept documented for provenance rather than as deviations, since the pin above already carries them upstream. Sections 3, 5, 8 and 9, plus the `.gitkeep` refinement noted in 2, are what is still genuinely ours, and all four were offered upstream on 2026-08-06 as separate pull requests (one fix each, so each can be judged on its own):

| section | change | upstream |
|---|---|---|
| 3 | `suggestedPresentationDelay` floor | **open**, [#58](https://github.com/EnvelopSound/Earshot/pull/58) |
| 5 | `DASH_NAME` decoupled from the stream key | **open**, [#59](https://github.com/EnvelopSound/Earshot/pull/59) |
| 8 | `max_message 10M` | **open**, [#60](https://github.com/EnvelopSound/Earshot/pull/60) |
| 9 | `yarn --network-timeout` for slow build hosts | **open**, [#61](https://github.com/EnvelopSound/Earshot/pull/61) |

If those merge, they move into the table above and this section shrinks to the `.gitkeep` refinement plus one line: #58 and #60 are byte-identical to what is vendored here (bar comment wording), but #59 defaults `DASH_NAME` to the generic `stream` upstream against `hoast_demo` here, so that default stays a local deviation either way.

### 1. `src/Dockerfile`: `--enable-libvpx` added to the ffmpeg configure

Upstream installs `libvpx-dev` in the build stage and `libvpx` in the runtime stage but never enables it in ffmpeg's configure, so the shipped ffmpeg cannot encode VP9 (`Unrecognized option 'deadline'`). This stack's VP9 codec policy (opt-in via `FFMPEG_FLAGS`; the committed default is `-c:v copy`) requires libvpx when enabled.

### 2. `src/nginx-transcoder/entrypoint.sh`: volume-safe startup

```
- rm -rf /opt/data && mkdir -p /opt/data/dash && ...
+ mkdir -p /opt/data/dash && (find /opt/data/dash -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true) && ...
```

(`.gitkeep` is spared because the dev compose backs the volume with the repo's `./output` bind mount.)


Upstream wipes `/opt/data` at startup, which fails on a busy mountpoint when a Docker volume is mounted at `/opt/data/dash` (the `&&` chain then breaks and nginx starts unconfigured). The patched version clears stale segments without removing the mountpoint itself.

### 3. `src/Dockerfile`: `suggestedPresentationDelay` floor patched into ffmpeg

A guarded `sed` on `libavformat/dashenc.c` at image build floors the MPD's `suggestedPresentationDelay` at `DASH_SPD_FLOOR` seconds (build arg, default 30). No ffmpeg flag can set SPD for WebM DASH (`-target_latency` is force-zeroed outside LL-DASH mode) and upstream hardcodes it to the last segment duration, which makes players join right at the live edge and gap-jump.

The guard is anchored to the `suggestedPresentationDelay=` line at both ends, so an upstream restructuring of that line fails the build rather than silently producing an image without the floor (an unanchored check could match an unrelated `FFMAX()` elsewhere in the file and pass silently). Offered upstream as [#58](https://github.com/EnvelopSound/Earshot/pull/58).

### 4. `src/nginx-transcoder/nginx*.conf`: `wait_key` / `wait_video` on the relay

The transcoder is an nginx-rtmp `exec` ffmpeg that *subscribes* to the internal relay, and a subscriber joining a live stream gets audio immediately but no decodable video until the next keyframe - up to a full GOP later. The DASH muxer records that skew as a leading empty edit (`elst media_time = -1`) on the video track, which Firefox honours and Chromium's MSE does not, so Chromium paints video early by the same amount. These two directives start the relayed video at a keyframe and hold audio until video flows, so the tracks start together and no edit box is written at all. Measured in the restart-loop run: empty edits on 10/10 joins without them, `elst [(0,0)]` and tracks aligned within 3 ms on 20/20 encoder restarts with them. That run is the source of both counts, and `src/nginx-transcoder/nginx-no-ssl.conf:30-34` quotes the same two figures beside the directives; see the measurement notes being written up for publication (top-level README, Documentation) for the run itself.

### 5. `entrypoint.sh` + both nginx confs: `DASH_NAME` default and validation

Upstream names the DASH manifest after the RTMP stream key (`$name.mpd`), which ties the player's manifest URL to the stream key: rotating the key moves the manifest and breaks the page. Here the manifest name is its own variable, so the key can be rotated freely.

`DASH_NAME` is defaulted and validated in `entrypoint.sh` before nginx starts and before either `envsubst` call, and it is exported - the `envsubst` whitelist is derived from `env`, so an unexported value would leave a literal `${DASH_NAME}` in the rendered config and ffmpeg would write a file the player never fetches. It is read only from the container environment, never from the network, and rejecting `.` and `/` makes `..` and absolute paths unrepresentable.

Both nginx confs also carry `rewrite ^/dash/[^/]+\.mpd$ /dash/${DASH_NAME}.mpd break;`: upstream's webtools preview requests `/dash/<streamname>.mpd`, which would 404 once the manifest is no longer named after the stream key. The rewrite maps any such request to the real manifest; segments are referenced relatively, so they resolve unchanged.

Offered upstream as [#59](https://github.com/EnvelopSound/Earshot/pull/59), where the default is the generic `stream` rather than this stack's `hoast_demo` - so even if it merges, that one default stays a local deviation.

### 6. `src/nginx-transcoder/nginx*.conf`: `absolute_redirect off` on the HTTP server

nginx builds directory redirects (e.g. `/webtools` -> `/webtools/`) as absolute URLs from its internal listen port, which drops the external mapped port behind a Docker or Tailscale bind: `http://host:8081/webtools` 301s to `http://host/webtools/` (port 80), the wrong service. `absolute_redirect off` at the HTTP server level makes the redirect relative, so the browser resolves it against the request URL and keeps the port. Contributed upstream as [#56](https://github.com/EnvelopSound/Earshot/pull/56) and merged on 2026-07-24 (`ac1dda7`); applied here ahead of that merge.

### 7. `src/Dockerfile`: `ENABLE_NONFREE` build ARG

ffmpeg's `--enable-nonfree` marks the binary non-redistributable, but this build links no nonfree library (only libx264/libopus/libvpx), so the flag is a no-op licence stamp that blocks publishing a pre-built image. The ARG defaults to 1 in the Dockerfile (stock build unchanged), but the stack's docker-compose.yml passes 0 by default so its images are redistributable; export ENABLE_NONFREE=1 to restore the stock build. Verified equivalent end to end (16-ch Opus hexadecagonal + VP9, full pipeline test). Contributed upstream as [#57](https://github.com/EnvelopSound/Earshot/pull/57) and merged on 2026-07-27 (`e765fdb`); applied here ahead of that merge.

### 8. `src/nginx-transcoder/nginx*.conf`: `max_message 10M` on the RTMP server

nginx-rtmp's default `max_message` (1 MB) is sized for typical broadcast keyframes, not this stack's 4K H.264 GOPs, whose keyframes exceed it - the symptom is the relay dropping the publish with "too big message" before ffmpeg ever sees a frame. Raised to 10 MB, comfortably above a 4K keyframe at the bitrates this stack runs. Found undocumented during the 2026-08-06 re-vendor audit and offered upstream the same day as [#60](https://github.com/EnvelopSound/Earshot/pull/60).

### 9. `src/Dockerfile`: `--network-timeout` on the webtools `yarn` install

yarn 1.x defaults `--network-timeout` to 30 s, and that ceiling covers the CPU time yarn spends alongside each request, not just transfer. On a slow enough build host it expires mid-install and yarn reports it as "There appears to be trouble with your network connection", which reads like a network fault and sends you chasing DNS, MTU and registry mirrors. It is not one. Measured on a Raspberry Pi 4 (arm64, native, not emulated) while the image would not build: the install needs 145 s with yarn CPU-bound at 100-148 % throughout, the package it died on (`@material-ui/icons`) fetches in 0.23 s from inside this same image, RAM never went near the limit and no OOM killer fired. Raised to 600 s, which costs nothing on a fast host because the install finishes long before the ceiling matters. amd64 hosts never hit this, which is why it took an arm64 deployment to surface it. Offered upstream as [#61](https://github.com/EnvelopSound/Earshot/pull/61).

## What this service does in the stack

nginx-rtmp accepts the relayed stream from `rtmp-ingest` on :1935 (internal only) and `exec`s Envelop's PCE-aware ffmpeg fork per published stream:

```
ffmpeg -analyzeduration 10M -i rtmp://127.0.0.1/live/$name \
  -strict -2 -c:a libopus -mapping_family 255 -b:a 1024k ${FFMPEG_FLAGS} \
  -f dash /opt/data/dash/${DASH_NAME}.mpd
```

That is the line as it stands in `src/nginx-transcoder/nginx-no-ssl.conf:58`, which is the canonical copy: read the rationale for `-b:a 1024k` and for keeping `$name` on `-i` only in the comment block directly above it (`nginx-no-ssl.conf:38-57`) rather than here. `nginx.conf` (the `SSL_ENABLED=true` variant) must carry the identical exec line, so diff the two whenever either changes: if they drift, an SSL deployment runs an audio configuration nothing has tested.

16-channel Opus is hardcoded upstream; the video codec policy comes from the `FFMPEG_FLAGS` env var (see `.env.example` at the repo root - `-c:v copy` passthrough by default, VP9 realtime documented as the opt-in codec policy). The live MPEG-DASH segmentation happens *here*, not in the shaka service (shaka cannot ingest a 16-channel live stream and is a `tools`-profile utility for VOD packaging only).

HTTP :80 (mapped to host :8081 in dev) serves the webtools monitoring UI at `/webtools`, `rtmp_stat` at `/stat`, a health endpoint at `/` and the raw DASH output at `/dash` (the player normally serves it from the shared volume instead).
