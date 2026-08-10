#!/bin/sh
# One-time bootstrap: prepare .env and, by default, the OWNER contribution route.
#
# WHY OWNER IS THE DEFAULT. If you are setting this box up, you are its owner,
# and the stream you want to push is your own. The owner route is built for
# exactly that: it authenticates you with a key, and that key is a real gate
# (SRT uses it as the connection's AES key, so a caller without it is refused
# at the handshake). The guest endpoint answers a different question - "let SOMEBODY ELSE
# push to my box" - and because it takes no key at all it stays off until you
# deliberately turn it on. Setting up your own box should not require opening an
# endpoint for strangers, which is what pointing the OBS guides at the guest
# route used to imply.
#
# Safe to re-run: it never overwrites a file that already exists, so it cannot
# eat secrets you have already set.
#
# Windows: run this from Git Bash or WSL, or follow the manual steps it prints.
set -eu

cd "$(dirname "$0")/.."

ENV_FILE=".env"
OVR_FILE="docker-compose.override.yml"
OWNER_PORT=8891

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# A real random secret, or nothing. Never a fixed literal: a default secret in a
# public repository is not a secret, and the whole point of this script is that
# every install ends up with its own.
gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
        od -An -tx1 -N24 /dev/urandom | tr -d ' \n'
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 1. .env
# ---------------------------------------------------------------------------
if [ -e "$ENV_FILE" ]; then
    say "keeping your existing $ENV_FILE (not overwritten)"
    # ...but complete the two things the owner route cannot run without, where
    # doing so is provably safe. An .env made by hand (say, a renamed
    # .env.example, which real first-time setups do) predates both secrets.
    #
    # RTMP_OWNER_KEY: replaced ONLY when missing, empty, or still one of the
    # two committed, publicly-known values - those are not secrets by
    # definition, so swapping them for a real one can break nothing but an
    # attacker's luck. A value you chose yourself is never touched.
    cur_key=$(grep -m1 '^RTMP_OWNER_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    case "${cur_key:-}" in
        ''|CHANGE_ME_this_default_is_public|hoast_demo_owner)
            k=$(gen_secret || true)
            if [ -n "${k:-}" ]; then
                if grep -q '^RTMP_OWNER_KEY=' "$ENV_FILE"; then
                    awk -v k="$k" '/^RTMP_OWNER_KEY=/ {print "RTMP_OWNER_KEY=" k; next} {print}' \
                        "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
                else
                    printf '\nRTMP_OWNER_KEY=%s\n' "$k" >> "$ENV_FILE"
                fi
                say "RTMP_OWNER_KEY was missing or still the committed public default - replaced with a fresh secret"
            fi ;;
    esac
    # LOOP_SOURCE_KEY: the same treatment, and for the same reason. It is
    # checked inside the owner application, so the committed default was a
    # working owner-publish credential for any reader of the repository until
    # 2026-08-10. rtmp-ingest now refuses to start on it, which means an .env
    # that predates this - including one left by an earlier setup.sh run, since
    # this generated only the owner key - would fail to come up without this.
    cur_loop=$(grep -m1 '^LOOP_SOURCE_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    case "${cur_loop:-}" in
        ''|hoast_demo|CHANGE_ME_this_default_is_public)
            l=$(gen_secret || true)
            if [ -n "${l:-}" ]; then
                if grep -q '^LOOP_SOURCE_KEY=' "$ENV_FILE"; then
                    awk -v k="$l" '/^LOOP_SOURCE_KEY=/ {print "LOOP_SOURCE_KEY=" k; next} {print}' \
                        "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
                else
                    printf '\nLOOP_SOURCE_KEY=%s\n' "$l" >> "$ENV_FILE"
                fi
                say "LOOP_SOURCE_KEY was missing or still the committed public default - replaced with a fresh secret"
            fi ;;
    esac
    # SRT_OWNER_PASSPHRASE: append when absent. The override below references
    # it, and the owner gateway refuses to start on an empty one, so without
    # this an existing .env means a crash-looping owner container.
    if ! grep -q '^SRT_OWNER_PASSPHRASE=' "$ENV_FILE"; then
        p=$(gen_secret || true)
        if [ -n "${p:-}" ]; then
            printf '\n# Added by scripts/setup.sh - the owner SRT route requires this.\nSRT_OWNER_PASSPHRASE=%s\n' \
                "$p" >> "$ENV_FILE"
            say "added the SRT_OWNER_PASSPHRASE the owner route requires"
        else
            warn "could not generate SRT_OWNER_PASSPHRASE (no openssl and no usable /dev/urandom);"
            warn "the owner route will not start until you set one in $ENV_FILE by hand"
        fi
    fi
    # GUEST_GW_SECRET: append when absent. It authenticates the gateways to
    # telemetry - optional defence-in-depth on the RTMP path, but MANDATORY on
    # the direct path's /gw/session/* routes, which fail closed without it
    # (there is no nginx in front of those to vouch for the caller, so the
    # address check and this secret are the whole trust anchor).
    if ! grep -q '^GUEST_GW_SECRET=' "$ENV_FILE"; then
        g=$(gen_secret || true)
        if [ -n "${g:-}" ]; then
            printf '\n# Added by scripts/setup.sh - authenticates the SRT gateways to telemetry.\nGUEST_GW_SECRET=%s\n' \
                "$g" >> "$ENV_FILE"
            say "added GUEST_GW_SECRET (gateway -> telemetry authentication)"
        else
            warn "could not generate GUEST_GW_SECRET; the direct path's session"
            warn "routes stay closed until you set one in $ENV_FILE by hand"
        fi
    fi
else
    [ -e .env.example ] || { warn "no .env.example here - run this from the repo root"; exit 1; }
    cp .env.example "$ENV_FILE"

    owner_key=$(gen_secret || true)
    owner_pass=$(gen_secret || true)
    gw_secret=$(gen_secret || true)
    loop_key=$(gen_secret || true)
    if [ -n "${owner_key:-}" ] && [ -n "${owner_pass:-}" ]; then
        # Replace the committed placeholders with secrets unique to this
        # install, and append the SRT passphrase the owner route requires.
        # Written with a temp file rather than `sed -i`, whose syntax differs
        # between GNU and BSD.
        #
        # BOTH keys, not just the owner one: LOOP_SOURCE_KEY is checked inside
        # the owner application, so its committed default was a working
        # owner-publish credential for any reader of the repository until
        # 2026-08-10, and rtmp-ingest now refuses to start on it.
        awk -v k="$owner_key" '/^RTMP_OWNER_KEY=/ {print "RTMP_OWNER_KEY=" k; next} {print}' \
            "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
        # An explicit if, not `[ -n ... ] && awk ... && mv ...`: this script runs
        # under set -e, where a false test at the head of an AND-OR list is the
        # SC2015 footgun that already bit a migration script here once.
        if [ -n "${loop_key:-}" ]; then
            awk -v k="$loop_key" '/^LOOP_SOURCE_KEY=/ {print "LOOP_SOURCE_KEY=" k; next} {print}' \
                "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
        fi
        printf '\n# Generated by scripts/setup.sh - the owner SRT route requires this.\nSRT_OWNER_PASSPHRASE=%s\n' \
            "$owner_pass" >> "$ENV_FILE"
        # .env.example ships GUEST_GW_SECRET commented out, so a fresh copy has
        # no value: append a real one, or the direct path's session routes
        # (which require it, and fail closed) stay shut on a brand-new install.
        [ -n "${gw_secret:-}" ] && printf '\n# Generated by scripts/setup.sh - authenticates the SRT gateways to telemetry.\nGUEST_GW_SECRET=%s\n' \
            "$gw_secret" >> "$ENV_FILE"
        say "created $ENV_FILE with a freshly generated owner key and passphrase"
    else
        warn "created $ENV_FILE, but could not generate secrets (no openssl and no usable /dev/urandom)."
        warn "Set RTMP_OWNER_KEY and SRT_OWNER_PASSPHRASE in it by hand before exposing this box."
    fi
fi

# ---------------------------------------------------------------------------
# 2. owner SRT route
# ---------------------------------------------------------------------------
if [ -e "$OVR_FILE" ]; then
    say "keeping your existing $OVR_FILE (not overwritten)"
    say "  if you want the owner route, copy the srt-gateway-owner block from"
    say "  docker-compose.override.yml.example into it."
else
    # Deliberately NOT a copy of docker-compose.override.yml.example: that file
    # also mounts ./custom/brand.json and binds a Tailscale address, neither of
    # which exists on a fresh clone, so copying it wholesale breaks the stack.
    # This writes only the owner service.
    cat > "$OVR_FILE" <<'YAML'
# Written by scripts/setup.sh. Yours to edit; it is gitignored.
#
# The owner SRT route: push YOUR OWN 16-channel stream, authenticated, without
# opening the keyless guest endpoint. See docs/GUEST-ENDPOINT.md.
services:
  srt-gateway-owner:
    image: ambi-box-srt-gateway:local
    build:
      context: ./services/srt-gateway
    environment:
      - SRT_ENABLED=1
      - SRT_MODE=owner
      # Direct-to-DASH: hand the probed stream straight to earshot's own
      # transcoder instead of re-encoding it to 16-ch AAC and republishing
      # over RTMP/FLV. Measured on the Mac Mini at 20 Mbps: ~28-42 % of a
      # core against the legacy ~90-130 %, and one lossy audio generation
      # deleted (OBS AAC -> Opus, with no AAC in between). Owner only; the
      # guest route keeps the RTMP hop, which is where guest admission and
      # the kick lever live. Set SRT_DIRECT=0 in .env to fall back.
      - SRT_DIRECT=${SRT_DIRECT:-1}
      # Authenticates this gateway to telemetry's /gw/session/* routes. The
      # owner container is a DIFFERENT container from srt-gateway, so it needs
      # its own copy; telemetry tells the two apart by peer address and will
      # refuse a claim that arrives without a matching secret.
      - GUEST_GW_SECRET=${GUEST_GW_SECRET:-}
      - RTMP_OWNER_KEY=${RTMP_OWNER_KEY}
      - SRT_PASSPHRASE=${SRT_OWNER_PASSPHRASE}   # mandatory in owner mode
      - SRT_LATENCY_MS=${SRT_LATENCY_MS:-2000}
      - HOME=/tmp
      - XDG_CACHE_HOME=/tmp
      - GST_REGISTRY=/tmp/gst-registry.bin
    ports:
      # All interfaces, matching the stack's other two contribution ports
      # (RTMP 1935 and guest SRT 8890 both bind 0.0.0.0 in docker-compose.yml).
      # A streaming server that can only be reached from itself is the rare
      # case, not the common one, so this is not loopback.
      #
      # What actually gates this port is the passphrase, and it is a real gate:
      # SRT uses it as the connection's AES key, so libsrt refuses the
      # handshake before a byte is parsed. setup.sh generated a 192-bit one.
      # Of the three contribution ports this is the best protected - 8890
      # admits guests with no key at all once GUEST_ENABLED=1.
      #
      # To stream in from outside, forward UDP 8891 to this host on your
      # router, then point OBS at srt://<your-public-address>:8891 with the
      # same streamid and passphrase.
      #
      # Narrow it if you want less exposure: 127.0.0.1 for this machine only,
      # or a VPN address (Tailscale/WireGuard) to keep it off the internet.
      # Do NOT write a public IP this host does not itself hold - behind NAT
      # that is your router's address, and the bind will look healthy while
      # receiving nothing. On a host with net.ipv4.ip_nonlocal_bind=1 (which
      # docs/ENDPOINTS.md recommends, for an unrelated boot race) that bind
      # does not even error. `ip -4 addr show scope global` lists what is
      # really here.
      - "0.0.0.0:8891:8890/udp"
    read_only: true
    tmpfs:
      - /tmp
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    init: true
    depends_on:
      rtmp-ingest:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "python3", "-c",
             "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8091/health', timeout=2)"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    restart: unless-stopped
YAML
    say "created $OVR_FILE with the owner SRT route on all interfaces, port $OWNER_PORT"
fi

# ---------------------------------------------------------------------------
# 3. what to do next
# ---------------------------------------------------------------------------
pass_now=$(grep -m1 '^SRT_OWNER_PASSPHRASE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)

say ""
say "Next:"
say "  docker compose up -d --build"
say ""
say "Then point OBS at (see docs/obs-windows.md or docs/obs-macos.md for the rest):"
if [ -n "${pass_now:-}" ]; then
    say "  srt://<address-you-reach-this-box-on>:$OWNER_PORT?streamid=owner&passphrase=$pass_now&latency=2000000&pkt_size=1128"
else
    say "  srt://<address-you-reach-this-box-on>:$OWNER_PORT?streamid=owner&passphrase=<SRT_OWNER_PASSPHRASE>&latency=2000000&pkt_size=1128"
fi
say ""
say "The owner route listens on all interfaces, like the stack's other two"
say "contribution ports. Testing on this machine: use 127.0.0.1. Streaming in"
say "from outside: forward UDP $OWNER_PORT to this host and use your public"
say "address. Either way the URL is otherwise identical."
say ""
say "That passphrase is in $ENV_FILE, which is gitignored. It is what gates the"
say "port - SRT uses it as the connection's AES key, so a caller without it is"
say "refused at the handshake. To narrow the bind instead, see $OVR_FILE."
say ""
say "Letting OTHER people push to this box is a separate, keyless route that is"
say "off by default: set GUEST_ENABLED=1 in $ENV_FILE. Read the trade-offs first"
say "in docs/GUEST-ENDPOINT.md - it takes no password from anyone."
