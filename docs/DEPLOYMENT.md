# Deployment

Where this stack has actually run, what was measured on each host, and the per-host settings that do not belong in the repo. The [README's Deployment section](../README.md#deployment) is the short version.

## Local / lab (AMD64)

The [quick start](../README.md#quick-start). Validated on WSL2 Ubuntu and on Ubuntu Server 22.04.

## Raspberry Pi 4 (ARM64): validated end to end

`docker buildx build --platform linux/arm64` compiles and `docker compose up` brings up all six services, but the interesting part is what was confirmed **on the device** rather than inferred from a successful build: a real RTMP publish produced a real 16-channel Opus DASH manifest, and the manifest, the live-edge behaviour and the channel count were each checked directly.

**Sustained load.** Twenty continuous minutes of real transcoding (H.264 passthrough plus the 16-channel Opus encode):

| Measure | Result |
|---|---|
| earshot CPU | steady 32-34 % |
| Temperature | 54.5-65.7 C |
| Official case fan | cycled at 70 % duty, held that ceiling |
| `vcgencmd get_throttled` | clean throughout |

**UDP source-address preservation** (2026-08-03), which the SRT guest attribution depends on, was confirmed separately on the same board. Without it every guest would key to one container address and per-IP bans could not work.

**Auto-idle held up as designed**, which matters more on a board this size than on a workstation: the demo loop stops encoding after `TEL_IDLE_STOP_MIN` minutes with nobody watching and resumes the moment a viewer connects. An always-encoding demo loop is a real cost here, not a rounding error.

### Two arm64 build issues, fixed in this repo

Both are fixed in the tree rather than worked around locally, so a fresh clone hits neither. They are recorded because both fail in ways that do not name their cause.

- **yarn's default network timeout is too short for this host's install speed.** It reports a network fault that is not one. See [services/earshot/README.md](../services/earshot/README.md) section 9.
- **nginx-rtmp's exec path can inherit an unbounded file-descriptor limit** from some hosts' containerd config, which silently stalls the transcoder for minutes before it ever starts. Fixed by the `ulimits` block on the `earshot` service in [docker-compose.yml](../docker-compose.yml), where the mechanism is written out in full.

Neither is arm64-specific in principle; the Pi is simply where a slow enough host and an unusual enough containerd default surfaced them.

## Azure: planned, not yet validated

For one-off events. Raw TCP ingress for 1935 is the constraint to solve. Treat this as a direction rather than a documented path: this section grows real instructions when a real deployment produces them.

## Per-host overrides

Deployment-specific settings live in `docker-compose.override.yml`, which Compose loads automatically and which is gitignored. Copy [docker-compose.override.yml.example](../docker-compose.override.yml.example) and adjust. The base stack runs without it.

Typical contents:

- bind the private dashboard (`:8090`) to a private or VPN address rather than loopback
- mount host CPU-temp and disk paths for the telemetry service
- Telegram tokens (better in `.env`, which is also gitignored)
- a branded landing page
- the `srt-gateway-owner` block, if you narrow the owner route's bind or want it on a VPN address only

`scripts/setup.sh` writes a minimal override containing just the owner route, and never overwrites one that already exists.
