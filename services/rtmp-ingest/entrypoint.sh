#!/bin/sh
set -e

if [ -z "${STREAM_KEY}" ]; then
    echo "[rtmp-ingest] STREAM_KEY is not set" >&2
    exit 1
fi

mkdir -p /run/nginx

# substitute only ${STREAM_KEY}; everything else ($arg_name, ...) is nginx syntax
envsubst '${STREAM_KEY}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

exec nginx -c /etc/nginx/nginx.conf
