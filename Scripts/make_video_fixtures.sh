#!/bin/bash
# Draws one short clip per video format Schnellbild shows into
# Tests/SchnellbildTests/Videos, all from UITests/Fixtures/clip.mp4 (2 s,
# a keyframe every half second, as camcorders and encoders write them), and
# Resources/FormatsCheck.mkv (the app's copy of clip.mkv), the UI tests'
# videos with two audio and two subtitle tracks
# (UITests/Fixtures/tracks.mp4 and tracks.mkv), the HDR clips (`hdr` as
# the only argument draws just those), the AC-3 / E-AC-3 sound (`sound`)
# Teletext subtitles (`teletext`) and the visual check's clips of the
# reference picture (`visual`).
# Needs ffmpeg (with libx265 for the HDR clips) and, for `visual`, swiftc;
# the clips are committed, so
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

# Downloads not finished and names that say nothing (UITests/Fixtures/partial,
# `partial` as the only argument draws just those): 10 s of ffmpeg's test
# picture as an MP4 with its index first, cut after 60 % of its bytes (plays
# as far as its data reaches), the same with its index last (can't play until
# the rest arrives), as Matroska, cut the same way; a JPEG without an
# extension and a whole MP4 named ".xyz".
draw_partial() {
  local P=UITests/Fixtures/partial whole
  whole=$(mktemp -d)
  mkdir -p "$P"
  clip10() {
    local out=$1; shift
    "$FFMPEG" -loglevel error -y -f lavfi -i "testsrc2=s=320x180:r=10:d=10" -an -c:v libx264 -pix_fmt yuv420p -g 10 \
      "$@" -fflags +bitexact -flags:v +bitexact "$whole/$out"
  }
  cut60() { head -c $(( $(wc -c < "$1") * 6 / 10 )) "$1" > "$2"; }
  clip10 front.mp4 -movflags +faststart
  clip10 end.mp4
  clip10 film.mkv
  cut60 "$whole/front.mp4" "$P/front.mp4.part"
  cut60 "$whole/end.mp4" "$P/end.mp4.part"
  cut60 "$whole/film.mkv" "$P/film.mkv.part"
  cp "$whole/front.mp4" "$P/video.xyz"
  cp UITests/Fixtures/large.jpg "$P/photo"
  rm -rf "$whole"
}
if [ "${1:-}" = partial ]; then draw_partial; exit 0; fi

# Sound VLC decodes through FFmpeg (SoundCodecTests; `sound` as the only
# argument draws just these): 2 s of a 440 Hz tone, stereo at 48 kHz, as
# AC-3 and as E-AC-3 in Matroska.
draw_sound() {
  local codec
  for codec in ac3 eac3; do
    "$FFMPEG" -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" -ac 2 \
      -c:a "$codec" -b:a 192k -fflags +bitexact -flags:a +bitexact "$OUT/$codec.mkv"
  done
}
if [ "${1:-}" = sound ]; then draw_sound; exit 0; fi

# Teletext subtitles (TeletextTests; `teletext` as the only argument draws
# just this): 6 s of even grey as H.264 in a transport stream, with
# Teletext page 888 showing one line from the start
# (Scripts/make_teletext_fixture.py; ffmpeg doesn't write Teletext).
draw_teletext() {
  local video
  video=$(mktemp -d)
  "$FFMPEG" -loglevel error -y -f lavfi -i "color=c=0x808080:s=640x360:r=25:d=6" -an -c:v libx264 -pix_fmt yuv420p -g 25 \
    -mpegts_pmt_start_pid 0x1000 -mpegts_start_pid 0x100 -fflags +bitexact -flags:v +bitexact -f mpegts "$video/video.ts"
  python3 -I Scripts/make_teletext_fixture.py "$video/video.ts" "$OUT/teletext.ts" "TELETEXT LINE"
  rm -rf "$video"
}
if [ "${1:-}" = teletext ]; then draw_teletext; exit 0; fi

# The visual check's clips (FormatVisualTests; `visual` as the only argument
# draws just these): the reference picture's 20 frames at 10 per second,
# each shown for 2.5 pictures at 25 per second (MPEG-1 and MPEG-2 know no
# 10) (Tests/SchnellbildTests/ReferencePicture.swift, written by
# Scripts/reference_frames.swift: a marker moving right, the frame's number
# as digits and as blocks the test reads back), as visual.<ext> in each
# format whose look is checked against those frames.
draw_visual() {
  local frames
  frames=$(mktemp -d)
  swiftc -parse-as-library Tests/SchnellbildTests/ReferencePicture.swift Scripts/reference_frames.swift -o "$frames/reference_frames"
  "$frames/reference_frames" "$frames" 20
  visual() {
    local name=$1; shift
    "$FFMPEG" -loglevel error -y -framerate 10 -i "$frames/frame-%02d.png" -an -r 25 -g 12 "$@" \
      -fflags +bitexact -flags:v +bitexact "$OUT/visual.$name"
  }
  visual asf  -c:v wmv2 -q:v 3 -pix_fmt yuv420p -f asf
  visual divx -c:v mpeg4 -q:v 3 -pix_fmt yuv420p -vtag DX50 -f avi
  visual m2t  -c:v mpeg2video -q:v 3 -pix_fmt yuv420p -f mpegts
  visual m1v  -c:v mpeg1video -q:v 3 -pix_fmt yuv420p -f mpeg1video
  visual ogm  -c:v libvpx -crf 10 -b:v 1M -pix_fmt yuv420p -f ogg
  visual f4v  -c:v libx264 -crf 18 -pix_fmt yuv420p -f f4v
  visual rm   -c:v rv20 -q:v 3 -pix_fmt yuv420p -f rm
  visual mxf  -c:v mpeg2video -q:v 3 -pix_fmt yuv422p -f mxf
  visual insv -c:v libx264 -crf 18 -pix_fmt yuv420p -f mp4
  # RealMedia's variable-bitrate name and GoPro MAX's ".360": the same files
  cp "$OUT/visual.rm" "$OUT/visual.rmvb"
  cp "$OUT/visual.insv" "$OUT/visual.360"
  # The tiles' colours against the full view's with the colours stated:
  # HD BT.709 (1152 × 720, each pixel three times) and SD BT.601, each as
  # Matroska (VLC) and MP4 (AVFoundation); stated on the pictures
  # (setparams), as the PNGs' own sRGB would otherwise be written. The MP4s
  # are keyframes only: QuickLook on CI's virtual Macs (macOS 15 and 26)
  # drew the frame it took from a group of 12 with the bars' right half
  # green, a Mac with a GPU the same file right; with keyframes only the SD
  # clip's comes right there, the HD clip's still not (FormatVisualTests)
  local hd709=(-vf "scale=1152:720:flags=neighbor:out_color_matrix=bt709:out_range=tv,format=yuv420p,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709")
  local sd601=(-vf "scale=out_color_matrix=bt601:out_range=tv,format=yuv420p,setparams=range=tv:color_primaries=smpte170m:color_trc=smpte170m:colorspace=smpte170m")
  visual bt709.mkv "${hd709[@]}" -c:v libx264 -crf 18
  visual bt601.mkv "${sd601[@]}" -c:v libx264 -crf 18
  visual bt709.mp4 "${hd709[@]}" -c:v libx264 -crf 18 -g 1
  visual bt601.mp4 "${sd601[@]}" -c:v libx264 -crf 18 -g 1
  # Pictures ImageIO reads but doesn't write: an AVIF sequence (AV1, its
  # frames at 10 per second) and AVC in HEIF (the first frame, wrapped by
  # Scripts/make_avci.py), both BT.709 limited range with sRGB's transfer, as stated
  local bt709=(-vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" -colorspace bt709 -color_primaries bt709
               -color_trc iec61966-2-1 -color_range tv)
  SVT_LOG=1 "$FFMPEG" -loglevel error -y -framerate 10 -i "$frames/frame-%02d.png" "${bt709[@]}" -c:v libsvtav1 -crf 20 -g 10 \
    -fflags +bitexact -flags:v +bitexact -f avif "$OUT/visual.avifs"
  "$FFMPEG" -loglevel error -y -i "$frames/frame-00.png" "${bt709[@]}" -frames:v 1 -c:v libx264 -profile:v main -crf 12 \
    -bsf:v filter_units=remove_types=6 -fflags +bitexact -flags:v +bitexact -f h264 "$frames/still.h264"
  python3 -I Scripts/make_avci.py "$frames/still.h264" "$OUT/visual.avci" 384 240
  rm -rf "$frames"
}
if [ "${1:-}" = visual ]; then draw_visual; exit 0; fi

make() { local name=$1; shift; "$FFMPEG" -loglevel error -y -i UITests/Fixtures/clip.mp4 -t 2 -an -g 12 "$@" "$OUT/$name"; }
make clip.mkv  -c:v libx264 -pix_fmt yuv420p
# The app's own check whether the user turned the media extension on (MediaFormats.isOn)
cp "$OUT/clip.mkv" Resources/FormatsCheck.mkv
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
make clip.ogm  -c:v libvpx -crf 30 -b:v 200k -f ogg
make clip.f4v  -c:v libx264 -pix_fmt yuv420p -f f4v
make clip.divx -c:v mpeg4 -q:v 8 -vtag DX50 -f avi
make clip.m2t  -c:v mpeg2video -q:v 8 -f mpegts
make clip.m1v  -c:v mpeg1video -q:v 8 -f mpeg1video
make clip.rm   -c:v rv20 -q:v 8 -f rm
make clip.mxf  -c:v mpeg2video -q:v 8 -pix_fmt yuv422p -f mxf
# RealMedia's variable-bitrate name, and the MP4 files of 360° cameras
# (Insta360 ".insv", GoPro MAX ".360"): the same files
cp "$OUT/clip.rm" "$OUT/clip.rmvb"
cp "$OUT/clip.mp4" "$OUT/clip.insv"
cp "$OUT/clip.mp4" "$OUT/clip.360"
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

# asstags.mkv: 10 s of even grey at 1280 × 720, the English SubRip lines
# first (the default) and second an ASS track whose lines carry override
# tags, two events every 2 s: one at the top (\an8) in red, bold and larger
# with a white outline, one placed by \pos at its bottom left in two lines,
# italic, underlined, in Courier New with a deeper shadow. The app's own
# line compared with VLC's (libass) where the tags put it.
asstags() {
  cat <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,40,40,30,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
ASS
  local i from to
  for i in 0 1 2 3 4; do
    from=$(printf '0:00:%02d.00' $((i * 2))); to=$(printf '0:00:%02d.00' $((i * 2 + 2)))
    echo "Dialogue: 0,$from,$to,Default,,0,0,0,,{\\an8\\fs60\\b1\\c&H0000FF&\\3c&HFFFFFF&\\bord3}TOP LINE"
    echo "Dialogue: 0,$from,$to,Default,,0,0,0,,{\\pos(320,500)\\an1\\i1\\u1\\fnCourier New\\fs40\\shad4}LEFT\\NPOS"
  done
}
asstags > "$SUBS/tags.ass"
"$FFMPEG" -loglevel error -y -f lavfi -i "color=c=0x808080:s=1280x720:r=10:d=10" \
  -i "$SUBS/en.srt" -i "$SUBS/tags.ass" -map 0:v -map 1:s -map 2:s -c:v libx264 -pix_fmt yuv420p -g 10 -c:s:0 srt -c:s:1 ass \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -metadata:s:s:1 language=deu -metadata:s:s:1 title=Tags \
  -disposition:s:0 default -disposition:s:1 0 -t 10 \
  -fflags +bitexact -flags:v +bitexact UITests/Fixtures/asstags.mkv
draw_hdr
draw_sound
draw_teletext
draw_visual
finished=1
