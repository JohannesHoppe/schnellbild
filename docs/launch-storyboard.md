# Demo GIF — storyboard

The GIF has one job: in the first 3 seconds, convey "damn, that's fast" — or
people scroll past on HN/Reddit. Everything below serves that. Keep it ~25–30 s,
silent, looping.

## Shot list (beat → what it proves)

**0–4 s — The hook: thumbnails snap in.**
Open a folder (drag it onto the window, or ⌘O) → tiles fill in *instantly*. Use a
**mixed folder**: photos + a **RAW/PSD** + a **PDF** + a **video** (poster frame).
One shot shows both *speed* and *QuickLook breadth*. **If at all possible, a
folder on the network share** — that's the whole story.

**4–9 s — Keyboard navigation.**
Arrow keys race through the grid, selection moving → Return → one image big →
←/→ in the full view, large images switching with no load hitch (shows the
ImageIO-downsampled full view). This is the core loop: browse fast with keys.

**9–14 s — Breadth, fast.**
Quickly: `[`/`]` rotate, one `+` zoom, then briefly play a **video** (ideally an
**AVI**, to show the VLCKit fallback in passing). Keep moving, don't linger.

**14–19 s — Search (what Preview can't do).**
⌘F → type three letters → grid filters live → flip to "Subfolders" → recursive
matches pop in. A clear differentiator.

**19–24 s — Folder nav + F1.**
Into a subfolder (Return on a folder tile), Backspace back up (Norton `..`) →
**F1** → shortcut cheat sheet flashes → Esc. Signals "thought-through, fully
keyboard-driven."

→ loop cleanly back to the grid.

Each beat maps to a claim in the pitch. Order is deliberate: speed first (the
scroll-stopper), polish (F1) last.

## Production notes

- **Window ~1280×800**, not fullscreen → legible at 680 px wide (matches the
  README slot).
- **Dark mode** (looks premium for a media viewer), 15 fps, 680 px wide, looping,
  **silent**.
- **Neutral sample files** — no private/identifiable filenames on screen.
- Don't let the mouse hunt around; deliberate key moves, hide the cursor where
  possible.

## Honest caveat

A GIF sells the *feel* ("looks snappy") but doesn't *prove* speed — there's no
reference. The real proof is a **"Schnellbild vs. Preview over the network"
benchmark**. Ideal: GIF for the eye, a benchmark number/clip for the skeptics in
the comments.

## Recipe

1. `⌘⇧5` → record the Schnellbild window region → save the `.mov`.
2. Convert (needs `ffmpeg`, or `brew install gifski` for sharper output):

   ```bash
   # ffmpeg (two-pass palette):
   ffmpeg -i demo.mov -vf "fps=15,scale=680:-1:flags=lanczos,palettegen" /tmp/p.png
   ffmpeg -i demo.mov -i /tmp/p.png -lavfi "fps=15,scale=680:-1:flags=lanczos[x];[x][1:v]paletteuse" -loop 0 docs/demo.gif

   # …or gifski (sharper):
   gifski --fps 15 --width 680 -o docs/demo.gif demo.mov
   ```
3. Drop it at `docs/demo.gif` and uncomment the demo line near the top of `README.md`.
