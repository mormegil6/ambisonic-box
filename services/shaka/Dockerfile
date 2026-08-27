# Shaka Packager with the dOps endianness bug patched.
#
# WHY THIS EXISTS. Shaka writes the Opus dOps box little-endian:
# OpusSpecific::ReadWriteInternal copies the OpusHead body into the box without
# byte-swapping, and the two headers share field order and widths, so the result
# is structurally valid and numerically reversed. A 48 kHz stream reports
# InputSampleRate 2159738880 and PreSkip 14337 instead of 48000 and 312.
# Chromium's MSE refuses such segments; progressive <video src> playback reads
# them correctly through FFmpegDemuxer and plays fine, which is how the defect
# survived since 2016. Reported as shaka-project/shaka-packager#1627.
#
# Nothing in the LIVE path needs this: that leg is ffmpeg end to end. It is the
# on-demand VOD clips that Shaka packages, and only they are affected.
#
# WHEN TO DELETE THIS DIRECTORY. As soon as an upstream release carries the fix.
# Check the issue, then pin scripts/package-vod-dash.sh back to
# google/shaka-packager:<version> and drop this. Carrying a private build of a
# third-party tool is a cost, and the whole point of filing the issue was to
# stop paying it.
#
# BUILD:
#   docker build -t shaka-packager:dops-fix .
#
# The build is memory-hungry. The upstream Dockerfile runs `cmake --build
# --parallel` with no job limit, which starts one compile per core and exhausts
# a default Docker Desktop VM: 16 cores against 7.7 GB failed with
# ResourceExhausted. Four jobs is the setting below and it completes.

FROM alpine:3.19 AS builder

# linux-headers: abseil's CPU detection includes asm/hwcap.h, which Alpine does
# not ship in build-base. Without it the build dies partway through third_party.
RUN apk add --no-cache build-base cmake git ninja python3 bash linux-headers

ARG SHAKA_REPO=https://github.com/shaka-project/shaka-packager.git
# Pinned to the commit the patch was written and verified against. A moving
# target here would let an upstream edit break the patch silently at build time.
ARG SHAKA_COMMIT=74ca0784a1b3f9a4e5e47869ad3833fbf0e31b62

WORKDIR /src
# --tags: the build reads a version from git describe, and a bare commit
# checkout leaves it reporting "Cannot find version tag!".
RUN git clone "$SHAKA_REPO" . \
    && git fetch --tags \
    && git checkout "$SHAKA_COMMIT" \
    && git submodule update --init --recursive --depth 1

# --check first: fail loudly at build time if upstream has moved under the patch,
# rather than producing a silently unpatched packager that reintroduces the bug.
COPY dops-endianness.patch /tmp/
RUN git apply --check /tmp/dops-endianness.patch \
    && git apply /tmp/dops-endianness.patch \
    && grep -q "dOps stores PreSkip big-endian" packager/media/formats/mp4/box_definitions.cc

# Debug, matching upstream's own Dockerfile. That is the configuration this
# patch was built and verified under; Release was tried and is not what the
# official image ships either.
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -G Ninja \
    && cmake --build build/ --config Debug --parallel 4

FROM alpine:3.19
RUN apk add --no-cache libstdc++ python3
COPY --from=builder /src/build/packager/packager /usr/bin/packager
WORKDIR /media
