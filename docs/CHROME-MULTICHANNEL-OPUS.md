# Chrome: multichannel Opus fails to decode (DirectOpusAudioDecoding)

If the player told you that your Chrome cannot decode multichannel audio and pointed you here, this page explains what is happening and how to fix it.

Short version: it is not your machine, not the stream, and not a missing codec. Chrome is rolling out an experimental audio decoder that breaks Opus above 2 channels. Launching Chrome once with a flag restores it.

## The fix

Quit Chrome completely, then start it with the experiment turned off.

macOS:

    open -na "Google Chrome" --args --disable-features=DirectOpusAudioDecoding

Linux:

    google-chrome --disable-features=DirectOpusAudioDecoding

Windows (Run dialog):

    chrome.exe --disable-features=DirectOpusAudioDecoding

The flag only applies to browser instances launched that way, so a normal launch from the Dock, taskbar or Start menu will still be affected. To make it permanent, launch Chrome from a shortcut, alias or wrapper script carrying the flag.

Or just use a different browser. Firefox and Brave both play this content correctly.

## What is actually broken

`DirectOpusAudioDecoding` is a Chrome field trial, delivered through the variations seed rather than shipped in a release, and it was at `EnabledLaunch` (actively rolling out) when this was found on 2026-08-16. With it active:

- 2-channel (stereo) Opus decodes normally.
- Every channel count above 2 fails, verified at 16 channels (3rd-order Ambisonics) and 25 channels (4th-order).
- Both decode paths fail: Web Audio's `decodeAudioData`, and Media Source Extensions `appendBuffer` (which reports `DecoderStatus::Codes::kUnsupportedConfig`).

Because this player carries 16-channel Ambisonic audio, that means no audio at all, and without the check that sent you here it presents as a stuck loading spinner rather than as an error.

This is a browser bug. Nothing in the page can work around it, because feature flags are set in the browser process at launch and a web page cannot read or change them.

## What was measured

Same machine (macOS, arm64), same byte-identical files, decoded through `decodeAudioData`. `on` and `off` mean the experiment forced with `--enable-features=` or `--disable-features=DirectOpusAudioDecoding`; `default` means whatever that browser's own variations configuration decides.

| Browser | Version | Experiment | Stereo | 16-ch (3OA) | 25-ch (4OA) |
|---|---|---|---|---|---|
| Chrome | 151.0.7922.138 | default (**on**, `EnabledLaunch`) | pass | **fail** | **fail** |
| Chrome | 151.0.7922.138 | forced off | pass | pass | pass |
| Brave | 151.1.93.136 | default (**off**, not enrolled) | pass | pass | pass |
| Brave | 151.1.93.136 | forced on | pass | **fail** | **fail** |
| Edge | 151.0.4129.86 | default (**off**, not enrolled) | pass | pass | pass |
| Edge | 151.0.4129.86 | forced on | pass | **fail** | **fail** |
| Firefox | 153.0.4 | not applicable | pass | pass | pass |
| Safari | 27.0 (20625.1.22.18.2) | not applicable | **fail** | **fail** | **fail** |

Three things follow from that table.

The experiment is the whole story on Chromium: every Chromium browser tested passes with it off and fails with it on, so Brave and Edge are safe today by enrolment rather than by being built differently. Chrome itself is not defective, it is simply the one enrolled.

Stereo always survives, which is why the failure is so confusing in practice: audio-capable test pages, stereo streams and ordinary video all keep working while this player does not.

Safari fails everything, including the stereo control. That is unrelated to this experiment. It is WebKit's long-standing trouble with Opus in WebM (webkit.org bugs 238546, 245428, 226922), and no flag changes it.

## Why it is easy to misdiagnose

Every obvious isolation step fails to isolate it:

- **Incognito does not help.** An incognito window does not start a new browser process; it inherits the same variations seed.
- **A guest profile does not help**, for the same reason.
- **Quitting and restarting Chrome does not help.** The seed is persistent, in `Local State`.
- **Version numbers match.** An unaffected Chrome and an affected one report the same version, because the difference is the experiment, not the build.
- **Other Chromium browsers are fine, but not because they are immune.** Brave and Edge run their own variations service rather than Google's, so they are simply not enrolled. Force the experiment on and they fail identically, as the table above shows. Switching browsers works today because of how they are enrolled, not because they are built differently.
- **`chrome://flags` does not list it.** The feature has no flags-UI entry, so searching there finds nothing.
- **Plain file playback can look fine.** Opening a multichannel `.webm` directly may show a demuxer initialising correctly in `chrome://media-internals` before anything fails.

## How it was identified

1. `chrome://media-internals` showed the demuxer accepting a 16-channel Opus stream cleanly (`FFmpegDemuxer ... channel_layout: DISCRETE, channels: 16`), ruling out the file and the container.
2. The same Chrome binary, launched with a fresh profile, decoded 2, 16 and 25 channels correctly, ruling out the build.
3. Copying only the `variations*` keys out of the real `Local State` into an otherwise clean profile reproduced the failure exactly, which located the cause in the variations seed. (Copying the whole file instead makes Chrome show a profile picker.)
4. `chrome://version/?show-variations-cmd` lists the active experiments by name rather than by hash. Two looked audio-related: `DirectOpusAudioDecoding` and `EnableHighChannelLayouts`.
5. Force-enabling each one individually on a clean profile identified `DirectOpusAudioDecoding` as the cause and cleared `EnableHighChannelLayouts`. `SymphoniaAudioDecoding`, which appears in `chrome://media-internals` logs and looks suspicious, is also not the cause.
6. `--disable-features=DirectOpusAudioDecoding` restores correct decoding with the same seed still in place.

7. Forcing the same feature on in Brave and in Edge reproduces the identical failure there, which places the bug in Chromium rather than in Chrome's packaging of it.

Measured on macOS, arm64: Chrome 151.0.7922.138, Brave 151.1.93.136, Edge 151.0.4129.86, Firefox 153.0.4. Firefox was unaffected throughout and has no such experiment. Safari 27.0 fails on Opus in WebM regardless, including stereo, which is a separate and long-standing WebKit limitation.

## If it stops reproducing

The experiment is server-controlled, so it can be switched off (or on) for a given machine when the seed refreshes. A browser that is affected today may recover on its own, and one that is fine today may start failing later without any update.
