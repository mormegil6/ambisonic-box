# Chrome: multichannel Opus fails to decode (DirectOpusAudioDecoding)

**STATUS 2026-09-15: the 1-channel report was a separate, unrelated bug, root-caused and fixed. The retirement condition below may now actually be met for the >2-channel case this page is about.** [Tracker comment #18](https://issues.chromium.org/issues/547065816#comment18) explains comment #15 precisely: it is a WebCodecs `AudioDecoder` configured with a non-48 kHz `sampleRate`. The pre-fix `FFmpegAudioDecoder` path silently ignored the caller's sample rate and always ran Opus at 48 kHz, correctly, per RFC 7845; the new `OpusAudioDecoder` passed the caller's `sampleRate` straight into `opus_multistream_decoder_create()`, which accepts only 8, 12, 16, 24 or 48 kHz, so a non-48 kHz config fails outright. Fixed by CL [8408705](https://chromium-review.googlesource.com/c/chromium/src/+/8408705). This is a distinct root cause from the channel-mapping fault CL 8266681 fixed and this page has always been about; they only looked related because both throw from the same `isConfigSupported: true` then decode-fails shape. Nothing here uses non-48 kHz Opus, so it was never a risk to this project regardless of how it resolved.

What is worth acting on: the 2026-09-14 check below already measured the actual channel-mapping fix, not the sample-rate one, on genuine Chrome **stable** 153.0.8010.36 on Linux (installed from `dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb`, not Canary), and it was clean, forced on and off. The retirement test at the bottom of this page asks for exactly that: a shipped stable, not Canary, measured clean. That condition looks met now. Re-run the one-click check on that page yourself before actually retiring the workaround; this status line records the finding, not the decision.

STATUS 2026-09-14, kept for the timeline: A new report says the shipped M153 stable does not measure clean either, and a same-build, same-platform recheck could not reproduce it. A third-party commenter (bl...@gmail.com, tracker comment #15) reports the same symptom on Chrome 153 stable and on today's 155 Canary, on Linux, for 1-channel Opus: `isConfigSupported()` reports `supported: true`, then `configure()`/decode throws `OperationError: Unsupported configuration`. Fixed with the same `--disable-features=DirectOpusAudioDecoding` workaround this page already recommends. Checked twice, same day. First on macOS Chrome 152.0.7977.76 (a different platform and build from the report, so inconclusive either way): clean in all three field-trial states. Second, matching the report exactly - native Linux (Ubuntu 26.04), Chrome 153.0.8010.36, the identical build number named in the comment - also clean in all three states (default, `--enable-features=DirectOpusAudioDecoding` forced on, forced off), a synthetic mono Opus clip through WebCodecs, 101 frames decoded, no error, every run. That does not refute the report: a bare sine-tone clip may simply not hit whatever their real content does, and the commenter describes the failure as sporadic at earlier Chrome versions before becoming consistent at 153 for them, so a handful of clean runs here does not rule out something narrower than a blanket regression. It does weaken "universal regression on 153" as the explanation - identical build, identical platform, zero reproduction. One concrete gap worth naming regardless of either check: the 2026-09-03 Google verification below tested only the 2-channel and 16-channel rows, matching this project's own repro page: 1-channel Opus was never in the tested matrix, on Canary or otherwise, so a channel-count-dependent gap in the fix would not have been caught either way. This is exactly the case the retirement condition below was written for - do not retire the workaround or tell anyone to upgrade past this.

STATUS 2026-09-03, kept for the timeline: 547065816 is Verified (fixed on `main`, confirmed on Canary 154.0.8021.0 on 2026-08-24), and the M153 merge request [555381064](https://issues.chromium.org/issues/555381064) has moved past the branch-merge stage that closed it on 2026-09-01: a Google tester ran the standard verification steps on Canary 153.0.8010.30 (macOS 26.6.2) on 2026-09-03 and confirmed both the 2-channel and 16-channel Opus rows pass, with the field trial flag both enabled and disabled, and the tracker now carries `Merge: Merged-8010, Merged-153`. That is stronger evidence than the 2026-09-01 branch merge, but it is still Canary, not a shipped stable. An upcoming M153 stable respin should carry the fix, ahead of **M154 stable, 2026-09-22**. Re-check the tracker, and retire the `--disable-features=DirectOpusAudioDecoding` workaround only once a shipped stable is measured clean.

Earlier status, kept for the timeline (2026-08-21): Chromium CL [8266681](https://chromium-review.googlesource.com/c/chromium/src/+/8266681) landed on `main` at position 1683608 on 2026-08-21, marked `Fixed: 547065816`. It repairs the channel-mapping logic in `OpusAudioDecoder` and adds regression tests. It missed the M153 branch point (2026-08-17) by four days, so the first release expected to carry it is **M154, stable 2026-09-22**. Stable Chrome 151 was measured still broken on 2026-08-21.

RETIREMENT TEST, so this page does not outlive the bug: re-run the one-click check below on a build that carries the fix (an M153 stable respin that includes the 2026-09-01 backport, or M154 and later). If the 16-channel row passes with no flags, delete this document and the workaround it describes. The player's own capability gate needs no change either way, because it probes rather than checking version numbers.

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

**NOT EVERY multichannel-Opus failure is this bug, and we got that wrong once.** On 2026-08-21 a tester reported the failure on a PICO 4 headset, and it was initially attributed to this field trial. The device's `chrome://version` settled it: **Chromium 105.0.5195.68**, a 2022 build that predates `DirectOpusAudioDecoding` entirely, so the cause there is something else (an old or vendor-restricted Chromium whose multichannel Opus support is simply absent or limited). The symptom is identical from the outside, which is exactly why the version matters. Ask for `chrome://version` before concluding anything: on Chrome 151 through 153 this field trial is the likely cause, and on an old embedded Chromium it cannot be.


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

One point from that matrix belongs here, because it is not about Chrome: **Safari fails this content regardless**, including the stereo control, which is unrelated to this experiment. Multichannel WebM Opus decode has its own WebKit bug, [229325](https://bugs.webkit.org/show_bug.cgi?id=229325), and it did get a fix this year, shipped in [Safari Technology Preview 240](https://webkit.org/blog/17896/release-notes-for-safari-technology-preview-240/). That fix does not reach this content: re-tested live against this project's own clips on Safari 27.0 on 2026-08-17, both the 2-channel and the 16-channel buffer still fail to decode, on both `decodeAudioData` and MSE. General Opus-in-WebM support is separately still inconsistent per [238546](https://bugs.webkit.org/show_bug.cgi?id=238546), still open. No flag changes any of this.
