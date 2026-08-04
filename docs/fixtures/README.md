# Test fixtures for the OBS recipes

Two small files that reproduce the exact setup the [macOS](../obs-macos.md) and [Windows](../obs-windows.md) guides were verified with. Both are plain text, self-contained, and carry no absolute paths.

| File | What it is |
|---|---|
| `AmbiX16ch_StreamTest.RPP` | A REAPER project: 16 mono tracks, each carrying one tone of a 100 → 1600 Hz ladder (100 Hz per step), each routed to its own hardware output 1-16. |
| `ReaRoute16ch-atkAudioPluginHost2.filtergraph` | The atkAudio PluginHost2 graph from the Windows guide: ReaRoute ASIO in, 16 channels wired to four "OBS Output" nodes of 4 channels each. Windows only. |

## The REAPER project

Open it and route the 16 hardware outputs at your end - ReaRoute on Windows, or your multichannel Core Audio device on macOS. The tones come from `synthesis/tonegenerator`, a **stock REAPER JS plugin**, so nothing needs installing.

One tone per channel is the whole point: it makes channel order and channel loss *visible* rather than a matter of opinion. Play it, capture at the far end, and run the check from either guide:

```bash
ffmpeg -v error -ss 5 -i merged.mov -map 0:a:0 -t 1.5 -f s16le -c:a pcm_s16le - \
  | python3 ../../scripts/check-tones.py 16 48000 100 100
```

The trailing `100 100` are this project's base frequency and step. `check-tones.py` asserts that channel *k* carries tone *k*, and fails a channel that is merely silent - which is how the muted-LFE trap was caught in the first place.

## The atkAudio graph

Load it from the PluginHost2 window rather than wiring the nodes by hand; it skips steps 2.4 and 2.5 of the Windows guide, including the per-node **Configure Audio I/O → Discrete #4** setting that is the easiest thing to miss.

Check the device afterwards (**Options > Change Device Settings**): the graph stores the routing, but the device and sample rate should be confirmed against your own machine.
