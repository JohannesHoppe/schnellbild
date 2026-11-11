#!/bin/bash
# Draws one short clip per video format Schnellbild shows into
# Tests/SchnellbildTests/Videos, all from UITests/Fixtures/clip.mp4 (2 s,
# a keyframe every half second, as camcorders and encoders write them).
# Needs ffmpeg; the clips are committed, so tests don't.
set -euo pipefail
cd "$(dirname "$0")/.."
FFMPEG="${FFMPEG:-ffmpeg}"
OUT=Tests/SchnellbildTests/Videos
mkdir -p "$OUT"
make() { local name=$1; shift; "$FFMPEG" -loglevel error -y -i UITests/Fixtures/clip.mp4 -t 2 -an -g 12 "$@" "$OUT/$name"; }
make clip.mkv  -c:v libx264 -pix_fmt yuv420p
make clip.webm -c:v libvpx-vp9 -crf 40 -b:v 0
make clip.avi  -c:v mpeg4 -q:v 8 -vtag xvid
make clip.mp4  -c:v libx264 -pix_fmt yuv420p
make clip.m4v  -c:v libx264 -pix_fmt yuv420p -f mp4
make clip.mov  -c:v libx264 -pix_fmt yuv420p
make clip.qt   -c:v libx264 -pix_fmt yuv420p -f mov
make clip.3gp  -c:v mpeg4 -q:v 8
make clip.3g2  -c:v mpeg4 -q:v 8
make clip.mpg  -c:v mpeg1video -q:v 8 -f mpeg
make clip.mpeg -c:v mpeg2video -q:v 8 -f vob
make clip.vob  -c:v mpeg2video -q:v 8 -f vob
make clip.m2v  -c:v mpeg2video -q:v 8 -f mpeg2video
make clip.ts   -c:v mpeg2video -q:v 8 -f mpegts
make clip.m2ts -c:v libx264 -pix_fmt yuv420p -f mpegts -mpegts_m2ts_mode 1
make clip.mts  -c:v libx264 -pix_fmt yuv420p -f mpegts -mpegts_m2ts_mode 1
make clip.wmv  -c:v wmv2 -q:v 8
make clip.asf  -c:v wmv2 -q:v 8 -f asf
make clip.flv  -c:v flv1 -q:v 8
make clip.ogv  -c:v libvpx -crf 30 -b:v 200k -f ogg
# DV is always full PAL size: three pictures only
"$FFMPEG" -loglevel error -y -i UITests/Fixtures/clip.mp4 -frames:v 3 -an -vf scale=720:576,setsar=16/15 -r 25 -c:v dvvideo -pix_fmt yuv420p -f dv "$OUT/clip.dv"
