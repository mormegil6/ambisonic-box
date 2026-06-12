# Phase 5; lip-sync / segment-duration measurement results

**Date:** 2026-06-12 · **Host:** the encode host (WSL2, 32 cores) · **Master:** `content/demo_4k.webm`
(VP9 3840×1920 @ 29.97 fps, 16-ch Opus, 95 min) · **Decision: 2 s segments.**

## Method

1. A 90 s excerpt (calm 0–17 s + high-bitrate section past 17 s) was re-encoded
   four times from the master with identical settings except GOP, per the
   GOP-per-segment rule at 29.97 fps: `-g 15 / 30 / 60 / 120` for 0.5 / 1 / 2 / 4 s
   segments. Audio was **stream-copied**, so audio timestamps are bit-identical
   across variants; video GOP is the only variable.
2. Each variant was packaged from its GOP-matched master with
   `scripts/package-dash-variants.sh <master> <duration>` (Shaka Packager
   v3.7.2, WebM on-demand profile, 16 channels preserved).
3. Static analysis: ffprobe start/first-pts of the packaged `video.webm` /
   `audio.webm` per variant, plus MPD inspection.
4. Dynamic analysis: `scripts/measure-lipsync.js`; headless Chromium, fresh
   page per variant, 20 s sampled playback: clocks, stalls, dropped frames,
   dash.js per-track buffer levels. Three runs.

## Results

### A/V offset (the actual lip-sync question)

| Variant | baked-in A−V start offset | audio PTO (Opus pre-skip) | A/V drift over 20 s |
|---|---|---|---|
| 0.5 s | 0.000 ms | 7 ms (uniform) | none |
| 1 s   | 0.000 ms | 7 ms (uniform) | none |
| 2 s   | 0.000 ms | 7 ms (uniform) | none |
| 4 s   | 0.000 ms | 7 ms (uniform) | none |

**Segment duration does not measurably affect A/V sync** in the combined-MPD
path: audio and video share one media element clock under MSE, Shaka preserved
timestamps exactly (0.000 ms start offset everywhere), and the only nonzero
timing term; `presentationTimeOffset="7000"` (7 ms, timescale 10⁶) on audio:
is the standard Opus codec-delay compensation, identical in all variants.
Per-track buffer fill stayed bounded (audio ≤ ~2 s ahead of video, no growth),
i.e. fill granularity, not drift.

### Side effects of segment duration (what actually differs)

| Variant | 90 s package size | effective video bitrate | stalls (typ.) | mean video buffer |
|---|---|---|---|---|
| 0.5 s | 465 MB | ~43 Mbps | 2–4 | 0.4–0.6 s |
| 1 s   | 125 MB | ~11 Mbps | 1 | 3–5 s |
| 2 s   |  87 MB | ~7.5 Mbps | 1 | 9–12 s |
| 4 s   |  69 MB | ~5.8 Mbps | 1 | 15–20 s |

- **0.5 s is not viable at 4K**: a keyframe every 15 frames forces libvpx far
  past the 4 Mbps target (~6× bitrate at its quality floor), and the playback
  buffer hovers under 1 s; it was the only variant with repeated stalls.
- 1 s / 2 s / 4 s are equivalent on sync; they differ only in bitrate overhead
  and buffer depth. Startup latency was ~0.4–0.6 s for all variants.
- Playback-ratio numbers below 1.0 in some runs are **headless software-decode
  throttling** (57–60 % dropped frames in *every* variant on this box), not a
  variant property.

## Decision: 2 s

- Sync is a wash, so the live-pipeline constraints decide.
- 2 s matches the live stack as deployed (`-g 60 -keyint_min 60
  -seg_duration 2` at 29.97/30 fps) and the ffmpeg DASH muxer's verified
  behaviour (uniform 2.002 s segments).
- With `liveDelay = 30 s` the player sits 15 segments behind the edge; ample
  cushion; 1 s segments would double manifest/request churn for no sync gain,
  4 s would halve the timeShiftBuffer granularity and slow startup-to-seek
  precision without benefit.
- 0.5 s ruled out (bitrate floor + buffer starvation, above).

## Caveats / repro

- Shaka's WebM parser rejects ffmpeg multi-track muxing ("block with a
  timecode before the previous block"); `package-dash-variants.sh` now splits
  the master into single-track inputs automatically.
- Human verification (by ear/eye, clap transient) on a GPU browser is still
  worthwhile: serve this folder (`python3 -m http.server 9000`) and use the
  four tabs + snap log. The headless harness cannot judge perceived sync,
  only clocks and packaging.
- Per-GOP excerpt masters kept in `content/lipsync_g{15,30,60,120}.webm`
  (gitignored) for re-runs.
