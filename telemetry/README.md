# `telemetry` service - operations monitoring for the stack

Operations monitoring for the HOA 360° stack, shipped as a compose service so any deployment gets it for free. Three outputs from one small stdlib collector:

1. **Private dashboard** - `http://<host>:8090/` (service health, encoder speed, viewers + countries, CPU temp, disk, uptime, sparklines). Bind `:8090` to a private interface (e.g. Tailscale) in `docker-compose.override.yml`; never publish it.
2. **Breakage-only push alerts** (Telegram out of the box; see [Alerting](#alerting) to swap it) - fire on the *rising edge* of a sustained problem (debounced: must persist `DEBOUNCE` consecutive checks) and again on recovery, so transient blips stay quiet. Disabled unless `BOT_TOKEN`/`CHAT_ID` are set.
3. **Curated public `status.json`** - written to the shared `status-public` volume and served by `hoast-player` at `/status/status.json` for the player's collapsible status panel. Deliberately excludes host internals (temp, disk, load stay on the private dashboard).

## Alerting

Telegram ships as the default because it needs the least: create a bot, set `BOT_TOKEN`/`CHAT_ID`, done - no account approval, no daemon, one HTTPS POST. Unset either variable and nothing is sent or contacted.

If you would rather not use it, swapping is deliberately small: `telegram()` in `collect.py` is under 60 lines across seven call sites, and it only ever needs to turn a string into one outbound request. The constraint to respect is that this service is **stdlib only** (see the Dockerfile), so a replacement should be reachable with `urllib` or `smtplib` rather than a vendor SDK. These are all straightforward\*:

| Instead of Telegram | Why |
|---|---|
| **[ntfy](https://ntfy.sh)** | Purpose-built for this: POST to a topic, push notification on your phone, no account. Open source and **self-hostable**, so alerts never leave your own infrastructure. About three lines. |
| **[Matrix](https://matrix.org)** | Federated, self-hostable, end-to-end capable. A bot posting to a room is a plain authenticated PUT. More setup than ntfy, strongest open-standards story. |
| **Email (SMTP)** | `smtplib` is stdlib and you probably already have a mailbox. Less immediate than push, but no new vendor. |
| **Slack / Discord webhooks** | The least work of all - one POST to a webhook URL - though both are corporate-hosted, so no privacy gain over Telegram. |

\* *Not shipped. Each is a small edit to one function, but you are writing and testing it, not configuring it.*

**Signal, WhatsApp and Messenger are poor fits here**, on mechanics rather than reputation. Signal has no bot API: you would run `signal-cli` as a separate daemon with its own registered number and linked session to keep alive. WhatsApp and Messenger need a Meta Business account, app review, and template messages outside a 24-hour session window - which is precisely the situation an unattended 3 a.m. alert is in.

**What actually leaves the box.** Alerts carry the host name (`TEL_HOST`), the dashboard URL, and - for guest-endpoint events - a guest's stream name, source IP and country. That is a copy of personal data living in a chat history, outside the retention window the CSVs promise (`GUEST_RETENTION_DAYS`). Changing hosted messenger does not address that; self-hosting ntfy or Matrix does. Worth a thought before adding anyone else to the chat.

## How it reads the stack

- **container health** and the **player access log** - via the mounted docker socket. Read-write, not read-only: besides `docker ps --format json`, `docker logs` and `docker exec`, on-demand idling runs `docker start` and `docker stop` on the loop source.
- **stream liveness** - `earshot`'s `/stat` (`<publishing/>`, `<nclients>`) plus the freshness of the newest segment in the `dash-output` volume.
- **viewers + countries** - unique public client IPs on `/dash/` in the last 90 s, parsed from `hoast-player`'s `cf` log format (`<CF-Connecting-IP> <CF-IPCountry> "<request>" <status>`), so viewers behind a Cloudflare tunnel (if one fronts the player) are counted with their real IP + country, and direct viewers fall back to the peer address.
- **Disk usage** needs the host `/` mount from the override example; CPU temp and uptime read host sysfs/procfs without extra mounts. Unavailable fields read `null`.

## Configuration (environment)

| var | default | meaning |
|-----|---------|---------|
| `TEL_HOST` | `ambisonic-box` | name shown on the dashboard + in alerts |
| `COMPOSE_PROJECT_NAME` | `ambi-box` | compose project label used to find containers |
| `FFMPEG_FLAGS` | – | parsed for reported resolution/bitrate (pass the same value `earshot` gets) |
| `BOT_TOKEN` / `CHAT_ID` | – | Telegram; unset ⇒ alerting disabled |
| `TEL_INTERVAL` | `60` | seconds between collections |
| `TEL_PORT` | `8090` | dashboard port |
| `TEL_THERMAL` | `/sys/class/thermal/thermal_zone0/temp` | CPU temp source (container sees host sysfs; no mount needed) |
| `TEL_DISK` | `/host/root` | path whose filesystem usage is reported (mount host `/`) |
| `TEL_IDLE_STOP_MIN` | `10` | minutes with no viewer before the demo loop is stopped; `0` disables on-demand idling |
| `TEL_START_GRACE_S` | `300` | seconds after a start during which idling never fires, so a fresh stack is not stopped under its own feet |
| `GUEST_RETENTION_DAYS` | `30` | how long a guest's IP survives in the CSVs before the column is redacted |

## Volumes

- `/var/run/docker.sock` - container health/logs, plus `docker start` / `docker stop` of the loop source for on-demand idling, so it is mounted read-write. This grants the collector full docker API access, i.e. root on the host; adding a `:ro` suffix would not change that, since it applies to the socket inode and not to the requests sent through it
- `telemetry-data` → `/data` - dashboard html + `stats.json` + `viewers.csv` history + alert state (private; only this service mounts it)
- `status-public` → `/pub` - the one curated `status.json`, shared read-only into `hoast-player`
- `dash-output` → `/dash:ro` - segment freshness

The image needs only the docker **CLI** (talks to the socket) - no docker engine, no Python dependencies. Multi-arch (amd64 + arm64).


## Guest session log: retention and geolocation

`guest_sessions.csv` rows are kept indefinitely as anonymised statistics (timestamp, sanitised stream name, country, duration, end reason), the same shape as the viewer stats (counts and countries, never identifiers). The IP column is truncated to its network prefix (a.b.c.x for v4, /48 for v6) after `GUEST_RETENTION_DAYS` (default 30), keeping repeat-network patterns visible without keeping the address, which is what the guest-endpoint notice on the player page refers to with its retention line (the `{RETENTION_DAYS}` placeholder).

Country is resolved locally at session end from the DB-IP country-lite database (fetched once into the data volume at start, fail-soft to `--` offline; refresh by deleting `dbip-country-lite.csv.gz` from the volume). Guest IPs are never sent to any online lookup service.

IP Geolocation by [DB-IP](https://db-ip.com) (CC BY 4.0).
