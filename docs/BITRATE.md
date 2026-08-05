# Contribution bitrate: what to send, and why

Applies to whatever pushes into this stack (stock OBS over SRT, OBS Music Edition over RTMP, a script). The [main README](../README.md#bitrate) links here from the sender settings; the per-OS guides ([docs/obs-macos.md](obs-macos.md), [docs/obs-windows.md](obs-windows.md)) link here from their bitrate rows.

## Audio: 384 kbit/s per track

That is this project's contribution rule of 96 kbit/s per channel, and the published anchors sit below it - the classic AAC-LC transparency figure is ~64 kbit/s per channel (MPEG-2 AAC's 5.1-at-320 target), [EBU Tech 3324](https://tech.ebu.ch/publications/tech3324) calls 448 kbit/s for 5.1 (~75 per channel) "a safe choice" for any content, and [YouTube's ambisonic spec](https://support.google.com/youtube/answer/6395969) sets a 256 kbit/s floor for 4-channel AAC, again 64 per channel. Two reasons not to trim it: OBS uses ffmpeg's native AAC encoder, which is weaker than reference encoders at low rates, and **audio is paid once on your uplink, not per viewer** - it is re-encoded to Opus downstream, so a generous contribution rate costs your viewers nothing. Note there is no published transparency measurement for AAC-coded *higher-order* ambisonics, so treat 96/channel as a well-covered convention rather than a proven threshold.

## Video: the opposite situation - you pay per viewer, and published 360 guidance is high

[Meta's 360 spec](https://creator.oculus.com/media-studio/documentation/video-spec/) recommends **25-60 Mbit/s** (25 being the floor at its *minimum* 3840x1920), and [YouTube's live table](https://support.google.com/youtube/answer/2853702) gives 30 Mbit/s for 2160p30 H.264. 360 needs far more than flat video at the same nominal resolution because the viewer only ever sees a fraction of the sphere, so perceived quality is that of a small crop.

This deployment runs 4096x2048 at about **6.5 Mbit/s** - far below those figures, and a deliberate egress choice rather than a quality recommendation: with `-c:v copy` all the way through, the sender's bitrate is what every viewer receives, so 25 Mbit/s to 25 viewers is 625 Mbit/s sustained from one host. Pick against your uplink and your expected audience together, and expect visible softness on fine detail at the low end. The shipped presets use 6000 kbit/s for that reason; raise it if you have the headroom.
