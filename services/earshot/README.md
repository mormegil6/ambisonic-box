# earshot - submodule of a fork of Envelop Earshot

`src/` is a git submodule pointing at [mormegil6/Earshot](https://github.com/mormegil6/Earshot), a fork of [EnvelopSound/Earshot](https://github.com/EnvelopSound/Earshot), GPL licensed (see `src/LICENSE`).

It was a hand-vendored copy until 2026-08-18. Vendoring existed only because there was no push access to Earshot until 2026-08-08; once maintainer status was live, the reason for vendoring was gone and the fork+submodule pattern already proven by `hoast360` (see the top-level `.gitmodules`) applied equally here: fix in the fork, bump the pointer, no `branch =` pin. One concrete cost of the vendored years is now gone too - the ~180 Dependabot alerts attached to `webtools/yarn.lock` (a 2020 npm tree on a `node:12` base) no longer show up in this repo's own Security tab, since submodule content isn't part of this repo's dependency graph. They didn't vanish; they moved to the fork, which is where they're actually actionable.

## Relationship to upstream

The fork tracks `EnvelopSound/Earshot`'s `master` directly (real GitHub fork relationship, `git fetch origin && git merge --ff-only origin/master` when catching up, same as any fork). General-purpose fixes are contributed upstream as PRs from the fork's own branches; the full history of what was sent where and its current status (merged / open / not yet upstreamable) is tracked centrally in [docs/UPSTREAM.md](../../docs/UPSTREAM.md), not duplicated here.

## What's still genuinely local to the fork

Everything that has no upstream analogue lives directly in the fork's own commit history, with the rationale in the code itself (each patch carries a comment explaining the WHY, often with real measurements) rather than repeated here. As of the fork's `8b0b267`:

| file | what, briefly |
|---|---|
| `Dockerfile` | SPD-floor guard (`DASH_SPD_FLOOR`, anchored `sed` into `dashenc.c`), `socat`, the `direct-dash-gate.sh` `COPY` |
| `nginx-transcoder/nginx.conf` / `nginx-no-ssl.conf` | `wait_key`/`wait_video` A/V-sync fix, `$name`/`${DASH_NAME}` path-safety split, `-b:a 1024k`, `dashName` in `/nginxInfo` |
| `nginx-transcoder/entrypoint.sh` | the SRT direct-DASH listener block (~150 lines: `socat` gate on `:9100`/`:9101`, `JOIN_MAP` derivation, the log-permission workaround) - this deployment's owner-SRT route bypasses RTMP entirely, which stock Earshot has no model for at all |
| `nginx-transcoder/direct-dash-gate.sh` | new file: the peer-IP admission gate for the two direct-DASH listeners |
| `webtools/src/Webtools.js` | `probeDirectStream()` and the `dashName`/`directStream` state pair - the client half of the same direct-DASH detection |
| `webtools/src/GainSliderBox.js` | one kept comment (measured RMS numbers for the AudioContext-suspend fix); the fix itself is upstream via #64 |

None of the above is upstreamable on its own terms: the SRT direct-DASH feature is architecture specific to this deployment, not a generic Earshot fix.

## What this service does in the stack

nginx-rtmp accepts the relayed stream from `rtmp-ingest` on :1935 (internal only) and `exec`s Envelop's PCE-aware ffmpeg fork per published stream:

```
ffmpeg -analyzeduration 10M -i rtmp://127.0.0.1/live/$name \
  -strict -2 -c:a libopus -mapping_family 255 -b:a 1024k ${FFMPEG_FLAGS} \
  -f dash /opt/data/dash/${DASH_NAME}.mpd
```

That is the line as it stands in `src/nginx-transcoder/nginx-no-ssl.conf`, which is the canonical copy: read the rationale for `-b:a 1024k` and for keeping `$name` on `-i` only in the comment block directly above it in that file rather than here. `nginx.conf` (the `SSL_ENABLED=true` variant) must carry the identical exec line, so diff the two whenever either changes: if they drift, an SSL deployment runs an audio configuration nothing has tested.

16-channel Opus is hardcoded upstream; the video codec policy comes from the `FFMPEG_FLAGS` env var (see `.env.example` at the repo root - `-c:v copy` passthrough by default, VP9 realtime documented as the opt-in codec policy). The live MPEG-DASH segmentation happens *here*, not in the shaka service (shaka cannot ingest a 16-channel live stream and is a `tools`-profile utility for VOD packaging only).

HTTP :80 (mapped to host :8081 in dev) serves the webtools monitoring UI at `/webtools`, `rtmp_stat` at `/stat`, a health endpoint at `/` and the raw DASH output at `/dash` (the player normally serves it from the shared volume instead).
