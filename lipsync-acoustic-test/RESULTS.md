# Audible A/V offset of the player, measured at the system output

**Date:** 2026-11-27 (the numbers on this page), after a first round on 2026-11-21 and 22 whose test clips were flawed · **Host:** a Mac with the sound output set to BlackHole 2ch · **Player:** the production on-demand page, `stream.bmroz.eu/vod/?clip=colortones`, with the clip replaced by the test clips below · **Result:** v1.3.13 played the sound about 60 ms late against video with an ordinary trimming edit list, and about 500 ms late against a 0.5 s trim, in the browsers that skip an empty edit. v1.3.14 is within about 20 ms of sync on every clip in Chrome 157, Chrome Canary 160 and Firefox. Safari 27.2 reads 20 to 50 ms early on every clip, in both builds.

## The question

The player decodes the 16-channel Opus audio itself and schedules it on the page's audio clock, because no browser decodes it natively everywhere. The picture comes from the browser's own video pipeline. They line up only if the page shifts the audio by the offset the browser does not apply to the picture. Browsers differ here: some apply the video track's edit list (`elst`, the MP4 box that carries the track's start offset and trim), others skip part of it. The earlier checks read the page's own clocks. This one compares the sound at the machine's output with the frame as it is painted.

Offset in the tables = time of the beep at the system output minus time of the flash on the video element, in milliseconds. **Positive means the audio is late.** Ten flash and beep pairs per run.

## Method

- **Sound:** the system output is BlackHole 2ch, recorded by `cap` (CoreAudio, sample-accurate). ffmpeg's avfoundation capture drops about 20 percent of samples and cannot be used for this.
- **Picture:** `requestVideoFrameCallback` on the player's video element gives, for each painted frame, its mean luma, its media time and a display time. Safari reports `expectedDisplayTime` on another clock, so there the callback time is used.
- **Flash time:** taken from the frames' media time, not from the first callback that shows a bright frame. The flash's place in the 4 s slot is the earliest media time at which a flash was seen to start or end at least twice in the run, and media time is mapped to the page clock by the median of (frame time minus media time) over the frames within 1 s. The first-callback time is one frame late whenever the browser delivers no callback for that frame, which Firefox did for about half of the flashes; `results.tsv` keeps it as `first_callback`.
- **Clock link:** three 3 kHz clicks, scheduled on an AudioContext at known output times. Their onsets in the recording map the recording's clock to the page's clock.
- **Pairing:** the slots repeat every 4 s, so an offset is only defined modulo 4 s. Each beep is paired with the nearest flash within 2 s.
- **Clips:** five 44 s DASH clips made by [`make-fixtures.sh`](make-fixtures.sh), identical except for the video track's edit list. Flash and beep present together at 2.7 + 4k s (2.7193 + 4k s in `live`, where the flash can only land on a frame and the beep is placed to match). Each clip was decoded and checked: every beep starts on the sample asked for and every flash on the frame asked for.

| Clip | Edit list of the video track | Why it is there |
|---|---|---|
| `nob` | one entry that trims nothing (no B-frames) | reference |
| `ctrl` | a 67 ms trim | what ffmpeg writes for any B-frame video |
| `trim` | one 0.5 s trim, no empty edit | the shape that exposed the v1.3.13 defect |
| `live` | a 53 ms empty edit, then the 67 ms trim | the live stream's list |
| `elst` | a 1.7 s empty edit, then the 67 ms trim | the 1.7 s empty edit behind the Chromium desync described in [docs/UPSTREAM.md](../docs/UPSTREAM.md) |

- **Engines:** Chrome 157 (skips an edit list that opens with an empty edit), Chrome Canary 160 (applies it), Canary with `--disable-features=MP4ApplyEmptyEditList` (skips it), Safari 27.2 (skips it), Firefox 161 Beta and Firefox 163 Nightly (both apply it, and play Opus natively, so the feed is not involved). Every engine applies a list that is only a trim.
- **Player builds:** v1.3.14 is the deployed player. v1.3.13 is its bundle taken from the release tag and served in place of the deployed one (`BUNDLE=`). The player measures at page load what the engine does with each shape of list (`hoast360/dependencies/EmptyEditProbe.js`) and the audio feed shifts accordingly.

## Results

### v1.3.13 (before the fix)

| Engine | nob | ctrl 67 ms | trim 0.5 s | live | elst 1.7 s |
|---|---|---|---|---|---|
| Chrome 157 | -10 | **62** | **506** | -7 | -10 |
| Canary 160 | -10 | -9 | -7 | 8 | -11 |
| Canary 160, empty edit skipped | 10 | **60** | **494** | 8 | -10 |
| Safari 27.2 | -40 | **61** | **462** | -40 | -30 |
| Firefox 161 Beta | -14 | -5 | -6 | -14 | -2 |
| Firefox 163 Nightly | -1 | -6 | -15 | -15 | -7 |

The engines that skip an empty edit still apply a trim, and the feed took the trim off the audio a second time. In Chrome 157 the ordinary 67 ms trim of B-frame video was therefore about 70 ms later than the reference clip, and a 0.5 s trim about 500 ms later. The live stream was not affected, because its list opens with an empty edit and so falls under the shape the player already handled. Before v1.3.13, the `elst` clip played 1610 ms early in Canary, which applies the empty edit that the player assumed every browser skipped (first round, `results-first-clips.tsv`).

### v1.3.14 (deployed)

| Engine | nob | ctrl 67 ms | trim 0.5 s | live | elst 1.7 s |
|---|---|---|---|---|---|
| Chrome 157 | -9 | 7 | -10 | -11 | -6 |
| Canary 160 | -7 | -4 | -5 | 18 | -6 |
| Canary 160, empty edit skipped | -6 | -4 | 21 | -11 | -10 |
| Safari 27.2 | -26 | -46 | -42 | -98 | -40 |
| Safari 27.2, repeated | -18 | -50 | -43 | -41 | -47 |
| Firefox 161 Beta | -9 | -6 | -5 | -5 | -4 |
| Firefox 163 Nightly | -8 | -5 | -4 | -4 | 0 |

### Both builds

![Audio offset at the sound output for each clip and browser, v1.3.13 and v1.3.14](offsets.png)

*Colour is the build and shape is the browser; each dot is one run of ten pairs. Clips are as in the table under Method ([`plot-offsets.py`](plot-offsets.py) draws it from `results.tsv`, as PNG and SVG; the repeated Safari row is not drawn). The three dots on the right are the `trim` clip in the engines that skip an empty edit (Chrome 157, Canary with the empty edit skipped, Safari); the axis is broken between 110 and 450 ms so that the rest stay readable.*

## Reading

- v1.3.14 removes the trim-only defect. In the three engines that skip the empty edit, `trim` went from 462 to 506 ms to between -43 and 21 ms, and `ctrl` from about 60 ms to between -50 and 7 ms. In each engine both clips now read like that engine's reference clip.
- Nothing that was right in v1.3.13 got worse. `nob`, `elst` and `live` read alike in the two builds, except the one Safari `live` run at -98 ms, which the repeat (-41 ms) did not reproduce.
- Safari reads 18 to 50 ms early on every clip, the reference clip included, and it did so with v1.3.13 as well. So this is not the edit list, and v1.3.14 did not introduce it. Whether Safari presents the sound early or reports its frames late was not established: its frame time here is the callback time, because its `expectedDisplayTime` is on another clock.
- Firefox, which plays the audio natively, reads 0 to 15 ms early, like Chrome. By the first-callback time it would read 18 to 31 ms early, because its frame callback skipped the first bright frame in 1 to 7 flashes of 10.
- This measurement found the defect; the earlier checks had passed. The v1.3.13 probe tested the empty edit only, and the page's clocks agreed with each other, so both passed while the sound was late at the output.

## Against the broadcast recommendation

Recommendation ITU-R BT.1359-1 [1] puts the detectability thresholds for sound relative to picture at about +45 ms to -125 ms, and the acceptability thresholds at about +90 ms to -185 ms, on the average, where a positive value means the sound is advanced. This page counts the other way (positive means the sound is late), so in this page's sign the detectability window is -45 ms to +125 ms and the acceptability window is -90 ms to +185 ms.

- Every v1.3.14 cell in Chrome, Canary and Firefox (-11 to 21 ms) is inside the detectability window.
- Safari's cells (-18 to -50 ms) sit at the early edge of the detectability window, some just outside it, and inside the acceptability window. The single `live` run at -98 ms is outside both.
- The ordinary 67 ms trim in v1.3.13 (60 to 62 ms late) was inside the detectability window. The defect was real and measurable, but by this recommendation an average viewer would not have noticed it.
- The 0.5 s trim in v1.3.13 (462 to 506 ms late) is far outside the acceptability limit.

The thresholds come from subjective tests on television material (a newsreader, Appendix 2 of the recommendation), so they are a scale for the numbers here, not a listening test of this player.

## Limits

- **Spread between runs.** Within a run the ten pairs agree to about 2 ms in Chrome and Firefox (standard deviation 0 to 2 ms) and less well in Safari (up to 9 ms). Between runs they do not: there is one run per cell, and single cells sit 20 to 30 ms from their neighbours for no reason this harness can name (Canary `live` at 18 ms, Canary with the empty edit skipped `trim` at 21 ms, Safari `live` at -98 and then -41 ms). Differences under about 30 ms between cells are not results.
- **Absolute accuracy.** The picture time is the browser's own report of when a frame is displayed, and the sound time is the recording corrected by the click calibration. Neither was checked with a camera and a microphone in a room. The constant of about 8 ms early that Chrome and Firefox share, and Safari's larger one, could each be in the browser or in these reports.
- **The first round's clips were flawed.** On 2026-11-21 and 22 the beeps started 9 and 20 ms late in alternate slots (the tone was switched on per 1024-sample frame), the third flash of every clip started one frame late (a floating-point miss in the flash expression), and the `live` flash was 19 ms late (2.714 s is not on the 30 fps frame grid). Those numbers read about 15 ms too late and are kept only in `results-first-clips.tsv`. They showed the same defect and the same fix.
- **On-demand clips, not the live stream.** The live path serves the same player and the same feed, but this harness plays DASH files it controls. The live list is covered by the `live` clip.
- **Firefox and Safari run through WebDriver**, Chromium through Playwright. The page and the recording are the same.

## Files

- `offsets.png`, `offsets.svg`, `plot-offsets.py`: the figure above and the script that draws it.
- `results.tsv`: one line per run, the raw record behind the tables above. The `player` column says which build was tested.
- `results-first-clips.tsv`: the first round, measured with the flawed clips and timed by the first callback.
- How to run it: [README.md](README.md).

## References

1. Recommendation ITU-R BT.1359-1, *Relative timing of sound and vision for broadcasting* (1998). [PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1359-1-199811-I!!PDF-E.pdf)
