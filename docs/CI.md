# CI (GitHub Actions)

> **This repository's source of truth is GitHub, and git.pg.edu.pl is the mirror.**
> That is the OPPOSITE of the maintainer's other repositories, which are all GitLab -> GitHub. It is deliberate; the reasoning is in "Why this one is backwards" at the end of this file.

Four workflows, on GitHub Actions rather than on git.pg.edu.pl: that instance has **no CI runner available to this project**, proven on 2026-08-09 by enabling CI/CD and watching two real pipelines sit `pending` with `runner: None` until they were cancelled. GitLab's own Secret Detection template behaved identically, which is the answer for every GitLab scanner at once - on self-managed GitLab a security scan is just another CI job, and it needs the same runner nothing here has.

Pushes land on GitHub and Actions runs immediately; a separate workflow copies `main` and tags on to GitLab afterwards. (Until 2026-08-10 this ran the other way round - see the last section.)

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


## Why this one is backwards (2026-08-10)

Every other repository of this maintainer's is GitLab-canonical, push-mirrored to GitHub. This one is the exception, and the exception is deliberate:

- **Contributions arrive on GitHub.** Outside contributors cannot realistically obtain accounts on a university GitLab, so pull requests will land here. Under the old direction that was a trap rather than a workflow: the GitLab mirror ran with `keep_divergent_refs=false`, so GitLab force-updated GitHub and anything merged here was silently reverted on the next push. The Merge button appeared to work and then quietly undid itself.
- **CI runs here.** git.pg.edu.pl has no CI runner available to this project - proven by enabling CI/CD and watching two real pipelines, including GitLab's own Secret Detection template, sit `pending` with `runner: None`. Every gate therefore lives on GitHub regardless of where the canonical copy is.
- **Reversing the mirror on GitLab's side is not possible here.** Pull mirroring is a Premium feature and this instance is Community Edition (`enterprise: false`, 16.11). GitLab cannot pull from GitHub, so if GitHub is to be canonical, GitHub must push - which is what `.github/workflows/mirror-to-gitlab.yml` does.

Practical consequences:

- Push to **GitHub**. `git push origin main` should reach GitHub; the mirror workflow copies `main` and tags to GitLab within a minute.
- The GitLab copy is **read-only in practice**. Pushing there directly will be overwritten by the next mirror run, and the two will disagree until then.
- Auth for the mirror is a GitLab **deploy key** scoped to this one project with push rights, not a personal token. The private half is the `GITLAB_MIRROR_SSH_KEY` GitHub secret.
- The old GitLab -> GitHub mirror was **disabled, not deleted**. To revert: re-enable it in the GitLab project's Repository Settings and delete the mirror workflow.
- The mirror pushes `main` and tags only, deliberately not `--mirror`: nothing should copy `dependabot/*` branches into the university instance, and `--mirror` would also delete GitLab refs that do not exist on GitHub.
