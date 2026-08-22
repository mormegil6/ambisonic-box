# Test fixtures for the OBS recipes

Two small files that reproduce the exact setup the [macOS](../obs-macos.md) and [Windows](../obs-windows.md) guides were verified with. Both are plain text, self-contained, and carry no absolute paths.

| File | What it is |
|---|---|
| [`AmbiX16ch_StreamTest-Mac.RPP`](AmbiX16ch_StreamTest-Mac.RPP) / [`-Win.RPP`](AmbiX16ch_StreamTest-Win.RPP) | A REAPER project, one per platform - the hardware-output routing differs (a multichannel Core Audio device on macOS, ReaRoute on Windows), so they are not interchangeable. Otherwise identical: sixteen mono tracks, `ACN-00` to `ACN-15`, each sent into its own channel of a 16-channel `3OA` bus, and that bus alone carries the hardware output. Each child carries one tone of a 100 → 1600 Hz ladder (100 Hz per step) at its own level, so both channel order and channel loss are visible. |
| [`obs-macos-blackhole.json`](obs-macos-blackhole.json) | OBS **scene collection** for macOS: four Audio Input Capture sources on BlackHole 16ch, channels 1-4 / 5-8 / 9-12 / 13-16, one per track. |
| [`obs-windows-atkaudio.json`](obs-windows-atkaudio.json) | OBS **scene collection** for Windows: the atkAudio Source Mixer host plus the four `Ph2Out` sources it produces, one per track. |
| `obs-macos-profile/` | OBS **profile** for macOS: Advanced output, Custom Output (FFmpeg) to an SRT URL, mpegts, `h264_videotoolbox`, keyframe interval 60, `aac` at 384 kbit/s, tracks 1-4, Channels 4.0. |
| `obs-windows-profile/` | OBS **profile** for Windows: as the macOS one but with `libx264`, since `h264_videotoolbox` is Apple-only. |
| [`ReaRoute16ch-atkAudioPluginHost2.filtergraph`](ReaRoute16ch-atkAudioPluginHost2.filtergraph) | The atkAudio PluginHost2 graph from the Windows guide: ReaRoute ASIO in, 16 channels wired to four "OBS Output" nodes of 4 channels each. Windows only. |

## The REAPER projects

Open the one for your platform. They differ only in where the bus's single 16-channel hardware output goes - ReaRoute on Windows, your multichannel Core Audio device on macOS - but that routing is stored in the project, so the wrong one will look correct and feed nothing. The tones come from `synthesis/tonegenerator`, a **stock REAPER JS plugin**, so nothing needs installing.

One tone per channel is the whole point: it makes channel order and channel loss *visible* rather than a matter of opinion. Play it, capture at the far end, and run the check from either guide:

```bash
ffmpeg -v error -ss 5 -i merged.mov -map 0:a:0 -t 1.5 -f s16le -c:a pcm_s16le - \
  | python3 ../../scripts/check-tones.py 16 48000 100 100
```

The trailing `100 100` are this project's base frequency and step. [`check-tones.py`](../../scripts/check-tones.py) asserts that channel *k* carries tone *k*, and fails a channel that is merely silent - which is how the muted-LFE trap was caught in the first place.

## The OBS presets

> The three recording-path settings OBS stores (`FFFilePath`, `FilePath`, `RecFilePath`) ship empty. OBS will ask you for a recording location the first time it needs one; this recipe streams to a URL rather than to a file, so none of them affects it.
>
> *Updating these fixtures?* They are exported from a real machine, so check those same three keys came back empty before committing.


Import the profile with **Profile > Import** and the scene collection with **Scene Collection > Import**, then change two things:

- the **URL** - it ships pointed at the OWNER route as `srt://127.0.0.1:8891?streamid=owner&passphrase=<SRT_OWNER_PASSPHRASE>&latency=2000000&pkt_size=1128`, which is the authenticated one for your own broadcasts. Run [`./scripts/setup.sh`](../../scripts/setup.sh) on the box and it prints this line with your real passphrase already in it. It ships as `127.0.0.1` so that an import connects straight away when OBS runs on the box; swap in whatever address reaches the box when it does not. A bare placeholder would look tidier, but it cannot connect, and the resulting error looks like a broken stack rather than a URL you still have to fill in. For the keyless guest endpoint instead, the URL becomes `srt://<box>:8890?streamid=<any-name>&latency=2000000&pkt_size=1128` and needs `GUEST_ENABLED=1`;
- the **video bitrate** - both profiles ship 6000 kbit/s. That is a choice about egress rather than a match to any resolution: published 360 guidance for the 4096x2048 this deployment sends is several times higher, and [`docs/BITRATE.md`](../BITRATE.md) sets out why it sends less anyway, and when to raise it.

The audio bitrate is deliberate: 384 kbit/s per 4-channel track is this project's contribution rule of 96 kbit/s per channel, the same rate the gateway and the test harness use. Everything downstream of the sender is either a copy or a higher-rate re-encode, so this is the one place quality is lost for good.

Two settings in the profile are correctness requirements rather than preferences, and the guides explain both: the **H.264 encoder** (`earshot` copies the sender's video straight into the DASH segments, and the player needs `avc1`; on the legacy routes - `SRT_DIRECT=0` or guest RTMP - the FLV hop rules out anything else as well) and the **keyframe interval of 60 frames** (2 s at the profile's 30 fps; the field counts frames, not seconds). Nothing downstream re-encodes video, so the sender's GOP alone decides where the DASH segments are cut: `earshot`'s `-seg_duration 2` is a floor rather than a target, and the muxer closes each segment at the first keyframe at or after it. A sender GOP longer than 2 s stretches the video segments while audio stays at 2 s.

## The atkAudio graph

Load it from the PluginHost2 window rather than wiring the nodes by hand; it skips the node wiring in section 3 of the Windows guide, including the per-node **Configure Audio I/O > Discrete #4** setting that is the easiest thing to miss.

Check the device afterwards (**Options > Change Device Settings**): the graph stores the routing, but the device and sample rate should be confirmed against your own machine.
