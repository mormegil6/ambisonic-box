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
	if [ -n "$JOIN_MAP" ]; then
		# Plain ( ... ) & subshells, NOT the $( ... ) & idiom the certbot lines
		# above use: on this image's shell the substitution variant survived
		# exactly one ffmpeg exit and then died silently, leaving no listener
		# and no log line. Each re-arm logs itself so a dead loop can never be
		# silent again.
		( while :; do
			echo "[direct-dash] 9100 (4x4) listening" >> /tmp/nginx_rtmp_ffmpeg_log
			ffmpeg -hide_banner -loglevel warning -analyzeduration 10M -probesize 20M \
			  -f mpegts -i "tcp://0.0.0.0:9100?listen=1" \
			  -filter_complex "[0:a:0][0:a:1][0:a:2][0:a:3]join=inputs=4:channel_layout=hexadecagonal:map=${JOIN_MAP}[a]" \
			  -map 0:v:0 -map "[a]" -tag:v avc1 -strict -2 -c:a libopus -mapping_family 255 -b:a 1536k \
			  ${FFMPEG_FLAGS} -f dash /opt/data/dash/${DASH_NAME:-hoast_demo}.mpd >> /tmp/nginx_rtmp_ffmpeg_log 2>&1
			sleep 1
		done ) &
		( while :; do
			echo "[direct-dash] 9101 (1x4) listening" >> /tmp/nginx_rtmp_ffmpeg_log
			ffmpeg -hide_banner -loglevel warning -analyzeduration 10M -probesize 20M \
			  -f mpegts -i "tcp://0.0.0.0:9101?listen=1" \
			  -map 0:v:0 -map 0:a:0 -tag:v avc1 -strict -2 -c:a libopus -mapping_family 255 -b:a 384k \
			  ${FFMPEG_FLAGS} -f dash /opt/data/dash/${DASH_NAME:-hoast_demo}.mpd >> /tmp/nginx_rtmp_ffmpeg_log 2>&1
			sleep 1
		done ) &
		echo "SRT direct-DASH listeners armed on :9100 (4x4) and :9101 (1x4)"
	else
		echo "SRT direct-DASH listeners DISABLED: no hexadecagonal layout in this ffmpeg"
	fi
fi

nginx
