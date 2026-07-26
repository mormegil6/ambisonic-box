# Architecture diagram

The data-flow diagram embedded in the top-level `README.md`.

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
