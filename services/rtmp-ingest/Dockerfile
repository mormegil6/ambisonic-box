# Edge RTMP ingest: stream-key auth + relay to earshot.
# alpine's nginx + nginx-mod-rtmp packages are published for x86_64 and aarch64.
FROM alpine:3.24

# Patch the base image's OS packages BEFORE installing. `apk add` resolves
# missing dependencies but never upgrades ones the base already carries: nginx
# depends on libssl3/libcrypto3, alpine:3.24.1 ships those at 3.5.7-r0, that
# satisfies the dependency, and apk leaves them. So this image kept scanning as
# 3.5.7-r0 and failing CVE-2026-14456 while Alpine v3.24 had 3.5.8-r0 available,
# and no amount of rebuilding changed it.
RUN apk upgrade --no-cache \
 && apk add --no-cache nginx nginx-mod-rtmp gettext

COPY nginx.conf.template /etc/nginx/nginx.conf.template
# guest endpoint snippets; the entrypoint includes them only when
# GUEST_ENABLED=1 (default: empty includes, no keyless application)
COPY guest-rtmp.conf /etc/nginx/guest-rtmp.conf.in
COPY guest-http.conf /etc/nginx/guest-http.conf.in
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 1935 8080

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
