# AAC contribution bitrate on 16-channel ambisonics: measurement results

**Date:** 2026-08-22 · **Host:** MacBook (arm64, macOS), encoding inside `ambi-box-earshot:local` · **Encoder:** ffmpeg 7.1 native AAC (the contribution leg's actual encoder - a host ffmpeg 9.0 cannot do 16-channel AAC at all, see Limits) · **Metric:** [AMBIQUAL](https://github.com/QxLabIreland/Ambiqual) · **Material:** five excerpts (30 s each) from the [HOA seven-year corpus](https://doi.org/10.34808/w8bx-2094), the same five items as [opus-compression-test/RESULTS.md](../opus-compression-test/RESULTS.md)

## The question

[docs/BITRATE.md](../docs/BITRATE.md) sets contribution audio at 96 kbit/s per channel and says so plainly: the figure is a convention borrowed from elsewhere - AAC-LC's classic ~64/channel, EBU Tech 3324's 448-for-5.1 (~75/channel), YouTube's 256-for-4-channel ambisonics (64/channel) - none of it measured on higher-order ambisonics, and the doc calls it "a well-covered convention rather than a proven threshold".

So: where does measurable degradation actually begin on this material, and where does 96 sit relative to it?

**What this cannot answer.** This is an objective metric, not a listening test: it says where the models detect degradation, nothing more. Read it as bounding the question, not closing it.

## Method

1. Same five excerpts as the Opus study, listed with their source recording, offset and length in [excerpts.tsv](excerpts.tsv). Both harnesses select and cut them from the published corpus through one shared helper, so the two studies measure identical material by construction.
2. Each excerpt AAC-encoded at six per-channel rates - 32, 48, 64, 96, 128, 160 kbit/s - with **only bitrate varying**, `channelmap=channel_layout=hexadecagonal` forced so the encoder accepts 16 channels.
3. **Two chains measured per excerpt per rate:**
   - **aac** - the contribution leg alone: uncompressed reference in, AAC out, decoded back to PCM.
   - **cascade** - what a viewer actually receives: the AAC output decoded, then re-encoded to Opus at the production setting (`-mapping_family 255 -b:a 1536k`), since `earshot` always re-encodes. If this curve flattens earlier than the AAC-alone curve, contribution bitrate stops mattering above that point because Opus is the binding constraint.
4. AMBIQUAL run with the **uncompressed excerpt as reference** in every case, never one encode against another - same discipline as the Opus study.

Harness: [`scripts/measure-aac-bitrate.sh`](../scripts/measure-aac-bitrate.sh). All encoding runs inside the `earshot` image, not on the host - a host ffmpeg 9.0 refuses 16-channel AAC entirely (see [Limits, stated plainly](#limits-stated-plainly)).

## Results

![AMBIQUAL LQ and LA vs contribution AAC bitrate, two chains: AAC alone and AAC-then-Opus cascade. Bold line is the mean across five excerpts, band is the min-max range. Both curves climb across the whole 32 to 160 kbit/s per channel range and neither flattens; the cascade runs below AAC alone at every rate and gains less at every step, so the gap widens as bitrate rises.](bitrate-curve-2026-08.png)

*Regenerate with `python3 scripts/plot-aac-bitrate.py 2026-08`.*

| kbit/s/channel | carnival | deusexmachina | orchestra | piano | quarry |
|---|---|---|---|---|---|
| 32 | 0.444 | 0.416 | 0.416 | 0.481 | 0.423 |
| 48 | 0.618 | 0.575 | 0.553 | 0.636 | 0.583 |
| 64 | 0.675 | 0.646 | 0.619 | 0.661 | 0.652 |
| 96 | 0.760 | 0.739 | 0.739 | 0.790 | 0.744 |
| 128 | 0.845 | 0.833 | 0.871 | 0.909 | 0.840 |
| 160 | 0.913 | 0.935 | 0.913 | 0.943 | 0.934 |

AAC-alone AMBIQUAL LQ per excerpt. Full table, both chains, both metrics: [results.tsv](results.tsv).

**The cascade gains less than the contribution leg, at every step.** From 64 to 128 kbit/s/channel, AAC-alone LQ rises by 0.17-0.25 across the five excerpts; the cascade rises by 0.13-0.20 over the same span, so AAC-alone gains 1.22 to 1.40x faster than what a viewer actually receives. The direction is consistent on all five. That is the Opus re-encode acting as a partial ceiling: some of what extra contribution bitrate buys does not survive to the listener. It is a tax, not a wall - neither curve plateaus inside the range measured, and both are still climbing at 160.

**96 is not a knee, and this study does not find one.** At 96 the aac-cascade gap is 0.03-0.05 LQ, and both curves keep rising through 128 and 160 (see the [bitrate curve](bitrate-curve-2026-08.png) above). Nothing in the data marks 96 as the point where further contribution bitrate stops paying. What the data supports is the weaker statement that every extra kbit/s above it returns less to the viewer than it costs on the uplink, and that trade is what the production setting rests on, not a measured ceiling.

**Localisation is punished far more than quality at low bitrate**, the same shape the Opus study found. At 32 kbit/s/channel, LA sits at 26-29% of LQ across the five excerpts; by 160 that ratio has risen to 82-87%. The ambisonic-specific failure mode AMBIQUAL exists to catch is exactly what a plain quality metric would miss here.

**An anomaly the first run could not explain turned out to be the excerpts.** That run showed three of five excerpts scoring *lower* at 160 than at 128, in both chains, and the write-up recorded it as unexplained. On content-selected windows it is simply absent: all five rise monotonically through 160 in both chains, by +0.034 to +0.102 for AAC alone. The dip was a property of the material being measured, not of the encoder or the metric.

## Second opinion: BAM-Q

AMBIQUAL works in the ambisonic domain. To ask a genuinely independent question, the same conditions were also scored with **BAM-Q + GPSM<sup>q</sup>** ([Fleßner et al. 2019](https://doi.org/10.1109/TASLP.2019.2904850)), a different model family that works on **binaural** signals and was validated against listening tests. That needs a binaural render, so every condition was decoded through **HOAST360's own decoder** - the real `HOASTloader` and `HOASTBinDecoder`, the shipped IRs, the same convolver topology - making the renderer a controlled constant and keeping the measurement about the chain that actually ships. Harness: [`scripts/measure-bamq.sh`](../scripts/measure-bamq.sh), one command over the same work directory the AMBIQUAL half fills. It renders every condition through [`scripts/binauralize.js`](../scripts/binauralize.js) in both decoder modes (the fixed one, and the pre-fix one the defect section below is measured from), pairs each render against its uncoded reference, and scores the pairs with [`scripts/run_bamq.m`](../scripts/run_bamq.m). Full output in [bamq.tsv](bamq.tsv).

Mean across the five excerpts. `OPM_fix` is the monaural measure, `binQ` the binaural one (100 = no binaural difference), `overall` the combined figure:

| condition | overall | OPM_fix | binQ |
|---|---|---|---|
| AAC 128 | 0.5580 | 68.53 | 99.2 |
| AAC 96 | 0.5347 | 65.00 | 98.4 |
| cascade 128 | 0.5494 | 67.19 | 98.0 |
| cascade 96 | 0.5424 | 66.15 | 98.0 |

**BAM-Q agrees that the cascade returns less, and puts it more strongly than AMBIQUAL does.** Monaural quality improves from 96 to 128 kbit/s/channel on all five excerpts for AAC alone (+1.26 to +6.97 OPM). The cascade gains less on four of them and goes *negative* on two (`carnival` -2.48, `deusexmachina` -1.95), meaning extra contribution bitrate reached the listener as slightly worse monaural quality on that material. The exception is `piano`, where the two chains move together (+6.97 against +6.86). Two metric families, different domains, different validation lineages, agreeing on direction while disagreeing on how much - which is more informative than either result alone, and a reason not to quote a single ratio as the finding.

**The degradation AAC causes is almost entirely monaural.** `binQ` sits at 97-100 for every codec condition (unchanged from the first run), meaning bitrate reduction leaves interaural cues substantially intact while damaging spectral quality. That is the monaural/binaural split Fleßner et al. describe, and it is the reason to pair a binaural metric with an ambisonic one rather than run two of the same kind. AMBIQUAL disagrees from the ambisonic side, and the disagreement is the interesting part: on the AAC leg LA runs 33-39 % below LQ at 96 kbit/s/channel and 19-27 % below at 128, wider on the cascade (41-47 % and 30-40 %). So the ambisonic model finds the spatial dimension the worst-hit where the binaural model finds it the least-hit. Both can hold: damage to the directional HOA channels does not have to survive binaural decoding as an interaural cue error, and can arrive as spectral colouring instead. What it means in practice is that neither metric alone bounds the question, which is the argument for running both.

### A decoder defect had to be fixed before any of this was measurable

Building the binaural render surfaced a bug in HOAST360's filter loading, upstream since 2020 and offered back as [thomasdeppisch/hoast360#31](https://github.com/thomasdeppisch/hoast360/pull/31): `HoastLoader.concatBuffers()` read source channel 0 for **every** destination channel in a higher-order group, so each group was filled with copies of its first channel's decoding filter. At 3rd order that is **10 of the 12 higher-order filter channels wrong**; only ambisonic 5 and 13 were correct, being first in their groups, and 1-4 were never affected (they come from the first-order buffer, handled separately).

It is fixed here, and the fix is what every binaural number above was measured through. Measuring the codec through a broken decode would have confounded a bitrate question with a decoder defect.

![BAM-Q comparison: on all five excerpts the decoder defect sits outside the cluster of codec conditions, on both binaural quality and interaural level error.](bamq-decoder-defect-2026-08.png)

*Regenerate with `python3 scripts/plot-bamq.py 2026-08`.*

**The defect costs more than any codec setting tested, on the binaural measures.** On every individual excerpt its `binQ` is below the worst codec condition (92-97 against 97-99) and its ILD error is 1.7x to 7.9x larger (piano: 853.5 against 107.4). It costs that with **no compression involved at all** - those figures compare an uncoded reference decoded two ways. The combined figures are closer than the binaural ones and should not be quoted alone: mean `overall` 0.5318 against 0.5347 for the worst codec condition, `OPM_fix` 64.55 against 65.00. The defect is a spatial fault, and it is the spatial measures that show it.

## Limits, stated plainly

- Five excerpts, one window each, no listening test, no repeats. Narrow enough that a single excerpt moves a mean, which is why the findings above are stated as directions holding across all five rather than as magnitudes.
- **Objective only.** Neither AMBIQUAL nor BAM-Q can establish transparency, which is a subjective ABX threshold; BAM-Q is validated *against* listening tests, it does not replace one. Two agreeing objective metrics raise confidence in the shape of the curve, not in any claim about audibility.
- **The BAM-Q arm carries the renderer with it.** Its numbers describe the material as decoded by HOAST360's own binaural chain. That is deliberate, since it is what a listener receives, but it means those figures are conditional on that renderer in a way the AMBIQUAL figures are not.
- Measured on arm64 macOS, encoding inside the `earshot` container so the encoder matches production; CPU-cost scaling to the Pi 4 was not measured here (that question is answered for Opus in the sibling study, not for AAC contribution, which both default routes leave to the sender: the box encodes 16-channel AAC only on the `SRT_DIRECT=0` / `GUEST_SRT_DIRECT=0` RTMP republish fallback, where it measured 59 % of a core on the deployment box and has never been measured on a Pi 4).
- **A host ffmpeg cannot run this study at all.** ffmpeg 9.0 here refuses `-ac 16` (resolves to layout `9.1.6`, rejected) and refuses `hexadecagonal` named explicitly too. The `earshot` image's pinned FFmpeg 7.1 encodes it cleanly, which is why the image pins a version at all ([EnvelopSound/Earshot#82](https://github.com/EnvelopSound/Earshot/pull/82)). The capability loss is filed upstream as [FFmpeg#24218](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/24218): `aacenc` has been unable to encode any layout above 8 channels since `c92c6cbf19` removed the last `aac_pce_configs[]` entries above `OCTAGONAL`, with 8.1 the last working release. The 16-channel ceiling in [docs/AMBISONIC-ORDER.md](../docs/AMBISONIC-ORDER.md) is therefore version-dependent as well as layout-dependent - reproducing this on a modern host ffmpeg would measure nothing, not merely hit the documented cap.
- **AMBIQUAL needs a patch to run at all**, before any of the above: as published it raises `NameError` on the first channel. The defect and the local fix are described in the [Opus study's limits](../opus-compression-test/RESULTS.md#limits-stated-plainly) and reported upstream as [Ambiqual #2](https://github.com/QxLabIreland/Ambiqual/issues/2). Both studies depend on that patch.
- **AMBIQUAL needs sample-exact length equality** between reference and degraded audio or it throws on the internal broadcast. AAC/Opus decode does not naturally land there; two time-based fixes (`apad -t N`, `apad=whole_dur=N`) both failed silently on this ffmpeg build. The harness uses `atrim=end_sample=N` and verifies the resulting frame count, retrying up to three times - even the exact command was observed to occasionally overshoot by one frame under concurrent load. See the harness header for the full account.
