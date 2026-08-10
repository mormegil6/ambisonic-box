# Security policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** Use GitHub's [private vulnerability reporting](https://github.com/mormegil6/ambisonic-box/security/advisories/new), which is enabled on this repository, or email bartlomiej.mroz@pg.edu.pl.

Useful things to include, roughly in order of how much they help:

- which route is affected: RTMP owner (`:1935/owner`), the guest application (`:1935/guest`), SRT guest (`:8890`), SRT owner (`:8891`), the direct-to-DASH listeners, the player, or telemetry
- whether it needs a credential, and if so which one
- whether it is reachable from outside the host, or only from inside the compose network
- the smallest way to reproduce it, and what you saw versus what you expected

This is a single-maintainer academic project, not a vendor with an on-call rota. Expect an acknowledgement within a few days rather than a few hours. If something is being actively exploited against a live deployment, say so in the first line and I will treat it that way.

## What is in scope

The parts of this repository that face untrusted input:

- **`rtmp-ingest`** publish authentication and the two applications it serves. The owner application is key-authed; the guest application is deliberately keyless and gated by the arbiter instead.
- **The guest arbiter in `telemetry`**: admission, the single-slot rule, session cap, cooldown, reconnect grace, the ban list, and the kick lever. Anything that lets a guest bypass one of those, hold a slot indefinitely, or act as another guest.
- **`srt-gateway`**, which parses hostile pre-authentication bytes off the internet by design. It runs privilege-separated (read-only rootfs, all capabilities dropped, no Docker socket) precisely because of that, so a way to escape those constraints is interesting.
- **The direct-to-DASH listeners** and the gateway session protocol (`/gw/session/claim|beat|done`), including anything that lets an unadmitted peer reach a listener or impersonate a gateway.
- **`telemetry`'s HTTP surface**, particularly the `/rtmp/*` callback routes and which peers may call them, and the three `/api` routes that `hoast-player` proxies to the public port.
- **`hoast-player`**, the only service intended to face the public internet directly.

## What is out of scope

Not because these do not matter, but because a report here cannot fix them:

- **`services/earshot/src`** is a vendored copy of [Envelop Earshot](https://github.com/EnvelopSound/Earshot), which is a separate project under GPL-2.0. Its `webtools` admin UI carries a 2020-era npm tree with known advisories in its build toolchain; that UI is bound to `127.0.0.1:8081` here and is not exposed. Report defects in Earshot itself upstream. The same applies to the [patched HOAST360 player](https://github.com/mormegil6/hoast360), which is a submodule.
- **The placeholder credentials that ship in `.env.example`** are published on purpose. `rtmp-ingest` refuses to start while `RTMP_OWNER_KEY` is still one of them, and `scripts/setup.sh` generates a real key. A report that the committed placeholder is public is expected rather than a finding.
- **Running with `ALLOW_DEFAULT_OWNER_KEY=1`.** That flag exists for a host nobody can reach, warns on every boot, and disables the guard deliberately.
- **`services/earshot/src/nginx-transcoder/certs/example.com.key`.** Upstream's self-signed example, expired in 2019, never presented (the stack ships `SSL_ENABLED=false`). It is recorded in `.gitleaksignore` with that reasoning.
- Anything requiring an attacker to already have shell access to the host or the Docker socket.

## Supported versions

Pre-1.0, so only the current `main` and the most recent tag receive fixes. There are no maintained release branches, and no backports to earlier tags.

## What this project already does

Stated so a reporter can tell a real gap from a deliberate choice:

- The guest endpoint is **off by default** (`GUEST_ENABLED=0`), and binding its port admits nobody on its own.
- Telemetry's dashboard binds to loopback, and its `/rtmp/*` callback routes are peer-authenticated.
- `rtmp-ingest` logs failed publish authentication, without the credential, so brute force leaves a trace. A `fail2ban` jail for it ships in the deployment notes.
- Every image is scanned for known CVEs in CI, and the four images this project controls are gated on that scan.
- Secrets are scanned across full git history weekly.
