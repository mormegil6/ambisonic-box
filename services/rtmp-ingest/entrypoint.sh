#!/bin/sh
set -e

if [ -z "${LOOP_SOURCE_KEY}" ]; then
    echo "[rtmp-ingest] LOOP_SOURCE_KEY is not set" >&2
    exit 1
fi
if [ -z "${RTMP_OWNER_KEY}" ]; then
    echo "[rtmp-ingest] RTMP_OWNER_KEY is not set" >&2
    exit 1
fi

# Refuse to serve the PUBLIC ingest with a publicly known owner key.
#
# Every other credential here has a harmless default, but this one is different
# on two counts: :1935 is published on ALL interfaces (docker-compose.yml calls
# it "the only public ingest"), and both placeholder values are committed to a
# public repository. So a clone that skips scripts/setup.sh comes up reachable,
# with a key every reader of the repo already has. An owner publish is not a
# small thing to hand out: it preempts any live guest, stops the demo loop and
# takes over the stream.
#
# This mirrors the posture the rest of the stack already takes - GUEST_ENABLED=0,
# telemetry bound to 127.0.0.1, SRT admitting nobody until asked - rather than
# introducing a new one. The list is the same one scripts/setup.sh treats as
# "still needs generating", so the two cannot drift.
# LOOP_SOURCE_KEY is the same class of credential, which is NOT what this file
# used to assume. nginx checks it in the `owner` application, so the committed
# default was a working owner-publish credential for anyone who had read the
# repository - reproduced on 2026-08-10 with a plain ffmpeg push. It is scoped
# to the loop's own stream name now, but a stranger publishing under that name
# still becomes the stream, so the key itself has to be real too.
case "${LOOP_SOURCE_KEY}" in
    hoast_demo|CHANGE_ME_this_default_is_public)
        if [ "${ALLOW_DEFAULT_OWNER_KEY:-0}" != "1" ]; then
            echo "[rtmp-ingest] REFUSING TO START: LOOP_SOURCE_KEY is still the public default." >&2
            echo "[rtmp-ingest] It is checked inside the owner application, which is published on" >&2
            echo "[rtmp-ingest] all interfaces, so anyone who has read the repository could publish" >&2
            echo "[rtmp-ingest] as the demo loop and become the live stream." >&2
            echo "[rtmp-ingest]   fix:  ./scripts/setup.sh        (generates one into .env)" >&2
            echo "[rtmp-ingest]   or:   set LOOP_SOURCE_KEY yourself in .env" >&2
            echo "[rtmp-ingest]   or:   ALLOW_DEFAULT_OWNER_KEY=1 to accept this on a private host" >&2
            exit 1
        fi
        echo "[rtmp-ingest] WARNING: serving with the PUBLIC default LOOP_SOURCE_KEY" >&2
        ;;
esac

case "${RTMP_OWNER_KEY}" in
    CHANGE_ME_this_default_is_public|hoast_demo_owner)
        if [ "${ALLOW_DEFAULT_OWNER_KEY:-0}" != "1" ]; then
            echo "[rtmp-ingest] REFUSING TO START: RTMP_OWNER_KEY is still the public default." >&2
            echo "[rtmp-ingest] Port 1935 is published on all interfaces, so anyone who has read" >&2
            echo "[rtmp-ingest] the repository could publish as the owner: that preempts any live" >&2
            echo "[rtmp-ingest] guest, stops the demo loop and takes over the stream." >&2
            echo "[rtmp-ingest]   fix:  ./scripts/setup.sh        (generates a 192-bit key into .env)" >&2
            echo "[rtmp-ingest]   or:   set RTMP_OWNER_KEY yourself in .env" >&2
            echo "[rtmp-ingest]   or:   ALLOW_DEFAULT_OWNER_KEY=1 to accept this on a private host" >&2
            exit 1
        fi
        echo "[rtmp-ingest] WARNING: serving with the PUBLIC default RTMP_OWNER_KEY" >&2
        echo "[rtmp-ingest] (ALLOW_DEFAULT_OWNER_KEY=1). Anyone who can reach :1935 can publish." >&2
        ;;
esac

# Everything this script GENERATES goes under /run/nginx, never back into
# /etc/nginx: the container runs with a read-only rootfs (docker-compose.yml),
# so /etc is not writable and only /run is. The inputs (.template, .in) stay in
# the image where they belong. nginx.conf.template's own `include` lines point
# at /run/nginx for the same reason.
mkdir -p /run/nginx/tmp

# substitute only these three; everything else ($arg_name, $loop_auth, ...) is
# nginx syntax and MUST survive. The explicit list is what protects it: a bare
# envsubst would eat $loop_auth and silently break the loop-token scope check.
if [ -z "${DASH_NAME}" ]; then
    echo "[rtmp-ingest] DASH_NAME is not set. It scopes LOOP_SOURCE_KEY to the" >&2
    echo "[rtmp-ingest] loop's own stream name, so without it the token would be" >&2
    echo "[rtmp-ingest] accepted for no name at all. compose always passes it, so" >&2
    echo "[rtmp-ingest] this container predates that change. Recreate it with:" >&2
    echo "[rtmp-ingest]   docker compose up -d --force-recreate rtmp-ingest" >&2
    exit 1
fi
envsubst '${LOOP_SOURCE_KEY} ${RTMP_OWNER_KEY} ${DASH_NAME}' < /etc/nginx/nginx.conf.template > /run/nginx/nginx.conf

# Guest test endpoint: OFF unless GUEST_ENABLED=1. The snippets contain no
# ${...}, so they are copied verbatim; disabled means empty includes and the
# keyless application simply does not exist in the rendered config.
if [ "${GUEST_ENABLED:-0}" = "1" ]; then
    cp /etc/nginx/guest-rtmp.conf.in /run/nginx/guest-rtmp.conf
    cp /etc/nginx/guest-http.conf.in /run/nginx/guest-http.conf
    echo "[rtmp-ingest] guest endpoint ENABLED (rtmp://<host>:1935/guest)"
else
    : > /run/nginx/guest-rtmp.conf
    : > /run/nginx/guest-http.conf
fi

# -e: name the error log on the COMMAND LINE. nginx opens its compile-time
# default (/var/lib/nginx/logs/error.log) before it ever parses the config, so
# on a read-only rootfs the config's own error_log directive comes too late and
# every start logs `could not open error log file`. Harmless but misleading.
exec nginx -c /run/nginx/nginx.conf -e /dev/stderr
