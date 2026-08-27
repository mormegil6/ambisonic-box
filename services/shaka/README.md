# Patched Shaka Packager

Shaka Packager writes the Opus `dOps` box little-endian. Packaging the VOD clips with a stock build produces audio that Chromium's MSE refuses, which means every DASH player, including Shaka's own. This directory rebuilds the packager with that fixed.

Reported upstream as [shaka-packager#1627](https://github.com/shaka-project/shaka-packager/issues/1627). Unfixed in every release up to and including v3.9.3.

## Build

    docker build -t shaka-packager:dops-fix .

Roughly 20 minutes. `scripts/package-vod-dash.sh` in the public repo expects that image tag.

## What the patch does

`OpusSpecific::ReadWriteInternal` copied the `OpusHead` body into the `dOps` box verbatim. `OpusHead` stores `PreSkip`, `InputSampleRate` and `OutputGain` little-endian (RFC 7845); `dOps` stores them big-endian, like every ISO BMFF field. Identical field order and widths, so the copy produced a valid box holding reversed numbers: `PreSkip` 312 written as 14337, `InputSampleRate` 48000 written as 2159738880.

The patch byte-swaps those three fields on write and reverses the same conversion on read. Everything else in the box is single bytes and needs nothing.

## Verifying a build

    docker run --rm -v "$PWD":/w -w /w shaka-packager:dops-fix \
      packager 'in=some-opus.webm,stream=audio,output=out.mp4'

Read the `dOps` payload of `out.mp4`. For a 48 kHz source it must contain `01 38` (PreSkip 312) and `00 00 bb 80` (48000). A stock build gives `38 01` and `80 bb 00 00`.

## The trap when testing

Packaging an existing Opus **MP4** comes out correct even on a stock build, because the reader carries the mirror defect and the two cancel exactly. Only WebM to MP4 exposes it. Test with a WebM input or you will conclude there is nothing wrong.

## Deleting this

The moment an upstream release carries the fix. Pin `scripts/package-vod-dash.sh` back to `google/shaka-packager:<version>`, rebuild the clips, and remove this directory. Carrying a private build of someone else's tool is a cost worth ending as soon as it can be.
