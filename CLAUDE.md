# Schnellbild — project guide & session handover

Read this first. It's the durable memory between sessions. Keep it accurate —
update it when the facts change.

## What this is

A **fast, lean macOS image/video viewer** (SwiftUI, macOS 15+) — "Phiewer but
minimal". Motto: **an image & video viewer that just doesn't suck.** Speed
(also over network volumes) is one part of that, not the headline. It does
what Preview does well: read little, load in parallel, cache via the system,
never block the main thread.

- Repo: <https://github.com/JohannesHoppe/schnellbild> — **public, MIT**,
  © 2026 HAUS HOPPE - ITS (Johannes Hoppe).
- Bundle id: `art.haushoppe.schnellbild`. Current version: **0.9.0**.
- Everything (code, comments, UI source strings, docs, commits) is in **English**;
  the UI is translated (see Localization). The user converses in **German**.

## Architecture & key files

SwiftPM **executableTarget** `Schnellbild` (sources in `Schnellbild/*.swift`).
There is **no Xcode project for the app build**; `xcodegen` generates
`Schnellbild.xcodeproj` (gitignored) **only for the XCUITests**, from `project.yml`.

- **`BrowserModel.swift`** — `@MainActor ObservableObject`, the single source of
  truth. Holds `entries`/`allEntries`, `selection`, `mode` (.grid/.detail),
  `zoom`, `rotation`, search (`searchText` → `didSet` runs `applyFilter`;
  `searchFocused`, `isSearching`, `isFiltering` = non-blank query), history
  (`backStack`/`forwardStack` of `Location` = folder + query + selection +
  finished results, capped at `historyLimit`), `renameTarget`, `showInspector`,
  `showHelp`, sort, `activePlayer` (`PlaybackControl`, AVKit or VLCKit).
  **The pane's key bindings live in `handleKey(_:command:) -> Bool`** with the
  `KeyInput` enum — the unit-tested dispatch; the window's (D, ⌃O, Tab, F5,
  F6) in `WindowModel.handleWindowKey`, and F9, F10, ⌃⌘F in the key monitor
  (`ContentView`). Keys typed in the search field go through
  `handleSearchFieldKey`.
  - Search is **always recursive** and matches **folder and file names**: local
    matches at once, then `recursiveMatches` streams batches (`AsyncStream`)
    from a tree walk; debounced via `searchDebounce`. Each search is a
    `SearchRun` (results, the walk's task, the changes made during the walk,
    replayed on a late batch when they came after the batch began: `ChangeClock`, `SearchBatch.stamp`; what moves out of the searched folder leaves the results); streamed batches are merged into the sorted list (`EntryOrder.merged`), not sorted anew; the model shows one (`search`), the history may hold more. A change below the folder of a search on screen (the other pane copies into it) searches only the changed folders (`refresh(changed:)`, `searchArrivals`); the folder's listing is read again once the search is cleared. Names match through `NameMatcher` in the mode beside the field (`searchMode`, per pane, remembered; `SearchModePicker`): ignoring case without the language's rules (Turkish "I" would miss "img"), the case as typed, or an ICU regular expression (one that doesn't compile matches nothing, no walk). A `SearchRun` keeps its matcher; history reuses a run only for the same query and mode.
  - **`FileChange`** (`.moved` / `.removed`) is the one mechanism for changes
    the app makes on disk: `apply(_:)` runs it over every list the model holds
    (folder entries, search results, pending selection, history, the slideshow's items) and keeps
    the selection. Rename and trash only create the change. A batch is looked up by path (`FileChanges`: each entry through its own folders, not through every change), so trashing or moving thousands stays fast.
  - A listing (`listing` → `FolderListing`) has the grid's entries and `otherFiles`: every other file (not hidden, not a later volume of an archive shown, packages included), listed by name under the grid (`OtherFilesList`) and counted in the status bar, so a folder with only such files never reads as empty. They aren't selectable; their rows (`OtherFileInteractions`, grid and list) have a context menu (rename: `beginRename(_: OtherFile)` → `renameFileTarget` → `RenameView(file:)`; reveal; trash) and drag like tiles; `applyHere` keeps `otherFiles` in step with every `FileChange`. A folder or archive that can't be listed sets `loadError` ("This folder / archive can't be read" with the system's reason), never "This folder is empty". Labels say exactly what is and what happens (no prose): check them when adding UI text.
  - ↑/↓ in the full view and slideshow (`verticalKey`): on a video the volume of every video in tenths (`changeVolume`, remembered, `PlaybackControl.setVolume`, shown by `VolumeDisplay` a moment); on a zoomed-in picture a fifth of the view further up / down (`panRequest`); otherwise nothing — paging is ← → / ⌘← ⌘→ only. Videos: ←/→ jump 10 % of the length (`skim`), ⇧←/⇧→ 1 % (`fineVideoJump`, `fineSkim`, staying in the video); `VideoProgressBar` under the position badge reads `activePlayer.progress` four times a second.
  - Paths are compared with `canonicalPath`: pure string work (standardized,
    `/private/var` → `/var`), no file system access, because it runs per entry
    on the main thread and must stay fast on network volumes.
  - `open(folder:)` records history; `navigateBack/Forward` restore folder,
    query, selection and the search (`SearchRun`: results, the walk, changes
    to replay). A search still running when the user leaves keeps running
    in the history (the newest `backgroundSearchLimit`; older ones stop and
    are searched again on return), so "Back" shows it without starting over.
    The stop button (`stopSearch`) ends a walk and keeps its results.
  - Moves and copies into folders (`move(_:into:how:)`: drops, F5, F6) are decided on the main thread (conflicts ask) and carried out off it (`FileActions.run`, the live ones through `LiveFiles`; a test's spy inline); `transfersRunning` shows in the status bar, and `finishMove` applies the result.
  - New folder (⇧⌘N, `beginNewFolder` → `NewFolderView` → `createFolder`): nothing is made until the name is confirmed; the folder is added to the listing and selected. Tiles drag (`TileDrag`: the file for the Finder, plus an own-process type so the window's drop zones stay away) onto a folder tile or `..`: `move(_:into:)` moves on the same volume and copies to another (`FileActions.transfer`), applies `FileChange.moved`, and drops what left the folder from its listing. Not in archives.
  - Renaming a folder or file (`rename`, also from the full view; a file must keep a media extension) never navigates: folder, query and
    results stay; the folder and everything listed inside it get the new path
    (`FileChange.moved`), as do history entries and results still streaming in.
    `FileActions.conflicts` refuses a target that is a different item (also
    the case-variant on case-sensitive volumes such as NAS shares); the live
    case-only move goes via a temporary name and rolls back on failure.
    ⌘↑ / `..` = enclosing folder (`goToParentFolder`; above "/" the drives' level `/Volumes`, nothing above that: `parentFolder`, `isDrivesLevel`; drives show an icon and are never read for previews or emptiness, `FolderTile.driveImage`; `com.apple.*` mounts are left out); Backspace is Back (`leaveDetailOrGoBack`: out of the full view, else `navigateBack`, with no history the enclosing folder).
  - Side effects (Finder, open, trash + confirm alert, move/rename) go through
    the injectable `FileActions`; tests pass a spy. `--ui-testing` makes the app
    use its own `UserDefaults` suite (`--reset-state` clears it).
  - As in the Finder, Space opens the selected item and Return renames it (`beginRename`; on `..` both go up); in the full view Return goes back to the grid, in the search field it opens the selected result.
  - ⌘⌫ / ⌘↩ return `false` from `handleKey` so they reach their menu items
    (the local key monitor sees keys before menu key equivalents). While a
    text field is edited the monitor hands them to the field editor instead
    (`ContentView.textFieldTakes`, also ⌘ with an arrow), so they edit the
    text. Keys with ⌥ pass untouched except ⌥← / ⌥→ (turn the picture, `handleKey(option:)`); keys with ⌃ pass untouched, except ⌃⌘F (full screen, through
    `FullScreenSwitch`) and ⌃O (the dual pane). On a layout without Latin
    letters a letter key is read as on the user's Latin layout (`LatinKeys`).
  - Packages (`.photoslibrary`, `.app`) are single items, as in the Finder:
    `entry(for:keys:)` drops them, so listing, search and slideshow never
    walk into them (`containsMedia` skips them too); one dropped, opened with `--open=` or saved as the last folder opens its folder with it selected (`isPackage`). Symbolic links are listed as what they point to; the slideshow's walk doesn't follow them (`isLink`), nor do the enumerators.
  - Marking: the ⇧ range starts at `markAnchor`, a path (re-sorts and search batches move items); plain arrows, Home and End reset it. Marks that leave the listing are dropped.
  - Rename, new folder (`renameOnDisk`, `createFolder`) and Keep Both's free names (`TransferProbe.freeNames`) touch the disk off the main thread, the live actions through `LiveFiles`; the Trash prompt waits for an archive's parts to be listed (`trashLookupPending`).
  - SVG is an image like any other. ImageIO can't read it, so the full view
    draws it with `NSImage` (`VectorPicture`, in `FullImageView.swift`) at
    the view's size, larger when zoomed in; QuickLook makes its tiles. PDFs are drawn the same way, as vector pages (ImageIO reports no size for them).
  - Full screen goes through `FullScreenSwitch`: a request during the
    window's animation (an empty slideshow ending at once) is carried out
    when it ends. Window actions use `BrowserModel.appWindow` (the main
    window; the key one can be the Adjustments popover).
- **`DualPane.swift`** — `WindowModel`: each pane's `onFileChange` hands its `FileChange`s to the other pane (`adopt`: its lists, history and the folder shown follow a rename, move or trash); only the active pane's changes reach the window's views and menus. the window's one or two panes (`left`, `right`, each a `BrowserModel`; the right one keeps its own last folder and sort through `settingsPrefix`), `active` (Tab), `dual` (D, ⌃O, remembered), `split` (the left pane's share of the width, dragged on `PaneDivider` in `ContentView`, remembered; double click: half), `sendToOtherPane` (F5 copy / F6 move the active pane's `actionEntries` into the other's folder), `handleWindowKey` (the window's keys before the pane's). A pane's `onFoldersChanged` makes the other pane `refresh()` when it shows a changed folder; volume and mini keyboard are kept in step. Tiles dragged over a pane where they would land in its folder (`paneDropFolder`: free space and bars via `PaneDrop`, non-folder tiles via `FolderDrop`) set `dropIntoFolderTargeted`: `PaneDropHint` outlines the pane and names the folder. `NortonMenus`: F9 (the app's menus in the window), F10 (quit after asking). Marking (`BrowserModel.marked`: ⌘-click, ⇧-click, ⇧-arrows, ⌘A, Insert; Esc unmarks) feeds `actionEntries`, which trash, F5/F6 and dragging use. Norton Commander's F-keys are a second way next to the Mac keys (F3 open, F4 default app, F6 rename in a single pane / ⇧F6, F7 new folder, F8 trash); where they collide the Mac key wins (F2 renames, not Norton's user menu).
- **Windows (⌘N)** — `WindowGroup(id: "browser")` → `WindowRoot`, one `WindowModel` per window (`WindowModel.claim`: the first window's model, made at launch, for a window while no other shows it; else a new one numbered by the lowest free number, its settings under `window<n>.` and `window<n>.rightPane.`, opening on its own last folder or the folder of the window it was opened from). `WindowAttach` ties the model to its `NSWindow` (`nsWindow`) and calls `windowClosed` (slideshow, full view, search end). `WindowModel.of(_:)` / `current` (key window, else main): the one key monitor sends each key to the window it was typed in, `ModifierClicks` keeps each window's tile frames apart, full screen and slideshows use the pane's `hostWindow`; the menus and Settings follow `WindowFocus.current`. `FileChange`s and changed folders go to every pane of every window. Bookmarks, caches and the slideshow time are app-wide.
- **`ContentView.swift`** — `ContentView` → `WindowView` (toolbar, key monitor, drop zones, mini keyboard, slideshow full screen; works on `window.active`) showing one `PaneView` or two side by side (`pane.left` / `pane.right`, the active one outlined); a `PaneView` is one pane's grid / full view, search bar, status bar and sheets.
- **`SearchField.swift`** — `NSSearchField` wrapper, always visible above the
  content. It refuses first responder until clicked or ⌘F, otherwise AppKit
  focuses it on launch and it swallows the grid keys.
- **`Bookmarks.swift`** — folder bookmarks (`Bookmarks.shared`, both panes, paths in the preferences, `makeDefaults()` so UI tests keep theirs): ⌘D toggles the folder shown, ⌃1 … ⌃9 open the first nine (`BookmarkItems`: the Bookmarks menu, the toolbar's star `BookmarksButton`), a folder tile's context menu adds / removes; `apply` hands every `FileChange` to `follow`, so a rename or move by the app carries the bookmark along.
- **`Undo.swift`** — `FileHistory` (one per window, both panes; `BrowserModel.undoHistory`): every rename, trash (`LiveFiles.trash` returns where the item lies in the Trash), move and copy (`finishMove`) is recorded as an `UndoStep` of parts; `undo()` / `redo()` carry them out off the main thread (`onFiles`), never over a name taken meanwhile (reported; what wasn't done stays to try again), apply the `FileChange`s and read the folders that got something back. Only in the context menus (`UndoMenuItems` on top of tiles', rows', other files' and the free space's), no keys on purpose.
- **`BossKey.swift`** — X (not while typing) makes every window invisible and click-through (alpha 0, kept open so the app's keys still arrive), hides the app and mutes the players (`BrowserModel.audibleVolume`, `BossKey.changed`); while engaged the key monitor hands every key to `BossKey.typed`, and only X X X (`Counter`, each within a second) restores. A window in full screen leaves it first (its space would stay black behind the invisible window); the app hides once it has (`hideAfterFullScreen`), and X X X puts it back into full screen (unhiding the app). `testBossKeyInFullScreen` checks only the leaving and hiding: XCUITest's keys to the hidden app brought it back in some CI runs and not in others (macOS 15 and 26; why is not known). The Dock icon reopens nothing (`applicationShouldHandleReopen`).
- **`SettingsView.swift`** — Settings (⌘,, SwiftUI's `Settings` scene): the slideshow's picture time (`WindowModel.slideshowSeconds`, 1–60 s, `BrowserModel.slideshowSecondsKey`, both panes) and forgetting the saved archive passwords (`ArchiveStore.forgetPasswords`: the keychain list and the archives a password opened).
- **`RenameView.swift`** — the F2 rename sheet (`model.rename`); for files the base name is preselected.
- **`ContentView.swift`** — one **local `NSEvent` keyDown monitor** maps key
  codes and hands each key, via `MainActor.assumeIsolated`, first to
  `WindowModel.handleWindowKey` (D, ⌃O, Tab, F5, F6), then to the active
  pane's `model.handleKey`; F9 / F10 (`NortonMenus`) it runs itself, outside
  text fields, sheets and slideshows. Keys are deliberately focus-independent,
  because SwiftUI focus can swallow Backspace/arrows. F1 works everywhere
  except over another sheet (rename, password, new folder: a second sheet
  can't open on top), F2 also while typing in the search field. The gates
  (text field editing via `textEditing:`, open sheets: `anySheetOpen` /
  `otherSheetOpen`) live in the models and are unit-tested. ⌘- and ⇧-clicks
  on tiles go through `ModifierClicks` (a mouse monitor; SwiftUI's taps don't
  fire with ⌘ held), acting on the tile under the pointer when the button comes up (found by the frames tiles and rows report, `ModifierClicks.place`; the hovered one as a fallback).
- **Video state:** `PlaybackControl.isPlaying` is the player's real state;
  the players report changes (own controls, end of video) through
  `model.playbackStateChanged`, which drives the "Paused" badge.
  Hardware keyCodes (`ContentView.keyInput`, unit-tested): 51 Backspace, 53 Esc,
  36/76 Return, 49 Space, 123 ←, 124 →, 125 ↓, 126 ↑, 115 Home, 119 End,
  122 F1, 120 F2, 99 F3, 118 F4, 96 F5, 97 F6, 98 F7, 100 F8, 101 F9,
  109 F10, 114 Insert, 48 Tab. Toolbar: Back / Forward / Up / Open Folder,
  then the folder's name (click to rename), Dual Pane, Auto Enhance, Adjust,
  Slideshow, Sort, all on the left; the full view adds Grid before Dual Pane (a centred item would push the others to the right edge).
- **Slideshow** (`BrowserModel.Slideshow`, `startSlideshow`): its own item list, filled by `walkForSlideshow` folder by folder (a folder's media in the sort order, then each subfolder, hidden folders skipped) and shown while the walk goes on. Its parts (a folder's own media, each subfolder; or each search result) are walked with the part holding the start first, the others' items inserted before or after it (`partCounts`), so a start deep in the tree shows at once. Starts over the folder passed in (drop zone, a folder tile's context menu "Start Slideshow of This Folder"), else the search results, else the current folder — always the whole of it; it starts at the item the full view shows, or at the file / inside the folder the user selected in the grid (`selectionChosen`: not the tile selected by default on opening a folder; `Slideshow.startAt` / `startInside`, nothing shown until it has arrived). Pictures advance after `slideshowInterval`, videos when `playbackStateChanged` reports their end. Full screen via the injectable `setFullScreen`; toolbar, search and status bar hide. Keys go through `handleSlideshowKey`. `shownMediaEntry` is the one item on screen (slideshow or full view); `page`/`skim` work on it. Dropping onto the window shows two zones (`DropZonesView`, `DropZoneDelegate`, `WindowModel.dropZone`): Browse / Slideshow. The panes and tiles take drops of the app's own tiles; a Finder drag over them would end there, so they take `.fileURL` too and hand it on (`FinderDrop`: the zone by the pointer's place in the window).
- **Auto enhance and adjustments** (`Enhancer.swift`): a view filter, files untouched. One parametric `Look` (exposure as a gamma curve, contrast, saturation, sharpness; filters run on sRGB-encoded values, the scale `PictureStats` measures on). Auto (`enhance`, key E, the wand) works out a `Look` from `PictureStats` (`Look.auto`); the sliders (`AdjustmentsView`, key A, model `look`) show it live. Moving a slider calls `model.adjust`: auto goes off, `manualLook` carries on from the shown values and stays while paging; auto off via E/the switch resets to the file as is. Players get `Enhancement` (.off/.auto/.manual) through `PlaybackControl.setEnhancement` and report auto's look via `onAutoLook` → `model.autoLookMeasured`. Photos: `FullImageView` measures once per picture and renders off the main thread. AVKit: one `AVVideoComposition` per video whose `VideoEnhancer` reads the current mode per frame (`AdaptiveLook`: measured once a second, black/white frames held, first picture and seeks at once, gliding in between); a paused video is redrawn by a zero-tolerance seek to a quarter or half into the frame shown (by the track's frame duration; without one 1/600 s off its time, the other way each time) (a seek to the very time reuses the frame already composed, without the new look). VLC: `VLCFrameOutput` takes VLC's decoded pictures through libVLC's video callbacks (`libvlc_video_set_callbacks`/`_format_callbacks`, looked up with `dlsym`; the native player via `-[VLCMediaPlayer libVLCMediaPlayer]`) into IOSurface-backed NV12 buffers (the video's own form: no colour conversion on the processor; BT.709 attachments when the visible height is above 576, BT.601 below; full-range sources get full-range buffers; the compositor converts) and shows them on a layer at the track's visible size with square pixels (from VLCKit's track information: the decoders' padding and an anamorphic video's pixel shape don't show), applying the `Look` with Core Image into BGRA buffers when it isn't neutral, so AVKit and VLC share one filter; auto measures the decoded picture once a second (no feedback from its own correction). No VLC OpenGL output at all: VLC's `macosx` output needs OpenGL, which CI runners (virtual Macs) lack and macOS deprecates. Media get `:no-osd` (VLC would draw messages into the picture) and `:no-play-and-pause` (VLCKit turns that on by default: VLC would pause once it has read the file to its end, before the last pictures, and never report the end, which the slideshow and Space-to-replay need). VLCKit supports only its shared `VLCLibrary`: a second instance lacks VLCKit's default options and plays nothing.
- **`EntryListView.swift`** — the list view (`BrowserModel.viewMode`, L, per pane, remembered): a row per entry with a small preview (folders: `FolderTile` at row size, its fan scaled up for small sides), name, kind, dates, size; a header click is `setSort` (the same sort as the menu); rows use `EntryInteractions` like tiles (click / ⌘ / ⇧, double click, drag, context menu); `columnCount` is 1 so ↑↓ step a row; other files as grey rows.
- **`ShortcutsHelpView.swift`** — F1 / "Schnellbild Help" cheat sheet (same
  content as the README keyboard tables; keep them in sync).
- **`ThumbnailView.swift` / `ThumbnailGridView.swift`** — `LazyVGrid`, thumbnails
  from QuickLook (`QLThumbnailGenerator`); MKV, WebM, WMV, ASF, FLV, Ogg and VOB videos come through Schnellbild's own QuickLook thumbnail extension (`ThumbnailExtension/`, see below), so macOS keeps them in its cache; a video QuickLook still has only an icon for (the extension not registered yet, or a type it doesn't claim such as MPEG, which macOS reads itself) gets a frame from VLC in the app (`VLCThumbnails`, two at a time, each a `VLCFrameGrab`: its own player on its own queue, decoding into memory; nothing in it waits for the main thread. VLCKit's `VLCMediaThumbnailer` is not used: its picture callback waits for the main thread, which then asks the player that is being stopped, and both hang). `ThumbnailCache` keeps one image per
  file with the size it was made for, limited by pixel bytes (an eighth of the Mac's memory, at most 2 GB; previews 256 MB), not by count (reused for smaller tiles, regenerated
  for larger; the full view's placeholder). Folder previews use their own
  `ThumbnailCache.previews`. `FolderTile` fans up to three previews of a
  folder's first media files, from its subfolders when it has none itself (`BrowserModel.folderPreviewFiles`, listed once
  per folder via `FolderPreviewCache`, which keeps listings and emptiness across navigation while the folder's modification date stays (checked off the main thread when a tile asks and the last check is older than 30 s; the app's own changes `forget` the folders around them). Folder tiles look into folders on `FolderProbes` (an OperationQueue, three at a time, not Swift's threads: walks that wait on a network share would hold them all and stall the search, listings and thumbnails), giving up after `probeLimit` items (20 000, 2 000 on a network volume: then not known, not greyed). A search's walk (on a dispatch queue of its own, `WalkStop`) tells the tiles what it saw (`FolderFacts` in its batches → `FolderPreviewCache.learn`): which found folders hold media, their previews, and at the end of a whole walk which hold none. Tiles made again (scrolled back) start from the in-memory caches (`ThumbnailCache.cached`, `FolderPreviewCache.knownFiles`), and a folder tile keeps its previews until new ones are there. `GridEntry.isArchive` is worked out once. Folders with no photo or video at any depth (`BrowserModel.containsMedia`, stops at the first hit; hidden files and non-media like `Thumbs.db` don't count) are greyed out; the model keeps them in `emptyFolders`, and a `FileChange` forgets the folders around it. Tiles carry accessibility ids
  `tile.<name>`; their label starts with `selected` / `not selected`. A cached
  thumbnail is used only for the modification date it was made for; folder
  tiles read their previews again after every `FileChange` (`folderChanges`).
- **`FullImageView.swift`** — ImageIO downsample + zoom/pan/rotate (view-only;
  **never modifies files** — important user constraint). Decoded at the
  view's size, again larger when the view grows (full screen) or, zoomed
  in, at the view's size × zoom (with room for a few more steps) up to the
  full size and at most 64 Mpx; at 100 % (`1`) at full size. A sharper
  decode that fails keeps the picture shown. Animations (GIF, also animated PNG and WebP) play there too (`AnimationFrames`): their frames decoded at the same size, each for its own time, with the same look, so zoom, rotation and enhance apply while they play; frames are kept up to 256 MB, else decoded again each round.
- **Media Extensions:** `SchnellbildApp.init` calls `MTRegisterProfessionalVideoWorkflowFormatReaders()` and `VTRegisterProfessionalVideoWorkflowVideoDecoders()`, so the format readers and decoders the user has turned on (Apple's, another app's) open videos in AVKit and give the grid Quick Look thumbnails (macOS 26); each runs sandboxed in its own process. See "Media Extensions (native thumbnails)" below.
- **`VideoDetailView.swift`** — native formats via AVKit; non-native fall back
  to VLCKit. MKV, WebM, WMV, ASF, FLV, Ogg and VOB always play in VLC (`vlcFormats`): with the app opted in to Media Extensions, AVFoundation calls an MKV playable through Schnellbild's own reader, which has no sound (it is for thumbnails). AVKit plays in an `AVPlayerView` (`AVPlayerViewHost`) with
  **floating** controls: the inline ones (SwiftUI's `VideoPlayer`) and the
  minimal ones dim the whole picture while they show, from macOS 26 on. While
  the video is turned its controls are off (they would turn with it). Where
  the user dragged the floating bar is not kept for the next video: AVKit
  puts it back with every new player, also in a reused `AVPlayerView`
  (seen on CI). The badge's
  `VideoProgressBar` shows the time left (`PlaybackControl.lengthSeconds`). Creates and registers the one `PlaybackControl` per file
  (`AVPlaybackControl` or `VLCPlaybackControl`) in its `.task(id: url)`.
- **Video zoom**: `VideoDetailView` scales, rotates and pans the player view like `FullImageView` (model `zoom`/`rotation`); a clear layer takes the drag only while zoomed (the player's control bar stays usable at fit). Trackpad pinch on videos goes through a `.magnify` event monitor in `ContentView`, since AVKit's view would take it. On videos `1` = fit.
- **`VLCVideoView.swift`** — `VLCPlaybackControl` (owns the `VLCMediaPlayer`,
  `import VLCKit`) and `VLCVideoView`, the `NSViewRepresentable` it draws into.
  `stop()` stops the player off the main thread (VLC waits for its reading
  thread, long on a stalled share). A video VLC plays without a known
  length (`playsWithoutLength`) is not skipped by the slideshow.
- **`MediaExtras.swift`** — `detachedCancellable`, `InspectorView`,
  `MediaInfo`, `LoadingSpinner`.
- **`.ts` files:** `BrowserModel.mediaKind` takes the extension, except `.ts` (TypeScript far more often than video): `TransportStreams.isVideo` reads its first 512 bytes once (`VLCSafety.container` says transport stream) and keeps the answer by path, size and date. Inside archives `.ts` is never a video (no first bytes without unpacking).
- **`FileFacts.swift`** — what the Inspector shows beyond name and size. `FileFacts.picture` (ImageIO's type of the content, bit depth, colour profile, camera) and `FileFacts.video` (the container its first 512 bytes show, through `VLCSafety.container`, so the note and VLC's choice of reader agree); `recommendedExtension` is set when the extension names another format than the content (pictures: the UTType's extensions, conformance either way, RAW to RAW, and a few aliases; videos: the container's extensions, the first one recommended). No verdict where the content shows nothing known (m2v, DV, inside an archive). `StreamFacts`: codecs, frames per second, channels and length from the player once it has opened the video (`PlaybackControl.streamFacts`: AVFoundation's format descriptions, VLC's `tracksInformation`); the bitrate is the file size over the length. `FileFactsTests`.
- **`Archives.swift`** — archives as folders. A place inside one is a file URL running through the archive file (`…/Holiday.zip/Day 1/a.jpg`, `ArchivePath.split`), so the model, history, search and grid need no special type; `scan` / `recursiveMatches` / `containsMedia` / `folderPreviewFiles` ask `ArchiveStore` for such URLs. `ArchiveName`: which names are archives (zip/cbz, rar/cbr, 7z, byte splits `.001`; later volumes hidden; download endings `.part`, `.crdownload` … ignored). Readers: `RarReader` (UnRAR via `Native/CArchives`: all RAR versions, solid, volumes, passwords, encrypted names; list mode for the index, so solid archives aren't unpacked to list them) and `LibArchiveReader` (the system's libarchive: ZIP by its central directory, else streaming, which also reads split `.z01` sets and unfinished downloads; 7z; ZIP passwords only — libarchive decrypts neither RAR nor 7z). `ArchiveStore`: one index per archive version (size + date), built with no password, then each remembered one; reads of one archive are served together in one pass in archive order (`servePending`), so a solid RAR is unpacked once for all its thumbnails; in a solid archive (RAR's solid flag, 7z) a pass keeps the pictures it unpacks on the way in a byte cache (`bytes`, NSCache, 256 MB, entries up to 32 MB), so paging through a comic doesn't unpack from the start each time. A known index is returned without waiting on the archive's queue (`current`); at most 200 archives are kept, the idle ones used longest ago go. `PasswordStore`: every password that opened something, newest first, in the login keychain (UI tests: their preferences; unit tests: memory). `BrowserModel.passwordRequest` → `PasswordView` sheet; `submitPassword` reloads with the typed one (remembered only if it opens), `cancelPassword` goes back. `MediaData` reads bytes / image sources from disk or archive. Videos inside archives stream (`ArchiveStreaming.swift`): `ArchiveEntryStream` unpacks the entry on a thread of its own into 1 MB chunks held in memory (chunks read kept longer than chunks only passed; the read-ahead follows the reader's last request; a read behind what's in memory unpacks again from the start), `ArchiveResourceLoader` feeds AVKit through a custom URL scheme, `ArchiveInputStream` feeds VLC (`VLCMedia(stream:)`, a new stream for every opening). Pictures read from an archive into memory are capped at 256 MB (`ArchiveStore.largestRead`, `ArchiveError.tooLarge`: a zip bomb isn't unpacked into memory), and a read nobody waits for any more is dropped. An incomplete or multi-volume index is read again when the containing folder's date changes (a volume arriving, a download renamed into place). RAR hard links and file copies read their source's data (`ArchiveItem.source`); symlinks are skipped. ZIP names that aren't UTF-8 are decoded in the code page of the user's language (Shift-JIS, GB18030, Big5, CP949, CP866 …), else CP850. Nothing is written to disk; the index lives only in memory. Inside archives nothing is renamed or trashed (`selectionIsChangeable`); an archive goes to the Trash with all its volumes (`ArchiveName.allFiles`).
- **`Native/CArchives`** — C module for Swift: `include/CArchives.h` (the UnRAR shim's API and the few libarchive functions, declared by hand since macOS ships no libarchive headers, as `sb_archive_*`), `libarchive_shim.cpp` (looks each one up in `/usr/lib/libarchive.2.dylib` with `dlsym`; not linked by name, because VLCKit exports its own libarchive and the linker would bind most names to that copy and the rest to the system's, two libarchives on one archive; `build_app.sh` fails if an executable takes anything but VLC's own names from VLCKit), `rar_shim.cpp` (UTF-8 names, data callback, passwords, missing volumes; UnRAR's error state (`ErrHandler`) is made per thread by `fetch_unrar.sh`'s patch to `global.hpp` — keep that patch when updating UnRAR: archives are read at the same time, each on its own queue, with no lock around UnRAR, so a shared error state would let one archive's error fail another's read; the shim clears it before each call, checks a file's data against its CRC32 itself, and reads a header that came out whole as read whatever code the previous file's processing left behind), `unrar` → `Vendor/unrar` (the official source, `Scripts/fetch_unrar.sh`, SHA-256-pinned; `fetch_vlckit.sh` calls it; all three fetch scripts download through `Scripts/fetch_verified.sh`). Built by `Package.swift` (target `CArchives`, sources = UnRAR's makefile `OBJECTS` + `LIB_OBJ`) and by `project.yml` (static library target) alike.
- **`ThumbnailExtension/`** — the QuickLook thumbnail extension (`SchnellbildThumbnails.appex` in `Contents/PlugIns`, bundle id `art.haushoppe.schnellbild.thumbnails`): `ThumbnailProvider` answers QuickLook's requests with `VLCFrameGrab.frame` (a frame at 30 %), for the types in its `Info.plist` (`QLSupportedContentTypes`: org.matroska.mkv and IINA's io.iina.mkv, WebM under the system's and VLC's identifiers, WMV, ASF, FLV, Ogg video, `org.videolan.vob`). macOS's own extension claims all of `public.audiovisual-content`; for system types QuickLook asks it, not ours, whatever ours claims: on CI (macOS 15 and 26) AVI and AVCHD (`public.avi`, `public.avchd-mpeg-2-transport-stream`) went to Apple's and got no picture for a process that doesn't opt in to Media Extensions (AVCHD did on macOS 26 for one that does, see Media Extensions below), so they are not claimed; WMV, ASF, FLV, Ogg, VOB reached ours; WebM reached ours on 15 and on 26 (once, on 26, Apple's answered it, with a picture; why is unknown). MPEG-1/2 (`.mpg`, `.ts`, `.m2v`) macOS draws itself. Matroska and VOB have no system type, so the app's `Info.plist` (and `ExportedTypes.plist` for the Xcode build) imports `org.matroska.mkv` and `org.videolan.vob`, VLC's identifiers. App Sandbox (`ThumbnailExtension.entitlements`), no network; it links the app's VLCKit (`build_app.sh` points its load path four levels up). Finder uses it too. macOS registers it with the app; `Scripts/check_thumbnail_extension.sh` (CI, after `build_app.sh`) registers the built app, asks from another process (`Scripts/thumbnail_probe.swift`) for a thumbnail of each claimed format's clip, printing which extension answered, again for `clip.mkv` from a new process (the system's cache), and checks `broken.mkv` gets none. Built by `Package.swift` (executable target, entry `_NSExtensionMain`, `-parse-as-library`; it must have no `main` of its own: the system's extension start calls `main` when there is one, which would start it again and again; `SchnellbildThumbnails_main` exists only for `swift test`, which links every executable target against `<Module>_main`) and `project.yml` (`app-extension`).
- **`FormatReader/`** — the media extension "Schnellbild Video Formats" (`Contents/Extensions/SchnellbildFormats.appex`, bundle id `art.haushoppe.schnellbild.formatreader`): format readers for macOS's own pipeline, Matroska and MPEG transport streams (AVCHD `.mts` / `.m2ts`; claimed as `public.avchd-mpeg-2-transport-stream`), H.264 / HEVC video only (other codecs and audio not offered; those files fall to the other paths). `MatroskaIndex.swift` reads a Matroska file in parts (heads: tracks, info, each cluster's place and time; a cluster's frames when first needed). `TransportIndex.swift` reads a transport stream in parts (192- or 188-byte packets, the video stream from PAT / PMT, first and last time from 1 MB at each end, frames chunk by chunk (about 2 MB) with PTS / DTS, the chunk for a time by binary search over each chunk's first frame; keyframes: random access flag, IDR, or SPS before the picture, as camcorders' open GOPs have no IDR). Both check every size against the data, nothing above `largestRead` / `largestFrame`; module `VideoContainers` for `ContainerTests`, which also cut and scramble files. `FormatReader.swift`: one `VideoTrackReader` and `VideoCursor` over a `VideoTrackSource` per container; Matroska frames are located (`sampleLocation`, macOS reads them), transport stream frames are spread over packets, so the cursor gathers them and hands them over (`loadSampleBufferContainingSamples`, NAL units length-prefixed, the format description from the stream's parameter sets); Quick Look's 10 s thumbnail seek in a shorter video becomes a quarter in. Built by `build_app.sh` with `swiftc` (entry `_EXExtensionMain`); `typecheck.sh` builds it to SIL (a missing return shows only there); signed with its entitlements and the embedded profile only with the Developer ID and `FORMATS_PROFILE` (release: secret `MACOS_PROFILE_FORMATREADER`), else ad hoc without (unused). Off until the user turns it on (System Settings → … → Media Extensions); Settings shows it (`MediaFormats.isOn`: AVFoundation plays the bundled `Resources/FormatsCheck.mkv`) and opens that page. Checked on CI by `spike-media-extension.yml` (signed job, by hand): Quick Look thumbnails of MKV and AVCHD (also a real camcorder clip, downloaded there) on macOS 26. Not in the Xcode project (UI tests don't need it).
- **`VLCFrames/`** — the module the app and the extension share: `LibVLCVideo` (libVLC's video callbacks), `VLCFrameGrab`, `VLCSafety`. A library target in `Package.swift`, a static library in `project.yml`; `Scripts/typecheck.sh` builds its module first.
- **`AboutPanel.swift`** — the About window: the system panel with credits for every library and its license; the full texts ship in `Resources/Licenses` (copied by `build_app.sh` and `project.yml`). Keep it, `THIRD-PARTY-NOTICES.md` and the README's license line in step with the dependencies.
- **Localization** — English is the source language; the UI follows the macOS language. Translations live in `Resources/Localization/<lang>.lproj/` (`Localizable.strings`, plus `Localizable.stringsdict` for the counted nouns "%lld folders / archives / pictures / videos / results"); `build_app.sh` copies them into `Contents/Resources`, `project.yml` adds them to the UI-test build, and `Info.plist` lists them in `CFBundleLocalizations`. SwiftUI literals (`Text`, `Button`, `Label`, `.help`, menus) are looked up by their English text; strings built in code use `String(localized:)`, so interpolations become `%@` / `%lld` keys. **Every new or changed UI string needs an entry in every `.lproj`** (English key = value); `LocalizationTests` fails otherwise (it scans the literals given to `Text`, `Button`, `Label`, `.help`, `.accessibilityLabel` / `Value`, `headerButton`, `String(localized:)`, the help's actions and its keys with words, both sides of a `?:`) and checks the placeholders match, positions included (`%2$@`), and the plurals' format keys. Key names in the F1 help (Return, Backspace …), file names and the accessibility labels the UI tests read (tile labels, zoom state; listed in `LocalizationTests.readByUITests`) stay English. UI tests launch the app with `-AppleLanguages (en)`.

## Security: files from others

Viewing must never run anything. What is in place:
- Archives are only read, never extracted to disk; entry names are cleaned (`..`, `.`, empty parts dropped). Reads into memory are capped at 256 MB (`ArchiveStore.largestRead`), also for whole files read from disk (`MediaData.read`: SVG, PDF).
- VLC (`VLCSafety`): every media, the thumbnailer's too, gets one demuxer: the video container its first 512 bytes show (`VLCSafety.container`: Matroska, transport stream at 188 or 192 bytes, MP4, AVI, MPEG-PS, ASF, FLV, Ogg; a recording named `.mkv` that is a transport stream plays), else the one its extension names, and only for a file with a video extension (`VLCSafety.reader`: `.wmv` → `asf,none`, `.flv` → FFmpeg held to its `flv` format, unknown → `none`), so a "video" that is really an HLS playlist can't make VLC fetch from the network. One demuxer, never a list: VLC treats a demuxer it is told to use as forced, and `ps` / `ts` then take any file, so everything after them in a list would get nothing. `VideoFormatTests` gets a frame from a clip of every listed extension and checks a playlist named like a video, whose segment is a clip on disk, gives none; no subtitle files picked up. VLCKit's `VLCParams` preference (libVLC options any local program could plant) is removed at launch. Lua is not in the bundled VLCKit and its modules are static.
- Open with Default App (`LiveFiles.openWithDefaultApp`): links and aliases are resolved, and only pictures, videos, PDFs, archives and folders are opened, each with the app for its type, never apps, packages or scripts. Finder aliases are listed among the other files; a symbolic link counts by what it points to, and a linked folder is shown at its real place.
- Other files (`LiveFiles.openOtherFile`, double click / Open in their menu): only documents that hold no program (an allow list of types: text, PDF, office, audio …; a refuse list of types and extensions: executables, apps, packages, scripts, installers, disk images, Terminal settings, Finder locations …; links and aliases resolved first), a .webloc / .url only to an http(s) address, opened with `NSWorkspace.open`. `OpenOtherFileTests`.
- A folder reopened at launch is remembered until the app has run 15 s or quits normally (`restoreUnconfirmed`): if the app ended before, the next launch doesn't reopen it (`skippedRestore`), so a file that crashes the app can't crash every launch.
- The app and its extensions run in the App Sandbox (see "One app, two ways out"): no network, no other programs started, only the folders the user opened to it; the release app has the Hardened Runtime (library validation); the thumbnail extension reads only the file QuickLook hands it, also when Finder asks for an MKV's thumbnail; no document types or URL schemes; `--open=` and the UI-test switches are command-line only.
- Media Extensions (opted in at launch) run each in its own sandboxed process, and only those the user turned on in System Settings.
- Remaining risk: the parsers run in the app's process (VLC with FFmpeg, UnRAR, the system's libarchive, ImageIO, CoreGraphics for PDF/SVG), several already while a folder is browsed (thumbnails, archive indexes). A bug in one of them could run code with the app's rights, which the sandbox limits to the folders opened to it, without network. A further step would be a sandboxed XPC helper (read-only, one file) for VLC and the archive readers; VLC's frames are IOSurfaces already, which can cross XPC. Until then: keep VLCKit and UnRAR current with their security releases.

## One app, two ways out (DMG and Mac App Store)

Free as the DMG (Developer ID, notarized: release.yml) and for 1 € in the Mac App Store (to support the project: appstore.yml, `Scripts/package_appstore.sh`). The same build (`Scripts/build_app.sh`), in the App Sandbox with VLCKit built without GPL modules (checked by `vlckit_licenses.py --no-gpl` in every build); only `Scripts/sign_app.sh` differs: App Store identity and profiles (App ID and team in the entitlements), Developer ID (without them; the media extension with its Developer ID profile), or ad hoc. `Sandbox/`: the entitlements (app: user-selected read-write, app-scope bookmarks, Pictures, Movies, Downloads; thumbnail extension; the format reader's own in `FormatReader/`), `PrivacyInfo.xcprivacy`, `UITests.entitlements` (the Xcode build, `project.yml` `SCHNELLBILD_APP_ENTITLEMENTS`: the sandbox with every file open, since a UI test can't answer open panels). `FolderAccess` (only in the sandbox): a folder chosen (`chooseFolder`) or dropped (`openDropped`) is kept as a security-scoped bookmark and opened again at launch (`SchnellbildApp.init`, before any folder is read); a folder that can't be read and lies outside every grant shows "Allow Access…" (`LoadError.needsAccess`, `allowAccess`: the open panel at that folder); Settings → Folder access forgets them. Certificates, profiles and secrets, when they run out and how to make them again (checked by `Scripts/set_signing_secrets.sh` before upload): `docs/SIGNING.md`. What is left for the App Store account and the open risks: `AppStore/CHECKLIST.md`; custom EULA draft: `AppStore/EULA.md`.

## VLCKit without GPL modules

VLCKit as VideoLAN builds it carries 8 VLC modules that state the GPL (Dolby Surround decoder, mono downmix, the dummy interface, syslog, the RTSP VoD server, stream output cycle and RTP, the rotate filter); `Scripts/vlckit_licenses.py <binary>` lists them (names from `nm`: the linker folds the identical licence functions into one, so the disassembly alone names one module for many). The App Store's terms don't go with the GPL. `Scripts/build_vlckit_lgpl.sh` (workflow `vlckit-lgpl.yml`, by hand, about an hour: VLC's libraries build one at a time, `MAKE_JOBS=1`, since its ninja and macOS's make 3.81 don't share jobs) builds VLCKit 3.7.5 (VLC 3.0.24) with VideoLAN's own `buildMobileVLCKit.sh` (macOS, arm64), the 8 added to its list of modules to delete, a `sha512sum` that reads check lines from standard input (VLC's downloads), with the current Xcode; it fails unless every module states the LGPL (236 modules); then the unit tests run against it (`SCHNELLBILD_OWN_VLCKIT=1`) and it is published as a pre-release of this repository (`vlckit-3.7.5-lgpl-<run>`, never latest); `Scripts/fetch_vlckit.sh` fetches it by its SHA-256 for every build.

## VLCKit (the heavy dependency — read carefully)

AVI/MKV/WebM and other non-native formats play **in-app via vendored VLCKit
(LibVLC), as a fallback only**; native formats stay on AVKit.

- It's **built by us from VideoLAN's source** without the GPL modules (see
  "VLCKit without GPL modules"), published as a pre-release of this repository
  and fetched + **SHA-256-verified** by `Scripts/fetch_vlckit.sh`.
- Vendored to **`Vendor/VLCKit.xcframework`** (gitignored; arm64 only). `Package.swift` references it as a **local `binaryTarget`**
  (`path: "Vendor/VLCKit.xcframework"`), the executable depends on `"VLCKit"`,
  code does `import VLCKit`.
- **Deliberately NOT a third-party SPM repo.** The user is security-conscious;
  we audited the community wrapper, then chose: VideoLAN's source and build
  script + our own hash + local vendoring → minimal attack vector, no external
  repo in the trust path.
- The Mac App Store version is the same app (see "One app, two ways out"): the LGPL allows it with the custom EULA (changing and reverse engineering the library allowed) and the source offer in THIRD-PARTY-NOTICES.

## Build / test / run — gotchas that will bite you

- Needs a **full Xcode** (not just Command Line Tools). With only the CLT,
  `swift build` fails ("SwiftUIMacros … plugin not found": `@State` is a macro
  in the macOS 27 SDK). Without Xcode on the machine, build and test on CI.
- **`swift test` ALONE FAILS.** VLCKit's `binaryTarget` links into the `.xctest`
  bundle but SwiftPM doesn't embed it (install name `@loader_path/../Frameworks/…`).
  **Always use `./Scripts/test.sh`** — it fetches VLCKit, `swift build --build-tests`,
  copies `VLCKit.framework` into the test bundle, then `swift test --skip-build`.
- Any build needs `Vendor/VLCKit.xcframework` present → run
  `./Scripts/fetch_vlckit.sh` first (`test.sh` and `build_app.sh` call it for you). With `SCHNELLBILD_OWN_VLCKIT=1` it keeps whatever framework is there (a modified VLCKit, as the LGPL allows; see THIRD-PARTY-NOTICES).
- Scripts with an EXIT trap end it with `[ -n "${finished:-}" ] || exit 1` and set `finished=1` last: macOS's bash 3.2 otherwise reports an aborted expansion (an unset variable) as success.
- **`./Scripts/build_app.sh`** → `build/Schnellbild.app`: fetch VLCKit, render
  icon, `swift build -c release`, assemble bundle, **embed VLCKit.framework into
  `Contents/Frameworks` + add `@executable_path/../Frameworks` rpath**, put the
  thumbnail extension into `Contents/PlugIns` (versions copied from `Info.plist`), sign
  inside out (the extension with its sandbox entitlements, before the app) (Developer ID with `MACOS_SIGN_IDENTITY`, else ad hoc).
  `./Scripts/package_dmg.sh dmg` packs it into `dist/Schnellbild.dmg` with
  **`dmgbuild`** (Python, pinned with wheel hashes in
  `Installer/requirements.txt`, installed only in the release workflow into a
  venv): the window shows the app, an arrow and the Applications folder, laid
  out by `Installer/dmg-settings.py` on `Resources/dmg-background*.png`.
  Redraw the background with `swift Scripts/make_dmg_background.swift`
  (positions must match the settings file). Check the result with
  `gh workflow run dmg-preview.yml -f run_id=<release run>`: it opens that
  run's DMG in Finder on the runner and uploads screenshots in light and dark
  mode (artifact `dmg-preview`, `Scripts/dmg_preview.sh`). The terminal on the
  dev Mac has no screen recording permission, so look at DMGs this way.
- After editing `project.yml` **or adding/removing a `.swift` file**, re-run
  `xcodegen generate` before the Xcode/UITest build (the app target embeds
  `Vendor/VLCKit.xcframework`).
- Tests: unit tests (`Tests/SchnellbildTests/BrowserModelTests.swift`: search,
  history, rename, file actions via spy, playback via `PlayerSpy`, the pane's
  key bindings; `DualPaneTests.swift`: the window's keys, marking, F5/F6, the
  other pane following; `ArchiveTests.swift`: readers, passwords, streaming; `CraftedArchiveTests.swift`: hostile archives (split-header floods, zip bombs, sizes near Int64.max, legacy code pages),
  against the fixtures in `Tests/SchnellbildTests/Archives`;
  `LocalizationTests.swift`; `VideoFormatTests.swift`: a frame from a clip of every video extension (`Tests/SchnellbildTests/Videos`, drawn by `Scripts/make_video_fixtures.sh` with ffmpeg), the readers held to the extension; `MediaTests.swift`: zoom decode sizes, PDFs, transparency in the measurements) + XCUITests (`ReadmeScreenshots` is skipped in CI) in `UITests/*UITests.swift` (grid, search, navigation,
  full view, video incl. VLC, actions incl. the dual pane, archives incl. RAR fixtures in `UITests/Fixtures/rar`), sharing `UITestSupport.swift`. Media
  fixtures live in `UITests/Fixtures` (bundled as test resources; the dark,
  overexposed, even grey, gradient, upright (EXIF orientation 6), colour-band, 4K60 and broken ones are drawn by `swift Scripts/make_test_fixtures.swift UITests/Fixtures`).
  **`VisualUITests` measure what the screen shows**: the CI shell of the
  UI-test job answers "measure:<id>:<rect>" pasteboard requests with
  `screencapture` + `Scripts/measure_brightness.swift` (mean luminance, its spread, mean red/green/blue) (the test runner can't
  record the screen; XCUITest's own screenshot shows VLC's picture black).
  They check that videos (AVKit, and VLC via `--force-vlc`) are bright from
  the start, that VLC draws no messages over the video, that handing a 4K picture over from VLC costs under 3 ms (lost pictures are only reported: CI's virtual Macs vary too much), that AVKit and VLC show the same video with the same brightness and the same colours channel by channel (unfiltered NV12 and filtered BGRA), that a photo with EXIF orientation stands upright at fit and zoomed in, that moving the mouse on and off a video never dims it, auto enhance and the exposure slider on videos and photos, and
  that broken files don't take the app down. Anything visual gets such a
  measured test, so it can't regress unnoticed. Launch switches for UI
  tests (only with `--ui-testing`; every argument starts with "-" and a
  value is joined with "=", since AppKit pairs "-name value" and takes an
  unpaired value for a file to open): `--open=<path>`, `--force-vlc` (every
  video through VLC), `--test-log=<path>` (the app logs what the screen
  doesn't show, e.g. each rename), `--search-delay=<ms>` (a search that stays
  running),
  `--hold-volume-display` (the volume display stays, for a test to read it). Not covered
  end-to-end: drag & drop from Finder, Reveal in Finder, Open with default app
  (unit-tested through `FileActions`).
  UI run: `xcodegen generate` → `xcodebuild test -project Schnellbild.xcodeproj
  -scheme Schnellbild -destination 'platform=macOS'
  -only-testing:SchnellbildUITests -derivedDataPath build/DerivedData`.
- **Local UI tests sometimes fail with "System authentication is running"
  (Touch ID / LocalAuthentication). That's ENVIRONMENTAL, not a code bug** —
  CI runners don't have it. Verify UI tests on CI.

## CI & release

- `.github/workflows/ci.yml`: `build-test` (fetch+cache VLCKit → `test.sh` →
  `build_app.sh` → upload zip), `thumbnail-extension` (that app on **macos-15 and macos-26**: `check_thumbnail_extension.sh`, fetched with `gh run download`) and `ui-tests` (fetch+cache VLCKit → `xcodegen`, pinned and SHA-256-checked by `Scripts/fetch_xcodegen.sh` →
  `xcodebuild` UI, on **macos-15 and macos-26**, since AVKit behaves differently
  from macOS 26 on; by hand with `-f only=<tests>` and `-f macos=<image>`). **`paths-ignore: ['**.md', 'LICENSE']`** → doc-only pushes
  don't trigger CI. Both jobs cache `Vendor/` keyed on the hashes of `fetch_vlckit.sh` and `fetch_unrar.sh`. A newer push cancels the older push's run; a run started by hand has its own concurrency group (`ci-<event>-<ref>`), so it never cancels a push's full run. Before tagging, check the push run of that very commit is green.
- `.github/workflows/release.yml` (tag `v*`, or by hand): fetch VLCKit →
  `test.sh` → signing setup → `build_app.sh` → DMG. With the Apple secrets the
  app is signed with the Developer ID (Hardened Runtime, timestamp; every Mach-O
  inside VLCKit and its plugins first, inside out), the DMG signed and
  **submitted to Apple without waiting** (`Scripts/package_dmg.sh submit`),
  kept as artifact `macos-signed` (90 days). The job `release` creates the
  GitHub Release, signed: not marked "Latest" until its DMG is attached, so the README's `releases/latest/download` link never 404s. Without secrets: ad-hoc signed DMG attached right away, marked Latest.
- `.github/workflows/mac-release.yml`: after every Release run, every 30 min
  and by hand. Finds the newest release without `Schnellbild.dmg`, fetches
  `macos-signed`, runs `package_dmg.sh finish` (scripts from the same commit):
  Apple still checking → green, the next run asks again; accepted → staple,
  check like Gatekeeper, attach to the release and mark it Latest (if it is the newest); rejected → artifact deleted; Apple refusing the API key → red (it would never pass on its own). Tag builds are found whether the tag was pushed or Release was started by hand on it; `finish` checks again that no DMG is attached yet before it staples.
- `.github/workflows/notary-status.yml` (manual): Apple's submissions + status.
- Secrets in the GitHub environment `release` (only tags `v*` and `main`):
  `MACOS_CERT_P12` (base64 .p12 of the "Developer ID Application" certificate),
  `MACOS_CERT_PASSWORD`, `NOTARY_KEY_P8` (App Store Connect API key, content of
  the .p8), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. Team ID `87884AP46G`
  (in `mac-release.yml`). `Scripts/macos-signing.sh` sets them up in a
  temporary keychain and removes them again.
- Same setup as the author's other notarized project; the scripts are kept
  close to it on purpose.
- **Cut a release:** bump the version (`Resources/Info.plist` *and*
  `project.yml`), push to `main`, wait for green CI, then
  `git tag vX.Y.Z && git push origin vX.Y.Z`. Check: `gh release view vX.Y.Z`
  lists `Schnellbild.dmg`, and
  `curl -sIL https://github.com/JohannesHoppe/schnellbild/releases/latest/download/Schnellbild.dmg`
  ends in HTTP 200. The file name never changes, so the README link always
  points at the newest version. Never move or rebuild a published tag; ship a
  patch version instead.

## Working conventions

- **Work directly on `main`, no feature branches.** There is a single developer. **Commit locally while working on a set of features and push once when they're all done**, so CI doesn't run (and cancel itself) on every small commit. Typecheck locally as far as possible before that push (see Build / test / run).
- **Verify heavy / UI changes on CI, not locally.** Local runs of the app,
  XCUITests, code-signing, or `sudo` pop macOS dialogs (Gatekeeper, Touch ID,
  license) that interrupt the user.
  - Fine locally (no popups): `./Scripts/typecheck.sh` (works with only the Command Line Tools: app, unit and UI tests are typechecked, with stand-ins for SwiftUI's `@State` macro and for XCTest in `Scripts/typecheck/`; run it before every commit), and with a full Xcode `./Scripts/test.sh`, `swift build`.
  - Prefer CI (push → watch): running the `.app`, XCUITest, `build_app.sh`,
    anything that signs or launches a freshly-built bundle.
  - Only fall back to local launches when CI genuinely can't answer — say so first.
  - **Keep the README current.** Whenever a feature, key binding or anything else users see changes, check README.md (features, keyboard tables, screenshots) and the F1 help (`ShortcutsHelpView.swift`) and update them in the same commit. Build/test instructions live in `BUILDING.md`; the README sells the product.
  - **Screenshots:** after a visible UI change run `gh workflow run screenshots.yml`, look at every picture of the artifact `screenshots` yourself, then copy the light/dark pairs into `docs/screenshots/` (README shows them via `<picture>`, light or dark to match the reader). `Scripts/make_sample_media.swift` draws the sample photos and videos (no external images, the same on every run); `UITests/ReadmeScreenshots.swift` drives the app (skipped unless `SCREENSHOTS=1`) and asks for each picture over the pasteboard; the workflow's shell runs `screencapture` (only it holds the screen recording permission) and `Scripts/shoot_window.swift` composes: the `-l` capture **with the window shadow** on a transparent background, the content from the screen so sheets and menus are in it. The runner's screen is 1024×768, so the window opens at 960×640 and the Dock is hidden. Never crop windows without their shadow.
  - **Check anything visual yourself on CI with screenshots** (e.g. `dmg-preview.yml`), don't hand it to the user to look at. A GitHub runner is a clean Mac: what works there works everywhere, while the dev Mac has much installed that users don't have.
- Releases are **Developer ID signed and notarized** (see CI & release). CI
  builds (`ci.yml`) stay ad-hoc signed.
- Use the **`gh` CLI** for all GitHub work, never WebFetch. Grep freely.
- Give honest, candid assessments — surface trade-offs and let the user decide,
  rather than cheerleading.
- This is a **public repo**: never write personal/identifying details (emails,
  private notes about the user) into tracked files.

## Media Extensions (native thumbnails) — what is known

Goal: teach macOS the formats it can't read (AVI, MKV …) with a MediaExtension format reader (and later a video decoder), so Quick Look, Finder and Schnellbild's own grid get system-cached thumbnails. The experiments live in `Spike/MediaExtension/` and the manual workflow `spike-media-extension.yml` (CI ignores `Spike/**`). What QuickLook Video teaches (architecture, FFmpeg build, pitfalls, links): `docs/quicklook-video-research.md`.

Seen on CI (macOS 15 and 26 runners):
- macOS lists and matches the reader when ad hoc signed, but starts it only with the entitlement `com.apple.developer.mediaextension.formatreader`, and that needs Developer ID plus the provisioning profile (App IDs `art.haushoppe.schnellbild.formatreader` / `.videodecoder`, profiles as secrets `MACOS_PROFILE_FORMATREADER` / `MACOS_PROFILE_VIDEODECODER` in the `release` environment; the profiles carry the Developer ID certificate that expires 2027-02-01 and must be generated again with a new one). Ad hoc with the entitlement: AMFI refuses it; without it: it starts, but is never asked.
- It is off until turned on in System Settings → General → Login Items & Extensions → Media Extensions; CI turns it on through the accessibility API (`ax-enable.swift`); `pluginkit -e use` doesn't.
- An app that calls `MTRegisterProfessionalVideoWorkflowFormatReaders()` gets it from AVFoundation.
- Quick Look thumbnails (`QLThumbnailGenerator`) use Media Extensions only when the asking process has opted in (`MTRegisterProfessionalVideoWorkflowFormatReaders()` and `VTRegisterProfessionalVideoWorkflowVideoDecoders()`, `Spike/MediaExtension/probe-me.swift`), and only on macOS 26: there QuickLook Video's extensions gave real MKV and WebM thumbnails and Quick Look asked our signed reader; on macOS 15 neither. A video-only AVI got none (AVFoundation reads that container itself; its codec needs a decoder).
- AVCHD (`.mts`, `.m2ts`, H.264 in 192-byte transport stream packets): AVFoundation opens it itself (opted in or not; 1.88 s for the fixture, where our reader says 2.00 s), but Quick Look's thumbnails of it on macOS 26 come only through our reader: with it on, a picture (the fixture 0.05 s; a real Canon HG10 1080/50i clip from samples.ffmpeg.org, 512×288 in 0.33 s, fields and 16:9 right); with the type claimed and the file refused by the reader, with it off, or for a process that doesn't opt in, none. On macOS 15 none either way. On the dev Mac (macOS 27, no reader installed) none, opted in or not. An x264-made interlaced test clip decodes with wrong colours in places through VideoToolbox, through our reader and through AVFoundation from an MP4 remux alike; the real camcorder clip doesn't.
- Schnellbild's own reader works: `Spike/MediaExtension/MKVParser.swift` (Matroska in plain Swift: tracks, codec setup, where each frame lies, bounds-checked) and `Reader.swift` (the MediaExtension classes; frames located with `sampleLocation`, decoded by macOS) gave AVFoundation frames on macOS 15 and 26, and a Quick Look thumbnail of an H.264 MKV on macOS 26 (0.8 s first, then from the cache), Developer ID signed with the profile, turned on, the asking process opted in. Open for the product: reading the file in parts instead of whole, hostile-file tests, VP9 and other codecs need a decoder.

Where the leads came from (QuickLook Video by Marginal, which moved to Media Extensions in its version 3):
- The asking app must opt in itself — `MTRegisterProfessionalVideoWorkflowFormatReaders` and `VTRegisterProfessionalVideoWorkflowVideoDecoders` — for Quick Look thumbnails to use Media Extensions (Finder does; ForkLift did from 4.7): https://github.com/Marginal/QuickLookVideo/issues/191, https://github.com/Marginal/QuickLookVideo/issues/197
- The thumbnailing process sometimes sees the extensions but doesn't use them (a macOS bug in the maintainer's words); its "Refresh" (`qlmanage -r cache`, killing `AudiovisualThumbnailExtension` and the extensions, Finder) helps: https://github.com/Marginal/QuickLookVideo/issues/172, https://github.com/Marginal/QuickLookVideo/issues/173, commit https://github.com/Marginal/QuickLookVideo/commit/107f71307f96e0b14e37edaad3f4f76231c7dcea
- Thumbnails need the video decoder too, and VideoToolbox hardware decoding (`VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`; virtual machines may lack it): commit https://github.com/Marginal/QuickLookVideo/commit/0835ef7
- Its exported types conform to `public.movie`, not `com.apple.mediaextension-content` (else the CoreMedia importer takes them): `formatreader/Info.plist` in that repo.
- A video-only AVI is read by AVFoundation itself, so the reader isn't asked; then only a decoder for its FourCC helps: https://github.com/Marginal/QuickLookVideo/issues/203

## Current state & open threads (handover)

Version 0.9.0: folders + drag&drop, subfolder nav (Norton `..`),
keyboard-first (NSEvent monitor, F1 help), zoom/pan/pinch/rotate (view-only), video (AVKit + VLCKit fallback),
animated GIFs, slideshow, inspector, sort, reveal/open/trash, light/dark,
last-folder restore, always-visible recursive search over folder + file
names, back/forward/up history, folder and file rename, folder preview tiles, greyed-out empty folders, sort by name/kind/date modified/date taken/size, arrow keys that skim through videos, recursive slideshow with drop zones, auto enhance (exposure both ways, tone, sharpening) for photos and videos, video zoom.
Releases ship as a signed, notarized DMG (and, signed for it, to the Mac App Store), one app in the App Sandbox with VLCKit built without GPL modules, folder access kept as security-scoped bookmarks, file info with format, codecs and a wrong-extension note, `.ts` transport streams by their content, light / dark setting, archives as folders (ZIP, RAR via UnRAR, 7z; split, unfinished, passwords remembered; videos streamed), other files listed, SVG, mini keyboard (K), shortcuts on buttons, About window with licenses, dual pane with Norton Commander's F-keys (marking, F5/F6, dragging between panes), list view (L), new folder (⇧⌘N / F7), the folder's name in the title bar renames it, video volume on ↑↓, search modes (case, regular expression), folder bookmarks, undo / redo of file actions, the drives' level above /, boss key, printable cheat sheet, other files renamed / moved / trashed / opened.

Open / next-up:
- **Own keyboard shortcuts** — let users assign their own keys to the actions (Phiewer offers this in its PRO version; its defaults are in `docs/phiewer-shortcuts.md`). Idea: a preset "as in Phiewer" to switch to, for people coming from it; where the defaults differ: ⌘← ⌘→ (Phiewer: seek in a video; here: previous / next item), ⌘+ ⌘− (zoom; here: tile size), ⌫ (delete; here: Back), ⌘D (duplicate; here: bookmark), ⌘R (rename), ⌘Z / ⇧⌘Z (undo / redo; here deliberately no keys), ⌘1–⌘3 (gallery modes; here: sort), ⌥⌘L (folder / thumbnail view; here: L), ⌘P (print pictures). Today the keys are fixed; F1 lists them all and prints them.
- **Demo GIF** — storyboard ready in `docs/launch-storyboard.md`. User records it
  later, drops `docs/demo.gif`, uncomments the demo line near the top of README.
- **Launch posts** — `docs/launch.md` has ready Show HN + r/macapps copy; user
  posts when ready. Validation strategy: free + OSS first, gauge interest, then
  the Mac App Store version for 1 € (support).
- **Homebrew tap** — possible free distribution path for techies
  (`JohannesHoppe/homebrew-tap` + a cask pointing at the notarized DMG). Not built yet.
- **Apple silicon only**, on purpose: no Intel build; `build_app.sh` also cuts VLCKit down to arm64 (VideoLAN's binary carries Intel code too).
- **Speed benchmark** — "Schnellbild vs. Preview over the network" was offered to
  *prove* the speed claim (the GIF only sells the feel). Not built.
- Known limits (not planned): packages (apps, the Photos library) stay closed; archives inside archives aren't opened; videos inside archives get an icon as thumbnail; sorting by date taken uses the date modified inside archives.
