# Edge RTMP ingest: stream-key auth + relay to earshot.
# alpine's nginx + nginx-mod-rtmp packages are published for x86_64 and aarch64.
FROM alpine:3.24

RUN apk add --no-cache nginx nginx-mod-rtmp gettext

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
