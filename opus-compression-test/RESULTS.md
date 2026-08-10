# libopus `-compression_level` on 16-channel ambisonics: measurement results

**Date:** 2026-08-10 · **Host:** MacBook (arm64, macOS) · **Encoder:** `libopus`, `-mapping_family 255`, `-b:a 1536k` (96 kbit/s per channel, the production setting) · **Metric:** [AMBIQUAL](https://github.com/QxLabIreland/Ambiqual) · **Material:** three 30 s excerpts from the [HOA seven-year corpus](https://doi.org/10.5281/zenodo.21789163)

## The question

Nothing in this stack sets `-compression_level`, so every Opus encode runs at libopus's default of **10**, the slowest and most thorough setting. Lowering it toward 5 is a standard way to buy encoder CPU back for a difference that is usually hard to hear, and here it would apply to 16 channels on every route including a Raspberry Pi 4, where the margin is thinnest.

So: what does level 5 actually save, and what does it cost?

## Answer

**Leave it unset.** There is no meaningful CPU to reclaim, and on solo piano the quality and localisation both measurably degrade.

## Method

1. Three 30 s excerpts, 16-channel ACN/SN3D at 48 kHz, chosen to span the ways a codec fails: sparse tonal with long decay (solo piano), broadband many-source (orchestra), dense contemporary ensemble.
2. Each excerpt encoded three times with **only `-compression_level` varying** (10, 5, 0), then decoded back to PCM.
3. AMBIQUAL run with the **uncompressed excerpt as reference** in every case, never one encode against another: the question is how much quality a setting gives up, so both settings need the same reference.
4. Encoder cost measured separately as wall-clock to encode the same 30 s.

Harness: [`scripts/measure-opus-compression.sh`](../scripts/measure-opus-compression.sh).

**Why not the tone ladder.** Pure tones are the easiest possible case for a transform codec, near-transparent at any setting, so an A/B on them would have shown nothing and invited the wrong conclusion. The synthetic ladder in `scripts/test-pipeline.sh` stays for wiring checks (channel order, level ramp), which is a different job.

**Why AMBIQUAL and not a binaural metric.** It works in the ambisonic domain, so there is no binaural render in the loop and therefore no HRIR choice and no renderer latency to confound the result.

## Encoder cost

Wall clock to encode 30 s of 16-channel audio, and what that is as a fraction of one core in realtime terms:

| `-compression_level` | encode time | share of one core |
|---|---|---|
| 10 (default) | 1.68 s | 5.6 % |
| 5 | 1.41 s | 4.7 % |
| 0 | 0.76 s | 2.5 % |

**Dropping 10 to 5 saves 0.9 % of a core.** For scale, the 16-channel AAC re-encode that the direct-to-DASH path removed measured **59 %** of a core. The Opus encode is an order of magnitude cheaper than the thing already optimised away, so the premise that this was worth optimising does not survive measurement.

## Quality

AMBIQUAL `LQ` (listening quality) and `LA` (localisation), both 0-1, higher is better. Deltas are against level 10.

| excerpt | c10 LQ | c5 LQ | c0 LQ | c5 ΔLQ | c5 ΔLA | c0 ΔLQ | c0 ΔLA |
|---|---|---|---|---|---|---|---|
| solo piano | 0.8900 | 0.8737 | 0.8698 | **−0.0163** | **−0.0381** | −0.0202 | −0.0489 |
| orchestra | 0.8256 | 0.8280 | 0.8255 | +0.0023 | +0.0031 | −0.0001 | +0.0018 |
| dense ensemble | 0.8128 | 0.8154 | 0.8123 | +0.0026 | +0.0072 | −0.0005 | +0.0007 |

Two things stand out.

**Only the sparse tonal material degrades.** Piano loses on both metrics at every step down; orchestra and dense ensemble move by ±0.003, change sign between settings, and are indistinguishable at level 0 from level 10. That is the expected pattern rather than a surprise: encoder search effort matters most where the signal is sparse and transient, and dense broadband material masks its own artifacts. It is also a useful sanity check on the metric, which reports a difference exactly where one should exist and noise where it should not.

**Localisation degrades harder than quality.** On piano, `LA` falls 2.3x further than `LQ` (−0.038 against −0.016). Lower encoder effort costs more in the spatial channels than in overall fidelity, which is the specific risk that motivated using an ambisonic-domain metric rather than a plain quality one.

## Why this closes the question rather than opening it

The trade on offer is 0.9 % of a core against measurable degradation of solo piano. Piano is the single most common content type in the corpus this stack was built for (8 of 23 sessions), so the material that loses is the material that matters most here.

This is not "safe to lower, take the win". There was no win to take.

## Limits, stated plainly

- Three excerpts, one 30 s window each, one metric, no listening test. The effect sizes on the dense material are within noise, and no confidence intervals were computed.
- Measured on arm64 macOS. The CPU fractions will differ on the Pi 4, but the *ratio* between settings is a property of the encoder, and 5.6 % of a core has a long way to fall before it competes with anything else in the pipeline.
- Two further excerpts were cut and discarded: a fixed 60 s offset put one in the pre-concert audience (spectral flatness 0.33 at −49 dBFS) and left another 66 % near-silent. **Choose excerpts by content, not by clock** - the selection is part of the method, not a detail.
- **AMBIQUAL as published does not run.** `calculate_ambiqual` references `n_channels`, which no longer exists after a rename to `n_channels_ref`/`n_channels_deg`, so it raises `NameError` on the first channel. Patched locally to `min(n_channels_ref, n_channels_deg)`, which is what the downstream NaN handling already assumes: same count means nothing was lost (fill 1.0), ref-HOA against deg-FOA means channels were lost (fill 0.1). Its pinned `numpy==1.23.5` also has no wheel for current Python; `numpy>=1.26,<2` works and stays on the 1.x API the code predates.
- The source audio is not in this repository. The corpus is published separately ([10.5281/zenodo.21789163](https://doi.org/10.5281/zenodo.21789163)); point the harness at any 16-channel ACN/SN3D material to reproduce the shape of the result.
