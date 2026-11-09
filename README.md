<p align="center">
  <img src="Resources/icon-256.png" width="168" alt="Schnellbild app icon">
</p>

<h1 align="center">Schnellbild</h1>

<p align="center">
  <a href="https://github.com/johanneshoppe/schnellbild/actions/workflows/ci.yml"><img src="https://github.com/johanneshoppe/schnellbild/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
</p>

<p align="center"><b>An image &amp; video viewer for macOS that just doesn't suck.</b></p>

<!-- Demo: record per docs/launch-storyboard.md, save as docs/demo.gif, then
     uncomment the next line:
<p align="center"><img src="docs/demo.gif" width="680" alt="Schnellbild in action"></p>
-->

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/grid-dark.png">
  <img src="docs/screenshots/grid-light.png" width="820" alt="Schnellbild: folders with previews and photo thumbnails">
</picture></p>

Open a folder, see thumbnails, look at one picture large, page through with the keyboard. Videos play right there, too, even AVI, MKV and WebM. No library to import into, no waiting, no clutter: it opens what you point it at, stays quick on big folders and network shares alike, and gets out of your way.

## Why it doesn't suck

- **No ads, no tracking, no account.** It shows your pictures and talks to nobody.
- **No upselling.** No pro version, no subscription, no "unlock" button. Every feature is in.
- **No bloat.** No library to import into, no editor, no cloud. Just looking at photos and videos, done well.
- **Fast.** Thumbnails appear while you scroll, big folders and network shares included (see [Why so fast?](#why-so-fast)).
- **Doesn't fall over.** Broken files, odd formats and slow disks show a placeholder instead of taking the app down. Your files are only changed when you rename or trash them.

## Download

**[Schnellbild.dmg](https://github.com/JohannesHoppe/schnellbild/releases/latest/download/Schnellbild.dmg)** (macOS 14+, Apple silicon): open it and drag Schnellbild into Applications. Signed with a Developer ID and notarized by Apple.

Schnellbild follows your Mac's language: English, Deutsch, Français, Español, Italiano, Português (Brasil), Nederlands, Polski, Svenska, Dansk, Norsk, Suomi, Čeština, Türkçe, Русский, Українська, 日本語, 한국어, 简体中文 and 繁體中文.

## Features

### Browse folders

Open a folder with ⌘O or drag it onto the window; drag a single file to open it straight in the full view. Subfolders come first, each previewing its first pictures or videos like Finder (from its subfolders when it holds none itself), with a `..` tile to go up. Folders without a single photo or video anywhere inside are greyed out, so you don't bother opening them (a `Thumbs.db` or `desktop.ini` doesn't count). Files that aren't pictures, videos or archives are listed by name and size under the grid, so a folder that holds only such files never looks empty; "This folder is empty" means it holds nothing at all; a folder Schnellbild can't read (no permission, a share that went away) says "This folder can't be read" with the reason, never "empty". Thumbnails come from QuickLook, so everything macOS can preview shows up: JPEG, HEIC, PNG, SVG, RAW, PSD, PDF, and a poster frame for videos. Schnellbild reopens the last folder on launch.

| Key | Action |
|---|---|
| ← → | previous / next item |
| ↑ ↓ | one row up / down |
| Return / Space | open the picture or video, or enter the folder |
| Backspace / ⌘↑ | up one folder level |
| Home / End | first / last item |
| ⌘+ / ⌘− | larger / smaller thumbnails |
| ⌘[ / ⌘] | back / forward, restoring the folder, the search and the selection |
| f / ⌃⌘F | full screen |
| F2 | rename the selected folder or file |
| Esc | clear the search |

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

The search field is always there. It matches folder and file names in the current folder and everything below it; results stream in while the tree is walked and show where they live. The stop button next to the spinner ends a long search over a slow network share and keeps what it has found. Back from an opened result returns to the same results without searching again; a search that was still running when you opened a result goes on in the background meanwhile.

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
| ⌘← ⌘→ | previous / next item, also from a video |
| ↑ ↓ | pictures zoomed in: look further up / down; videos: volume up / down |
| Space | next picture |
| Esc / Backspace / Return | back to the grid, at the same place |

### Slideshow

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/slideshow-dark.png">
  <img src="docs/screenshots/slideshow-light.png" width="760" alt="The slideshow">
</picture></p>

Schnellbild has two ways of looking at a folder: **browse** it in the grid, or sit back and watch a **slideshow** of everything in it. The slideshow plays every photo and video in the folder **and all its subfolders**, in full screen, folder by folder in the sort order you chose. The sort order applies within each folder and to the order of the subfolders: sorted by name, folders like `Day 1`, `Day 2` … play one after the other; sorted by date taken, the pictures in each folder play in the order they were shot. Pictures stay three seconds, videos play to their end, then it moves on. It starts at once, while the subfolders are still being read; until then the count at the top says "so far" ("3 / 57 so far").

Three ways to start it:

- **▶︎ Slideshow** in the toolbar, or the `s` key: plays the folder you're in, with everything below it. While you search, it plays the search results instead.
- **Right-click a folder tile → Start Slideshow of This Folder:** plays just that folder (and its subfolders), without opening it first.
- **Drag a folder onto the window:** the window splits into two halves. Drop it on **Browse** to look around in the grid, or on **Slideshow** to start the show straight away. A single dropped picture starts the slideshow of its folder at that picture.

It starts where you are: from the full view at the picture you're looking at; in the grid at the file you selected, or at the first picture inside the folder you selected (also deep in the subfolders), and goes on from there, round to the start at the end. `Esc` ends it and brings you back to where you were.

| Key | Action |
|---|---|
| s | start the slideshow (again: end it) |
| Space | pause / resume |
| ← → | previous / next picture; in a video 10 % of its length back / ahead |
| ⇧← ⇧→ | in a video 1 % of its length back / ahead |
| ⌘← ⌘→ | previous / next item |
| ↑ ↓ | pictures zoomed in: look further up / down; videos: volume up / down |
| f / i / e / a | full screen, file info, auto enhance, sliders, as in the full view |
| Esc | end the slideshow |

### Zoom and rotate

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/zoom-dark.png">
  <img src="docs/screenshots/zoom-light.png" width="760" alt="A photo zoomed in">
</picture></p>

Zoom with the keyboard or a trackpad pinch, drag to pan, rotate in steps of 90°, for photos and videos alike, also in the slideshow. Only the view changes; Schnellbild never modifies your files.

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

Videos play right away, MP4 and MOV through AVKit, formats macOS can't play (AVI, MKV, WebM …) through the built-in VLC engine, which also draws their tiles in the grid. The arrow keys skim: each press jumps a tenth of the video ahead or back, past the end on to the next item, with ⇧ a hundredth. So one key pages through photos and skims through videos; ⌘← ⌘→ skip a video at once. A thin bar under the name at the top shows how far the video has played. ↑ ↓ set the volume of every video, shown a moment while it changes, and kept for the next launch.

| Key | Action |
|---|---|
| Space | play / pause |
| ← → | 10 % of the length back / ahead; at the end on to the next item, at the start back to the previous one |
| ⌘← ⌘→ | previous / next item straight away |
| ↑ ↓ | volume up / down in tenths, for every video, remembered (shown while it changes) |
| ⇧← ⇧→ | 1 % of the length back / ahead, to find a place exactly |

### Auto enhance and adjustments

Night shots and dark videos, or washed-out, overexposed ones: press `e` (or the wand in the toolbar) and Schnellbild sets four values for the picture on screen:

- **Exposure:** brightens dark material and tones down overexposed material.
- **Contrast:** stretches flat, hazy pictures.
- **Saturation:** lifts washed-out colours and calms garish ones.
- **Sharpness:** crisper edges, like an unsharp mask.

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/adjust-dark.png">
  <img src="docs/screenshots/adjust-light.png" width="760" alt="The sliders for exposure, contrast, saturation and sharpness over a photo">
</picture></p>

Press `a` (or the sliders button next to the wand) to see these values. With auto enhance on, the sliders show what it sets for each photo, and for videos they move with the scenes. Videos are measured once a second, and the values glide instead of jumping, so a dark intro or a cut doesn't throw them and nothing flickers. After you skip, they're measured again at once.

When auto gets a picture wrong, move a slider. Auto enhance switches off and you carry on from its values. Your settings stay while you page on, until you reset them or switch auto enhance on again. Switching it off shows the files as they are.

It's a filter on the screen only: your files stay exactly as they are. Photos and videos of every format go through the same filter, so the sliders work the same everywhere, at once.

| Key | Action |
|---|---|
| e | auto enhance on / off |
| a | show / hide the sliders (Esc hides them too) |

### File info

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/inspector-dark.png">
  <img src="docs/screenshots/inspector-light.png" width="760" alt="The file inspector over a photo">
</picture></p>

Name, type, resolution, size and date of the item on screen.

| Key | Action |
|---|---|
| i | show / hide the file info |

### Rename, reveal, trash, sort into folders

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/rename-dark.png">
  <img src="docs/screenshots/rename-light.png" width="760" alt="Renaming a folder">
</picture></p>

Rename a folder or file in place (F2, the Actions menu, or right-click), in the grid or straight from the full view. For files the name without its extension is selected, like in Finder. The search results and the history follow the new name. Reveal an item in Finder, open it in its default app, or move it to the Trash after a confirmation. To sort pictures into folders: ⇧⌘N makes a folder (it exists only once you have named it and pressed ↩), then drag tiles onto a folder tile, or onto `..` to move them up a level. On the same volume they are moved, onto another one copied, as in the Finder. Tiles can be dragged to the Finder too. Inside archives nothing is changed.

| Key | Action |
|---|---|
| F2 | rename the selected folder or file, also in the full view |
| ⇧⌘N | new folder: type its name, ↩ creates it, Esc creates none |
| ⇧⌘R | reveal in Finder |
| ⌘↩ | open with the default app |
| ⌘⌫ | move to Trash |

### Archives as folders

ZIP, RAR and 7z archives open like folders: browse their folders, page through their pictures, play their videos, start a slideshow, search their names. Nothing is unpacked to disk: pictures are unpacked into memory, videos stream from the archive while they play (packed or not), and jumping back in a long packed video unpacks it again from its start, which takes a moment. Archives are only read: renaming or trashing something inside them isn't offered.

- **RAR** of every version, also solid archives (the official UnRAR inside).
- **Split archives** show once, by their first part: `x.part1.rar` …, `x.rar` + `x.r00` …, `x.z01` … + `x.zip`, `x.7z.001` ….
- **Downloads still in progress** (`x.rar.part`, `x.zip.crdownload`) already show what has arrived; a later part that is missing ends the list there.
- **Passwords:** a protected archive asks for its password once. ZIP and RAR with a password work, also RAR with encrypted file names; encrypted 7z can't be opened.
- **7z** goes through the archive library built into macOS, so what it reads depends on the macOS version: on macOS 15 that library lacks 7-Zip's usual LZMA compression, so most 7z archives can't be read there; recent versions read them.

> [!WARNING]
> **Schnellbild remembers every archive password you type, permanently, and tries all of them on every protected archive**, without tying a password to a file. That's on purpose: type a password once, and every archive with it opens by itself from then on. They are kept in your login keychain (entry "Schnellbild archive passwords"); delete that entry in Keychain Access to forget them.

### All keys at hand

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/help-dark.png">
  <img src="docs/screenshots/help-light.png" width="760" alt="The keyboard cheat sheet">
</picture></p>

F1 (or ⌘?) shows every key in the app. `K` slides up the **mini keyboard** under the window: the keys that work on what's on screen right now (the grid, a picture, a video, the slideshow), each with what it does. It is a cheat sheet you can click, handy with only a trackpad; a key you press on the real keyboard lights up on it, so you see what just happened. In a slideshow it shows while you move the mouse. Buttons with a shortcut show it on the button as a key.

## Why so fast?

1. **Riding on the system.** Thumbnails come from Apple's QuickLook (`QLThumbnailGenerator`). It pulls **embedded previews** (EXIF thumbnail, JPEG in RAW): a few KB instead of tens of MB over the network, for any format QuickLook knows, including third-party plugins. QuickLook keeps the thumbnails in the system's own cache; Schnellbild only remembers what's on screen right now.
2. **Lazy and parallel.** The grid only loads the tiles on screen, and the system runs thumbnail generation in parallel.
3. **Full view downsampled.** The full picture is read through ImageIO and sampled straight to screen size, no 8000 px monster in memory. The thumbnail shows instantly as a placeholder.
4. **Nothing blocks the main thread.** Reading folders, searching and decoding run in the background.

## Status

Early, but already a usable daily driver. Known limits:

- The slideshow interval is fixed at 3 s.
- `1` (100 %) is approximate (it assumes the main display's scale).
- Animated GIFs don't zoom or pan.
- Packages such as the Photos library count as one file, as in the Finder: they aren't browsed, searched or played.
- Archives inside archives aren't opened. Thumbnails of videos inside archives are an icon. Sorting by date taken uses the date modified inside archives.

Building from source, tests and releases: [BUILDING.md](BUILDING.md).

## License

[MIT](LICENSE) © 2026 HAUS HOPPE - ITS (Johannes Hoppe)

Schnellbild is built with VLCKit (LGPL 2.1), UnRAR (UnRAR license) and the libarchive of macOS (BSD): see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and the app's About window.
