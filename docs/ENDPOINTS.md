# Endpoints & ports

Every address the stack exposes, what serves it, and whether it is meant to be public or private. Ports below are the Compose host-published ports; a deployment maps them to real addresses/domains in `docker-compose.override.yml` and (for anything public) a reverse proxy or tunnel.

## Container-published ports

| Port | Service | Serves | Exposure intent |
|---|---|---|---|
| 1935 | `rtmp-ingest` | RTMP contribution `rtmp://<host>:1935/live/<key>` | public only if you run open ingest; else LAN/VPN |
| 8890/udp | `srt-gateway` | SRT contribution `srt://<host>:8890?streamid=<name>` (native OBS multitrack), the recommended ingest; bound by default, but admits nobody unless `GUEST_ENABLED=1` (`SRT_ENABLED=0` unbinds it) | public if you run the SRT guest endpoint. The gateway is privilege-separated (no docker socket, no volumes, no STREAM_KEY, read-only rootfs) because it terminates hostile pre-auth internet bytes |
| 8080 | `hoast-player` | player `/`, DASH `/dash/<DASH_NAME>.mpd`, public status `/status/status.json`, telemetry proxy `/api/live` (GET), `/api/start` (POST, rate-limited 6r/m burst 3) and `/api/guest/report` (POST, 1r/m burst 3) | **public** (front with TLS / a tunnel) |
| 8081 | `earshot` | dev monitor `/webtools`, `/stat`, `/dash` | **private**: debug only. `docker-compose.yml` binds `127.0.0.1:8081:80` (loopback only). Note Compose appends port entries, so a plain override list can widen but not narrow a base mapping (narrowing needs `!override`/`!reset` on the key). Firewall the port or edit the base file |
| 8090 | `telemetry` | dashboard `/`, `/stats.json`, `/viewers.csv` | **private**: bind localhost/VPN only, never `0.0.0.0` |

### If you bind a private port to a VPN or floating address

Binding these private ports to a VPN interface address (Tailscale, WireGuard, a keepalived VIP) rather than loopback is a reasonable way to reach them from your own devices only. It has one sharp edge worth knowing before a power cut finds it for you.

At boot, the container runtime generally starts once the VPN's *service* is active, but active does not mean the address has been **assigned** - the client may still be authenticating. Publishing a port to an address that does not exist yet fails with `cannot assign requested address`, and the container exits immediately. A `restart: unless-stopped` policy does **not** recover this, because the failure is in container networking setup rather than in the container process: the container stays dead until something restarts it by hand. Services bound to `0.0.0.0` come up normally in the same boot, so the stack appears half-working rather than obviously broken.

Two independent mitigations, worth having both:

- `net.ipv4.ip_nonlocal_bind = 1` (via `/etc/sysctl.d/`) lets the bind succeed regardless of when the address appears; traffic flows once it does. This prevents the failure.
- A boot-time script that waits for the address, brings the stack up, and then **verifies the private endpoints actually answer** - recreating any service whose port is not bound. This recovers from it.

Order matters on the way back up: `rtmp-ingest`'s nginx resolves `earshot` once when it loads its config, so it must start (or be restarted) after earshot is healthy, or it crash-loops on `host not found in url earshot:1935/live`.

The failure mode that makes this worth automating is not the downtime, it is the silence: **`telemetry` is the alerting path**, so if it is one of the services that failed to bind, nothing can report the outage - including the outage of the alerter itself. Any boot-recovery script should send its own notification, independently of telemetry, on success as well as failure.

Internal-only, never published: earshot's RTMP relay + `on_publish` callback (1935 / 80 inside the network), rtmp-ingest's health port (8080 internal), the `srt-gateway` status/health port (8091 internal; discloses the active caller IP, so same loopback-only reasoning as earshot's `/stat`), and the `dash-output` / `status-public` volumes.

### Control routes proxied on 8080

`hoast-player` reverse-proxies exactly three telemetry routes to the public port (`/api/live`, `/api/start`, `/api/guest/report`), all three as exact-match `location =` blocks, so nothing else on 8090 is reachable from outside:

| Route | Method | Proxies to | Notes |
|---|---|---|---|
| `/api/live` | GET | `telemetry:8090/api/live` | readiness poll while a visitor waits out a cold start |
| `/api/start` | POST | `telemetry:8090/api/start` | starts the loop source; `limit_req` zone `startreq`, 6r/m, burst 3 |
| `/api/guest/report` | POST | `telemetry:8090/api/guest/report` | viewer's abuse report against the live guest session; `limit_req` zone `reportreq`, 1r/m, burst 3, keyed on `$viewer_ip` rather than `$binary_remote_addr` so a tunnel does not share one bucket. nginx passes the reporter's IP and country as `X-Viewer-IP` / `X-Viewer-CC` for the moderation alert |

`/api/stop` is deliberately **not** proxied: stopping the source is the one verb a visitor could use to spoil the demo for everyone else, so it stays on telemetry's own 127.0.0.1-bound port.

The docker socket telemetry mounts is read-write, because starting and stopping the source needs it. What keeps that safe is this route list, not the mount: if you add a fourth `/api` route here, it must not pass any request-controlled string into a docker invocation.

### Player URL flags

`?dbg` shows a small on-page diagnostic badge: the build tag, live delay, the video element / drawing buffer / decoded video-frame dimensions, aspect, and `gl.MAX_TEXTURE_SIZE`. It is a read-only overlay for debugging render and sizing issues, and because it needs no dev console it is the way to read that state on a phone. It does not affect playback and is off by default.

Audio-path flags (mechanism measured in the publication notes; see the README's Documentation section). The player compensates for a video edit list Chromium's MSE ignores by driving the audio itself (the SegmentAudioFeed), on **desktop Chromium** only; Firefox and mobile use the legacy element audio.

- `?audiofeed` forces the segment-audio feed ON where it is off by default, i.e. on mobile Chromium, for testing the decode/sync there before it is enabled.
- `?legacyaudio` forces the old element-audio wiring ON anywhere (Firefox-style), for A/B comparison against the feed.

## What telemetry itself polls (the monitoring inputs)

- `earshot /stat` → `<publishing/>`, `<nclients>`: is a stream live?
- newest `chunk-stream*` segment (`.webm`/`.m4s`/`.mp4`) mtime in the dash volume: segment freshness
- docker container health + the hoast-player access log: viewers + countries
- `/sys/class/thermal/thermal_zone0/temp`, `df /`, uptime, load: host health

## What to watch from outside

| Check | Healthy |
|---|---|
| `GET <player-public-url>/` | 200 |
| `GET <player-public-url>/status/status.json` | 200; `live:true` while streaming |
| `GET <player-public-url>/dash/<DASH_NAME>.mpd` | 200 while streaming |
| dashboard (:8090) | reachable **only** on your private/VPN address |
| tunnel / edge (if used) | active |

## Your deployment (fill in; keep OUT of git)

Record the real addresses in a local ops note or in `docker-compose.override.yml`, not in this committed file:

- Host / SSH: `<hostname>` / `<vpn-ip>` (+ any port-forward)
- Player public URL: `https://<your-domain>`
- Telemetry dashboard: `http://<vpn-ip>:8090`
- Ingest: `rtmp://<host-or-public-ip>:1935/live/<key>`
