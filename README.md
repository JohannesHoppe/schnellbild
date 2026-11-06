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

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/grid-dark.png">
  <img src="docs/screenshots/grid-light.png" width="820" alt="Schnellbild: folder grid with folder previews and thumbnails">
</picture>
</p>

A **fast** file/image viewer for macOS. Open a folder, see thumbnails,
view one image large, page through with the keyboard. Nothing more — but
without stalling, even over network volumes.

Born out of frustration with viewers that crawl over the network while
**macOS Preview** stays smooth. Schnellbild does exactly what Preview does:
read little, load in parallel, cache aggressively, never block the UI thread.

## Why so fast? (The four tricks)

1. **Riding on the system.** Thumbnails come from Apple's
   `QLThumbnailGenerator` (QuickLook). The framework automatically pulls
   **embedded previews** (EXIF thumbnail, JPEG-in-RAW) — a few KB instead of
   tens of MB over the network — and handles **any format** QuickLook knows
   (JPEG, PNG, HEIC, RAW, PSD, PDF …), including third-party plugins. The
   persistent cache lives in the system; we write **zero cache code**.

2. **Lazy & parallel.** The grid (`LazyVGrid`) only loads visible tiles. The
   system throttles thumbnail generation concurrently on its own.

3. **Full view downsampled.** The full-size view loads the real image, but via
   `ImageIO` (`CGImageSourceCreateThumbnailAtIndex`) sampled directly to screen
   size — no 8000px monster in RAM. The already-available thumbnail appears
   instantly as a placeholder.

4. **Nothing blocks the main thread.** Directory scanning and full decoding
   run in `Task.detached`.

## Download

**[Schnellbild.dmg](https://github.com/JohannesHoppe/schnellbild/releases/latest/download/Schnellbild.dmg)** (macOS 14+, Apple silicon) — open it and drag Schnellbild into Applications. Signed with a Developer ID and notarized by Apple.

## Build & Run

> **Requirement:** a full **Xcode** install (not just the Command Line Tools —
> those have no macOS platform metadata and can't build SwiftUI).

```bash
# Activate Xcode (one-time):
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# In the project folder:
./Scripts/fetch_vlckit.sh   # vendors the official VLCKit once (~80 MB download)
swift build
swift run                   # starts the app
./Scripts/test.sh           # run the unit tests
# …or open in Xcode:
open Package.swift
```

> Video formats macOS can't play natively (AVI, MKV, WebM …) are handled by a
> vendored **VLCKit** (official VideoLAN binary, fetched and SHA-256-verified by
> `Scripts/fetch_vlckit.sh`; gitignored). Native formats stay on AVKit.

To produce a proper **`.app` bundle** (icon + Info.plist, ad-hoc signed):

```bash
./Scripts/build_app.sh      # → build/Schnellbild.app
```

The icon is generated from `Scripts/make_icon.swift` (CoreGraphics, no external
tools). CI builds, tests, and packages the app on every push; tagging `vX.Y.Z`
publishes a GitHub Release with the zipped app.

## Tests

Logic unit tests run via SwiftPM (the script vendors VLCKit and copies it into
the test bundle, since SwiftPM doesn't embed binary frameworks there):

```bash
./Scripts/test.sh
```

End-to-end UI tests use XCUITest, which needs an Xcode project generated from
`project.yml` with [xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
xcodebuild test -project Schnellbild.xcodeproj -scheme Schnellbild \
  -destination 'platform=macOS' -only-testing:SchnellbildUITests
```

CI runs both on every push.

## Features

<table>
  <tr>
    <td><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/inspector-dark.png">
  <img src="docs/screenshots/inspector-light.png" alt="Full view with the file inspector">
</picture></td>
    <td><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/search-dark.png">
  <img src="docs/screenshots/search-light.png" alt="Search across folder and file names, including subfolders">
</picture></td>
  </tr>
  <tr>
    <td align="center">Full view with the inspector (<kbd>I</kbd>)</td>
    <td align="center">Search, including subfolders</td>
  </tr>
</table>

- **Folders & drag-and-drop.** Open a folder (⌘O) or drag one onto the window.
  Drag a single file to open it straight in the full view. Subfolders show up in
  the grid (folders first) with a Norton-style `..` tile to go up a level.
  Folder tiles preview their first images, like Finder. Hidden files and
  folders are shown.
- **Back / Forward / Up** in the toolbar (⌘[ ⌘] ⌘↑), with a history that
  remembers the folder, the search and the selection.
- **Search, always visible.** Matches folder and file names in the current
  folder and all subfolders; results stream in while the tree is walked and
  show where they live.
- **Rename folders** (F2, the Actions menu, or right-click).
- **Thumbnails for everything QuickLook supports** — images, RAW, PSD, PDF, and
  a poster frame for videos.
- **Full view** with zoom (keyboard + trackpad pinch) and drag-to-pan.
- **Video** plays via AVKit (autoplay); formats macOS can't play natively
  (AVI, MKV, WebM …) play through a vendored **VLCKit** fallback.
- **Animated GIFs** play in the full view.
- **Slideshow**, **file inspector** (resolution/size/date), **sorting**
  (name/date/size), **Reveal in Finder**, **Open with default app**,
  **Move to Trash**, a status bar, and last-folder restore.

## Keyboard

Bindings follow [Phiewer](https://phiewer.com/) where it makes sense.

**Grid**

| Key | Action |
|---|---|
| ← → | previous / next item |
| ↑ ↓ | one row up / down |
| Return / Space | open image, or enter folder |
| Backspace | up one folder level |
| Home / End | first / last item |
| ⌘+ / ⌘− | larger / smaller thumbnails |
| F2 | rename selected folder |
| Esc | clear search |

**Full view**

| Key | Action |
|---|---|
| ← → | image: previous / next · video: skip a tenth of its length back / ahead; at the end on to the next item, at the start back to the previous one |
| ⌘← ⌘→ ↑ ↓ | previous / next item, also from a video |
| Space | image: next · video: play/pause |
| ⌘+ / ⌘− (or + / −) | zoom in / out |
| 0 / 1 | fit to window / 100 % |
| [ / ] | rotate left / right (view only) |
| i | file info |
| s | slideshow |
| f | fullscreen |
| Esc / Backspace / Return | back to grid |

**Search** (the field is always visible above the grid)

| Key | Action |
|---|---|
| ⌘F | focus search: folder and file names, this folder and all subfolders |
| ↓ | move into the results |
| Return | open the selected result |
| Esc | clear · leave the field |

**Navigation**

| Key | Action |
|---|---|
| ⌘[ / ⌘] | back / forward (history; restores the search you came from) |
| ⌘↑ | enclosing folder |
| ⌘1 … ⌘5 | sort by name, kind, date modified, date taken, size (the same again reverses) |

**Menus**

| Shortcut | Action |
|---|---|
| ⌘O | open folder |
| ⇧⌘R | reveal in Finder |
| ⌘↩ | open with default app |
| ⌘⌫ | move to Trash |

## Status

**Early stage, but already a usable daily driver.** Known open items:

- Slideshow interval is fixed at 3 s.
- `1` (100 %) is approximate (assumes the main display's backing scale).
- Animated GIFs don't zoom/pan in the full view.

## License

[MIT](LICENSE) © 2026 HAUS HOPPE - ITS (Johannes Hoppe)
