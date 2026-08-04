#!/usr/bin/env bash
# Regenerate architecture.svg (vector source) and architecture.png (README asset)
# from architecture.mmd. Run from anywhere; it cd's to its own directory.
#
# Needs:
#   - node / npx           (pulls mermaid-cli, pinned for a stable SVG structure)
#   - a Chromium-based browser, path in puppeteer-config.json (mmdc + rasterise)
#   - python3              (postprocess.py; standard library only)
set -euo pipefail

# Chromium path: env override, else first match from common locations, so the
# committed config carries no machine-specific path.
BROWSER_PATH="${BROWSER_PATH:-}"
if [ -z "$BROWSER_PATH" ]; then
  for c in \
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome; do
    [ -x "$c" ] && BROWSER_PATH="$c" && break
  done
fi
[ -n "$BROWSER_PATH" ] || { echo "no Chromium found; set BROWSER_PATH" >&2; exit 1; }
printf '{\n  "executablePath": "%s"\n}\n' "$BROWSER_PATH" > puppeteer-config.json

cd "$(dirname "$0")"

MMD=architecture.mmd
RAW=architecture.raw.svg
SVG=architecture.svg
PNG=architecture.png
SCALE=2                                   # PNG is 2x for crisp README rendering

# 0. inline the OS logos. architecture.mmd carries {{LOGO_*}} placeholders so it
#    stays readable; they are replaced here with base64 data URIs, because the
#    committed SVG has to render standalone (an external file reference would
#    break it outside this directory). Substitution must happen BEFORE mmdc so
#    dagre measures the real label width.
BUILT_MMD=architecture.build.mmd
python3 - "$MMD" "$BUILT_MMD" <<'PY'
import base64, pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
import re
def img(name, h):
    """A logo as a data-URI <img>, wrapped in a fixed-size inline-block span.

    Two mermaid behaviours to work around. It rewrites images inside labels,
    forcing display:flex, flex-direction:column and width:100% onto them -
    which, unwrapped, makes each logo a full-width block on its own line. The
    span pins the box, so that width:100% resolves to the logo's own size and
    the flow stays inline. And a raw <svg> element cannot be used instead:
    mermaid's label parser mangles the surrounding text. Attributes are single
    quoted because the mermaid label itself is double-quoted."""
    p = pathlib.Path(f"logos/{name}")
    vb = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', p.read_text())
    w = round(h * float(vb.group(1)) / float(vb.group(2)), 1)
    b64 = base64.b64encode(p.read_bytes()).decode()
    return (f"<span style='display:inline-block;width:{w}px;height:{h}px;"
            f"vertical-align:-2px'>"
            f"<img src='data:image/svg+xml;base64,{b64}' "
            f"style='width:100%;height:100%'></span>")
t = src.read_text()
t = t.replace("{{LOGO_APPLE}}",   img("apple-white.svg", 14))
t = t.replace("{{LOGO_WINDOWS}}", img("windows-white.svg", 12))
dst.write_text(t)
PY

# 1. mermaid -> raw dagre SVG. Pin the version: postprocess.py keys off this
#    release's element structure. Dark background baked in.
npx --yes @mermaid-js/mermaid-cli@11.16.0 -i "$BUILT_MMD" -o "$RAW" \
    -c mermaid-config.json -p puppeteer-config.json -b "#0a0e1a"

# 2. rearrange the layout (flanking nodes, box, title, viewBox) -> final SVG
python3 postprocess.py "$RAW" "$SVG"

# 3. rasterise to PNG. mermaid puts label text in <foreignObject> (HTML), whose
#    rendering in <img>-loaded SVGs depends on the viewer's browser and fonts
#    (not universal), so the README embeds the PNG; the SVG stays as the
#    scalable source (open it directly to view).
BROWSER=$(python3 -c "import json;print(json.load(open('puppeteer-config.json'))['executablePath'])")
read -r W H < <(python3 - "$SVG" "$SCALE" <<'PY'
import re, sys
svg = open(sys.argv[1]).read(); scale = float(sys.argv[2])
vb = re.search(r'viewBox="[-\d.]+ [-\d.]+ ([-\d.]+) ([-\d.]+)"', svg)
w, h = float(vb.group(1)), float(vb.group(2))
open('.wrap.html', 'w').write(
    '<!doctype html><meta charset=utf8><style>html,body{margin:0;background:#0a0e1a}'
    'svg{max-width:none!important;width:%dpx!important;height:auto!important;display:block}'
    '</style>' % (w * scale) + svg)
print(int(w * scale) + 16, int(h * scale) + 16)
PY
)
"$BROWSER" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size="$W","$H" --screenshot="$PNG" "file://$PWD/.wrap.html" >/dev/null 2>&1

rm -f "$RAW" "$BUILT_MMD" .wrap.html
echo "wrote $SVG and $PNG"
