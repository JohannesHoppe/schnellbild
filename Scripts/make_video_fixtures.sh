#!/bin/bash
# Draws one short clip per video format Schnellbild shows into
# Tests/SchnellbildTests/Videos, all from UITests/Fixtures/clip.mp4 (2 s,
# a keyframe every half second, as camcorders and encoders write them), and
# the UI tests' videos with two audio and two subtitle tracks
# (UITests/Fixtures/tracks.mp4 and tracks.mkv), and the HDR clips (`hdr` as
# the only argument draws just those).
# Needs ffmpeg (with libx265 for the HDR clips); the clips are committed, so
# tests don't.
set -euo pipefail
cd "$(dirname "$0")/.."
FFMPEG="${FFMPEG:-ffmpeg}"
OUT=Tests/SchnellbildTests/Videos
mkdir -p "$OUT"

# HDR: 2 s of SMPTE colour bars as 10-bit HEVC (Main10), the bars' code
# values read as PQ or HLG. hdr10.mkv states its colours twice (Matroska's
# Colour element and the stream's VUI), hdr10-vui.mkv only in the stream (VLC
# learns them from the decoder, after its video output has opened); both
# carry HDR10's mastering display and content light level. hlg.mkv is HLG,
# sdr10.mkv 10-bit BT.709 (SDR in a 10-bit stream). hdr10.mp4 and the UI
# tests' copy of hdr10.mkv show AVKit and VLC side by side, as does sdr10.mp4
# (10-bit BT.709 at 1280 × 720, HD: VLC's pictures are tagged BT.709 as the
# stream is, so the colours compare with AVKit's). The colours are
# stated on the pictures (setparams), so the encoder writes them into the
# stream and the muxer into the container; hdr10-vui.mkv's go to the encoder
# only (x265's own parameters).
hdr() {
  local out=$1 colours=$2 params=$3; shift 3
  "$FFMPEG" -loglevel error -y -f lavfi -i "smptebars=s=${SIZE:-320x180}:r=10:d=2" -an \
    -vf "format=yuv420p10le,setparams=range=tv:$colours" -c:v libx265 -preset fast -crf 28 \
    -x265-params "log-level=error:keyint=10$params" \
    "$@" -fflags +bitexact -flags:v +bitexact "$out"
}
draw_hdr() {
  local hdr10=":hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400"
  local pq="color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc"
  hdr "$OUT/hdr10.mkv" "$pq" "$hdr10"
  hdr "$OUT/hdr10-vui.mkv" "colorspace=bt2020nc" ":colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc$hdr10"
  hdr "$OUT/hlg.mkv" "color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc" ""
  hdr "$OUT/sdr10.mkv" "color_primaries=bt709:color_trc=bt709:colorspace=bt709" ""
  hdr UITests/Fixtures/hdr10.mp4 "$pq" "$hdr10" -tag:v hvc1 -movflags +faststart
  SIZE=1280x720 hdr UITests/Fixtures/sdr10.mp4 "color_primaries=bt709:color_trc=bt709:colorspace=bt709" "" \
    -tag:v hvc1 -movflags +faststart
  cp "$OUT/hdr10.mkv" UITests/Fixtures/hdr10.mkv
}
if [ "${1:-}" = hdr ]; then draw_hdr; exit 0; fi

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
# German subtitles over the whole length, a line every 2 s as in a film (a
# player shows a track chosen or switched off from the next line on at the
# latest); the English ones are the default.
# MP4: mov_text (3GPP timed text) for both; MKV: SubRip and ASS.
SUBS=$(mktemp -d)
trap 'rm -rf "$SUBS"; [ -n "${finished:-}" ] || exit 1' EXIT
lines() {
  for i in 0 1 2 3 4 5 6 7 8 9; do
    printf '%d\n00:00:%02d,000 --> 00:00:%02d,000\n%s\n\n' $((i + 1)) $((i * 2)) $((i * 2 + 2)) "$1"
  done
}
lines "SUBTITLE ONE" > "$SUBS/en.srt"
lines "UNTERTITEL ZWEI" > "$SUBS/de.srt"
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

# ramp.mkv: 20 s whose grey rises with time (luma 32 + 9 per second, the
# same over the whole picture), the English SubRip lines of tracks.mkv, no
# sound: a picture's brightness tells its time, so a UI test sees where
# VLC goes on after opening the video again for subtitles.
"$FFMPEG" -loglevel error -y -f lavfi -i "nullsrc=s=640x360:r=10:d=20,geq=lum='32+9*T':cb=128:cr=128,format=yuv420p" \
  -i "$SUBS/en.srt" -map 0:v -map 1:s -c:v libx264 -pix_fmt yuv420p -g 10 -c:s srt \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -disposition:s:0 default \
  -fflags +bitexact -flags:v +bitexact UITests/Fixtures/ramp.mkv

# tracks720.mkv: 10 s of even grey at 1280 × 720, the German ASS lines first
# (the default) and the English SubRip ones second, no sound: the app's own
# subtitle lines compared with VLC's at another size than tracks.mkv's.
"$FFMPEG" -loglevel error -y -f lavfi -i "color=c=0x808080:s=1280x720:r=10:d=10" \
  -i "$SUBS/de.ass" -i "$SUBS/en.srt" -map 0:v -map 1:s -map 2:s -c:v libx264 -pix_fmt yuv420p -g 10 -c:s:0 ass -c:s:1 srt \
  -metadata:s:s:0 language=deu -metadata:s:s:0 title=Deutsch -metadata:s:s:1 language=eng -metadata:s:s:1 title=English \
  -disposition:s:0 default -disposition:s:1 0 -t 10 \
  -fflags +bitexact -flags:v +bitexact UITests/Fixtures/tracks720.mkv
draw_hdr
finished=1
