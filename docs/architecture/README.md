# Architecture diagram

The data-flow diagram embedded in the top-level `README.md`.

## What the diagram simplifies

The diagram draws the data path and compresses everything else. The omissions are deliberate, so the picture stays readable; this is the honest list:

- **`shaka packager (profile: tools)`** means the service sits behind the Compose profile named `tools`: a plain `docker compose up` never starts it, it runs only on demand (`docker compose run --rm shaka <packager args>`) for offline VOD packaging and the A/V-sync test fixtures. The dotted edge into the volume means exactly that: not part of the live path, and it could not be (it cannot ingest a 16-channel live stream).
- **telemetry has one drawn input (the dash-output freshness probe) but several real ones**, all undrawn: container health and the hoast-player access log (viewer counts, countries) via the Docker socket, earshot's `/stat` (is a publisher connected), and the host's temperature, disk and uptime.
- **telemetry is not only a sink.** Undrawn control and output edges: it starts and stops `loop-source` for on-demand idling (a Docker-socket action, which is why the socket mount is read-write), writes the curated public `status.json` into the `status-public` volume that hoast-player serves, and sends Telegram alerts.
- **the viewer's control path is invisible.** A visitor wakes the idle demo through exactly three `/api` routes that hoast-player reverse-proxies to telemetry; the diagram shows only the one HTTP edge. The route list, and why it is exactly three, is in [`docs/ENDPOINTS.md`](../ENDPOINTS.md).
- **`rtmp-ingest`'s "auth" label compresses the mechanism**: the `on_publish` callback goes to an auth endpoint inside the same container, not to another service.
- **only the `dash-output` volume is drawn**; `telemetry-data` (private dashboard history) and `status-public` (public status JSON) exist but carry no arrows here.

- `architecture.png` - what the README embeds (see the foreignObject note below)
- `architecture.svg` - the scalable vector source (open it directly to view)

## Files

| file | role |
|---|---|
| `architecture.mmd` | mermaid source - the only file you edit by hand |
| `mermaid-config.json` | theme: colours, font, dagre curves |
| `puppeteer-config.json` | Chromium-based browser path for mermaid-cli + rasteriser |
| `postprocess.py` | rearranges mermaid's raw dagre layout (python stdlib only) |
| `build.sh` | `mmdc` render -> `postprocess.py` -> `architecture.svg` + `.png` |
| `architecture.svg` / `architecture.png` | generated outputs, committed |

## Regenerate

```sh
./build.sh
```

Needs `node`/`npx`, `python3`, and a Chromium-based browser (path in `puppeteer-config.json`). Edit `architecture.mmd`, rerun, commit the outputs.

## Why a PNG in the README, not the SVG

mermaid renders node and label text inside `<foreignObject>` (HTML). Whether that renders when the SVG is loaded through an `<img>` tag depends on the viewer's browser and installed fonts (current Chrome and Firefox do render it, but support isn't universal and shouldn't be relied on for a README that has to work everywhere). The README embeds `architecture.png`; the SVG remains the vector source.

## Why postprocess.py

mermaid's dagre layout stacks everything top-to-bottom. `postprocess.py` keys off mermaid's stable element ids to: flank rtmp-ingest with OBS (left, external) and loop-source (right) on straight horizontal edges, place the viewer left of the box and centred under OBS, shrink the DOCKER COMPOSE box to its content with the title sitting on the top edge in a chip that breaks the border, and round the corners. It relies on the raw SVG having a single coordinate system, which is why the subgraph in `architecture.mmd` carries no `direction` (a nested one would give mermaid two coordinate systems).
