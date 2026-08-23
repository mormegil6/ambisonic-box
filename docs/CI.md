# CI (GitHub Actions)

> **This repository's source of truth is GitHub, and git.pg.edu.pl is the mirror.**
> That is the OPPOSITE of the maintainer's other repositories, which are all GitLab -> GitHub. It is deliberate; the reasoning is in [Why this one is backwards](#why-this-one-is-backwards-github-to-gitlab-not-the-reverse-2026-08-10) at the end of this file.

Six quality workflows plus two that copy things to GitLab, on GitHub Actions rather than on [git.pg.edu.pl](https://git.pg.edu.pl/p829296/ambisonic-box): that instance has **no CI runner available to this project**, proven on 2026-08-09 by enabling CI/CD and watching two real pipelines sit `pending` with `runner: None` until they were cancelled. GitLab's own Secret Detection template behaved identically, which is the answer for every GitLab scanner at once - on self-managed GitLab a security scan is just another CI job, and it needs the same runner nothing here has.

Pushes land on GitHub and Actions runs immediately; a separate workflow copies `main` and tags on to GitLab afterwards. (Until 2026-08-10 this ran the other way round - see the last section.)

A docs-only push (`**.md`, `docs/**`, `LICENSE`) skips `build`, `integration` and `security` entirely - prose cannot break an image, and the point is to not spend six minutes, or a notification email, on a typo fix. `hygiene` still runs on everything, because it is the workflow that checks the docs.

| workflow | when | roughly |
|---|---|---|
| `hygiene` | every push and PR, and on `v*` tags | 20 s |
| `build` | every push and PR | 6 min cold, seconds warm |
| `integration` | PRs, `main`, nightly 04:20 UTC | 3 min (guest suite ~17 min, nightly only) |
| `security` | pushes, PRs, Mondays | 6 min |
| `arm64` | Dockerfile/compose changes, Mondays | up to 90 min under emulation |
| `ghcr-publish` | `v*` tags, and manual dispatch | 1h30m cold, minutes warm |

## Why each check exists

Nothing here is generic. Every check traces to a mistake this project actually made, named below with the check that now catches it.

**hygiene** - shell/python/yaml parse, `shellcheck`, `docker compose config`, and three consistency gates. The vocabulary gate refuses retired identifiers (`LIVE_APP_KEY`, `/rtmp/live/`, `rtmp-ingest`'s old `:1935/live`) because the 2026-08-09 rename took three manual sweeps and still left references behind. It matches *uses* rather than mentions, so a comment explaining the rename is allowed. The docs gate asserts [`docker-compose.yml`](../docker-compose.yml)'s `FFMPEG_FLAGS` fallback still agrees with README and [`.env.example`](../.env.example), which drifted apart once and made the shipped stack fail its own test, and that the placeholder owner key is never presented as a credential to type. The version gate is described under [Versions and releases](#versions-and-releases) below.

**arm64** - builds the four light images for `linux/arm64` under QEMU, weekly and on any change to how images are built. `earshot` is excluded because emulating its ffmpeg compile takes hours and the Pi builds it natively anyway. It catches an amd64-only dependency or a package with no arm64 build; it says nothing about runtime behaviour, thermals or speed, which need the actual device. The cheaper `arm64-bases` job in [`hygiene.yml`](../.github/workflows/hygiene.yml) covers `earshot` instead - it checks manifests rather than building, seconds instead of hours - and its checkout needs `submodules: recursive` for that check to see `services/earshot/src/Dockerfile` at all; without it, the job silently checks zero `FROM` lines there instead of failing (found and fixed 2026-08-18, the day the submodule swap landed).

**build** - `docker buildx bake` straight from [`docker-compose.yml`](../docker-compose.yml), so build contexts cannot drift from the ones compose uses (a hand-written matrix got `hoast-player` wrong immediately: its context is the repo root, for the player submodule). Then two regression tests: `earshot`'s ffmpeg must not carry `--enable-nonfree`, or published images stop being redistributable; and `rtmp-ingest` must still **refuse to start** on the committed placeholder owner key, with the documented `ALLOW_DEFAULT_OWNER_KEY=1` escape still warning.

**integration** - the two real suites. [`test-pipeline.sh`](../scripts/test-pipeline.sh) on every PR; [`test-guest-endpoint.sh`](../scripts/test-guest-endpoint.sh) nightly and on demand, because it takes about 17 minutes and a slow gate gets ignored. CI runs [`scripts/setup.sh`](../scripts/setup.sh) to generate a real key, which also exercises the happy path of the startup guard.

The `defaults` job inside it installs with [`scripts/setup.sh`](../scripts/setup.sh) and starts the stack exactly as a first-time user would, which means it pulls the published images at the tag `PIN_TAG` names. That tag is bumped by `ghcr-publish` after a release's images exist, not by the release commit: bumping it earlier made every release fail this job until the build finished, because the tree advertised images that were still being built. If you see `manifest unknown` here, check whether a release is mid-publish before looking anywhere else.

**security** - gitleaks over full history. Note the trigger matters: on a `push` the action scans only that push's commits, so the FULL-history scan happens on the Monday schedule. The first one (2026-08-10) flagged Earshot's vendored placeholder TLS cert, which is a self-signed example with OpenSSL's default dummy subject, expired since 2019, and byte-identical to upstream. It is silenced by fingerprint in `.gitleaksignore` rather than by excluding a path, so a genuinely new key anywhere still fails. Gitleaks over full history (this repo carries placeholder credentials by design, so a full-history scan is expected to surface them), Trivy on the four images this project controls, and CodeQL. `earshot` is scanned but **report-only**, and the reason is worth stating correctly: its *runtime* image is `alpine:3.11` with `nginx 1.15.1`, not the `node:24-alpine3.24` build stage, which contributes only static files. Alpine 3.11 has been end-of-life since November 2021, so `ignore-unfixed: true` on a distribution whose security data has stopped means this scan reports close to nothing - moving it forward means changing the base in Earshot itself and proving the nginx-rtmp build still works on both architectures, which is a project rather than a scan fix, and failing the job in the meantime would train everyone to ignore the job. [SECURITY.md](../.github/SECURITY.md) says the same thing where a reporter will see it.

## Scope rule

Both submodules (`services/earshot/src`, a fork of Earshot; `hoast360`, the patched player) are read here, not maintained here - fixes belong in the fork/upstream, not as local restyling. `git ls-files`-based tooling (shellcheck's file list) never sees submodule content regardless of checkout config, so no exclusion is needed there. CodeQL still carries an explicit `paths-ignore` for both ([`.github/codeql-config.yml`](../.github/codeql-config.yml)) as insurance against that changing, even though neither this job's checkout nor CodeQL's own scan currently initializes submodules either. Trivy still reports on `earshot` without gating - that one is about the *base image* being EOL (alpine:3.11), unrelated to how the source is carried, so vendored-vs-submodule never changed it. Until 2026-08-18 `earshot` was vendored rather than submoduled (write access to Earshot was the blocker); see [`services/earshot/README.md`](../services/earshot/README.md) for what that move changed. Alerts nobody can act on are worse than no alerts.

## Honest limits

None of these would have caught the bugs found by hand on 2026-08-09 - a misnested CSV write, two test assertions that passed while testing nothing, 41 stale comments. Secret scanning in particular finds committed secrets, not a placeholder *documented* as the default; the hygiene workflow's own check covers that case, and it exists because README once printed that placeholder as the stream key to type.

Per-push builds are amd64 only, and the weekly `arm64` workflow covers four of the five images under emulation - `earshot` is excluded there because emulating its ffmpeg compile takes hours. Multi-arch `earshot` is built on the release cadence instead: `ghcr-publish` runs on a `v*` tag and builds all five images for `linux/amd64,linux/arm64`, `earshot` included, verifying each architecture's ffmpeg is free of `--enable-nonfree` before anything is pushed. Measured 2026-08-21, cold cache: the dual-arch `earshot` job took 1h27m against the hosted-runner ceiling of six hours.

Emulated timings are meaningless, so nothing in CI says anything about performance. The Raspberry Pi 4 numbers that matter (thermals, sustained transcode CPU, and how long a guest handover really takes) can only come from the device - and as of 2026-08-10 they exist: build 19m38s, peak 71.0 C, never throttled, handover 0.5 s median and 1.0 s worst against a 4 s budget.

The recommended contribution route WAS the one thing CI did not touch, which was backwards. Until 2026-08-10 `integration` drove RTMP only, so an SRT or direct-to-DASH regression would have left every job green. Both suites now run on every push and PR: [`test-direct-session.sh`](../scripts/test-direct-session.sh) (the session protocol, no media) and [`test-srt-ingest.sh`](../scripts/test-srt-ingest.sh) (a real SRT push, its caller running inside the compose network so the runner needs no libsrt ffmpeg). What is still hand-certified rather than gated: the browser player, whose worst bug to date passed headless and failed only on real GPU browsers, so a headless check would not catch the class it most wants to.

## Versions and releases

A running stack reports its version on `/api/live`, which the dashboard and the player show and which the bug report form asks reporters for. That number comes from [`telemetry/VERSION`](../telemetry/VERSION), baked into the image at build time. An `AMBI_VERSION` environment variable overrides it for `git describe` precision, but it is deliberately not the primary: set once by hand it freezes into the container and goes stale, which is exactly what happened within a day of it being introduced.

So the file is primary, and two things keep it honest:

- **`./scripts/set-version.sh <version>`** writes `telemetry/VERSION` and [`CITATION.cff`](../CITATION.cff) together. `X.Y.Z` means a release and stamps today's date; `X.Y.Z-dev` means the tree has moved past the release named by `date-released` and has not itself been released, and leaves that date alone.
- **The `version metadata agrees` gate** fails a push where the two files disagree, where the version is not semver-shaped, where `date-released` is not an ISO date, or where a `v*` tag does not match what the tree says. It also refuses a tag carrying a `-dev` version, because that would ship a stack reporting a version that was never cut. On a branch it prints a reminder instead of failing, since `git push origin main v1.0.0` runs it on both refs.

`integration` then proves the part that reaches a user, `telemetry/VERSION` to `/api/live`, with `AMBI_VERSION` unset so it exercises the fallback a real deployment uses.

Cutting one:

```
./scripts/set-version.sh 1.0.0
git commit -am "Release 1.0.0"
git tag -a v1.0.0 -m v1.0.0
git push origin main v1.0.0
./scripts/set-version.sh 1.0.1-dev && git commit -am "Back to development on 1.0.1-dev" && git push
```

The tag push is what publishes: `ghcr-publish` builds all five images for both architectures and tags them `v1.0.0` and `latest`, and [`set-version.sh`](../scripts/set-version.sh) has already moved [`scripts/setup.sh`](../scripts/setup.sh)'s `PIN_TAG` to the new release, so a fresh install pulls it. A GitHub release created on that tag is copied to GitLab by `release to gitlab`; the assets are not, deliberately.

Publishing a GitHub release from that tag also fires `release to gitlab`, which copies the release metadata but deliberately not the assets.


## Why this one is backwards: GitHub to GitLab, not the reverse (2026-08-10)

Every other repository of this maintainer's is GitLab-canonical, push-mirrored to GitHub. This one is the exception, and the exception is deliberate:

- **Contributions arrive on GitHub.** Outside contributors cannot realistically obtain accounts on a university GitLab, so pull requests will land here. Under the old direction that was a trap rather than a workflow: the GitLab mirror ran with `keep_divergent_refs=false`, so GitLab force-updated GitHub and anything merged here was silently reverted on the next push. The Merge button appeared to work and then quietly undid itself.
- **CI runs here.** The GitLab instance has no runner available to this project (evidence at the top of this page), so every gate lives on GitHub regardless of where the canonical copy is.
- **Reversing the mirror on GitLab's side is not possible here.** Pull mirroring is a Premium feature and this instance is Community Edition (`enterprise: false`, 16.11). GitLab cannot pull from GitHub, so if GitHub is to be canonical, GitHub must push - which is what [`.github/workflows/mirror-to-gitlab.yml`](../.github/workflows/mirror-to-gitlab.yml) does.

Practical consequences:

- Push to **GitHub**. `git push origin main` should reach GitHub; the mirror workflow copies `main` and tags to GitLab within a minute.
- The GitLab copy is **read-only in practice**. Pushing there directly will be overwritten by the next mirror run, and the two will disagree until then.
- Auth for the mirror is a GitLab **deploy key** scoped to this one project with push rights, not a personal token. The private half is the `GITLAB_MIRROR_SSH_KEY` GitHub secret.
- The old GitLab -> GitHub mirror was **disabled, not deleted**. To revert: re-enable it in the GitLab project's Repository Settings and delete the mirror workflow.
- The mirror pushes `main` and tags only, deliberately not `--mirror`: nothing should copy `dependabot/*` branches into the university instance, and `--mirror` would also delete GitLab refs that do not exist on GitHub.
