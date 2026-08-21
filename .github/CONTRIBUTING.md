# Contributing

Thanks for looking. This is a research project from a university department rather than a product, so the bar is "does it work and is it honest about what it does" rather than anything ceremonial.

## Where to file things

**GitHub is the canonical repository.** You may find a copy at `git.pg.edu.pl`; that is a mirror, it is pushed to automatically, and issues or merge requests opened there will not be seen. Everything happens here.

For security problems, do not open an issue. See [SECURITY.md](SECURITY.md).

## Getting it running

```bash
git clone https://github.com/mormegil6/ambisonic-box.git && cd ambisonic-box
git submodule update --init      # the patched HOAST360 player; nothing works without it
./scripts/setup.sh               # writes .env and generates YOUR OWN publish key
docker compose up -d --build
```

On Windows, run `.\setup.cmd` in place of `./scripts/setup.sh` (cmd.exe and PowerShell alike), and split the first line at the `&&`, which Windows PowerShell does not accept. `setup.cmd` is a launcher for that same `scripts/setup.sh` rather than a second implementation of it; the README's quick start has the detail.

Two things that catch people:

- **The submodule is not optional.** `hoast-player` builds from the repository root because it needs `hoast360/dist`. Skip `submodule update` and the build fails in a way that does not obviously say why.
- **`setup.sh` is not optional either.** `RTMP_OWNER_KEY` and `LOOP_SOURCE_KEY` are declared mandatory in `docker-compose.yml`, so without an `.env` compose refuses to create anything and says why on your terminal. With an `.env` that still carries the placeholders committed to this repository, `rtmp-ingest` refuses to start instead, because port 1935 is published on all interfaces and both values are public. Both errors name the fix.

You do not need media to start: with `DEMO_CONTENT=1` (the default) `loop-source` synthesises a spherical test loop in-container.

## Running the tests

```bash
./scripts/test-pipeline.sh                            # ~3 min, the documented smoke test
GUEST_ENABLED=1 ./scripts/test-guest-endpoint.sh      # ~14 min, ten full cycles plus nine cases
```

`test-pipeline.sh` is the one to run for almost any change. The guest suite is long and drives a live stack, so CI runs it nightly rather than per push; run it yourself if you touch the arbiter, the gateway, or anything in the guest path.

These scripts run on the maintainer's macOS machine as well as in CI, and macOS ships **bash 3.2**. Avoid `mapfile`/`readarray`, associative arrays and `${var,,}`: they are bash 4+, and `bash -n` will not catch them because a missing builtin fails at runtime.

## What CI will check

Five workflows, described in [docs/CI.md](../docs/CI.md). The ones most likely to surprise a first contribution:

- **shell, python and yaml must parse**, and `shellcheck` must be clean at error level.
- **Retired identifiers must not come back.** A rename in 2026 left stragglers behind three manual sweeps, so a gate now refuses them. It matches uses rather than mentions, so writing about an old name in a comment is fine.
- **The docs must agree with the code.** `docker-compose.yml`'s `FFMPEG_FLAGS` fallback is the single source of truth for video codec policy; README and `.env.example` must not contradict it. They drifted apart once and the shipped stack failed its own test as a result.
- **Base images must publish `linux/arm64`.** A Raspberry Pi 4 is a supported target, and an amd64-only base breaks it somewhere nobody would notice until the device.
- **Version metadata must agree.** `telemetry/VERSION` is what a running stack reports on `/api/live`, and `CITATION.cff` must say the same thing. Do not edit either by hand: `./scripts/set-version.sh` writes both, and the gate fails a push where they have drifted.

A docs-only change skips the expensive workflows.

## Things that are not ours to change

- **`services/earshot/src`** and **`hoast360/`** are both submodules - the first a fork of [Envelop Earshot](https://github.com/EnvelopSound/Earshot) (GPL-2.0), the second a fork of the HOAST360 player. Fixes go in the fork, not here: a PR against this repo can only bump the pinned commit, never edit source inside either directory. If upstream is unresponsive and a fix cannot wait, it lives in the fork, deliberately and recorded there.
- Check [docs/UPSTREAM.md](../docs/UPSTREAM.md) first. It lists what has already been reported or fixed upstream, in Earshot, HOAST360, and their dependencies, so you do not duplicate work that is already merged, open, or waiting on something outside this repo.

## Style

- Comments and commit messages explain **why**, not what. The code already says what. A comment that records the failure a line prevents is worth more than one restating it.
- If you find a comment or a document that is wrong, fix it in the same change. Stale prose is treated as a defect here, not as cosmetics, because someone eventually acts on it.
- Markdown is unwrapped: one line per paragraph, no manual line breaks.
- No em-dashes in shipped text.

## Licensing

Configuration and orchestration are Apache 2.0. The Earshot fork is GPL-2.0, the HOAST360 player is GPLv3, and the reference media clips are CC BY 4.0 with one documented exception. If a contribution mixes these, say so.
