# Deployment

Where this stack has actually run, what was measured on each host, and the per-host settings that do not belong in the repo. The [README's Deployment section](../README.md#deployment) is the short version.

## Local / lab (AMD64)

The [quick start](../README.md#quick-start). Validated on WSL2 Ubuntu 24.04 LTS and on Ubuntu Server 26.04 LTS, the latter being what the reference deployment host (a 2012 Mac Mini, quad-core i7) runs.

## Raspberry Pi 4 (ARM64): validated end to end

Raspberry Pi OS 13 (trixie), 64-bit, kernel `6.18.34+rpt-rpi-v8`.

`docker buildx build --platform linux/arm64` compiles and `docker compose up` brings up all six services, but the interesting part is what was confirmed **on the device** rather than inferred from a successful build: a real RTMP publish produced a real 16-channel Opus DASH manifest, and the manifest, the live-edge behaviour and the channel count were each checked directly.

**Sustained load.** Twenty continuous minutes of real transcoding (H.264 passthrough plus the 16-channel Opus encode):

| Measure | Result |
|---|---|
| `earshot` CPU | steady 32-34 % |
| Temperature | 54.5-65.7 C |
| Official case fan | cycled at 70 % duty, held that ceiling |
| `vcgencmd get_throttled` | clean throughout |

**UDP source-address preservation** (2026-08-03), which the SRT guest attribution depends on, was confirmed separately on the same board. Without it every guest would key to one container address and per-IP bans could not work.

**Auto-idle held up as designed**, which matters more on a board this size than on a workstation: the demo loop stops encoding after `TEL_IDLE_STOP_MIN` minutes with nobody watching and resumes the moment a viewer connects. An always-encoding demo loop is a real cost here, not a rounding error.

### Two arm64 build issues, fixed in this repo

Both are fixed in the tree rather than worked around locally, so a fresh clone hits neither. They are recorded because both fail in ways that do not name their cause.

- **yarn's default network timeout is too short for this host's install speed.** It reports a network fault that is not one. Fixed upstream in Earshot [#61](https://github.com/EnvelopSound/Earshot/pull/61), so any current Earshot build has it; the measurements behind the one-flag fix are in the comment above `RUN yarn --network-timeout 600000` in [the earshot `Dockerfile`](https://github.com/mormegil6/Earshot/blob/master/Dockerfile).
- **nginx-rtmp's exec path can inherit an unbounded file-descriptor limit** from some hosts' containerd config, which silently stalls the transcoder for minutes before it ever starts. Fixed by the `ulimits` block on the `earshot` service in [docker-compose.yml](../docker-compose.yml), where the mechanism is written out in full.

Neither is arm64-specific in principle; the Pi is simply where a slow enough host and an unusual enough containerd default surfaced them.

## Azure: planned, not yet validated

For one-off events. The constraint is raw L4 ingress for the contribution leg, and it is not specific to RTMP: the recommended SRT path needs **UDP** 8890 (guest) or 8891 (owner), and the legacy RTMP path needs **TCP** 1935. HTTP-only front ends carry neither, so this wants a VM or an L4 load balancer - and UDP is the less widely supported of the two, so choosing SRT does not sidestep the problem, it changes which half of it you have. Delivery is the easy half either way: the player and DASH segments are ordinary HTTP and already sit behind a tunnel.

Treat this as a direction rather than a documented path: this section grows real instructions when a real deployment produces them.

## Optional: caching live segments at a CDN edge

If you front the player with a CDN, its default rules probably do NOT cache the live DASH segments, and the reason is a single detail that costs a day to find: a CDN's default cacheable-extension list is built for the web, so `.mp4` is on it but `.m4s` is not. Under the committed `-c:v copy` default both the video and the audio segments are `.m4s`, on the opt-in VP9 path both are `.webm`, and neither extension is cached by default. So without a rule every viewer's every segment request travels all the way to the box: N viewers cost N times the origin egress through your tunnel, on a home uplink, for bytes that are identical across all of them.

A single cache rule fixes it. On Cloudflare, a Cache Rule matching the segment paths - `URI Path starts with /dash/chunk-` and `URI Path starts with /dash/init-` - set to Eligible for cache with an Edge TTL of ~120 s that ignores the origin's cache-control, makes the edge serve every viewer after the first from cache. Matching on the path prefix rather than the extension keeps the rule correct under either container policy: all `.m4s` on the committed passthrough default, all `.webm` if you switch to VP9. Verified off-box: an init segment returns `cf-cache-status: MISS` once, then `HIT` for everyone after.

**Two things the rule must never grow to cover.** The manifest (`*.mpd`) MUST stay dynamic and uncached: this stack counts viewers by manifest polls reaching the origin, and the same polls are the heartbeat that keeps the on-demand loop awake, so an edge-cached manifest blinds the dashboard and can let the demo idle out under a live audience. And there is nothing to gain from caching `/vod-dash/` this way - the on-demand path has its own object-storage answer in [docs/VOD.md](VOD.md#optional-serving-vod-from-object-storage).

**Check your CDN's terms first, same as for VOD.** Serving the segments from your box origin through a CDN edge is closer to "delivering large non-Cloudflare-hosted video through the proxy" than uncached passthrough was - the pattern [Cloudflare's terms](https://blog.cloudflare.com/updated-tos) restrict. A research demo with a handful of viewers is not what that enforcement is for, but the profile scales with your audience, and unlike VOD there is no free Cloudflare-hosted origin for a live stream the way R2 is for VOD. Worth knowing before an announcement, not a reason to avoid the rule at demo scale.

## Per-host overrides

Deployment-specific settings live in `docker-compose.override.yml`, which is gitignored and always loaded: automatically when no `COMPOSE_FILE` is set, and as part of the list `scripts/setup.sh` writes otherwise. Copy [docker-compose.override.yml.example](../docker-compose.override.yml.example) and adjust. The base stack runs without it.

Typical contents:

- bind the private dashboard (`:8090`) to a private or VPN address rather than loopback
- mount host CPU-temp and disk paths for the `telemetry` service
- Telegram tokens (better in `.env`, which is also gitignored)
- a branded landing page
- the `srt-gateway-owner` block, if you narrow the owner route's bind or want it on a VPN address only

`scripts/setup.sh` writes a minimal override containing just the owner route, and never overwrites one that already exists.
