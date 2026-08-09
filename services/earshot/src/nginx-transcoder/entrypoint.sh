#!/bin/sh
# Create a self signed default certificate, so Ngix can start before we have
# any real certificates.

#Ensure we have folders available

# DASH manifest filename. This is the ONLY variable component of the ffmpeg
# output path in either transcoder config (nginx-no-ssl.conf / nginx.conf), so
# it is defaulted and validated HERE, before nginx starts and before either
# envsubst call below. It must be exported: the envsubst whitelist is derived
# from `env`, so an unexported value would leave the literal ${DASH_NAME} in the
# rendered config and ffmpeg would write a file the player never fetches. It is
# sourced only from the container environment (compose/.env), never from the
# network; rejecting '.' and '/' makes '..' and absolute paths unrepresentable.
DASH_NAME="${DASH_NAME:-hoast_demo}"
case "$DASH_NAME" in
    ''|*[!A-Za-z0-9_-]*)
        echo "[earshot] DASH_NAME must be a non-empty [A-Za-z0-9_-]+ string (got: $DASH_NAME)" >&2
        exit 1 ;;
esac
export DASH_NAME

if [ "$SSL_ENABLED" = true ] ; then

	if [ "$DOMAIN" = "" ]; then
		echo "Cannot start Earshot"
		echo "Please make sure you have configured your environment correctly."
		echo "The following environment variable was not set: DOMAIN"
		exit -1;
	fi
	if [ "$EMAIL" = "" ]; then
		echo "Cannot start Earshot"
		echo "Please make sure you have configured your environment correctly."
		echo "The following environment variable was not set: EMAIL"

		exit -1;
	fi

	echo "Running Earshot in SSL mode"

	if [[ ! -f /usr/share/nginx/certificates/fullchain.pem ]];then
	    mkdir -p /usr/share/nginx/certificates
	fi

	### If certificates don't exist yet we must ensure we create them to start nginx
	if [[ ! -f /usr/share/nginx/certificates/fullchain.pem ]]; then
	    openssl genrsa -out /usr/share/nginx/certificates/privkey.pem 4096
	    openssl genrsa -out /usr/share/nginx/certificates/privkey.pem 4096
	    openssl req -new -key /usr/share/nginx/certificates/privkey.pem -out /usr/share/nginx/certificates/cert.csr -nodes -subj \
	    "/C=PT/ST=World/L=World/O=${DOMAIN:-example.org}/OU=${DOMAIN:-example.org} lda/CN=${DOMAIN:-example.org}/EMAIL=${EMAIL:-info@example.org}"
	    openssl x509 -req -days 365 -in /usr/share/nginx/certificates/cert.csr -signkey /usr/share/nginx/certificates/privkey.pem -out /usr/share/nginx/certificates/fullchain.pem
	fi



	mkdir -p /opt/data/dash && (find /opt/data/dash -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true) && chown nginx /opt/data/dash && chmod 777 /opt/data/dash && mkdir -p /www && \
	  envsubst "$(env | sed -e 's/=.*//' -e 's/^/\$/g')" < \
	  /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
	### Send certbot Emission/Renewal to background
	$(while :; do /certbot.sh; sleep "${RENEW_INTERVAL:-12h}"; done;) &

	### Check for changes in the certificate (i.e renewals or first start) and send this process to background
	$(while inotifywait -e close_write /usr/share/nginx/certificates; do nginx -s reload; done) &

else
	echo "Running Earshot without SSL (connections will be insecure)"
	mkdir -p /opt/data/dash && (find /opt/data/dash -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true) && chown nginx /opt/data/dash && chmod 777 /opt/data/dash && mkdir -p /www && \
	  envsubst "$(env | sed -e 's/=.*//' -e 's/^/\$/g')" < \
	  /etc/nginx/nginx-no-ssl.conf.template > /etc/nginx/nginx.conf
fi

# ---- SRT direct-DASH listeners --------------------------------------------
# Design: docs/srt-direct-dash-design.md in the deployment repo. The owner SRT
# gateway can feed raw mpegts here instead of republishing over RTMP/FLV, which
# deletes the FLV hop's forced 16-ch AAC re-encode (measured at 59 % of a core
# at 20 Mbps) AND one lossy audio generation (OBS AAC -> gateway AAC -> Opus
# becomes OBS AAC -> Opus).
#
# THIS ffmpeg on purpose: the SPD floor (DASH_SPD_FLOOR) and the PCE-aware
# decode exist only in this image's build, and /opt/data/dash tolerates exactly
# one writer, which this container already is. Two fixed-layout listeners
# rather than one parameterised one, because the join filter depends on the
# probed track count and two dumb listeners beat a smart handshake:
#   9100 - 4x4ch tracks (3rd order), joined to hexadecagonal
#   9101 - 1x4ch track  (1st order), passthrough map
# Ports are compose-internal only; nothing publishes them. -listen 1 accepts
# one connection, transcodes until EOF, exits; the loop re-arms it. Idle
# listeners cost nothing. Audio bitrates follow the gateway's 96 kbit/s per
# channel rule (16 ch matches the RTMP relay's 1024k closely enough for A/B).
# The join map is derived from THIS ffmpeg's own layout table, exactly as the
# gateway's build_join_map() does: merged channel g IS track g/4's channel g%4.
if [ "${SRT_DIRECT_LISTENERS:-1}" = "1" ]; then
	JOIN_MAP=$(ffmpeg -hide_banner -layouts 2>/dev/null | awk '$1=="hexadecagonal"{n=split($2,a,"+");s="";for(i=0;i<16;i++){t=int(i/4);o=i%4;s=s sprintf("%s%d.%d-%s",(i?"|":""),t,o,a[i+1])};print s}')
	# Needed by direct-dash-gate.sh, a SEPARATE process this script only
	# execs (via socat's SYSTEM: address) - a plain shell variable would not
	# reach it. FFMPEG_FLAGS is already a real container env var (compose
	# `environment:`), so it needs no export here.
	export JOIN_MAP
	# BOTH root (this script, before nginx starts and drops privilege) and
	# nginx (every su-wrapped write below) append to this log, and root here
	# has no CAP_DAC_OVERRIDE (cap_add omits it, same reason the DASH
	# directory below needs its own chmod 777) - so whichever uid creates the
	# file first locks the OTHER one out with "Permission denied" (found live
	# testing this listener's gate, 2026-08-09: chown'ing it to nginx just
	# moved the failure onto this script's own first echo). chmod 666, not
	# chown: permission bits sidestep the ownership question entirely.
	touch /tmp/nginx_rtmp_ffmpeg_log && chmod 666 /tmp/nginx_rtmp_ffmpeg_log
	if [ -n "$JOIN_MAP" ]; then
		# Plain ( ... ) & subshells, NOT the $( ... ) & idiom the certbot lines
		# above use: on this image's shell the substitution variant survived
		# exactly one ffmpeg exit and then died silently, leaving no listener
		# and no log line. Each re-arm logs itself so a dead loop can never be
		# silent again.
		# AS NGINX, not root, and it is load-bearing: the hardened container
		# drops capabilities, so root has no CAP_DAC_OVERRIDE and CANNOT
		# overwrite the nginx-owned 644 files the RTMP relay's children write
		# into the same tree - found live as "Could not write header ...
		# Permission denied" whenever the relay had written first. One uid for
		# every dash writer makes takeover symmetric in both directions.
		# socat fronts each port and gates on the connecting peer's real IP
		# (direct-dash-gate.sh) before any byte reaches ffmpeg - closes the
		# "compose-network reachability is the entire gate" hole found in the
		# guest-direct-dash design review (BLOCKER 2, 2026-08-09): an admitted
		# caller's slot could otherwise be stolen by whichever TCP connection
		# to the port happened to land first, with child_exit then memoizing
		# the INNOCENT admitted caller while the squatter's un-probed bytes
		# flow under its identity. The gate script, once it confirms the
		# peer, execs directly into the same ffmpeg this port always ran (one
		# script serves both ports, keyed on the argument) - no relay, no
		# extra hop in the media path. socat exits after exactly one
		# connection (matching ffmpeg's former -listen 1), so the existing
		# re-arm loop below is unchanged; a rejected connection also ends the
		# socat process (the gate script exits without exec'ing ffmpeg), so a
		# hostile prober cannot wedge the port by connecting and going silent
		# - it is indistinguishable from one failed accept cycle.
		( while :; do
			echo "[direct-dash] 9100 (4x4) listening" >> /tmp/nginx_rtmp_ffmpeg_log
			su -s /bin/sh nginx -c "socat -u TCP-LISTEN:9100,reuseaddr SYSTEM:'/usr/local/bin/direct-dash-gate.sh 9100'" >> /tmp/nginx_rtmp_ffmpeg_log 2>&1
			sleep 1
		done ) &
		( while :; do
			echo "[direct-dash] 9101 (1x4) listening" >> /tmp/nginx_rtmp_ffmpeg_log
			su -s /bin/sh nginx -c "socat -u TCP-LISTEN:9101,reuseaddr SYSTEM:'/usr/local/bin/direct-dash-gate.sh 9101'" >> /tmp/nginx_rtmp_ffmpeg_log 2>&1
			sleep 1
		done ) &
		# Watchdog for a WEDGED listener: an abruptly killed feeder can leave
		# the accepting process holding a CLOSE_WAIT socket it never reads
		# (observed live 2026-08-09 against the former direct ffmpeg listener:
		# nine threads asleep, none in a read, an hour after the peer died),
		# and with single-accept semantics that bricks the port until the
		# process dies - every new session then fails with "Connection
		# refused" and the operator sees an unexplained OBS error. socat now
		# holds the raw socket instead of ffmpeg (see the gate above), so this
		# watchdog targets socat's own cmdline (`TCP-LISTEN:910N`, unique per
		# port and present nowhere else); killing it closes the pipe, and
		# ffmpeg on the far end exits cleanly on EOF. A read-timeout on the
		# socket would NOT have fired on the original wedge (no thread was in
		# a read), so the detector is the socket state itself, not a timeout.
		# A healthy session end also passes through CLOSE_WAIT briefly while
		# the trailer flushes, so only a state persisting across a 10 s
		# recheck is treated as wedged; killing during a slow flush would
		# only cost a trailer the next session rewrites anyway. Runs as
		# nginx, same uid as the listeners, because root in this hardened
		# container has no CAP_KILL over another uid.
		su -s /bin/sh nginx -c '
		while :; do
			sleep 15
			for port in 9100 9101; do
				if netstat -tn 2>/dev/null | grep ":$port" | grep -q CLOSE_WAIT; then
					sleep 10
					if netstat -tn 2>/dev/null | grep ":$port" | grep -q CLOSE_WAIT; then
						echo "[direct-dash] watchdog: killing wedged :$port listener (CLOSE_WAIT persisted)" >> /tmp/nginx_rtmp_ffmpeg_log
						# Pattern BUILT AT RUNTIME from the port number on
						# purpose. Written as a literal it also matched this
						# watchdog loop own command line (the old for-list
						# held the strings TCP-LISTEN:9100 and 9101), so the
						# first activation killed the watchdog itself and
						# wedge recovery worked at most once per container.
						# With the variable unexpanded in our own cmdline we
						# cannot match ourselves. NOTE: this whole block is
						# single-quoted for su, so no apostrophes in here.
						pkill -9 -f "socat -u TCP-LISTEN:$port"
					fi
				fi
			done
		done' &
		echo "SRT direct-DASH listeners armed on :9100 (4x4) and :9101 (1x4), peer-IP gated, CLOSE_WAIT watchdog on both"
	else
		echo "SRT direct-DASH listeners DISABLED: no hexadecagonal layout in this ffmpeg"
	fi
fi

nginx
