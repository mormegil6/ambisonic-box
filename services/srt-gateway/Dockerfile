# SRT guest-ingest gateway: GStreamer srtsrc terminates SRT (the only tool
# here that exposes caller IP + streamid pre-accept), one ffmpeg child per
# session republishes into rtmp-ingest. trixie: GStreamer 1.26 srtsrc carries
# the authentication property + caller-* signals the admission hook needs
# (verified, as was bookworm's 1.22; trixie matches the Pi fleet), and its
# ffmpeg 7.1 knows the hexadecagonal layout the join map is built from.
# Debian publishes both amd64 and arm64.
FROM debian:trixie-slim

# WHY THIS IMAGE SCANS BADLY, AND WHY THAT NUMBER MISLEADS.
# `srtsrc` is the whole reason GStreamer is here, and Debian ships it only
# inside gstreamer1.0-plugins-bad. That package depends on an ML inference
# runtime (ONNX, for its libgstonnx.so element), a printing library (CUPS),
# image codecs (OpenEXR, TIFF, libde265) and an audio server (PipeWire). An SRT
# terminator touches none of them, but they are installed, so an image scan
# counts their CVEs: ~230 HIGH/CRITICAL across 51 packages at the time of
# writing. There is no narrower package (checked: only gstreamer1.0-libav ships
# separately), and --no-install-recommends is already set, so they cannot be
# trimmed by configuration - only by building GStreamer from source with just
# the SRT plugin, which is not worth it for this container.
#
# Measured rather than assumed: the running process maps 46 shared libraries,
# and ONNX, CUPS, OpenEXR, TIFF, libde265, PipeWire, libsoup, libxml2 and
# libavcodec are NOT among them. Of the 51 flagged packages, 11 are actually
# loaded - glib, libcurl, libcjson, libmbedcrypto, libmount, plugins-bad
# itself and their kin. Those are the ones worth reading. `scripts/scan-gateway.sh`
# does this split for you and calls out libsrt specifically, since libsrt is the
# one library that parses a stranger's bytes before any authentication.
#
# Whatever is reachable also lands in a container with a read-only rootfs, all
# capabilities dropped, no docker socket, no volumes, no credentials in guest
# mode, running as uid 900.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-gi gir1.2-gstreamer-1.0 gir1.2-glib-2.0 \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        ffmpeg ca-certificates \
    # Same reason as telemetry/Dockerfile: a Debian security fix can be
    # published and installable days before it reaches the base image, and the
    # CVE gate fails on it meanwhile. On 2026-08-21 that was util-linux
    # 2.41.5-0+deb13u1 against a base still shipping 2.41-5. Costs build
    # reproducibility, which is the trade taken knowingly.
    && apt-get upgrade -y \
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
