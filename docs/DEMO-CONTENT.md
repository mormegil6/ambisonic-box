# The demo loop and preparing `content/demo.mp4`

The stack always has something to play. The `loop-source` service loops `content/demo.mp4` into the pipeline as if it were a live contribution; when that file is absent, it synthesises a placeholder at first start instead, in-container and without network: a black sphere with a test pattern as a front screen and one 440 Hz source orbiting the listener in 3rd-order Ambisonics, so looking around audibly works before any real content exists. [`scripts/make-demo-loop.sh`](../scripts/make-demo-loop.sh) produces the same placeholder from the host.

[`DEMO_CONTENT`](../.env.example) in `.env` governs the automation (default `1`). It also covers the VOD reference-master fetch when `VOD_ENABLED=1` (see [VOD.md](VOD.md)). Set `DEMO_CONTENT=0` to do neither; the loop then idles until you provide `demo.mp4`. The file is checked once at `loop-source` startup, so after adding it run `docker compose restart loop-source`.

## What the file must be

H.264 video plus 16-channel AAC with PCE headers, in MP4 (or FLV), with a GOP that fits the 2 s segment target (see [the GOP constraint](#the-gop-constraint) below). The requirement comes from the RTMP contribution leg: legacy RTMP cannot carry VP9 or Opus, and `loop-source` streams the file with `-c copy` (zero CPU), so nothing re-encodes it on the way in. Channel order must be ACN/SN3D (AmbiX) end to end.

If your master already is H.264 + 16-ch AAC MP4, no transcode is needed:

```bash
cp /path/to/your-master-h264-aac16.mp4 content/demo.mp4
```

## Preparing it from any 16-channel master

From WebM, MOV, or WAV-plus-video, use the `earshot` image's ffmpeg, which writes correct PCE headers (build it first: `docker compose build earshot`):

```bash
docker run --rm -v "$PWD/content:/content" --entrypoint ffmpeg \
  ambi-box-earshot:local \
  -i /content/your-master.webm \
  -c:v libx264 -preset veryfast -b:v 6M -pix_fmt yuv420p -g 50 \
  -af "channelmap=channel_layout=hexadecagonal" \
  -c:a aac -ac 16 -b:a 2048k \
  -movflags +faststart \
  /content/demo.mp4
```

## The GOP constraint

Keep `-g` (GOP length in frames) equal to segment duration times frame rate, or an exact sub-multiple of it; segment duration must be an integer multiple of GOP duration, and equality is the preferred default since extra keyframes cost bitrate. The `-g 50` above is the 25 fps value for the stack's 2-second segments; a 29.97 fps master needs `-g 60`. This matters because the committed default passes video through untouched (`-c:v copy`), so `earshot` applies no GOP of its own: the contribution file's GOP is the one that governs segmentation, and a master written without one silently produces multi-second video segments against 2-second audio. [`scripts/test-pipeline.sh`](../scripts/test-pipeline.sh) checks the master for exactly this and fails the run when its GOP does not fit.

Audio bitrate guidance, and why the demo ships at the rate it does, is in [BITRATE.md](BITRATE.md). What the 16 channels are and why second order still pads to 16 is in [AMBISONIC-ORDER.md](AMBISONIC-ORDER.md).
