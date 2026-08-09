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

# Everything this script GENERATES goes under /run/nginx, never back into
# /etc/nginx: the container runs with a read-only rootfs (docker-compose.yml),
# so /etc is not writable and only /run is. The inputs (.template, .in) stay in
# the image where they belong. nginx.conf.template's own `include` lines point
# at /run/nginx for the same reason.
mkdir -p /run/nginx/tmp

# substitute only these two; everything else ($arg_name, ...) is nginx syntax
envsubst '${LOOP_SOURCE_KEY} ${RTMP_OWNER_KEY}' < /etc/nginx/nginx.conf.template > /run/nginx/nginx.conf

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
