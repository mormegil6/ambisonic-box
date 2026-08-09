# Architecture diagram

The data-flow diagram embedded in the top-level `README.md`.

## What the diagram simplifies

The diagram draws the data path and compresses everything else. The omissions are deliberate, so the picture stays readable; this is the honest list:

- **`shaka packager (profile: tools)`** means the service sits behind the Compose profile named `tools`: a plain `docker compose up` never starts it, it runs only on demand (`docker compose run --rm shaka <packager args>`) for offline VOD packaging and the A/V-sync test fixtures. The dotted edge into the volume means exactly that: not part of the live path, and it could not be (it cannot ingest a 16-channel live stream).
- **telemetry has one drawn input (the dash-output freshness probe) but several real ones**, all undrawn: container health and the hoast-player access log (viewer counts, countries) via the Docker socket, earshot's `/stat` (is a publisher connected), and the host's temperature, disk and uptime.
- **telemetry is not only a sink.** Undrawn control and output edges: it starts and stops `loop-source` for on-demand idling (a Docker-socket action, which is why the socket mount is read-write), writes the curated public `status.json` into the `status-public` volume that hoast-player serves, and sends Telegram alerts.
- **the viewer's control path is invisible.** A visitor wakes the idle demo through exactly three `/api` routes that hoast-player reverse-proxies to telemetry; the diagram shows only the one HTTP edge. The route list, and why it is exactly three, is in [`docs/ENDPOINTS.md`](../ENDPOINTS.md).
- **`rtmp-ingest`'s "auth" label compresses the mechanism**: the `on_publish` callback goes to an auth endpoint inside the same container, not to another service.
- **the two SRT gateways are drawn as one box.** There are really two instances of the same image: `srt-gateway` (guest, 8890/udp, in the base compose) and `srt-gateway-owner` (8891/udp, written into the override by `scripts/setup.sh`). They differ only in mode, and drawing both would double the busiest corner of the picture, so one box carries both labels. The two outgoing edges are real and are the whole point of the distinction: the guest route republishes over RTMP into `rtmp-ingest`, and the owner route (default `SRT_DIRECT=1`) hands MPEG-TS straight to earshot, skipping ingest and the 16-channel AAC re-encode it would otherwise force.
- **`srt-gateway` is drawn first because it is the recommended contribution path** (stock OBS, same recipe on macOS and Windows) and it is on by default. What the drawing cannot show is that binding the port admits nobody on its own: the guest arbiter refuses every caller unless `GUEST_ENABLED=1`, which is itself off by default.
- **contribution is really a 2x2 that the port labels flatten to transports, not roles.** Both roles can arrive over both transports: an OWNER pushes SRT to `:8891` (the owner gateway) or RTMP to `:1935/owner` (key-authed), and a GUEST pushes SRT to `:8890` (the guest gateway) or RTMP to `:1935/guest` (keyless, arbiter-gated) - stock OBS over SRT or OBS Music Edition over RTMP, per `docs/GUEST-ENDPOINT.md`. So `RTMP :1935` carries owner and guest alike (different application, same port), and `SRT :8890` is specifically the guest SRT port while the owner's `:8891` is folded into the one gateway box above. The diagram draws one representative sender per transport rather than all four combinations.
- **the "MPEG-TS, direct" edge is drawn once but is not one policy.** It is default-ON for the owner and default-OFF for a guest (`GUEST_SRT_DIRECT`, 2026-08-09): both are authenticated the same way once a session takes this edge (telemetry's `/gw/session/claim|beat|done`, peer-address + secret), but a guest additionally needs the operator to have turned the flag on. Until then a guest's only route is the `RTMP /guest` edge above, same as before that path existed.
- **the guest arbitration behind that gateway is invisible here.** The drawn edge into `rtmp-ingest` hides the whole session lifecycle the SRT route inherits by republishing into the existing `guest` application: single-slot admission, session cap, cooldown, reconnect grace, IP bans and the dashboard kill. See the guest section of the top-level `README.md`.
- **only the `dash-output` volume is drawn**; `telemetry-data` (private dashboard history) and `status-public` (public status JSON) exist but carry no arrows here.
- **the `dash-output` cylinder has exactly one live writer** (`earshot`); `hoast-player` and `telemetry` mount it read-only, so the internet-facing player can serve the live segments but cannot alter them. That single-writer invariant is load-bearing beyond the diagram - it is what the SRT contribution paths are careful never to violate by putting a second writer on the tree.

- `architecture.png` - what the README embeds (see the foreignObject note below)
- `architecture.svg` - the scalable vector source (open it directly to view)

## Files

| file | role |
|---|---|
| `architecture.mmd` | mermaid source - the only file you edit by hand |
| `logos/` | the OS marks used in the two sender nodes (see below) |
| `mermaid-config.json` | theme: colours, font, dagre curves |
| `puppeteer-config.json` | Chromium-based browser path for mermaid-cli + rasteriser |
| `postprocess.py` | rearranges mermaid's raw dagre layout (python stdlib only) |
| `build.sh` | inline the logos -> `mmdc` render -> `postprocess.py` -> `architecture.svg` + `.png` |
| `architecture.svg` / `architecture.png` | generated outputs, committed |

## Regenerate

```sh
./build.sh
```

Needs `node`/`npx`, `python3`, and a Chromium-based browser (path in `puppeteer-config.json`). Edit `architecture.mmd`, rerun, commit the outputs.

## Why a PNG in the README, not the SVG

mermaid renders node and label text inside `<foreignObject>` (HTML). Whether that renders when the SVG is loaded through an `<img>` tag depends on the viewer's browser and installed fonts (current Chrome and Firefox do render it, but support isn't universal and shouldn't be relied on for a README that has to work everywhere). The README embeds `architecture.png`; the SVG remains the vector source.

## Why postprocess.py

mermaid's dagre layout stacks everything top-to-bottom. `postprocess.py` keys off mermaid's stable element ids to: run the SRT contribution chain (stock OBS -> srt-gateway -> rtmp-ingest) as one straight horizontal line on ingest's row, curve the legacy RTMP sender up into ingest from below on the same gutter axis, flank rtmp-ingest with loop-source on a straight horizontal edge to the right, place the viewer in that same left gutter level with hoast-player, shrink the DOCKER COMPOSE box to its content with the title sitting on the top edge in a chip that breaks the border, and round the corners. It relies on the raw SVG having a single coordinate system, which is why the subgraph in `architecture.mmd` carries no `direction` (a nested one would give mermaid two coordinate systems).

Two placements the source cannot express, both consequences of `srt-gateway` being a compose service while its sender is not:

- the gateway has to sit *inside* the box on ingest's row, and dagre leaves nowhere near enough room there, so `postprocess.py` pushes the box's **left wall outward** until the gateway plus its edge label fit. The empty area this opens in the box's lower left is the cost of putting the gateway beside ingest rather than above it.
- the legacy RTMP edge therefore has to reach ingest *past* the gateway. It is drawn as an S-curve (the same style as the dash-output volume edges) that stays flat until it is clear of the gateway and then lifts into ingest's left edge, which also reads correctly: that path bypasses the gateway entirely.

## The OS logos

`architecture.mmd` carries `{{LOGO_APPLE}}` / `{{LOGO_WINDOWS}}` placeholders rather than the artwork, so the source stays readable; `build.sh` substitutes them before `mmdc` runs, because dagre has to measure the real label width. They are inlined as base64 data URIs so the committed SVG renders standalone.

Both marks come from Wikimedia Commons and are **public domain for copyright purposes** (simple geometry, below the threshold of originality) while remaining **registered trademarks** of their owners:

| file | source |
|---|---|
| `logos/apple-white.svg` | [Apple_logo_white.svg](https://commons.wikimedia.org/wiki/File:Apple_logo_white.svg) |
| `logos/windows-white.svg` | [Windows logo - 2002-2012 (Black)](https://commons.wikimedia.org/wiki/File:Windows_logo_-_2002%E2%80%932012_(Black).svg), recoloured white |

They appear here only to state which platforms each sender runs on - nominative use, indicating compatibility. Nothing in this project is endorsed by, affiliated with, or certified by Apple or Microsoft.

Two implementation notes, both learned the hard way and both load-bearing: the sources need an explicit `viewBox` (without one an `<img>` cannot preserve their aspect and they render as smears), and each logo must be wrapped in a fixed-size `inline-block` span, because mermaid forces `display:flex; flex-direction:column; width:100%` onto images inside labels - unwrapped, every logo becomes a full-width block on its own line. Substituting a raw `<svg>` element instead is not a way around it: mermaid's label parser mangles the surrounding text.
