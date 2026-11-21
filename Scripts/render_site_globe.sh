#!/bin/bash
# Renders the home page footer's globe band, docs/hero/globe-<light|dark>-<1600|3200|phone>.webp,
# with Scripts/render_globe_hero.sh: the app's globe without sky (--transparent), the world
# trip's photos on it, the top fading out into the page.
#   light: the day side over the Sahara, looking north across the Mediterranean
#          (the Sun behind the camera, 21 June 10:30 UTC)
#   dark:  the night side over Italy, looking north-east, the Sun just below the
#          horizon (21 June 02:06 UTC)
#   wide:  1600 × 500 pt at 2× (3200 × 1000 px), also scaled to 1600 px
#   phone: 600 × 450 pt at 2× (1200 × 900 px), a longer lens
# The renders go to build/site-globe/ as PNG, the WebPs (lossy at quality 80, lossless
# alpha, -exact) to docs/hero or the folder given:
#   Scripts/render_site_globe.sh [<out folder>]
# Needs the globe's and the map's data (Scripts/fetch_globe.sh, Scripts/fetch_map.sh), the
# world trip's photos in build/world-photos (Scripts/fetch_world_photos.sh build/world-photos)
# and cwebp (Homebrew's webp).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="${1:-$ROOT/docs/hero}"
PNG="$ROOT/build/site-globe"
mkdir -p "$PNG" "$OUT"

render() {
    local name="$1"; shift
    ./Scripts/render_globe_hero.sh "$@" --transparent --out="$PNG/$name.png" > /dev/null
}
render light-wide  --camera=34,16,5,75.56,5 --lens=16 --distance=0.9  --size=1600x500 --fade-top=150 --date=2026-06-21T10:30:00Z --theme=light
render light-phone --camera=36,16,5,68.38,5 --lens=32 --distance=0.9  --size=600x450  --fade-top=120 --date=2026-06-21T10:30:00Z --theme=light
render dark-wide   --camera=41,16,5,76.68,48 --lens=16 --distance=0.75 --size=1600x500 --fade-top=150 --date=2026-06-21T02:06:00Z --theme=dark
render dark-phone  --camera=41,16,5,77,48 --lens=32 --distance=0.75 --shift=-40 --size=600x450 --fade-top=120 --date=2026-06-21T02:06:00Z --theme=dark

for theme in light dark; do
    for w in 1600 3200; do
        cwebp -quiet -q 80 -alpha_q 100 -exact -resize "$w" 0 "$PNG/$theme-wide.png" -o "$OUT/globe-$theme-$w.webp"
    done
    cwebp -quiet -q 80 -alpha_q 100 -exact "$PNG/$theme-phone.png" -o "$OUT/globe-$theme-phone.webp"
done
ls -l "$OUT"/globe-*.webp
finished=1
