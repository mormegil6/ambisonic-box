# Shared ffmpeg graph for the synthesised spherical demo loop. Sourced by the
# loop-source entrypoint (in-container synthesis) and scripts/make-demo-loop.sh
# (host utility), so both produce the identical file.
#
# Video: the testsrc2 pattern as a genuinely FLAT screen inside the sphere.
# v360 treats the pattern as a rectilinear (gnomonic, input=flat) image with a
# 60x30 degree field of view and maps it into the equirectangular frame; after
# the player textures the sphere, straight edges render straight, like a
# planar screen floating at the front direction, black everywhere else.
# (Pasting the rectangle into the equirect canvas directly gives a
# constant-angular-size patch instead, which the viewport shows as a bowed,
# theatre-curved band.) No text labels: the PCE ffmpeg build has no freetype;
# the proper orientation card remains scripts/make-360-testcard.py.
#
# Audio: ONE mono 440 Hz source encoded to 3rd-order Ambisonics (SN3D/ACN,
# AmbiX) with time-varying gains via aeval: it orbits the listener once every
# ORBIT_S seconds with a +/-30 degree elevation wobble every WOBBLE_S seconds,
# so turning your head (or dragging the view) audibly moves the tone. The
# encoding coefficients are the closed-form SN3D spherical harmonics,
# verified numerically against an independent Legendre-recurrence reference
# to 3e-16 before being baked in here.
#
# Loop seam: with DEMO_DUR a multiple of 30 s, the orbit (15 s), the wobble
# (10 s) and the 440 Hz carrier all complete integer cycles, so -stream_loop
# repeats with no click and no spatial jump. (testsrc2's timestamp overlay
# still visibly resets; it is a test pattern, that is fine.)
#
# Provides: DEMO_GRAPH (filter_complex string) and DEMO_ENC (codec args) for:
#   ffmpeg -filter_complex "$DEMO_GRAPH" -map '[out0]' -map '[out1]' $DEMO_ENC out.mp4

DEMO_DUR="${DEMO_DUR:-60}"

# angle expressions (ffmpeg expression syntax; PI is predefined)
_TH="(2*PI*t/15)"                      # azimuth: one orbit / 15 s, CCW from front
_PH="(PI/6*sin(2*PI*t/10))"            # elevation: +/-30 deg, 10 s period
_G="0.5"                               # master gain

# SN3D/ACN (AmbiX) gains, constants precomputed so no sqrt() in the exprs:
# 0.8660254=sqrt(3)/2  0.6123724=sqrt(3/8)  0.7905694=sqrt(5/8)  1.9364917=sqrt(15)/2
_A="val(0)*${_G}"
_E0="${_A}"
_E1="${_A}*sin(${_TH})*cos(${_PH})"
_E2="${_A}*sin(${_PH})"
_E3="${_A}*cos(${_TH})*cos(${_PH})"
_E4="${_A}*0.8660254*sin(2*${_TH})*cos(${_PH})*cos(${_PH})"
_E5="${_A}*0.8660254*sin(${_TH})*sin(2*${_PH})"
_E6="${_A}*(3*sin(${_PH})*sin(${_PH})-1)/2"
_E7="${_A}*0.8660254*cos(${_TH})*sin(2*${_PH})"
_E8="${_A}*0.8660254*cos(2*${_TH})*cos(${_PH})*cos(${_PH})"
_E9="${_A}*0.7905694*sin(3*${_TH})*cos(${_PH})*cos(${_PH})*cos(${_PH})"
_E10="${_A}*1.9364917*sin(2*${_TH})*sin(${_PH})*cos(${_PH})*cos(${_PH})"
_E11="${_A}*0.6123724*sin(${_TH})*cos(${_PH})*(5*sin(${_PH})*sin(${_PH})-1)"
_E12="${_A}*sin(${_PH})*(5*sin(${_PH})*sin(${_PH})-3)/2"
_E13="${_A}*0.6123724*cos(${_TH})*cos(${_PH})*(5*sin(${_PH})*sin(${_PH})-1)"
_E14="${_A}*1.9364917*cos(2*${_TH})*sin(${_PH})*cos(${_PH})*cos(${_PH})"
_E15="${_A}*0.7905694*cos(3*${_TH})*cos(${_PH})*cos(${_PH})*cos(${_PH})"

DEMO_GRAPH="color=c=black:size=2048x1024:rate=30:duration=${DEMO_DUR}[bg];\
testsrc2=size=512x256:rate=30:duration=${DEMO_DUR},format=rgba,\
v360=input=flat:ih_fov=75:iv_fov=37.5:output=equirect:w=2048:h=1024:alpha_mask=1[scr];\
[bg][scr]overlay=shortest=1[out0];\
sine=frequency=440:sample_rate=48000:duration=${DEMO_DUR}[a0];\
[a0]aeval=exprs='${_E0}|${_E1}|${_E2}|${_E3}|${_E4}|${_E5}|${_E6}|${_E7}|${_E8}|${_E9}|${_E10}|${_E11}|${_E12}|${_E13}|${_E14}|${_E15}':channel_layout=hexadecagonal[out1]"

# H.264 + 16-ch AAC (PCE): the contribution format the RTMP leg requires.
# -ac 16 is LOAD-BEARING: without it the PCE this encoder writes is malformed
# (decode_pce "Input buffer exhausted", stream reads as 0 channels) even
# though the filter already outputs 16-ch hexadecagonal. With it, the stream
# decodes as hexadecagonal, matching the documented master-prep command.
# NB: word-splitting of this string is intentional at the call site.
DEMO_ENC="-c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 1M -g 60 -keyint_min 60 -c:a aac -strict -2 -ac 16 -b:a 512k -movflags +faststart"
