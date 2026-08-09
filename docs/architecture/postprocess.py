#!/usr/bin/env python3
# Post-process the raw mermaid (dagre) SVG of architecture.mmd into the final
# architecture diagram. Keying off mermaid's stable element ids, it:
#   - lays the SRT chain (stock OBS -> srt-gateway -> rtmp-ingest) out as one
#     horizontal run, curves the legacy RTMP sender up into ingest beneath it,
#     flanks ingest with loop-source, and puts the viewer in the left gutter;
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

# srt-gateway sits INSIDE the box on rtmp-ingest's row, immediately left of it,
# but dagre leaves nowhere near enough room there. Push the box's left wall out
# far enough to seat the gateway plus a gap wide enough for its edge label. The
# space this opens is the box's lower-left, which is empty in this layout.
GW_INSET = 18.0                  # gateway's inset from the wall (mirrors loop-source)
GW_GAP   = 175.0                 # gateway -> ingest run; sized for the old
                                  # mechanism-named labels ("RTMP, arbiter-gated"
                                  # at 146px) and left wide since role-named ones
                                  # ("RTMP, guest" / "RTMP, owner", ~95px) fit
                                  # with room to spare rather than exactly
_ix, _iy = node_pos('INGEST')
box_left = min(box_left,
               (_ix - node_halfwidth('INGEST')) - GW_INSET
               - 2 * node_halfwidth('GATEWAY') - GW_GAP)

# The same problem on the right wall, and it appeared when the owner's direct
# edge was added: giving earshot a second parent makes dagre re-rank the top
# row, ingest grows rightward, and the gap it leaves for loop-source is no
# longer wide enough for that edge's label ("RTMP, owner (internal)", ~165px)
# to avoid clipping. Push the right wall out so the run always fits, the
# mirror of the GW_INSET/GW_GAP treatment above.
LOOP_INSET = 18.0
LOOP_GAP   = 150.0               # ingest -> loop-source run; fits the label
box_right = max(box_right,
                (_ix + node_halfwidth('INGEST')) + LOOP_GAP
                + 2 * node_halfwidth('LOOP') + LOOP_INSET)

# === lower half: restore the two-column grid dagre gave up when the gateway
#     was added. hoast-player sits under earshot, telemetry under shaka, and
#     the dash-output volume is centred between those two columns, which is
#     how this half read before the SRT route existed. Moving the volume means
#     redrawing all four of its edges, since dagre's originals point at the old
#     coordinates; see _edge_curve for how their shape is reproduced. ===
def _move(nid, nx, ny):
    global s
    s = re.sub(r'(id="my-svg-flowchart-' + nid + r'-\d+"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\))',
               lambda m: f"{m.group(1)}{nx}, {ny}{m.group(2)}", s, count=1)

def _cyl_half(nid):
    """The volume is a cylinder <path>, not a <rect>: its own offset transform
    carries (-halfwidth, -halfheight)."""
    blk = s[s.find('id="my-svg-flowchart-' + nid + '-'):][:800]
    m = re.search(r'outer-path"[^>]*?transform="translate\((-?[\d.]+),\s*(-?[\d.]+)\)"', blk)
    return abs(float(m.group(1))), abs(float(m.group(2)))

ex_, ey_ = node_pos('EARSHOT'); ehh = node_halfheight('EARSHOT')
sx_, sy_ = node_pos('SHAKA');   shh = node_halfheight('SHAKA')
_,   vy_ = node_pos('VOL');     vhw_, vhh_ = _cyl_half('VOL')
_,   ppy = node_pos('PLAYER');  phh = node_halfheight('PLAYER')
_,   tty = node_pos('TELEM');   thh = node_halfheight('TELEM')

# Slide the whole lower X-cluster right so earshot sits directly under
# rtmp-ingest and the relay edge (RTMP relay, authenticated) is a straight
# vertical instead of a diagonal. earshot, shaka, the volume, hoast-player and
# telemetry all shift by the same delta, so the X keeps its shape; the edges
# below already derive from ex_/sx_, so only the two edges INTO earshot need
# redrawing (the relay just below, the owner-direct edge at its own section).
X_DELTA = _ix - ex_
_move('EARSHOT', _ix, ey_)
_move('SHAKA', sx_ + X_DELTA, sy_)
ex_ = _ix
sx_ = sx_ + X_DELTA

PLX = ex_                      # hoast-player under earshot
TLX = sx_                      # telemetry under shaka
VLX = (ex_ + sx_) / 2.0        # volume centred between the columns
_move('PLAYER', PLX, ppy)
_move('TELEM',  TLX, tty)
_move('VOL',    VLX, vy_)

# telemetry's own label ("telemetry dashboard :8090 + alerts") is wider than
# shaka's, so it can reach past the wall the LOOP_GAP formula sized further
# down (that formula only knows about loop-source, not this column). Widen to
# clear whichever of shaka/telemetry actually reaches furthest right, same
# 18px inset convention as loop-source gets below.
RCOL_INSET = 18.0
box_right = max(box_right,
                 TLX + node_halfwidth('TELEM') + RCOL_INSET,
                 sx_ + node_halfwidth('SHAKA') + RCOL_INSET)

def _edge_curve(eid, p0, p1, out_dir, in_dir):
    """One cubic in dagre's own idiom for these edges: it leaves a box face
    along the perpendicular ('v') and meets the cylinder at an angle ('d'),
    or the reverse. Forcing both tangents vertical gives a flat-then-steep
    step; keeping them different is what makes the original curves read as
    curves. Returns the t=0.5 point, for label placement."""
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    c1 = (x0, y0 + dy * 0.55) if out_dir == 'v' else (x0 + dx * 0.30, y0 + dy * 0.30)
    c2 = (x1, y1 - dy * 0.55) if in_dir == 'v' else (x1 - dx * 0.30, y1 - dy * 0.30)
    d = f"M{x0},{y0}C{c1[0]},{c1[1]} {c2[0]},{c2[1]} {x1},{y1}"
    globals()['s'] = re.sub(r'(<path d=")[^"]*(" id="my-svg-' + eid + r'")',
                            lambda m: f"{m.group(1)}{d}{m.group(2)}", globals()['s'], count=1)
    return ((x0 + 3 * c1[0] + 3 * c2[0] + x1) / 8.0,
            (y0 + 3 * c1[1] + 3 * c2[1] + y1) / 8.0)

VIN = 46.0                     # how far in from the volume's centre edges land
mid = _edge_curve('L_EARSHOT_VOL_0', (ex_, ey_ + ehh), (VLX - VIN, vy_ - vhh_ + 4), 'v', 'd')
s = re.sub(r'(<g class="edgeLabel"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\)"[^>]*>\s*<g class="label"[^>]*data-id="L_EARSHOT_VOL_0")',
           lambda m: f"{m.group(1)}{mid[0] - 78.0}, {mid[1] - 16.0}{m.group(2)}", s, count=1)

mid = _edge_curve('L_SHAKA_VOL_0', (sx_, sy_ + shh), (VLX + VIN, vy_ - vhh_ + 4), 'v', 'd')
s = re.sub(r'(<g class="edgeLabel"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\)"[^>]*>\s*<g class="label"[^>]*data-id="L_SHAKA_VOL_0")',
           lambda m: f"{m.group(1)}{mid[0] + 30.0}, {mid[1] - 16.0}{m.group(2)}", s, count=1)

_edge_curve('L_VOL_PLAYER_0', (VLX - VIN, vy_ + vhh_ - 4), (PLX, ppy - phh - 6), 'd', 'v')

mid = _edge_curve('L_VOL_TELEM_0', (VLX + VIN, vy_ + vhh_ - 4), (TLX, tty - thh - 6), 'd', 'v')
s = re.sub(r'(<g class="edgeLabel"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\)"[^>]*>\s*<g class="label"[^>]*data-id="L_VOL_TELEM_0")',
           lambda m: f"{m.group(1)}{mid[0] + 22.0}, {mid[1] - 14.0}{m.group(2)}", s, count=1)

px, py = node_pos('PLAYER')
phw = node_halfwidth('PLAYER')
vhw = node_halfwidth('VIEWER')

# --- placement: viewer in the left gutter, level with hoast-player ---
# OBS sits left of the box (its left edge set by GAP); the viewer is centred on
# the SAME vertical axis as OBS (OBS is wider, so the viewer is inset & centred,
# not left-aligned). anchor_left is that shared left reference == OBS's left edge.
GAP = float(sys.argv[3]) if len(sys.argv) > 3 else 162.0   # gutter (overridable)
ohw = node_halfwidth('OBS')

# The gutter has to be wide enough for the PORT LABELS that sit in it, and it
# is MEASURED rather than guessed: a hand-tuned constant here has already been
# outgrown twice (once when the route labels got longer, once when the single
# "SRT :8890" became the :8891/:8890 pair), and the failure is silent in the
# build - the label simply renders underneath the gateway node with its tail
# cut off. The labels are centred between the external senders' right edge and
# the gateway's left face, so the gutter must be at least as wide as the widest
# of them. Solving the placement chain below for that condition:
#     gutter = GW_INSET + GAP - 2 * (ohw - vhw)
GUTTER_PAD = 16.0
def edge_label_width(eid):
    """Rendered width of an edge label, read from the raw SVG (the second
    occurrence of the id is the label group; the first is the path)."""
    hits = [m.start() for m in re.finditer('data-id="' + eid + '"', s)]
    if len(hits) < 2:
        return 0.0
    m = re.search(r'<foreignObject width="([-\d.]+)"', s[hits[1]:hits[1] + 400])
    return float(m.group(1)) if m else 0.0

_port_w = max(edge_label_width(e) for e in
              ('L_SRTOBS_GATEWAY_0', 'L_SRTOBS_GATEWAY_2', 'L_OBS_INGEST_0'))
GAP = max(GAP, _port_w + GUTTER_PAD - GW_INSET + 2 * (ohw - vhw))

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

# === input side: two contribution routes into rtmp-ingest. ===
#   SRT (recommended):  stock OBS --SRT--> srt-gateway --RTMP /guest--> ingest
#   RTMP (legacy):      OBS Music Edition --RTMP :1935--------------> ingest
# The SRT chain runs as one straight horizontal line on ingest's own row, with
# srt-gateway inside the box (it is a compose service) and its sender outside
# in the left gutter. OBS Music Edition sits below on the same gutter axis and
# curves up into ingest, so the legacy path visibly joins the main run.
ix, iy = node_pos('INGEST')
ihw, ihh = node_halfwidth('INGEST'), node_halfheight('INGEST')
ghw, ghh = node_halfwidth('GATEWAY'), node_halfheight('GATEWAY')
shw = node_halfwidth('SRTOBS')

ROW_OFF = 190.0                  # OBS Music Edition's row, below ingest's
GY = iy                          # srt-gateway + its sender share ingest's row
OY = iy + ROW_OFF

# gateway just inside the box's left wall (the wall was pushed out above to
# make room), mirroring loop-source's inset on the right
GX = box_left + GW_INSET + ghw
# both external senders share the viewer's centre axis (VX)
SX, OX = VX, VX

for nid, nx, ny in (('GATEWAY', GX, GY), ('SRTOBS', SX, GY), ('OBS', OX, OY)):
    s = re.sub(r'(id="my-svg-flowchart-' + nid + r'-\d+"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\))',
               lambda m, x=nx, y=ny: f"{m.group(1)}{x}, {y}{m.group(2)}", s, count=1)

def set_edge(eid, d):
    global s
    s = re.sub(r'(<path d=")[^"]*(" id="my-svg-' + eid + r'")',
               lambda m: f"{m.group(1)}{d}{m.group(2)}", s, count=1)

def set_label(eid, lx, ly):
    global s
    s = re.sub(r'(<g class="edgeLabel"[^>]*transform="translate\()[-\d.]+,\s*[-\d.]+(\)"[^>]*>\s*<g class="label"[^>]*data-id="' + eid + r'")',
               lambda m: f"{m.group(1)}{lx}, {ly}{m.group(2)}", s, count=1)

# 1) stock OBS -> srt-gateway: TWO parallel lines, mirroring the pair into
#    ingest below. One stock-OBS sender reaches either gateway instance, and
#    the port it dials IS the difference between the two routes - :8891 is the
#    owner instance, :8890 the guest one - so a single "SRT" arrow hid the one
#    thing a sender has to get right. The box already stands for both
#    instances (see this directory's README); now its input side says so.
# ARROW_SEP is the ONE spacing both parallel pairs use, so the SRT pair and the
# RTMP pair read as the same gesture rather than two different ones. It is the
# gap BETWEEN the two lines; the SRT pair straddles the gateway row, so each of
# its lines sits half that from the centre.
ARROW_SEP = 30.0
sr_sx, sr_ex = SX + shw, GX - ghw - 6.0
SRT_OWNER_Y, SRT_GUEST_Y = GY - ARROW_SEP / 2.0, GY + ARROW_SEP / 2.0
set_edge('L_SRTOBS_GATEWAY_0', f"M{sr_sx},{SRT_OWNER_Y}L{sr_ex},{SRT_OWNER_Y}")
set_edge('L_SRTOBS_GATEWAY_2', f"M{sr_sx},{SRT_GUEST_Y}L{sr_ex},{SRT_GUEST_Y}")
# All three port labels share one x so they line up vertically. It is the
# midpoint to the GATEWAY, not to the box wall, so the labels deliberately
# overlap the wall and break it the way the DOCKER COMPOSE title chip does -
# that overlap is the intended look, not a collision to correct. Measured from
# whichever external box reaches furthest right, so the wider label cannot
# ride up onto it.
PORT_LX = (max(SX + shw, OX + ohw) + (GX - ghw)) / 2.0
set_label('L_SRTOBS_GATEWAY_0', PORT_LX, SRT_OWNER_Y - 15.0)
set_label('L_SRTOBS_GATEWAY_2', PORT_LX, SRT_GUEST_Y + 15.0)

# 2) srt-gateway -> ingest: TWO parallel lines, not one. The gateway can land
#    a stream in either of ingest's applications - guests through the one that
#    is admission-controlled, owners (and a gateway with no session-protocol
#    secret) through the one that is only key-checked - and drawing them as
#    two lines between the same two boxes is the point: same wire, two
#    different security models, exactly as real as each other. mermaid gives
#    the second edge of a repeated pair the id _2, not _1 (its own global edge
#    counter, confirmed empirically for both pairs, not a typo here).
# Three arrows land on ingest's left face in total (this pair, plus OBS Music
# Edition's curve below) and are spaced evenly by ARROW_SEP. OWNER IS ON TOP,
# here and on the SRT pair above: it is the route that is on by default, while
# guest exists only where the operator turned it on. Order therefore comes
# from the source file - the first edge of each pair takes the top slot - so
# swapping the two lines in architecture.mmd swaps them in the drawing.
g_sx, g_ex = GX + ghw, ix - ihw - 6.0
OWNER_Y, GUEST_Y = iy - ARROW_SEP, iy
set_edge('L_GATEWAY_INGEST_0', f"M{g_sx},{OWNER_Y}L{g_ex},{OWNER_Y}")
set_edge('L_GATEWAY_INGEST_2', f"M{g_sx},{GUEST_Y}L{g_ex},{GUEST_Y}")
# Labels sit close to their own line, not the ±22 used elsewhere: the lower
# one has only ~31px before the OBS Music Edition curve passes beneath it
# (that curve's closest approach is y=iy+31, at the label's own right edge),
# so anything looser would ride onto the curve.
ROUTE_LABEL_OFF = 15.0
set_label('L_GATEWAY_INGEST_0', (g_sx + (ix - ihw)) / 2.0, OWNER_Y - ROUTE_LABEL_OFF)
set_label('L_GATEWAY_INGEST_2', (g_sx + (ix - ihw)) / 2.0, GUEST_Y + ROUTE_LABEL_OFF)

# 2b) srt-gateway -> earshot, the OWNER route: leaves the gateway's underside
#     and lands on earshot's left face, deliberately below and clear of the
#     guest run above it. Dagre draws this edge for its own pre-move layout,
#     so like every other rerouted edge it has to be redrawn here or it points
#     at coordinates nothing occupies any more.
ehw_ = node_halfwidth('EARSHOT')
d_sx, d_sy = GX + ghw * 0.35, GY + ghh
d_ex, d_ey = ex_ - ehw_ - 6.0, ey_
set_edge('L_GATEWAY_EARSHOT_0',
         f"M{d_sx},{d_sy}C{d_sx},{d_sy + (d_ey - d_sy) * 0.62} "
         f"{d_sx + (d_ex - d_sx) * 0.55},{d_ey} {d_ex},{d_ey}")
# Label under the gateway rather than at the curve's midpoint: the midpoint is
# where this edge passes closest to the guest run's own label, and two labels
# that near each other read as one.
set_label('L_GATEWAY_EARSHOT_0', d_sx - 30.0, d_sy + 26.0)

# With earshot now under ingest, redraw the relay edge as a straight vertical
# (dagre drew it diagonal for the pre-shift earshot position). Its label rides
# on the line, its dark bg box occluding it the way every other edge label does.
set_edge('L_INGEST_EARSHOT_0', f"M{ix},{iy + ihh}L{ex_},{ey_ - ehh - 6}")
set_label('L_INGEST_EARSHOT_0', ix, (iy + ihh + ey_ - ehh) / 2.0 - 8.0)

# 3) OBS Music Edition -> ingest: a symmetric S-curve in the style of the
#    dash-output volume edges - horizontal at both ends, sweeping up into
#    ingest's LEFT edge below the gateway's arrow. Landing on the left edge
#    rather than underneath keeps it clear of the earshot relay arrow and its
#    label, which both occupy ingest's underside.
o_sx, o_sy = OX + ohw, OY
o_ex, o_ey = ix - ihw - 6.0, iy + ARROW_SEP
# Both control points share one x, placed late (0.78) so the curve stays flat
# beneath srt-gateway and only lifts once past it: the legacy path visibly
# runs UNDER the gateway to reach ingest directly, without grazing its corner.
o_mid = o_sx + (o_ex - o_sx) * 0.78
set_edge('L_OBS_INGEST_0', f"M{o_sx},{o_sy}C{o_mid},{o_sy} {o_mid},{o_ey} {o_ex},{o_ey}")
# share the SRT label's x so the two port labels line up vertically; the
# curve is still flat here, so the label sits directly over its own line
set_label('L_OBS_INGEST_0', PORT_LX, o_sy - 24.0)

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
# gateway and ingest share a row but the gateway is the taller box, so the top
# edge follows whichever actually reaches highest
NEW_TOP = min(iy - ihh, GY - ghh) - 46.0  # room for the title on the edge
tm = re.search(r'<g class="cluster-label ?" transform="translate\(([-\d.]+),\s*[-\d.]+\)"><foreignObject width="([-\d.]+)"', s)
tx, tw = float(tm.group(1)), float(tm.group(2))
# dagre centred the title on the box it laid out; the left wall has since been
# pushed outward to seat the gateway, so re-centre it on the box as drawn
tx = (box_left + box_right) / 2.0 - tw / 2.0
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
s = re.sub(r'(<g class="cluster-label ?" transform="translate\()[-\d.]+,\s*[-\d.]+(\)")',
           lambda m: f"{m.group(1)}{tx}, {NEW_TOP - 12}{m.group(2)}", s, count=1)

# 3b) legend for the `*` on the two guest labels. The marker is one character
#     because the labels have no room for a clause, so the clause lives here.
#     Written as plain SVG <text> rather than a mermaid node: dagre would lay
#     a node out inside the graph, and this belongs beside the drawing, not in
#     it. Sits under the box's bottom-left corner; the viewBox grows to fit.
#     Right-aligned under the box's right wall: the left end of that strip sits
#     directly below the viewer/OBS gutter, where a reader's eye is still
#     tracking the data path, whereas the right end is past the last node and
#     genuinely empty.
LEGEND_TEXT = "* off by default; set GUEST_ENABLED=1"
LEGEND_GAP  = 26.0
legend_y = box_bottom + LEGEND_GAP
s = s.replace('</svg>',
              f'<text x="{box_right:.2f}" y="{legend_y:.2f}" text-anchor="end" '
              f'style="font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,'
              f'Helvetica,Arial,sans-serif;font-size:15px;fill:#8b9bb4">{LEGEND_TEXT}</text></svg>', 1)

# 4) trim the viewBox: widen left for the viewer, trim the now-empty top down to
#    the title, and trim the bottom (the raw layout reserved space below the box).
#    Do NOT touch any styled <rect>.
vb = re.search(r'viewBox="([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)"', s)
x0, y0, w, h = map(float, vb.groups())
leftmost = min(VX - vhw, OX - ohw, SX - shw)   # widest external box sets the left extent
new_x0 = min(x0, leftmost - 20.0)
new_y0 = NEW_TOP - 34.0                   # just above the title on the edge
# the legend, not the box, is now the lowest element
new_h = legend_y - new_y0 + 12.0
# Trim the right to the real content instead of inheriting mermaid's width:
# every node that used to sit out there has been repositioned, so the raw
# layout's right extent is stale padding. The box wall is now the rightmost
# thing in the drawing (loop-source is tucked inside it).
new_w = (box_right + 22.0) - new_x0
s = s.replace(vb.group(0), f'viewBox="{new_x0} {new_y0} {new_w} {new_h}"', 1)
s = re.sub(r'max-width:\s*[-\d.]+px', f'max-width: {new_w:.2f}px', s, count=1)

open(out, 'w').write(s)
print(f"box_left={box_left:.0f}  player=({px:.0f},{py:.0f})  viewer=({VX:.0f},{VY:.0f})  "
      f"curve {sx:.0f},{sy:.0f} -> {ex:.0f},{ey:.0f}  viewBox=({new_x0:.0f} {y0:.0f} {new_w:.0f} {new_h:.0f})")
