#!/bin/bash
# Draws one short clip per video format Schnellbild shows into
# Tests/SchnellbildTests/Videos, all from UITests/Fixtures/clip.mp4 (2 s,
# a keyframe every half second, as camcorders and encoders write them), and
# the UI tests' videos with two audio and two subtitle tracks
# (UITests/Fixtures/tracks.mp4 and tracks.mkv).
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

# tracks.mp4 / tracks.mkv: 20 s of even grey (the subtitles stand out where
# they are drawn), English sound (440 Hz) and German (880 Hz), English and
# German subtitles over the whole length; the English ones are the default.
# MP4: mov_text (3GPP timed text) for both; MKV: SubRip and ASS.
SUBS=$(mktemp -d)
trap 'rm -rf "$SUBS"; [ -n "${finished:-}" ] || exit 1' EXIT
printf '1\n00:00:00,000 --> 00:00:30,000\nSUBTITLE ONE\n\n' > "$SUBS/en.srt"
printf '1\n00:00:00,000 --> 00:00:30,000\nUNTERTITEL ZWEI\n\n' > "$SUBS/de.srt"
"$FFMPEG" -loglevel error -y -i "$SUBS/de.srt" "$SUBS/de.ass"
tracks() {
  local out=$1 second=$2; shift 2
  "$FFMPEG" -loglevel error -y -f lavfi -i "color=c=0x808080:s=640x360:r=10:d=20" \
    -f lavfi -i "sine=frequency=440:sample_rate=22050:duration=20" \
    -f lavfi -i "sine=frequency=880:sample_rate=22050:duration=20" \
    -i "$SUBS/en.srt" -i "$SUBS/$second" -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s \
    -c:v libx264 -pix_fmt yuv420p -g 10 -c:a aac -b:a 24k -ac 1 "$@" \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title=English -metadata:s:a:1 language=deu -metadata:s:a:1 title=Deutsch \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -metadata:s:s:1 language=deu -metadata:s:s:1 title=Deutsch \
    -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 default -disposition:s:1 0 \
    -fflags +bitexact -flags:v +bitexact -flags:a +bitexact "UITests/Fixtures/$out"
}
tracks tracks.mp4 de.srt -c:s mov_text
tracks tracks.mkv de.ass -c:s:0 srt -c:s:1 ass
finished=1
