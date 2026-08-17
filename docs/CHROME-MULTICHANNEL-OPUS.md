# Chrome: multichannel Opus fails to decode (DirectOpusAudioDecoding)

If the player told you that your browser cannot decode multichannel audio and pointed you here, this page explains what is happening and how to fix it.

Short version: it is not your machine, not the stream, and not a missing codec. Chrome is rolling out an experimental audio decoder that breaks Opus above 2 channels. Launching Chrome once with a flag restores it.

**Check your own browser in one click:** https://mormegil6.github.io/opus-multichannel-repro/

That page decodes a 2-channel and a 16-channel Opus buffer and tells you whether yours is affected. If the 16-channel row fails while the 2-channel row passes, this page is about you.

## The fix

Quit Chrome completely, then start it with the experiment turned off.

macOS:

    open -na "Google Chrome" --args --disable-features=DirectOpusAudioDecoding

Linux:

    google-chrome --disable-features=DirectOpusAudioDecoding

Windows (Run dialog):

    chrome.exe --disable-features=DirectOpusAudioDecoding

The flag only applies to browser instances launched that way, so a normal launch from the Dock, taskbar or Start menu will still be affected. To make it permanent, launch Chrome from a shortcut, alias or wrapper script carrying the flag.

Or just use a different browser. Firefox, Brave and Edge all play this content correctly today.

## What is actually broken

`DirectOpusAudioDecoding` is a Chrome field trial, delivered through the variations seed rather than shipped in a release, and it was at `EnabledLaunch` (actively rolling out) when this was found on 2026-08-16. With it active, stereo Opus decodes normally and every channel count above 2 fails, in both decode paths a player can use: Web Audio's `decodeAudioData`, and Media Source Extensions playback, which fails at decoder initialisation with `DecoderStatus::Codes::kUnsupportedConfig`.

Because this player carries 16-channel Ambisonic audio, that means no audio at all, and without the check that sent you here it presents as a stuck loading spinner rather than as an error.

This is a browser bug. Nothing in the page can work around it, because feature flags are set in the browser process at launch and a web page cannot read or change them.

## Why it is easy to misdiagnose

Every obvious isolation step fails to isolate it, which is worth knowing before you spend an evening on it:

- **Incognito does not help.** An incognito window does not start a new browser process; it inherits the same variations seed.
- **A guest profile does not help**, for the same reason.
- **Quitting and restarting Chrome does not help.** The seed is persistent, in `Local State`.
- **`chrome://flags` does not list it.** The feature has no flags-UI entry, so searching there finds nothing.
- **Version numbers match.** An unaffected Chrome and an affected one report the same version, because the difference is the experiment, not the build.
- **Other Chromium browsers are fine, but not because they are immune.** Brave and Edge run their own variations service rather than Google's, so they are simply not enrolled. Force the experiment on and they fail identically.
- **Plain file playback can look fine.** Opening a multichannel `.webm` directly may show a demuxer initialising correctly in `chrome://media-internals` before anything fails.

## If it stops reproducing

The experiment is server-controlled, so it can be switched off (or on) for a given machine when the seed refreshes. A browser that is affected today may recover on its own, and one that is fine today may start failing later without any update.

## Evidence, and the bug report

The reproduction, the full browser matrix (Chrome, Brave, Edge and Firefox, with the experiment forced both ways) and the method used to identify the responsible feature all live with the reproduction rather than being repeated here:

https://github.com/mormegil6/opus-multichannel-repro

It is filed with Chromium as https://issues.chromium.org/issues/547065816, as a regression: decoding of Opus beyond 8 channels was added deliberately in M62, and this trial withdraws it.

One point from that matrix belongs here, because it is not about Chrome: **Safari fails this content regardless**, including the stereo control, which is unrelated to this experiment and is instead WebKit's long-standing trouble with Opus in WebM (webkit.org bugs 238546, 245428, 226922). No flag changes that one.
