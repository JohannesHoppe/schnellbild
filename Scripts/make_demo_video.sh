#!/bin/bash
# Cuts and encodes the demo video from the recording of
# .github/workflows/demo-video.yml (its artifact: raw.mov and marks.txt):
#
#   Scripts/make_demo_video.sh <artifact folder> <out folder>
#
# Writes into <out folder>
#   demo-<w>.mp4      the website's video, H.264 (every browser), no sound
#   demo-<w>.webm     the same as AV1 in WebM (smaller; browsers that play it
#                     take it first)
#   demo-poster-<w>.webp / .jpg  its first picture, shown before it plays
#   appstore-preview.mp4  the App Store's app preview: 1920 × 1080, 30 fps,
#                     H.264 High at level 4.0, about 10 Mbps, a silent stereo
#                     AAC track (App Store Connect turns away previews without
#                     sound), at most 30 s
# for each width in WIDTHS (default "1024 640"). The cut starts LEAD seconds
# before the first scene's mark ("grid") and ends TAIL seconds after the
# tour ended ("atlas again"); the App Store's cut is the same, sped up when
# it is longer than 30 s and held to at least 15 s.
# Needs ffmpeg with libx264 and libsvtav1, and cwebp (libwebp).
set -euo pipefail
[ $# = 2 ] || { echo "usage: $0 <artifact folder> <out folder>"; exit 1; }
in=$1 out=$2
WIDTHS=${WIDTHS:-"1024 640"}
LEAD=${LEAD:-0.3}
TAIL=${TAIL:-2}
raw="$in/raw.mov"; marks="$in/marks.txt"
[ -f "$raw" ] && [ -f "$marks" ] || { echo "$in needs raw.mov and marks.txt"; exit 1; }
mkdir -p "$out"

mark() { awk -v name="$1" '$1 == "DEMO-MARK" { $1 = ""; t = $2; $2 = ""; sub(/^ +/, ""); if ($0 == name) { print t; exit } }' "$marks"; }
recording=$(awk '$1 == "DEMO-RECORDING" { print $2; exit }' "$marks")
first=$(mark grid); last=$(mark "atlas again")
[ -n "$recording" ] && [ -n "$first" ] && [ -n "$last" ] || { echo "marks missing in $marks"; exit 1; }
start=$(python3 -c "print(max(0, $first - $recording - $LEAD))")
length=$(python3 -c "print($last - $first + $LEAD + $TAIL)")
echo "cut: from $start s, $length s long"

size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$raw")
echo "recording: $size, $(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 "$raw") fps"

# The cut, once, losslessly: every encode below starts from it
cut="$out/.cut.mkv"
ffmpeg -v error -y -ss "$start" -i "$raw" -t "$length" -an -c:v libx264 -preset veryfast -crf 0 -pix_fmt yuv444p "$cut"

for w in $WIDTHS; do
    scale="scale=$w:-2:flags=lanczos,fps=30,format=yuv420p"
    ffmpeg -v error -y -i "$cut" -vf "$scale" -c:v libx264 -preset slow -crf 26 -profile:v high \
        -movflags +faststart -an "$out/demo-$w.mp4"
    ffmpeg -v error -y -i "$cut" -vf "$scale" -c:v libsvtav1 -preset 4 -crf 38 -g 300 \
        -an "$out/demo-$w.webm"
    ffmpeg -v error -y -i "$cut" -frames:v 1 -vf "scale=$w:-2:flags=lanczos" "$out/.poster-$w.png"
    cwebp -quiet -q 85 "$out/.poster-$w.png" -o "$out/demo-poster-$w.webp"
    ffmpeg -v error -y -i "$out/.poster-$w.png" -q:v 3 "$out/demo-poster-$w.jpg"
    rm "$out/.poster-$w.png"
done

# The App Store's preview: 15 to 30 s, 1920 × 1080 (the recording scaled
# to fit, on the window's own background colour where its shape differs)
speed=$(python3 -c "print(max(1.0, $length / 29.5))")
pad=$(python3 -c "print(min(15.0, max(0.0, 15.2 - $length / max(1.0, $length / 29.5))))")
ffmpeg -v error -y -i "$cut" -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
    -filter_complex "[0:v]setpts=PTS/$speed,scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=${PAD_COLOUR:-#f5f5f7},fps=30,tpad=stop_mode=clone:stop_duration=$pad,format=yuv420p[v]" \
    -map "[v]" -map 1:a -shortest -c:v libx264 -preset slow -profile:v high -level:v 4.0 \
    -b:v 10M -maxrate 12M -bufsize 20M -c:a aac -b:a 256k -ar 48000 -ac 2 -movflags +faststart \
    "$out/appstore-preview.mp4"
rm "$cut"
ls -l "$out"
