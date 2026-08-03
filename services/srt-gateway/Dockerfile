# SRT guest-ingest gateway: GStreamer srtsrc terminates SRT (the only tool
# here that exposes caller IP + streamid pre-accept), one ffmpeg child per
# session republishes into rtmp-ingest. trixie: GStreamer 1.26 srtsrc carries
# the authentication property + caller-* signals the admission hook needs
# (verified, as was bookworm's 1.22; trixie matches the Pi fleet), and its
# ffmpeg 7.1 knows the hexadecagonal layout the join map is built from.
# Debian publishes both amd64 and arm64.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-gi gir1.2-gstreamer-1.0 gir1.2-glib-2.0 \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -u 900 -s /usr/sbin/nologin gateway
COPY gateway.py /app/gateway.py
# read_only rootfs: point every cache/home write at the tmpfs the compose
# file mounts on /tmp, so ffmpeg's fontconfig and gstreamer's registry do not
# try to write under a read-only HOME (baked here, not only in compose, so
# the image is correct on its own)
ENV HOME=/tmp XDG_CACHE_HOME=/tmp GST_REGISTRY=/tmp/gst-registry.bin
USER gateway

EXPOSE 8890/udp 8091

HEALTHCHECK --interval=10s --timeout=3s --retries=3 --start-period=5s \
  CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8091/health', timeout=2)"]

ENTRYPOINT ["python3", "-u", "/app/gateway.py"]
