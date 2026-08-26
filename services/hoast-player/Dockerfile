# Serves the patched HOAST360 player  and the live DASH output.
# Build context must be the repo root (needs the hoast360/ submodule):
#   docker build -f services/hoast-player/Dockerfile .
FROM nginx:1.31.3-alpine

# Patch the base image's OS packages, as every image here should. An earlier
# version of this comment claimed the other images got this for free because
# `apk add` refreshes the package index and so picks up current versions. That
# is wrong, and it cost a red CI run on 2026-08-27: `apk add` installs what is
# MISSING and leaves what is already present, so a base image's own OpenSSL
# survives untouched however fresh the build. rtmp-ingest shipped 3.5.7-r0 for
# exactly that reason. This image is still the most exposed one, being the only
# one on the public internet, but it is not the only one that needs the line. Container scanning found the difference:
# OpenSSL (heap use-after-free in PKCS7_verify, CVE-2026-45447), curl/libcurl
# (cookie leak across reused connections, CVE-2026-6276), c-ares, expat and
# libxml2, all HIGH and all with fixes already available upstream.
# The nginx version itself stays pinned above; this upgrades only what sits
# underneath it.
RUN apk upgrade --no-cache

# 00-logformat.conf defines the `cf` log_format (real viewer IP + country from
# Cloudflare headers) that nginx.conf's access_log references; it must load first
# (conf.d is included alphabetically), hence the 00- prefix.
COPY services/hoast-player/00-logformat.conf /etc/nginx/conf.d/00-logformat.conf
COPY services/hoast-player/nginx.conf         /etc/nginx/conf.d/default.conf
# VOD locations, activated (or stubbed to 404) by 15-vod-enabled.sh per the
# VOD_ENABLED env var; see that script for the rationale
COPY services/hoast-player/vod-locations.conf /etc/nginx/vod-locations.conf.on
COPY services/hoast-player/15-vod-enabled.sh  /docker-entrypoint.d/15-vod-enabled.sh

COPY services/hoast-player/index.html /usr/share/nginx/html/index.html
COPY services/hoast-player/fonts/     /usr/share/nginx/html/fonts/
# standalone capability check page (/check/): static, independent of the
# player and the stream, so the multichannel-Opus question gets an answer
# even when everything else is broken or idle
COPY services/hoast-player/check/     /usr/share/nginx/html/check/
COPY hoast360/dist/      /usr/share/nginx/html/dist/
COPY hoast360/irs/       /usr/share/nginx/html/irs/

# /usr/share/nginx/html/dash   is the shared dash-output volume (live segments)
# /usr/share/nginx/html/status is the shared status-public volume (telemetry
#   writes status.json there; the page fetches /status/status.json). Both are
#   declared in docker-compose.yml.

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:80/index.html || exit 1
