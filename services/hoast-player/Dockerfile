# Serves the patched HOAST360 player (Phase 1 build) and the live DASH output.
# Build context must be the repo root (needs the hoast360/ submodule):
#   docker build -f services/hoast-player/Dockerfile .
FROM nginx:1.30.2-alpine

COPY services/hoast-player/nginx.conf /etc/nginx/conf.d/default.conf

COPY hoast360/index.html /usr/share/nginx/html/index.html
COPY hoast360/dist/      /usr/share/nginx/html/dist/
COPY hoast360/irs/       /usr/share/nginx/html/irs/

# /usr/share/nginx/html/dash is the shared dash-output volume (see docker-compose.yml)

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:80/index.html || exit 1
