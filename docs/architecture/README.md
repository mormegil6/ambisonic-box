# Architecture diagram

The data-flow diagram embedded in the top-level [`README.md`](../../README.md#architecture).

## What the diagram simplifies

The diagram draws the data path and compresses everything else, so the picture stays readable:

- **`shaka packager (profile: tools)`** means the service sits behind the Compose profile named `tools`: a plain `docker compose up` never starts it, it runs only on demand (`docker compose run --rm shaka <packager args>`) for offline VOD packaging and the A/V-sync test fixtures. The dotted edge into the volume marks that: not part of the live path, and unable to be, since it cannot ingest a 16-channel live stream.
- **`telemetry` has one drawn input (the dash-output freshness probe) but several real ones**, all undrawn: container health and the `hoast-player` access log (viewer counts, countries) via the Docker socket, `earshot`'s `/stat` (is a publisher connected), and the host's temperature, disk and uptime.
- **`telemetry` is not only a sink.** Undrawn control and output edges: it starts and stops `loop-source` for on-demand idling (a Docker-socket action, which is why the socket mount is read-write), writes the curated public `status.json` into the `status-public` volume that `hoast-player` serves, and sends Telegram alerts.
- **the viewer's control path is invisible.** `hoast-player` reverse-proxies three `/api` routes to `telemetry` behind the one drawn HTTP edge. Two wake the idle demo: `/api/live` polls readiness through a cold start, `/api/start` starts `loop-source`. The third, `/api/guest/report`, starts nothing - it files a viewer's abuse report, and answers only while a guest session is already live. Full list in [`docs/ENDPOINTS.md`](../ENDPOINTS.md).
- **`rtmp-ingest`'s "auth" label compresses the mechanism**: the [`on_publish`](../../services/rtmp-ingest/nginx.conf.template) callback goes to an auth endpoint inside the same container, not to another service.
- **the two SRT gateways are drawn as one box.** There are really two instances of the same image: `srt-gateway` (guest, 8890/udp, in the base compose) and `srt-gateway-owner` (8891/udp, written into the override by [`scripts/setup.sh`](../../scripts/setup.sh)). They differ only in mode, and drawing both would double the busiest corner of the picture, so one box carries both labels. The port is not flattened: the inbound edges stay labelled `:8891, owner` and `:8890, guest`, which is what a sender has to get right. Nor are the outgoing edges - both roles default to the direct edge, handing MPEG-TS straight to `earshot` and skipping ingest and the 16-channel AAC re-encode it would otherwise force. The two `RTMP` edges into `rtmp-ingest` are the fallback each role drops to when its flag is set to 0.
- **owner routes are drawn above guest routes.** Both parallel pairs, SRT into the gateway and RTMP into ingest, put owner on top. The owner routes are on by default, while every guest route exists only where the operator switched it on. Ordering comes straight from edge order in `architecture.mmd` - the first edge of a repeated pair takes the top slot - so swapping two lines in the source swaps them in the drawing.
- **`*` on a label means "off by default".** It marks the two guest edges, and the legend under the box carries the condition ([`GUEST_ENABLED=1`](../../.env.example)). One character rather than a word because the labels have no room for a clause. This is a different statement from the dotted edges, which mean "not part of the live path at all" (shaka's offline packaging, `telemetry`'s freshness probe).
- **`srt-gateway` is drawn first because it is the recommended contribution path** (stock OBS, same recipe on macOS and Windows) and it is on by default. Binding the port admits nobody on its own, which the drawing cannot show: the guest arbiter refuses every caller unless [`GUEST_ENABLED=1`](../../.env.example), itself off by default.
- **contribution is a 2x2, and the drawing folds one cell away.** Both roles can arrive over both transports: an OWNER pushes SRT to `:8891` (the owner gateway) or RTMP to `:1935/owner` (key-authed), and a GUEST pushes SRT to `:8890` (the guest gateway) or RTMP to `:1935/guest` (keyless, arbiter-gated) - stock OBS over SRT or OBS Music Edition over RTMP, per [`docs/GUEST-ENDPOINT.md`](../GUEST-ENDPOINT.md). Three are drawn explicitly: both SRT ports on the gateway's input side, both applications on its output side. The fourth is OBS Music Edition's single `RTMP :1935` edge, which addresses either application from one port - the role comes from the path typed, not from a second port to draw.
- **the "MPEG-TS, direct" edge is drawn once but is two flags.** Both roles take it by default: the owner under [`SRT_DIRECT`](../../.env.example), a guest under [`GUEST_SRT_DIRECT`](../../.env.example). Both are authenticated the same way once a session takes this edge (`telemetry`'s `/gw/session/claim|beat|done`, peer-address + secret). Setting either flag to 0 returns that role to its `RTMP` edge above.
- **the guest arbitration behind that gateway is invisible here.** Neither outgoing edge shows the session lifecycle `telemetry` runs on every guest: single-slot admission, session cap, cooldown, reconnect grace, IP bans and the dashboard kill. The direct route reimplements none of it: its claim calls `guest_publish`, the same handler nginx-rtmp's [`on_publish`](../../services/rtmp-ingest/guest-rtmp.conf) reaches on the republish. The two differ only in how liveness arrives, as gateway beats or as [`on_update`](../../services/rtmp-ingest/guest-rtmp.conf) pings. See the guest section of the top-level [`README.md`](../../README.md#guest-test-endpoint-the-guest-application).
- **only the `dash-output` volume is drawn**; `telemetry-data` (private dashboard history) and `status-public` (public status JSON) exist but carry no arrows here.
- **the `dash-output` cylinder has exactly one live writer** (`earshot`); `hoast-player` and `telemetry` mount it read-only, so the internet-facing player can serve the live segments but cannot alter them. The SRT contribution paths never put a second writer on the tree.


## Files

| file | role |
|---|---|
| `architecture.mmd` | mermaid source: the nodes, edges and labels |
| `logos/` | the OS marks used in the two sender nodes ([The OS logos](#the-os-logos)) |
| `mermaid-config.json` | theme: colours, font, dagre curves |
| `puppeteer-config.json` | Chromium-based browser path for mermaid-cli + rasteriser |
| `postprocess.py` | rearranges mermaid's raw dagre layout (python stdlib only) |
| `build.sh` | inline the logos -> `mmdc` render -> `postprocess.py` -> `architecture.svg` + `.png` |
| `architecture.svg` / `architecture.png` | generated outputs, committed. The README embeds the PNG ([why](#why-a-png-in-the-readme-not-the-svg)) |

## Regenerate

```sh
./build.sh
```

Needs `node`/`npx`, `python3`, and a Chromium-based browser (path in `puppeteer-config.json`). Edit `architecture.mmd`, rerun, commit the outputs.

## Why a PNG in the README, not the SVG

mermaid renders node and label text inside `<foreignObject>` (HTML). Whether that renders when the SVG is loaded through an `<img>` tag depends on the viewer's browser and installed fonts, which a README cannot assume. The README embeds `architecture.png`; the SVG remains the vector source.

## Why postprocess.py

mermaid's dagre layout stacks everything top-to-bottom. `postprocess.py` keys off mermaid's stable element ids to: run the SRT contribution chain (stock OBS -> `srt-gateway` -> `rtmp-ingest`) as one straight horizontal line on ingest's row, curve the legacy RTMP sender up into ingest from below on the same gutter axis, flank `rtmp-ingest` with `loop-source` on a straight horizontal edge to the right, place the viewer in that same left gutter level with `hoast-player`, shrink the DOCKER COMPOSE box to its content with the title sitting on the top edge in a chip that breaks the border, and round the corners. It relies on the raw SVG having a single coordinate system, which is why the subgraph in `architecture.mmd` carries no `direction` (a nested one would give mermaid two coordinate systems).

Two placements the source cannot express, both consequences of `srt-gateway` being a compose service while its sender is not:

- the gateway has to sit *inside* the box on ingest's row, and dagre leaves nowhere near enough room there, so `postprocess.py` pushes the box's **left wall outward** until the gateway plus its edge label fit. The empty area this opens in the box's lower left is the cost of putting the gateway beside ingest rather than above it.
- the legacy RTMP edge therefore has to reach ingest *past* the gateway. It is drawn as an S-curve (the same style as the dash-output volume edges) that stays flat until it is clear of the gateway and then lifts into ingest's left edge, matching what that path does: it bypasses the gateway entirely.

## The OS logos

`architecture.mmd` carries `{{LOGO_APPLE}}` / `{{LOGO_WINDOWS}}` placeholders rather than the artwork, so the source stays readable; `build.sh` substitutes them before `mmdc` runs, because dagre has to measure the real label width. They are inlined as base64 data URIs so the committed SVG renders standalone.

Both marks come from Wikimedia Commons and are **public domain for copyright purposes** (simple geometry, below the threshold of originality) while remaining **registered trademarks** of their owners:

| file | source |
|---|---|
| `logos/apple-white.svg` | [Apple_logo_white.svg](https://commons.wikimedia.org/wiki/File:Apple_logo_white.svg) |
| `logos/windows-white.svg` | [Windows logo - 2002-2012 (Black)](https://commons.wikimedia.org/wiki/File:Windows_logo_-_2002%E2%80%932012_(Black).svg), recoloured white |

They appear here only to state which platforms each sender runs on - nominative use, indicating compatibility. Nothing in this project is endorsed by, affiliated with, or certified by Apple or Microsoft.

Two implementation notes: the sources need an explicit `viewBox` (without one an `<img>` cannot preserve their aspect and they render as smears), and each logo must be wrapped in a fixed-size `inline-block` span, because mermaid forces `display:flex; flex-direction:column; width:100%` onto images inside labels - unwrapped, every logo becomes a full-width block on its own line. Substituting a raw `<svg>` element instead is not a way around it: mermaid's label parser mangles the surrounding text.
