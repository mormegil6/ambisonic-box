# Endpoints & ports

Every address the stack exposes, what serves it, and whether it is meant to be
public or private. Ports below are the Compose host-published ports; a
deployment maps them to real addresses/domains in `docker-compose.override.yml`
and (for anything public) a reverse proxy or tunnel.

## Container-published ports

| Port | Service | Serves | Exposure intent |
|---|---|---|---|
| 1935 | `rtmp-ingest` | RTMP contribution `rtmp://<host>:1935/live/<key>` | public only if you run open ingest; else LAN/VPN |
| 8080 | `hoast-player` | player `/`, DASH `/dash/<key>.mpd`, public status `/status/status.json` | **public** (front with TLS / a tunnel) |
| 8081 | `earshot` | dev monitor `/webtools`, `/stat`, `/dash` | **private** — debug only, bind LAN/localhost |
| 8090 | `telemetry` | dashboard `/`, `/stats.json`, `/viewers.csv` | **private** — bind localhost/VPN only, never `0.0.0.0` |

Internal-only, never published: earshot's RTMP relay + `on_publish` callback
(1935 / 8000 inside the network), rtmp-ingest's health port (8080 internal),
and the `dash-output` / `status-public` volumes.

## What telemetry itself polls (the monitoring inputs)

- `earshot /stat` → `<publishing/>`, `<nclients>` — is a stream live?
- newest `chunk-stream*.webm` mtime in the dash volume — segment freshness
- docker container health + the hoast-player access log — viewers + countries
- `/sys/class/thermal/thermal_zone0/temp`, `df /`, uptime, load — host health

## What to watch from outside

| Check | Healthy |
|---|---|
| `GET <player-public-url>/` | 200 |
| `GET <player-public-url>/status/status.json` | 200; `live:true` while streaming |
| `GET <player-public-url>/dash/<key>.mpd` | 200 while streaming |
| telemetry dashboard | reachable **only** on your private/VPN address |
| tunnel / edge (if used) | active |

## Your deployment (fill in; keep OUT of git)

Record the real addresses in a local ops note or in
`docker-compose.override.yml` — not in this committed file:

- Host / SSH: `<hostname>` / `<vpn-ip>` (+ any port-forward)
- Player public URL: `https://<your-domain>`
- Telemetry dashboard: `http://<vpn-ip>:8090`
- Ingest: `rtmp://<host-or-public-ip>:1935/live/<key>`
