# Test fixtures for the OBS recipes

Two small files that reproduce the exact setup the [macOS](../obs-macos.md) and [Windows](../obs-windows.md) guides were verified with. Both are plain text, self-contained, and carry no absolute paths.

| File | What it is |
|---|---|
| `AmbiX16ch_StreamTest.RPP` | A REAPER project: a 16-channel `3OA` parent track with sixteen mono children, `ACN-00` to `ACN-15`. Each child carries one tone of a 100 → 1600 Hz ladder (100 Hz per step) at its own level, so both channel order and channel loss are visible. |
| `obs-macos-blackhole.json` | OBS **scene collection** for macOS: four Audio Input Capture sources on BlackHole 16ch, channels 1-4 / 5-8 / 9-12 / 13-16, one per track. |
| `obs-macos-profile/` | OBS **profile** for macOS: Advanced output, Custom Output (FFmpeg) to an SRT URL, mpegts, `h264_videotoolbox`, keyframe interval 60, `aac` at 384 kbit/s, tracks 1-4, Channels 4.0. |
| `ReaRoute16ch-atkAudioPluginHost2.filtergraph` | The atkAudio PluginHost2 graph from the Windows guide: ReaRoute ASIO in, 16 channels wired to four "OBS Output" nodes of 4 channels each. Windows only. |

## The REAPER project

Open it and route the 16 hardware outputs at your end - ReaRoute on Windows, or your multichannel Core Audio device on macOS. The tones come from `synthesis/tonegenerator`, a **stock REAPER JS plugin**, so nothing needs installing.

One tone per channel is the whole point: it makes channel order and channel loss *visible* rather than a matter of opinion. Play it, capture at the far end, and run the check from either guide:

```bash
ffmpeg -v error -ss 5 -i merged.mov -map 0:a:0 -t 1.5 -f s16le -c:a pcm_s16le - \
  | python3 ../../scripts/check-tones.py 16 48000 100 100
```

The trailing `100 100` are this project's base frequency and step. `check-tones.py` asserts that channel *k* carries tone *k*, and fails a channel that is merely silent - which is how the muted-LFE trap was caught in the first place.

## The OBS presets

Import the profile with **Profile > Import** and the scene collection with **Scene Collection > Import**, then change two things:

- the **URL** - it ships as `srt://<host>:8890?streamid=<your-name>&latency=2000000` and will not connect until you put your own host and name in it;
- the **video bitrate** if you are not sending roughly 4K equirect. 6000 kbit/s suits 4096x2048; lower resolutions need less.

The audio bitrate is deliberate: 384 kbit/s per 4-channel track is this project's contribution rule of 96 kbit/s per channel, the same rate the gateway and the test harness use. Everything downstream of the sender is either a copy or a higher-rate re-encode, so this is the one place quality is lost for good.

Two settings in the profile are correctness requirements rather than preferences, and the guides explain both: the **H.264 encoder** (the gateway republishes into FLV, which cannot carry MPEG-2 at all) and the **keyframe interval of 60** (both downstream hops copy video, so the sender's GOP sets the DASH segment boundaries).

## The atkAudio graph

Load it from the PluginHost2 window rather than wiring the nodes by hand; it skips steps 2.4 and 2.5 of the Windows guide, including the per-node **Configure Audio I/O → Discrete #4** setting that is the easiest thing to miss.

Check the device afterwards (**Options > Change Device Settings**): the graph stores the routing, but the device and sample rate should be confirmed against your own machine.
