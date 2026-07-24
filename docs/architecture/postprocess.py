#!/usr/bin/env python3
# Post-process the raw mermaid (dagre) SVG of architecture.mmd into the final
# architecture diagram. Keying off mermaid's stable element ids, it:
#   - moves OBS (external) and loop-source (in-box) to flank rtmp-ingest with
#     straight horizontal edges, and the viewer browser to the left of the box,
#     centred under OBS and level with hoast-player;
#   - lifts each rerouted edge's label above its line and re-centres it;
#   - shrinks the DOCKER COMPOSE box to its content, puts the title on the top
#     edge in a chip that breaks the border, and rounds the corners;
#   - widens/trims the viewBox to the final content.
# Needs a flattened source (no `direction TB` in the subgraph) so the SVG has a
# single coordinate system. Driven by build.sh; not meant to be run by hand.
#   Usage: postprocess.py <raw.svg> <out.svg> [gutter]
import re, sys

src = sys.argv[1] if len(sys.argv) > 1 else 'architecture.raw.svg'
out = sys.argv[2] if len(sys.argv) > 2 else 'architecture.svg'
s = open(src).read()

def node_pos(nid):
    m = re.search(r'id="my-svg-flowchart-' + nid + r'-\d+"[^>]*transform="translate\(([-\d.]+),\s*([-\d.]+)\)"', s)
    return float(m.group(1)), float(m.group(2))

def node_halfwidth(nid):
    blk = s[s.find('id="my-svg-flowchart-' + nid + '-'):][:1200]
    return float(re.search(r'<rect[^>]*width="([-\d.]+)"', blk).group(1)) / 2.0

def node_halfheight(nid):
    blk = s[s.find('id="my-svg-flowchart-' + nid + '-'):][:1200]
    return float(re.search(r'<rect[^>]*height="([-\d.]+)"', blk).group(1)) / 2.0

# COMPOSE box (the cluster rect carries stroke-width:3px from `style COMPOSE`)
bm = re.search(r'<rect style="stroke-width:3px[^"]*"\s*x="([-\d.]+)"\s*y="([-\d.]+)"\s*width="([-\d.]+)"\s*height="([-\d.]+)"', s)
box_left = float(bm.group(1))
box_right = float(bm.group(1)) + float(bm.group(3))
box_bottom = float(bm.group(2)) + float(bm.group(4))

px, py = node_pos('PLAYER')
phw = node_halfwidth('PLAYER')
vhw = node_halfwidth('VIEWER')

# --- placement: viewer in the left gutter, level with hoast-player ---
# OBS sits left of the box (its left edge set by GAP); the viewer is centred on
# the SAME vertical axis as OBS (OBS is wider, so the viewer is inset & centred,
# not left-aligned). anchor_left is that shared left reference == OBS's left edge.
GAP = float(sys.argv[3]) if len(sys.argv) > 3 else 152.0   # gutter (overridable)
ohw = node_halfwidth('OBS')
anchor_left = box_left - GAP - 2 * vhw
VX = anchor_left + ohw           # viewer centre == OBS centre
VY = py                          # same height as hoast-player

# 1) move VIEWER node
s = re.sub(r'(id="my-svg-flowchart-VIEWER-\d+"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\))',
           lambda m: f"{m.group(1)}{VX}, {VY}{m.group(2)}", s, count=1)

# 2) reroute PLAYER->VIEWER as a straight horizontal line. End it a few px PAST
#    the viewer's right edge: mermaid's arrowhead marker is centred on the path
#    endpoint (refX=5), so ending exactly on the border bisects the arrowhead --
#    half ends up inside the box, under its fill. That was the "box overlaps the
#    arrow". Padding pushes the whole arrowhead into the gutter, tip at the border.
viewer_right = VX + vhw
sx, sy = px - phw, py            # start: player left edge (inside the box)
ex, ey = viewer_right + 6.0, VY  # end: arrowhead sits just outside the viewer
newd = f"M{sx},{sy}L{ex},{ey}"
s = re.sub(r'(<path d=")[^"]*(" id="my-svg-L_PLAYER_VIEWER_0")',
           lambda m: f"{m.group(1)}{newd}{m.group(2)}", s, count=1)

# 3) place the "HTTP :8080" label ABOVE the line, centred over the full visible
#    connector (viewer's right edge <-> player's left edge), nudged 13.5 right.
#    The line stays unbroken beneath it.
lx = (viewer_right + sx) / 2.0 + 13.5
ly = sy - 24.0
s = re.sub(r'(<g class="edgeLabel"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\)"[^>]*>\s*<g class="label"[^>]*data-id="L_PLAYER_VIEWER_0")',
           lambda m: f"{m.group(1)}{lx}, {ly}{m.group(2)}", s, count=1)

# === OBS: mirror the viewer on the input side. Drop OBS from its high position
#     to rtmp-ingest's height (keep its x) so the RTMP :1935 edge runs straight
#     left->right into ingest instead of diagonally down. ===
ix, iy = node_pos('INGEST')
ihw = node_halfwidth('INGEST')
ox, _oy = node_pos('OBS')
# drop OBS level with ingest; OBS and the viewer share the same centre axis
OX, OY = VX, iy
s = re.sub(r'(id="my-svg-flowchart-OBS-\d+"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\))',
           lambda m: f"{m.group(1)}{OX}, {OY}{m.group(2)}", s, count=1)
# reroute OBS->INGEST straight; end just short of ingest's left edge so the
# arrowhead clears the node (same marker-refX trick as the viewer edge)
o_sx = OX + ohw                  # OBS right edge
o_ex = ix - ihw - 6.0            # just outside ingest's left edge
s = re.sub(r'(<path d=")[^"]*(" id="my-svg-L_OBS_INGEST_0")',
           lambda m: f'{m.group(1)}M{o_sx},{iy}L{o_ex},{iy}{m.group(2)}', s, count=1)
# RTMP :1935 label above the line, centred over the connector (OBS edge <-> ingest edge)
o_lx, o_ly = (o_sx + (ix - ihw)) / 2.0, iy - 22.0
s = re.sub(r'(<g class="edgeLabel"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\)"[^>]*>\s*<g class="label"[^>]*data-id="L_OBS_INGEST_0")',
           lambda m: f"{m.group(1)}{o_lx}, {o_ly}{m.group(2)}", s, count=1)

# === loop-source: mirror OBS on the right. Move it level with ingest, to its
#     right, so RTMP (internal) runs straight right->left into ingest. It lives
#     INSIDE the box, so keep its right edge just inside the box wall. ===
lphw = node_halfwidth('LOOP')
LPX, LPY = box_right - 18.0 - lphw, iy    # right edge ~18px inside the wall
s = re.sub(r'(id="my-svg-flowchart-LOOP-\d+"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\))',
           lambda m: f"{m.group(1)}{LPX}, {LPY}{m.group(2)}", s, count=1)
# reroute LOOP->INGEST straight; arrow points left into ingest, end just outside
# ingest's right edge so the arrowhead clears the node
l_sx = LPX - lphw                # LOOP left edge
l_ex = ix + ihw + 6.0            # just outside ingest's right edge
s = re.sub(r'(<path d=")[^"]*(" id="my-svg-L_LOOP_INGEST_0")',
           lambda m: f'{m.group(1)}M{l_sx},{iy}L{l_ex},{iy}{m.group(2)}', s, count=1)
# RTMP (internal) label above the line, centred over the connector
l_lx, l_ly = ((ix + ihw) + l_sx) / 2.0, iy - 22.0
s = re.sub(r'(<g class="edgeLabel"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\)"[^>]*>\s*<g class="label"[^>]*data-id="L_LOOP_INGEST_0")',
           lambda m: f"{m.group(1)}{l_lx}, {l_ly}{m.group(2)}", s, count=1)

# === shrink the COMPOSE box: pull its top edge down to just above the ingest
#     row (both feeders now sit at ingest's level, leaving the top empty), put
#     the DOCKER COMPOSE title ON the edge with a break in the border, and round
#     the corners. ===
ingest_top = iy - node_halfheight('INGEST')
NEW_TOP = ingest_top - 46.0               # room for the title on the edge
tm = re.search(r'<g class="cluster-label" transform="translate\(([-\d.]+),\s*[-\d.]+\)"><foreignObject width="([-\d.]+)"', s)
tx, tw = float(tm.group(1)), float(tm.group(2))
# 1. resize + round the cluster rect
old_rect = re.search(r'<rect style="stroke-width:3px[^"]*"\s*x="[-\d.]+"\s*y="[-\d.]+"\s*width="[-\d.]+"\s*height="[-\d.]+"\s*/>', s).group(0)
new_rect = (f'<rect style="stroke-width:3px !important" x="{box_left}" y="{NEW_TOP}" '
            f'width="{box_right - box_left}" height="{box_bottom - NEW_TOP}" rx="16" ry="16"/>')
# 2. mask the top border where the title sits (page-bg colour) -> the "break".
#    Rendered after the border rect, before the title, so it cuts the line but
#    the title text stays on top.
# the DOCKER COMPOSE title in a rounded chip that interrupts the top border
# (box fill + the cluster's purple border). inline style so it renders exactly
# this way regardless of the `.cluster rect` CSS rule.
mask = (f'<rect x="{tx - 12:.2f}" y="{NEW_TOP - 15:.2f}" width="{tw + 24:.2f}" height="30" rx="7" '
        f'style="fill:#0f1830;stroke:#7b6cf0;stroke-width:1.5"/>')
s = s.replace(old_rect, new_rect + mask, 1)
# 3. move the title so its vertical centre sits on the new top edge
s = re.sub(r'(<g class="cluster-label" transform="translate\()[-\d.]+,\s*[-\d.]+(\)")',
           lambda m: f"{m.group(1)}{tx}, {NEW_TOP - 12}{m.group(2)}", s, count=1)

# 4) trim the viewBox: widen left for the viewer, trim the now-empty top down to
#    the title, and trim the bottom (the raw layout reserved space below the box).
#    Do NOT touch any styled <rect>.
vb = re.search(r'viewBox="([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)"', s)
x0, y0, w, h = map(float, vb.groups())
leftmost = min(VX - vhw, OX - ohw)   # OBS is wider than the viewer -> left extent
new_x0 = min(x0, leftmost - 20.0)
new_w = w + (x0 - new_x0)
new_y0 = NEW_TOP - 34.0                   # just above the title on the edge
new_h = box_bottom - new_y0 + 22.0        # box is the lowest element
s = s.replace(vb.group(0), f'viewBox="{new_x0} {new_y0} {new_w} {new_h}"', 1)
s = re.sub(r'max-width:\s*[-\d.]+px', f'max-width: {new_w:.2f}px', s, count=1)

open(out, 'w').write(s)
print(f"box_left={box_left:.0f}  player=({px:.0f},{py:.0f})  viewer=({VX:.0f},{VY:.0f})  "
      f"curve {sx:.0f},{sy:.0f} -> {ex:.0f},{ey:.0f}  viewBox=({new_x0:.0f} {y0:.0f} {new_w:.0f} {new_h:.0f})")
