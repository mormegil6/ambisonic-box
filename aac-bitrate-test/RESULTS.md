# AAC contribution bitrate on 16-channel ambisonics: measurement results

**Date:** 2026-08-15 · **Host:** MacBook (arm64, macOS), encoding inside `ambi-box-earshot:local` · **Encoder:** ffmpeg 4.3 native AAC (the contribution leg's actual encoder - a host ffmpeg 9.0 cannot do 16-channel AAC at all, see Limits) · **Metric:** [AMBIQUAL](https://github.com/QxLabIreland/Ambiqual) · **Material:** five excerpts (30 s each) from the [HOA seven-year corpus](https://doi.org/10.34808/w8bx-2094), the same five items as [opus-compression-test/RESULTS.md](../opus-compression-test/RESULTS.md)

## The question

[docs/BITRATE.md](../docs/BITRATE.md) sets contribution audio at 96 kbit/s per channel and says so plainly: the figure is a convention borrowed from elsewhere - AAC-LC's classic ~64/channel, EBU Tech 3324's 448-for-5.1 (~75/channel), YouTube's 256-for-4-channel ambisonics (64/channel) - none of it measured on higher-order ambisonics, and the doc calls it "a well-covered convention rather than a proven threshold".

So: where does measurable degradation actually begin on this material, and where does 96 sit relative to it?

**What this cannot answer.** This is an objective metric, not a listening test. It can say where AMBIQUAL detects degradation; it cannot establish transparency, which is a subjective ABX threshold. Read it as bounding the question, not closing it.

## Method

1. Same five excerpts as the Opus study, recovered from this project's own session transcripts since that study's work directory was gitignored and is gone (details in the private plan log). Two would have been wrong on the obvious guess: `piano` is Grainger's *Bridal Lullaby*, not the corpus's more prominent Chopin recording, and `quarry`'s second take is marked not-for-publication and genuinely absent from the corpus, leaving its first take as the only choice rather than a default that happened to be right.
2. Each excerpt AAC-encoded at six per-channel rates - 32, 48, 64, 96, 128, 160 kbit/s - with **only bitrate varying**, `channelmap=channel_layout=hexadecagonal` forced so the encoder accepts 16 channels.
3. **Two chains measured per excerpt per rate:**
   - **aac** - the contribution leg alone: uncompressed reference in, AAC out, decoded back to PCM.
   - **cascade** - what a viewer actually receives: the AAC output decoded, then re-encoded to Opus at the production setting (`-mapping_family 255 -b:a 1536k`), since earshot always re-encodes. If this curve flattens earlier than the AAC-alone curve, contribution bitrate stops mattering above that point because Opus is the binding constraint.
4. AMBIQUAL run with the **uncompressed excerpt as reference** in every case, never one encode against another - same discipline as the Opus study.

Harness: [`scripts/measure-aac-bitrate.sh`](../scripts/measure-aac-bitrate.sh). All encoding runs inside the earshot image, not on the host - a host ffmpeg 9.0 refuses 16-channel AAC entirely (see Limits).

## Results

![AMBIQUAL LQ and LA vs contribution AAC bitrate, two chains: AAC alone and AAC-then-Opus cascade. Bold line is the mean across five excerpts, band is the min-max range. The cascade curve visibly flattens above roughly 96 kbit/s per channel while the AAC-alone curve keeps climbing to 128.](bitrate-curve-2026-08.png)

*Regenerate with `python3 scripts/plot-aac-bitrate.py 2026-08`.*

| kbit/s/channel | carnival | deusexmachina | orchestra | piano | quarry |
|---|---|---|---|---|---|
| 32 | 0.566 | 0.546 | 0.571 | 0.690 | 0.546 |
| 48 | 0.689 | 0.660 | 0.696 | 0.780 | 0.641 |
| 64 | 0.768 | 0.735 | 0.789 | 0.848 | 0.734 |
| 96 | 0.896 | 0.850 | 0.906 | 0.941 | 0.847 |
| 128 | 0.947 | 0.915 | 0.962 | 0.972 | 0.904 |
| 160 | 0.929 | 0.965 | 0.907 | 0.925 | 0.974 |

AAC-alone AMBIQUAL LQ per excerpt. Full table, both chains, both metrics: [results.tsv](results.tsv).

**The cascade flattens; the contribution leg does not, not yet.** From 64 to 128 kbit/s/channel, AAC-alone LQ rises by 0.12-0.18 across the five excerpts; the cascade rises by only 0.08-0.11 over the same span - AAC-alone gains 1.6 to 1.96x faster than what a viewer actually receives. That is the Opus re-encode acting as a ceiling: past a point, spending more contribution bitrate buys quality the downstream Opus encode cannot pass through.

**96 sits close to where that ceiling starts to bind, not below it.** At 96, the aac-cascade gap is already 0.08-0.11 LQ across every excerpt - the two curves have visibly separated by production's own operating point (see the figure). Contribution bitrate is not underspent: pushing past 96 keeps improving the AAC-alone number but buys the cascade comparatively little.

**Localisation is punished far more than quality at low bitrate**, the same shape the Opus study found. At 32 kbit/s/channel, LA sits at 32-43% of LQ across the five excerpts; by 160 that ratio has risen to 73-84%. The ambisonic-specific failure mode AMBIQUAL exists to catch is exactly what a plain quality metric would miss here.

**One thing this study cannot explain, stated rather than smoothed over.** Three of five excerpts (piano, orchestra, carnival) show LQ *lower* at 160 than at 128, in both chains, by 0.02-0.05. The other two (deusexmachina, quarry) keep rising cleanly through 160. The two chains are not independent evidence here - cascade's input *is* the AAC output for that item, so a dip in one is expected to appear in the other; this is one effect observed twice, not two confirmations. Five excerpts, one window each, no repeats: the same limitation the Opus study carries, and not enough to distinguish real high-bitrate encoder behaviour from AMBIQUAL noise on this material. Read the 128-160 range as "no further measurable gain," not as "160 is worse than 128."

## Limits, stated plainly

- Five excerpts, one window each, one metric, no listening test, no repeats. The 160 dip above is the visible cost of that design; a wider corpus or repeated windows would settle it.
- **Objective only.** AMBIQUAL cannot establish transparency. A BAM-Q pass at the decision points (a different model family, validated against listening tests) is planned as corroboration, not yet run.
- Measured on arm64 macOS, encoding inside the earshot container so the encoder matches production; CPU-cost scaling to the Pi 4 was not measured here (that question is answered for Opus in the sibling study, not for AAC contribution, which is upstream of any host this project runs).
- **A host ffmpeg cannot run this study at all.** ffmpeg 9.0 here refuses `-ac 16` (resolves to layout `9.1.6`, rejected) and refuses `hexadecagonal` named explicitly too. Earshot's pinned 4.3-era fork encodes it cleanly. The 16-channel ceiling in [docs/AMBISONIC-ORDER.md](../docs/AMBISONIC-ORDER.md) is therefore version-dependent as well as layout-dependent - reproducing this on a modern host ffmpeg would measure nothing, not merely hit the documented cap.
- **AMBIQUAL needs sample-exact length equality** between reference and degraded audio or it throws on the internal broadcast. AAC/Opus decode does not naturally land there; two time-based fixes (`apad -t N`, `apad=whole_dur=N`) both failed silently on this ffmpeg build. The harness uses `atrim=end_sample=N` and verifies the resulting frame count, retrying up to three times - even the exact command was observed to occasionally overshoot by one frame under concurrent load. See the harness header for the full account.
