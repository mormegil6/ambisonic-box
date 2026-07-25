# tests/av-sync/ - browser A/V-sync measurement tools

Console-pasted instruments built during the DASH A/V-desync investigation
(measured for publication; the top-level README's Documentation section will carry the citation). Open the HOAST360 player page and paste
one of these into the browser console. They need the colour+tone A/V-sync clip
(generate it with `scripts/make-colortones.sh`) playing.

- **avmeter.js**: frequency-identified A/V-offset meter. Taps the HOAST360
  `masterGain`, identifies each beep's dominant frequency, then locates that
  tone inside the independently fetched + decoded DASH audio segments (Goertzel)
  and reports the median offset (positive = audio late). Alias-free: the
  *frequency*, not the event period, identifies each beep, so it cannot be fooled
  by a delay that equals the flash interval. Exposes `window.__avmeter2()`.

- **ratelab.js**: "rate-lab" probe of whether element `playbackRate`
  (`preservesPitch=false`) can drain the Chromium `MediaElementSource`+MSE audio
  delay, with a live A/V-offset readout from the flash/beep onset train.

- **inspect.js**: on-screen mobile console. Captures errors/rejections and
  samples the player's live `<video>` element into a WebGL overlay, for debugging
  on mobile where there is no console and the sphere may render black.

Superseded scratch (multiple `avmeter`/harness iterations, old player bundles,
throwaway test media) was left out; these three are the canonical tools.
