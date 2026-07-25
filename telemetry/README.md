# telemetry

Operations monitoring for the HOA 360° stack, shipped as a compose service so any
deployment gets it for free. Three outputs from one small stdlib collector:

1. **Private dashboard** — `http://<host>:8090/` (service health, encoder speed,
   viewers + countries, CPU temp, disk, uptime, sparklines). Bind `:8090` to a
   private interface (e.g. Tailscale) in `docker-compose.override.yml`; never
   publish it.
2. **Breakage-only Telegram alerts** — fire on the *rising edge* of a sustained
   problem (debounced: must persist `DEBOUNCE` consecutive checks) and again on
   recovery, so transient blips stay quiet. Disabled unless `BOT_TOKEN`/`CHAT_ID`
   are set.
3. **Curated public `status.json`** — written to the shared `status-public`
   volume and served by hoast-player at `/status/status.json` for the player's
   collapsible status panel. Deliberately excludes host internals (temp, disk,
   load stay on the private dashboard).

## How it reads the stack

- **container health** and the **player access log** — via the mounted docker
  socket. Read-write, not read-only: besides `docker ps --format json`,
  `docker logs` and `docker exec`, on-demand idling runs `docker start` and
  `docker stop` on the loop source.
- **stream liveness** — earshot's `/stat` (`<publishing/>`, `<nclients>`) plus
  the freshness of the newest segment in the `dash-output` volume.
- **viewers + countries** — unique public client IPs on `/dash/` in the last
  90 s, parsed from hoast-player's `cf` log format
  (`<CF-Connecting-IP> <CF-IPCountry> "<request>" <status>`), so viewers behind
  the Cloudflare tunnel are counted with their real IP + country.
- **CPU temp / disk / uptime** — optional Linux-host mounts (see the override
  example); without them those fields read `null`.

## Configuration (environment)

| var | default | meaning |
|-----|---------|---------|
| `TEL_HOST` | `hoa360` | name shown on the dashboard + in alerts |
| `COMPOSE_PROJECT_NAME` | `hoa360` | compose project label used to find containers |
| `FFMPEG_FLAGS` | – | parsed for reported resolution/bitrate (pass the same value earshot gets) |
| `BOT_TOKEN` / `CHAT_ID` | – | Telegram; unset ⇒ alerting disabled |
| `TEL_INTERVAL` | `60` | seconds between collections |
| `TEL_PORT` | `8090` | dashboard port |
| `TEL_THERMAL` | `/sys/class/thermal/thermal_zone0/temp` | CPU temp source (container sees host sysfs; no mount needed) |
| `TEL_DISK` | `/host/root` | path whose filesystem usage is reported (mount host `/`) |

## Volumes

- `/var/run/docker.sock` — container health/logs, plus `docker start` /
  `docker stop` of the loop source for on-demand idling, so it is mounted
  read-write. This grants the collector full docker API access, i.e. root on the
  host; adding a `:ro` suffix would not change that, since it applies to the
  socket inode and not to the requests sent through it
- `telemetry-data` → `/data` — dashboard html + `stats.json` + `viewers.csv`
  history + alert state (private; only this service mounts it)
- `status-public` → `/pub` — the one curated `status.json`, shared read-only into
  hoast-player
- `dash-output` → `/dash:ro` — segment freshness

The image needs only the docker **CLI** (talks to the socket) — no docker engine,
no Python dependencies. Multi-arch (amd64 + arm64).


## Guest session log: retention and geolocation

`guest_sessions.csv` rows are kept indefinitely as anonymised statistics
(timestamp, sanitised stream name, country, duration, end reason), mirroring
the viewer stats' long-standing shape (counts and countries, never
identifiers). The IP column is redacted after `GUEST_RETENTION_DAYS`
(default 30), which is what the public notice's 30-day line refers to.

Country is resolved locally at session end from the DB-IP country-lite
database (fetched once into the data volume at start, fail-soft to `--`
offline; refresh by deleting `dbip-country-lite.csv.gz` from the volume).
Guest IPs are never sent to any online lookup service.

IP Geolocation by [DB-IP](https://db-ip.com) (CC BY 4.0).
