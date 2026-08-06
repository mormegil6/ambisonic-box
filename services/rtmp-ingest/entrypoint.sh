#!/bin/sh
set -e

if [ -z "${LIVE_APP_KEY}" ]; then
    echo "[rtmp-ingest] LIVE_APP_KEY is not set" >&2
    exit 1
fi
if [ -z "${RTMP_OWNER_KEY}" ]; then
    echo "[rtmp-ingest] RTMP_OWNER_KEY is not set" >&2
    exit 1
fi

mkdir -p /run/nginx

# substitute only these two; everything else ($arg_name, ...) is nginx syntax
envsubst '${LIVE_APP_KEY} ${RTMP_OWNER_KEY}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Guest test endpoint: OFF unless GUEST_ENABLED=1. The snippets contain no
# ${...}, so they are copied verbatim; disabled means empty includes and the
# keyless application simply does not exist in the rendered config.
if [ "${GUEST_ENABLED:-0}" = "1" ]; then
    cp /etc/nginx/guest-rtmp.conf.in /etc/nginx/guest-rtmp.conf
    cp /etc/nginx/guest-http.conf.in /etc/nginx/guest-http.conf
    echo "[rtmp-ingest] guest endpoint ENABLED (rtmp://<host>:1935/guest)"
else
    : > /etc/nginx/guest-rtmp.conf
    : > /etc/nginx/guest-http.conf
fi

exec nginx -c /etc/nginx/nginx.conf
