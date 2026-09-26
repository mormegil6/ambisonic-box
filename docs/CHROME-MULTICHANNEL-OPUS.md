# Chrome: multichannel Opus failed to decode (DirectOpusAudioDecoding), fixed in Chrome 153

**Fixed.** Chrome 153.0.8010.36 and later decode multichannel Opus. If the player told you that your browser cannot decode multichannel audio and pointed you here, update Chrome and reload. No flag is needed on a current build.

Chrome 151 and 152 fail when the experiment is on, and 153.0.8010.36 is the first build measured clean with it on, so an earlier 153 build may fail too. If you cannot update, [the flag below](#if-you-cannot-update) restores decoding.

## What was measured

Sixteen-channel Opus through `decodeAudioData` and Media Source Extensions, with the experiment (`DirectOpusAudioDecoding`) in each state. "Forced" means the browser was launched with `--enable-features` or `--disable-features` for that feature, which overrides whatever the server-side rollout would have chosen. "Default" means the browser as launched: the 151 rows used a profile enrolled in the experiment, while the 152, 153 and 154 rows used a fresh profile with no server seed, which is not enrolled, so only their forced-on rows exercise the fix.

| Chrome build | OS | Experiment | 16-channel Opus | Measured |
|---|---|---|---|---|
| 151.0.7922.138 | macOS 15 | default (on) | fails | 2026-08-16 |
| 151.0.7922.138 | macOS 15 | forced off | decodes | 2026-08-16 |
| 152.0.7977.76 | macOS 15.7.9 | forced on | fails | 2026-09-14 |
| 152.0.7977.76 | macOS 15.7.9 | default, forced off | decodes | 2026-09-14 |
| 153.0.8010.36, stable | Ubuntu 26.04 | default, forced on, forced off | decodes | 2026-09-14 |
| 154.0.8037.58, stable | macOS 15.8 | default, forced on, forced off | decodes | 2026-09-26 |

Chromium's own testers confirmed the fix on Canary 154.0.8021.0 (2026-08-24), on Canary 153.0.8010.30 (2026-09-03, experiment enabled and disabled) and on Canary 156.0.8063.1 (2026-09-17, enabled and disabled). Stereo decoded in every row above, and Brave and Edge 151 decoded 16 channels unless the experiment was forced on.

**Check your own browser in one click:** https://mormegil6.github.io/opus-multichannel-repro/

That page decodes 1-channel, 2-channel and 16-channel Opus buffers and tells you which pass. If the 16-channel row fails while the 2-channel row passes, this page is about you.

## If you cannot update

For Chrome 151 and 152. Quit Chrome completely, then start it with the experiment turned off.

macOS:

    open -na "Google Chrome" --args --disable-features=DirectOpusAudioDecoding

Linux:

    google-chrome --disable-features=DirectOpusAudioDecoding

Windows (Run dialog):

    chrome.exe --disable-features=DirectOpusAudioDecoding

The flag only applies to browser instances launched that way, so a normal launch from the Dock, taskbar or Start menu will still be affected. To make it permanent, launch Chrome from a shortcut, alias or wrapper script carrying the flag. Or use Firefox, Brave or Edge.

## What was broken

`DirectOpusAudioDecoding` is a Chrome field trial, delivered through the variations seed rather than shipped in a release, and it was at `EnabledLaunch` (actively rolling out) when this was found on 2026-08-16. With it active, stereo Opus decoded normally and every channel count above 2 failed, in both decode paths a player can use: Web Audio's `decodeAudioData`, and Media Source Extensions playback, which failed at decoder initialisation with `DecoderStatus::Codes::kUnsupportedConfig`.

This player carries 16-channel Ambisonic audio, so on an affected Chrome there was no audio at all, and without the check that sent you here it presented as a stuck loading spinner rather than as an error. It was filed with Chromium as https://issues.chromium.org/issues/547065816, as a regression: decoding of Opus beyond 8 channels was added deliberately in M62, and this trial withdrew it. The fix is Chromium change [8266681](https://chromium-review.googlesource.com/c/chromium/src/+/8266681), which repairs the channel-mapping logic in `OpusAudioDecoder`.

The reproduction, the browser matrix (Chrome, Brave, Edge and Firefox, with the experiment forced both ways) and the method used to identify the responsible feature are in https://github.com/mormegil6/opus-multichannel-repro

## Why it was easy to misdiagnose

Every obvious isolation step failed to isolate it:

- **Incognito did not help.** An incognito window does not start a new browser process; it inherits the same variations seed.
- **A guest profile did not help**, for the same reason.
- **Quitting and restarting Chrome did not help.** The seed is persistent, in `Local State`.
- **`chrome://flags` does not list it.** The feature has no flags-UI entry, so searching there finds nothing.
- **Version numbers matched.** An unaffected Chrome and an affected one reported the same version, because the difference was the experiment, not the build.
- **Other Chromium browsers were fine, but not because they are immune.** Brave and Edge run their own variations service rather than Google's, so they were not enrolled. Forcing the experiment on made them fail identically.
- **Plain file playback could look fine.** Opening a multichannel `.webm` directly may show a demuxer initialising correctly in `chrome://media-internals` before anything fails.

Not every multichannel-Opus failure is this bug. A PICO 4 headset report on 2026-08-21 was first attributed to this field trial, and its `chrome://version` settled otherwise: Chromium 105.0.5195.68, a 2022 build that predates `DirectOpusAudioDecoding`, so the cause there is something else (an old or vendor-restricted Chromium whose multichannel Opus support is absent or limited). The symptom looks the same from the outside, so ask for `chrome://version` before concluding anything. On Chrome 151 or 152 this field trial is the likely cause. On Chrome 153.0.8010.36 or later, or on an old embedded Chromium, it is not.

## History

- 2026-08-16: found on Chrome 151 with the experiment active, and filed.
- 2026-08-21: the fix landed on Chromium `main`. It missed the M153 branch point by four days, and stable Chrome 151 was still broken.
- 2026-08-24: verified on Canary 154.0.8021.0.
- 2026-09-01: the M153 backport merged ([tracker 555381064](https://issues.chromium.org/issues/555381064)). On 2026-09-03 a Chromium tester confirmed it on Canary 153.0.8010.30.
- 2026-09-14: measured on shipped stable 153.0.8010.36 (Linux), clean in all three experiment states, while 152 still failed when forced on.
- 2026-09-15: a separate report of failing 1-channel Opus on the same tracker was traced to a different bug. A WebCodecs `AudioDecoder` configured with a sample rate other than 48 kHz reached libopus, which accepts only 8, 12, 16, 24 or 48 kHz; the earlier decoder ignored the requested rate and always decoded at 48 kHz, as RFC 7845 specifies. It was fixed by Chromium change [8408705](https://chromium-review.googlesource.com/c/chromium/src/+/8408705), landed on `main` on 2026-09-16. It does not affect Opus configured at 48 kHz, which is what this player uses.
- 2026-09-25: first measured on shipped stable 154.0.8037.58 (macOS), clean. Re-run and recorded on 2026-09-26 in all three experiment states.

## If it still fails on a current Chrome

The experiment is server-controlled, so on 151 and 152 it could be switched on or off for a given machine when the seed refreshed, and a browser that was fine one day could start failing without any update. On a build that carries the fix that no longer applies. If the 16-channel row of the check page fails on Chrome 153.0.8010.36 or later, the cause is not this experiment: check `chrome://version` and the failure text.

## Safari is a separate matter

Safari refuses this content for reasons unrelated to the experiment, and no Chrome flag changes that. On Safari 27.0 (macOS 15.8), `decodeAudioData` refuses every Opus WebM stream whose channel mapping family is not 0, including mono and stereo in other families, and WebCodecs refuses every stream above 2 channels, including plain 5.1 and 7.1. A family 0 stereo stream decodes. The player therefore decodes its 16-channel Opus in WebAssembly on Safari; [IOS-SAFARI.md](IOS-SAFARI.md) has the measurements and what that takes on iOS. The per-family, per-channel-count matrix is in https://github.com/mormegil6/safari-multichannel-opus-repro

WebKit bug [229325](https://bugs.webkit.org/show_bug.cgi?id=229325), multichannel WebM decoding, was fixed on 2026-03-05 and is listed in the [Safari Technology Preview 240 release notes](https://webkit.org/blog/17896/release-notes-for-safari-technology-preview-240/). The measurements above were made on a Safari 27.0 release build whose branch contains that fix, and the refusals described are still there.
