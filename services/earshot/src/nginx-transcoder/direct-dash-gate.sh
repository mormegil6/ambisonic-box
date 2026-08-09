#!/bin/sh
# Peer-IP gate for the SRT direct-DASH listeners (:9100/:9101). Invoked by
# socat's SYSTEM: address for the one connection it accepts, with this
# process's own stdin wired to the raw TCP bytes and SOCAT_PEERADDR set to
# the real peer address of that connection. $1 selects which listener this
# is (9100 or 9101), since one script serves both.
#
# WHY THE PEER CHECK IS TRUSTWORTHY, NOT JUST A CHECK: SOCAT_PEERADDR is the
# kernel's own view of who is on the other end of the socket, and both
# gateway containers (srt-gateway, srt-gateway-owner) run cap_drop: [ALL] -
# no NET_RAW, no NET_ADMIN - so neither one, even fully compromised by
# hostile guest input, can spoof a different container's source IP. This is
# a network-layer identity check, not an application-layer secret that could
# be stolen or replayed, and it needs no coordination with telemetry at all.
#
# Resolved FRESH on every single accept (getent, not a cached list), so a
# gateway container recreate - which changes its IP on this bridge network -
# self-heals within one connection attempt. srt-gateway-owner may not exist
# in this deployment (override-only); a failed lookup just yields no match.
#
# -stats (NOT -stats_period, which is ffmpeg 5.0+ and this fork is 4.3 - it
# exits "Unrecognized option" and the listener dies on every connect): the
# dashboard's encoder tile tails this log for speed=/time=, and without stats
# a direct session leaves the PREVIOUS RTMP session's numbers on screen as if
# they were current. -loglevel warning alone suppresses them, so it must be
# explicit here even though the RTMP relay gets them by default.
#
# ON MATCH: exec straight into the SAME ffmpeg this port always ran. Nothing
# has read this process's stdin yet, so ffmpeg's `-i pipe:0` picks up exactly
# the accepted connection's bytes - no relay, no second hop, no FIFO: this
# process simply BECOMES the transcoder. stdout/stderr are pointed at the
# shared log explicitly, so ffmpeg's own output never rides back over the
# TCP connection the way SYSTEM: would otherwise wire it.
# ON NO MATCH: exit without touching ffmpeg. socat's single-shot cycle ends
# (indistinguishable from one failed accept), and the entrypoint's own
# re-arm loop has the listener back up within a second.
PORT="$1"
LOG=/tmp/nginx_rtmp_ffmpeg_log

for h in srt-gateway srt-gateway-owner; do
    ip=$(getent hosts "$h" 2>/dev/null | awk '{print $1; exit}')
    if [ -n "$ip" ] && [ "$ip" = "$SOCAT_PEERADDR" ]; then
        case "$PORT" in
            9100)
                exec ffmpeg -hide_banner -loglevel warning -stats \
                  -analyzeduration 10M -probesize 20M \
                  -f mpegts -i pipe:0 \
                  -filter_complex "[0:a:0][0:a:1][0:a:2][0:a:3]join=inputs=4:channel_layout=hexadecagonal:map=${JOIN_MAP}[a]" \
                  -map 0:v:0 -map "[a]" -tag:v avc1 -strict -2 -c:a libopus -mapping_family 255 -b:a 1536k \
                  $FFMPEG_FLAGS -f dash "/opt/data/dash/${DASH_NAME}.mpd" >> "$LOG" 2>&1
                ;;
            9101)
                exec ffmpeg -hide_banner -loglevel warning -stats \
                  -analyzeduration 10M -probesize 20M \
                  -f mpegts -i pipe:0 \
                  -map 0:v:0 -map 0:a:0 -tag:v avc1 -strict -2 -c:a libopus -mapping_family 255 -b:a 384k \
                  $FFMPEG_FLAGS -f dash "/opt/data/dash/${DASH_NAME}.mpd" >> "$LOG" 2>&1
                ;;
            *)
                echo "[direct-dash] gate script invoked with unknown port '$PORT'" >> "$LOG"
                exit 1
                ;;
        esac
    fi
done

echo "[direct-dash] rejected connection to :$PORT from ${SOCAT_PEERADDR:-unknown} (not a known gateway)" >> "$LOG"
exit 1
