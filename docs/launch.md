# Launch material

Honest, low-hype copy for validating demand. Lead with the pain (slow viewers
over the network), be upfront about scope (it's a *viewer*, not an editor).

---

## Show HN

**Title:** Show HN: Schnellbild – a fast macOS image/video viewer that doesn't choke on network folders

**Body:**

I kept getting annoyed that image viewers crawl when I browse folders on a
network share (NAS), while macOS Preview stays smooth. So I built the lean
viewer I actually wanted: open a folder, thumbnails appear right away, arrow
through them, one image big. Nothing more.

Why it stays fast — the same tricks Preview uses that most viewers skip:

- Thumbnails come from Apple's QuickLook (`QLThumbnailGenerator`). It pulls the
  *embedded* preview (EXIF thumbnail, JPEG-in-RAW), so it reads a few KB over the
  network instead of tens of MB — and supports RAW/PSD/PDF/HEIC plus video
  poster frames for free.
- Lazy, parallel thumbnail loading; the full view downsamples via ImageIO to
  screen size (no 8000px image sitting in RAM); nothing blocks the main thread.

Kept deliberately lean: folder navigation (Norton-style `..`), keyboard-first
(Phiewer-like bindings, F1 cheat sheet), search (current folder + optional
recursive), zoom/pan/pinch/rotate (view-only — never touches your files), video
via AVKit with a VLCKit fallback for AVI/MKV/WebM, animated GIFs, slideshow,
sort, trash, light/dark.

SwiftUI, ~1k LOC, MIT, unit + XCUITest E2E, CI. macOS 14+.

It's a viewer, not an organizer — no library, no tagging, no AI. If you browse
big image folders (especially over a network) and just want something that
doesn't lag, this is for you.

Repo: https://github.com/JohannesHoppe/schnellbild

Feedback very welcome — especially: does it feel faster than Preview on *your*
network setup?

---

## r/macapps

**Title:** I built Schnellbild — a fast, keyboard-driven image/video viewer (free, open source)

**Body:**

Preview is great, but it stutters for me when I browse photo folders on my NAS,
and the fancier viewers feel bloated. So I made a small one that does just the
core well: open a folder → instant thumbnails → big image → arrow keys. Fast,
even over the network.

- Rides macOS QuickLook for thumbnails, so RAW/PSD/PDF/HEIC and video posters
  just work, and it reads embedded previews instead of whole files.
- Keyboard-first (F1 shows all shortcuts), folder browsing, search (with
  optional subfolder search), zoom/rotate, slideshow, video (incl. AVI/MKV via
  a bundled VLCKit fallback), animated GIFs, light/dark.
- Free and open source (MIT). macOS 14+.

Download/build: https://github.com/JohannesHoppe/schnellbild

Would love to know if it feels snappier than what you use now — particularly on
network volumes.

---

## Recording the demo GIF

Screen recording can't be automated here, so record it by hand (30–40 s):

1. Put a folder with a mix of images (incl. a RAW/PSD and a video) on a network
   share if you have one — the speed is the story.
2. `⌘⇧5` → record the Schnellbild window region → save the `.mov`.
   Show the flow: open folder → thumbnails fill in → arrow keys → one big image
   → `[`/`]` rotate → `⌘F` search → Esc back.
3. Convert to a tidy GIF (needs `ffmpeg`, or `brew install gifski` for nicer output):

   ```bash
   # ffmpeg (good, two-pass palette):
   ffmpeg -i demo.mov -vf "fps=15,scale=680:-1:flags=lanczos,palettegen" /tmp/p.png
   ffmpeg -i demo.mov -i /tmp/p.png -lavfi "fps=15,scale=680:-1:flags=lanczos[x];[x][1:v]paletteuse" -loop 0 docs/demo.gif

   # …or gifski (sharper):
   gifski --fps 15 --width 680 -o docs/demo.gif demo.mov
   ```
4. Drop it at `docs/demo.gif` and uncomment the demo line near the top of `README.md`.

Keep it short and silent; the first 3 seconds (thumbnails snapping in) are what
sell it.
