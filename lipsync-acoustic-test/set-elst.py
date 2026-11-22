#!/usr/bin/env python3
"""Replace the video trak's edit list in an fMP4 init segment. usage: set-elst.py src dst "dur:media_time,dur:media_time"  (dur in movie timescale units, media_time in track timescale units, -1 = empty edit)"""
import struct, sys
def boxes(d, s, e):
    while s < e:
        size, typ = struct.unpack('>I4s', d[s:s+8]); yield typ, s, size; s += size
def child(d, parent, typ):
    for t, off, size in boxes(d, parent[0]+8, parent[0]+parent[1]):
        if t == typ: return (off, size)
src, dst, spec = sys.argv[1:4]
ents = [tuple(int(x) for x in e.split(':')) for e in spec.split(',')]
d = bytearray(open(src, 'rb').read())
moov = next((o, sz) for t, o, sz in boxes(d, 0, len(d)) if t == b'moov')
vtrak = None
for t, off, size in boxes(d, moov[0]+8, moov[0]+moov[1]):
    if t == b'trak':
        hd = child(d, child(d, (off, size), b'mdia'), b'hdlr')
        if d[hd[0]+16:hd[0]+20] == b'vide': vtrak = (off, size)
edts = child(d, vtrak, b'edts')
body = struct.pack('>BBBBI', 0, 0, 0, 0, len(ents)) + b''.join(struct.pack('>IiHH', dur, mt, 1, 0) for dur, mt in ents)
elst = struct.pack('>I4s', 8 + len(body), b'elst') + body
new = struct.pack('>I4s', 8 + len(elst), b'edts') + elst
delta = len(new) - edts[1]
d[edts[0]:edts[0]+edts[1]] = new
for off in (vtrak[0], moov[0]):
    d[off:off+4] = struct.pack('>I', struct.unpack('>I', d[off:off+4])[0] + delta)
open(dst, 'wb').write(d); print(dst, 'elst entries:', ents)
