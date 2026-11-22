# Audible A/V offset of the player, measured at the system output

**Dates:** 2026-11-21 (v1.3.13 and the candidate fixes), 2026-11-22 (v1.3.14) · **Host:** a Mac with the sound output set to BlackHole 2ch · **Player:** the production on-demand page, `stream.bmroz.eu/vod/?clip=colortones`, with the clip replaced by the test clips below · **Result:** v1.3.14 is within about 20 ms of sync in Chrome 157, Chrome Canary 160 and Safari 27.2 on every clip, including the clip that v1.3.13 played about 500 ms late.

## The question

The player decodes the 16-channel Opus audio itself and schedules it on the page's audio clock, because no browser decodes it natively everywhere. The picture comes from the browser's own video pipeline. They line up only if the page shifts the audio by the offset the browser does not apply to the picture. Browsers differ here: some apply the video track's edit list (`elst`, the MP4 box that carries the track's start offset and trim), others skip part of it. The earlier checks read the page's own clocks. This one compares the sound at the machine's output with the frame as it is painted.

Offset in the tables = time of the beep at the system output minus time of the flash on the video element, in milliseconds. **Positive means the audio is late.** Ten flash and beep pairs per run; the spread (sd) is 5 to 20 ms, mostly video frame quantisation (33 ms frames).

## Method

- **Sound:** the system output is BlackHole 2ch, recorded by `cap` (CoreAudio, sample-accurate). ffmpeg's avfoundation capture drops about 20 percent of samples and cannot be used for this.
- **Picture:** `requestVideoFrameCallback` on the player's video element, mean luma of each painted frame. Safari reports `expectedDisplayTime` on another clock, so there the callback time is used.
- **Clock link:** three 3 kHz clicks, scheduled on an AudioContext at known output times. Their onsets in the recording map the recording's clock to the page's clock.
- **Pairing:** the slots repeat every 4 s, so an offset is only defined modulo 4 s. Each beep is paired with the nearest flash within 2 s.
- **Clips:** five 44 s DASH clips made by [`make-fixtures.sh`](make-fixtures.sh), identical except for the video track's edit list. Flash and beep are both meant to present at 2.7 + 4k s.

| Clip | Edit list of the video track | Why it is there |
|---|---|---|
| `nob` | one entry that trims nothing (no B-frames) | reference |
| `ctrl` | a 67 ms trim | what ffmpeg writes for any B-frame video |
| `trim` | one 0.5 s trim, no empty edit | the shape that exposed the v1.3.13 defect |
| `live` | a 53 ms empty edit, then the 67 ms trim | the live stream's list |
| `elst` | a 1.7 s empty edit, then the 67 ms trim | the 1.7 s empty edit behind the Chromium desync described in [docs/UPSTREAM.md](../docs/UPSTREAM.md) |

- **Engines:** Chrome 157 (skips an edit list that opens with an empty edit), Chrome Canary 160 (applies it), Canary with `--disable-features=MP4ApplyEmptyEditList` (skips it), Safari 27.2 (skips it), Firefox 161 Beta and Firefox 163 Nightly, build 20261121200250 (both apply it, and play Opus natively, so the feed is not involved). Every engine applies a list that is only a trim.
- **Player builds:** the deployed one in each run. The player measures at page load what the engine does with each shape of list (`hoast360/dependencies/EmptyEditProbe.js`) and the audio feed shifts accordingly.

## Results

### v1.3.13 (before the fix)

| Engine | nob | ctrl 67 ms | trim 0.5 s | live | elst 1.7 s |
|---|---|---|---|---|---|
| Canary 160 | -1 | 28 | -4 | -20 | 11 |
| Canary 160, empty edit skipped | 9 | 76 | **494** | -5 | 11 |
| Chrome 157 | 8 | 73 | **493** | -11 | 9 |
| Safari 27.2 | 1 | 68 | **502** | -16 | 5 |
| Firefox 161 Beta | -17 | -15 | -11 | -28 | -11 |

The engines that skip an empty edit still apply a trim, and the feed took the trim off the audio a second time. The ordinary 67 ms trim of B-frame video was therefore about 70 ms late in those engines, and a 0.5 s trim about 500 ms late. The live stream was not affected, because its list opens with an empty edit and so falls under the shape the player already handled. Before v1.3.13, the `elst` clip played 1610 ms early in Canary, which applies the empty edit that the player assumed every browser skipped.

### v1.3.14 (deployed)

| Engine | nob | ctrl 67 ms | trim 0.5 s | live | elst 1.7 s |
|---|---|---|---|---|---|
| Canary 160 | | 1 | 20 | -11 | 2 |
| Canary 160, empty edit skipped | | 1 | 4 | -15 | 0 |
| Chrome 157 | 3 | -1 | 7 | -14 | 15 |
| Safari 27.2 | | -3 | -7 | -17 | -14 |
| Firefox 161 Beta | -7 | -16 | -10 | -23 | -6 |
| Firefox 163 Nightly | -12 | -16 | -17 | -19 | -3 |

The first Chrome 157 `elst` run recorded one beep of ten and was repeated (`dep-chrome157-elst-r2`, 15 ms); the failed run is in `results.tsv` as `dep-chrome157-elst`. `nob` was run only in Chrome 157 and the two Firefox builds.

### Both builds

![Audio offset at the sound output for each clip and browser, v1.3.13 and v1.3.14](offsets.png)

*Colour is the build and shape is the browser; each dot is the mean of one run of ten pairs. Clips are as in the table under Method ([`plot-offsets.py`](plot-offsets.py) draws it from `results.tsv`, as PNG and SVG). The three dots near 500 ms are the `trim` clip in the engines that skip an empty edit (Chrome 157, Canary with the empty edit skipped, Safari); the axis is broken between 110 and 480 ms so that the rest stay readable. `nob` was run only in Chrome 157 and the two Firefox builds.*

## Reading

- v1.3.14 removes the trim-only defect. In the three engines that skip the empty edit, `trim` went from 493 to 502 ms late to between -7 and 7 ms, and `ctrl` from about 70 ms late to between -3 and 1 ms.
- Nothing that was right in v1.3.13 got worse. `elst` and `live` are within the run-to-run spread of the earlier numbers.
- Firefox reads 3 to 23 ms early on every clip, in both channels, and it did the same under v1.3.13 (average about 13 ms early). It plays the audio natively, so the player's feed is not involved, and a constant on every clip does not come from the edit list. Whether it comes from Firefox's audio path or from how the frame time is read was not tested.
- This measurement found the defect; the earlier checks had passed. The v1.3.13 probe tested the empty edit only, and the page's clocks agreed with each other, so both passed while the sound was late at the output.

## Against the broadcast recommendation

Recommendation ITU-R BT.1359-1 [1] puts the detectability thresholds for sound relative to picture at about +45 ms to -125 ms, and the acceptability thresholds at about +90 ms to -185 ms, on the average, where a positive value means the sound is advanced. This page counts the other way (positive means the sound is late), so in this page's sign the detectability window is -45 ms to +125 ms and the acceptability window is -90 ms to +185 ms.

- Every v1.3.14 cell (-23 to 20 ms) is inside the detectability window.
- The ordinary 67 ms trim in v1.3.13 (68 to 76 ms late) was also inside it. The defect was real and measurable, but by this recommendation an average viewer would not have noticed it.
- The 0.5 s trim in v1.3.13 (493 to 502 ms late) is far outside the acceptability limit.

The thresholds come from subjective tests on television material (a newsreader, Appendix 2 of the recommendation), so they are a scale for the numbers here, not a listening test of this player.

## Limits

- **Spread.** One run of ten pairs per cell. The same clip with the same build has read between -14 and +1 ms in Chrome 157 (`live`) and between -15 and -54 ms in Safari (`live`, two runs of one candidate build). The Safari difference is not explained. Differences under about 20 ms between cells are not results.
- **Absolute accuracy.** The picture time is the browser's own report of when a frame is displayed, and the sound time is the recording corrected by the click calibration. Neither was checked with a camera and a microphone in a room.
- **On-demand clips, not the live stream.** The live path serves the same player and the same feed, but this harness plays DASH files it controls. The live list is covered by the `live` clip.
- **Firefox and Safari run through WebDriver**, Chromium through Playwright. The page and the recording are the same.

## Files

- `offsets.png`, `offsets.svg`, `plot-offsets.py`: the figure above and the script that draws it.
- `results.tsv`: one line per run, the raw record behind the tables above. The `player` column says which build was tested; "candidate build, not released" rows are intermediate versions of the v1.3.14 fix.
- How to run it: [README.md](README.md).

## References

1. Recommendation ITU-R BT.1359-1, *Relative timing of sound and vision for broadcasting* (1998). [PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1359-1-199811-I!!PDF-E.pdf)
