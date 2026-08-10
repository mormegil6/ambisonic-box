# CI (GitHub Actions)

Four workflows, on GitHub Actions. Not on GitLab, despite git.pg.edu.pl being this project's source of truth: that instance has **no CI runner available to this project**, proven on 2026-08-09 by enabling CI/CD and watching two real pipelines sit `pending` with `runner: None` until they were cancelled. GitLab's own Secret Detection template behaved identically, which is the answer for every GitLab scanner at once - on self-managed GitLab a security scan is just another CI job, and it needs the same runner nothing here has.

GitLab push-mirrors every branch to GitHub within seconds, so a push to GitLab arrives here and Actions runs. There is no private branch: `only_protected_branches` is false on the mirror.

| workflow | when | roughly |
|---|---|---|
| `hygiene` | every push and PR | 20 s |
| `build` | every push and PR | 6 min cold, seconds warm |
| `integration` | PRs, `main`, nightly 04:20 UTC | 3 min (guest suite ~17 min, nightly only) |
| `security` | pushes, PRs, Mondays | 6 min |

## Why each check exists

Nothing here is generic. Every check traces to a mistake this project actually made; the CI section of the deployment repo's `PLAN.md` records which incident each one comes from.

**hygiene** - shell/python/yaml parse, `shellcheck`, `docker compose config`, and two consistency gates. The vocabulary gate refuses retired identifiers (`LIVE_APP_KEY`, `/rtmp/live/`, rtmp-ingest's old `:1935/live`) because the 2026-08-09 rename took three manual sweeps and still left references behind. It matches *uses* rather than mentions, so a comment explaining the rename is allowed. The docs gate asserts `docker-compose.yml`'s `FFMPEG_FLAGS` fallback still agrees with README and `.env.example`, which drifted apart once and made the shipped stack fail its own test, and that the placeholder owner key is never presented as a credential to type.

**build** - `docker buildx bake` straight from `docker-compose.yml`, so build contexts cannot drift from the ones compose uses (a hand-written matrix got `hoast-player` wrong immediately: its context is the repo root, for the player submodule). Then two regression tests: earshot's ffmpeg must not carry `--enable-nonfree`, or published images stop being redistributable; and rtmp-ingest must still **refuse to start** on the committed placeholder owner key, with the documented `ALLOW_DEFAULT_OWNER_KEY=1` escape still warning.

**integration** - the two real suites. `test-pipeline.sh` on every PR; `test-guest-endpoint.sh` nightly and on demand, because it takes about 17 minutes and a slow gate gets ignored. CI runs `scripts/setup.sh` to generate a real key, which also exercises the happy path of the startup guard.

**security** - gitleaks over full history (this repo carries placeholder credentials by design and had a history purge in July), Trivy on the four images this project controls, and CodeQL. earshot is scanned but **report-only**: it is a vendored upstream fork whose webtools stage sits on `node:12.22.1-alpine3.12` and carries CVEs nobody can fix from here, and failing on those would train everyone to ignore the job.

## Scope rule

Vendored upstream (`services/earshot/src`) and the player submodule (`hoast360`) are read here, not maintained here. shellcheck skips them, CodeQL ignores them (`.github/codeql-config.yml`), and Trivy reports on earshot without gating. Alerts nobody can act on are worse than no alerts.

## Honest limits

None of these would have caught the bugs found by hand on 2026-08-09 - a misnested CSV write, two test assertions that passed while testing nothing, 41 stale comments. Secret scanning in particular finds committed secrets, not a placeholder *documented* as the default; the hygiene workflow's own check covers that case, and it exists because README once printed that placeholder as the stream key to type.

Builds are amd64 only. The project also targets arm64, but building that here means QEMU-emulating an ffmpeg compile. Multi-arch belongs on a release job.
