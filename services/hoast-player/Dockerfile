# Serves the patched HOAST360 player  and the live DASH output.
# Build context must be the repo root (needs the hoast360/ submodule):
#   docker build -f services/hoast-player/Dockerfile .
FROM nginx:1.30.2-alpine

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
