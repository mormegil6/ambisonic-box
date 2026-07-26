#!/bin/sh
# VOD feature gate, mirroring the guest endpoint's shape: code ships in the
# image, the feature is OFF unless the deployer sets VOD_ENABLED=1. The
# stack's purpose is live HOA streaming; VOD is an addition a fresh clone
# should not get unasked (nor its 373 MB reference-master fetch, which
# loop-source gates on the same flag).
#
# Enabled:  the real VOD locations (page + packaged DASH) are included.
# Disabled: explicit 404 stubs. Stubs rather than an empty include: without
# them /vod-dash/ would fall through to `location /` and serve the mounted
# files with default MIME types, no Expose-Headers and no Cache-Control. The
# Live|VOD nav pill is also removed
# from the served page, so the feature leaves no visible trace.
if [ "${VOD_ENABLED:-0}" = "1" ]; then
    cp /etc/nginx/vod-locations.conf.on /etc/nginx/vod-locations.conf
    echo "[hoast-player] VOD enabled (/vod/, /vod-dash/)"
else
    cat > /etc/nginx/vod-locations.conf <<'EOF'
    location = /vod { return 404; }
    location = /vod/ { return 404; }
    location /vod-dash/ { return 404; }
EOF
    sed -i 's#<a href="/vod/">VOD</a>##' /usr/share/nginx/html/index.html
fi
