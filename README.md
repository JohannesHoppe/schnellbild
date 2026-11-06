<p align="center">
  <img src="Resources/icon-256.png" width="168" alt="Schnellbild app icon">
</p>

<h1 align="center">Schnellbild</h1>

<p align="center">
  <a href="https://github.com/johanneshoppe/schnellbild/actions/workflows/ci.yml"><img src="https://github.com/johanneshoppe/schnellbild/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center"><b>The fast macOS image &amp; video viewer that doesn't choke on network folders.</b></p>

<!-- Demo: record per docs/launch-storyboard.md, save as docs/demo.gif, then
     uncomment the next line:
<p align="center"><img src="docs/demo.gif" width="680" alt="Schnellbild in action"></p>
-->

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/grid-dark.png">
  <img src="docs/screenshots/grid-light.png" width="820" alt="Schnellbild: folders with previews and photo thumbnails">
</picture></p>

Open a folder, see thumbnails, look at one picture large, page through with the keyboard. Videos play right there, too, even AVI, MKV and WebM. Nothing more, but without stalling, even over network volumes where other viewers crawl.

Schnellbild does what macOS Preview does well: read little, load in parallel, let the system cache, never block the UI.

## Download

**[Schnellbild.dmg](https://github.com/JohannesHoppe/schnellbild/releases/latest/download/Schnellbild.dmg)** (macOS 14+, Apple silicon): open it and drag Schnellbild into Applications. Signed with a Developer ID and notarized by Apple.

## Features

### Browse folders

Open a folder with ⌘O or drag it onto the window; drag a single file to open it straight in the full view. Subfolders come first, each previewing its first pictures like Finder, with a `..` tile to go up. Thumbnails come from QuickLook, so everything macOS can preview shows up: JPEG, HEIC, PNG, RAW, PSD, PDF, and a poster frame for videos. Schnellbild reopens the last folder on launch.

| Key | Action |
|---|---|
| ← → | previous / next item |
| ↑ ↓ | one row up / down |
| Return / Space | open the picture or video, or enter the folder |
| Backspace / ⌘↑ | up one folder level |
| Home / End | first / last item |
| ⌘+ / ⌘− | larger / smaller thumbnails |
| ⌘[ / ⌘] | back / forward, restoring the folder, the search and the selection |
| f | full screen |

### Sort

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/sort-dark.png">
  <img src="docs/screenshots/sort-light.png" width="760" alt="The sort menu in the toolbar">
</picture></p>

By name, kind, date modified, date taken or size, from the toolbar or with one key. The same key again reverses the order. Date taken reads the camera's capture date (EXIF, or the video's creation date), so copied photos still line up in the order they were shot. Dates and sizes start newest and largest first, like Finder. Schnellbild remembers the order.

| Key | Action |
|---|---|
| ⌘1 … ⌘5 | sort by name, kind, date modified, date taken, size (again: reverse) |

### Search, including subfolders

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/search-dark.png">
  <img src="docs/screenshots/search-light.png" width="760" alt="Search results from the folder and its subfolders">
</picture></p>

The search field is always there. It matches folder and file names in the current folder and everything below it; results stream in while the tree is walked and show where they live. Back from an opened result returns to the same results.

| Key | Action |
|---|---|
| ⌘F | focus the search field |
| ↓ | move into the results |
| Return | open the selected result |
| Esc | clear the search, leave the field |

### Full view

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/full-dark.png">
  <img src="docs/screenshots/full-light.png" width="760" alt="A photo in the full view">
</picture></p>

One picture, as large as the window allows, with its position in the folder. The full image is sampled to screen size, the thumbnail shows instantly until it's there. Animated GIFs play.

| Key | Action |
|---|---|
| ← → | previous / next picture (on a video: see below) |
| ⌘← ⌘→ ↑ ↓ | previous / next item, also from a video |
| Space | next picture |
| s | slideshow |
| Esc / Backspace / Return | back to the grid, at the same place |

### Zoom and rotate

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/zoom-dark.png">
  <img src="docs/screenshots/zoom-light.png" width="760" alt="A photo zoomed in">
</picture></p>

Zoom with the keyboard or a trackpad pinch, drag to pan, rotate in steps of 90°. Only the view changes; Schnellbild never modifies your files.

| Key | Action |
|---|---|
| + / − (or ⌘+ / ⌘−) | zoom in / out |
| 0 / 1 | fit to window / 100 % |
| [ / ] | rotate left / right |

### Videos

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/video-dark.png">
  <img src="docs/screenshots/video-light.png" width="760" alt="A video in the full view, paused">
</picture></p>

Videos play right away, MP4 and MOV through AVKit, formats macOS can't play (AVI, MKV, WebM …) through the built-in VLC engine. The arrow keys skim: each press jumps a tenth of the video ahead or back, past the end on to the next item. So one key pages through photos and skims through videos; ⌘← ⌘→ skip a video at once.

| Key | Action |
|---|---|
| Space | play / pause |
| ← → | skip a tenth back / ahead; at the end on to the next item, at the start back to the previous one |
| ⌘← ⌘→ | previous / next item straight away |

### File info

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/inspector-dark.png">
  <img src="docs/screenshots/inspector-light.png" width="760" alt="The file inspector over a photo">
</picture></p>

Name, type, resolution, size and date of the item on screen.

| Key | Action |
|---|---|
| i | show / hide the file info |

### Rename, reveal, trash

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/rename-dark.png">
  <img src="docs/screenshots/rename-light.png" width="760" alt="Renaming a folder">
</picture></p>

Rename a folder in place (F2, the Actions menu, or right-click); the search results and the history follow the new name. Reveal an item in Finder, open it in its default app, or move it to the Trash after a confirmation.

| Key | Action |
|---|---|
| F2 | rename the selected folder |
| ⇧⌘R | reveal in Finder |
| ⌘↩ | open with the default app |
| ⌘⌫ | move to Trash |

### All keys at hand

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/help-dark.png">
  <img src="docs/screenshots/help-light.png" width="760" alt="The keyboard cheat sheet">
</picture></p>

F1 (or ⌘?) shows every key in the app.

## Why so fast?

1. **Riding on the system.** Thumbnails come from Apple's QuickLook (`QLThumbnailGenerator`). It pulls **embedded previews** (EXIF thumbnail, JPEG in RAW): a few KB instead of tens of MB over the network, for any format QuickLook knows, including third-party plugins. The cache lives in the system; Schnellbild has no cache code of its own.
2. **Lazy and parallel.** The grid only loads the tiles on screen, and the system runs thumbnail generation in parallel.
3. **Full view downsampled.** The full picture is read through ImageIO and sampled straight to screen size, no 8000 px monster in memory. The thumbnail shows instantly as a placeholder.
4. **Nothing blocks the main thread.** Reading folders, searching and decoding run in the background.

## Status

Early, but already a usable daily driver. Known limits:

- The slideshow interval is fixed at 3 s.
- `1` (100 %) is approximate (it assumes the main display's scale).
- Animated GIFs don't zoom or pan.

Building from source, tests and releases: [BUILDING.md](BUILDING.md).

## License

[MIT](LICENSE) © 2026 HAUS HOPPE - ITS (Johannes Hoppe)
