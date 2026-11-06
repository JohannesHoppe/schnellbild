# Schnellbild — project guide & session handover

Read this first. It's the durable memory between sessions. Keep it accurate —
update it when the facts change.

## What this is

A **fast, lean macOS image/video viewer** (SwiftUI, macOS 14+) — "Phiewer but
minimal". Motto: **an image & video viewer that just doesn't suck.** Speed
(also over network volumes) is one part of that, not the headline. It does
what Preview does well: read little, load in parallel, cache via the system,
never block the main thread.

- Repo: <https://github.com/JohannesHoppe/schnellbild> — **public, MIT**,
  © 2026 HAUS HOPPE - ITS (Johannes Hoppe).
- Bundle id: `art.haushoppe.schnellbild`. Current version: **0.4.0**.
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
  **All key bindings live in `handleKey(_:command:) -> Bool`** with the
  `KeyInput` enum — this is the unit-tested dispatch. Keys typed in the search
  field go through `handleSearchFieldKey`.
  - Search is **always recursive** and matches **folder and file names**: local
    matches at once, then `recursiveMatches` streams batches (`AsyncStream`)
    from a tree walk; debounced via `searchDebounce`. Each search is a
    `SearchRun` (results, the walk's task, the changes made during the walk,
    replayed on every late batch so it never revives old paths); the model
    shows one (`search`), the history may hold more.
  - **`FileChange`** (`.moved` / `.removed`) is the one mechanism for changes
    the app makes on disk: `apply(_:)` runs it over every list the model holds
    (folder entries, search results, pending selection, history) and keeps
    the selection. Rename and trash only create the change.
  - Paths are compared with `canonicalPath`: pure string work (standardized,
    `/private/var` → `/var`), no file system access, because it runs per entry
    on the main thread and must stay fast on network volumes.
  - `open(folder:)` records history; `navigateBack/Forward` restore folder,
    query, selection and the search (`SearchRun`: results, the walk, changes
    to replay). A search still running when the user leaves keeps running
    in the history (the newest `backgroundSearchLimit`; older ones stop and
    are searched again on return), so "Back" shows it without starting over.
    The stop button (`stopSearch`) ends a walk and keeps its results.
  - Renaming a folder or file (`rename`, also from the full view; a file must keep a media extension) never navigates: folder, query and
    results stay; the folder and everything listed inside it get the new path
    (`FileChange.moved`), as do history entries and results still streaming in.
    `FileActions.conflicts` refuses a target that is a different item (also
    the case-variant on case-sensitive volumes such as NAS shares); the live
    case-only move goes via a temporary name and rolls back on failure.
    Backspace / ⌘↑ / `..` = enclosing folder (`goToParentFolder`).
  - Side effects (Finder, open, trash + confirm alert, move/rename) go through
    the injectable `FileActions`; tests pass a spy. `--ui-testing` makes the app
    use its own `UserDefaults` suite (`--reset-state` clears it).
  - ⌘⌫ / ⌘↩ return `false` from `handleKey` so they reach their menu items
    (the local key monitor sees keys before menu key equivalents).
- **`SearchField.swift`** — `NSSearchField` wrapper, always visible above the
  content. It refuses first responder until clicked or ⌘F, otherwise AppKit
  focuses it on launch and it swallows the grid keys.
- **`RenameView.swift`** — the F2 rename sheet (`model.rename`); for files the base name is preselected.
- **`ContentView.swift`** — one **local `NSEvent` keyDown monitor** dispatches
  *every* key through `model.handleKey` via `MainActor.assumeIsolated`. Keys are
  deliberately focus-independent, because SwiftUI focus can swallow
  Backspace/arrows. F1 works everywhere except in the rename sheet (a second
  sheet can't open on top), F2 also while typing in the search field. The
  monitor only maps key codes; the gate (text field editing via
  `textEditing:`, open sheets) lives in `handleKey` and is unit-tested.
- **Video state:** `PlaybackControl.isPlaying` is the player's real state;
  the players report changes (own controls, end of video) through
  `model.playbackStateChanged`, which drives the "Paused" badge.
  Hardware keyCodes (`ContentView.keyInput`, unit-tested): 51 Backspace, 53 Esc,
  36/76 Return, 49 Space, 123 ←, 124 →, 125 ↓, 126 ↑, 115 Home, 119 End,
  122 F1, 120 F2. Toolbar: Back / Forward / Up / Open Folder.
- **Slideshow** (`BrowserModel.Slideshow`, `startSlideshow`): its own item list, filled by `walkForSlideshow` folder by folder (a folder's media in the sort order, then each subfolder, hidden folders skipped) and shown while the walk goes on. Starts over the folder passed in (drop zone, a folder tile's context menu "Play Slideshow"), else the search results, else the current folder — never over the selected tile (a folder is selected by default); from the full view at the item shown. Pictures advance after `slideshowInterval`, videos when `playbackStateChanged` reports their end. Full screen via the injectable `setFullScreen`; toolbar, search and status bar hide. Keys go through `handleSlideshowKey`. `shownMediaEntry` is the one item on screen (slideshow or full view); `page`/`skim` work on it. Dropping onto the window shows two zones (`DropZonesView`, `DropZoneDelegate`): Browse / Slideshow.
- **Auto enhance and adjustments** (`Enhancer.swift`): a view filter, files untouched. One parametric `Look` (exposure as a gamma curve, contrast, saturation, sharpness; filters run on sRGB-encoded values, the scale `PictureStats` measures on). Auto (`enhance`, key E, the wand) works out a `Look` from `PictureStats` (`Look.auto`); the sliders (`AdjustmentsView`, key A, model `look`) show it live. Moving a slider calls `model.adjust`: auto goes off, `manualLook` carries on from the shown values and stays while paging; auto off via E/the switch resets to the file as is. Players get `Enhancement` (.off/.auto/.manual) through `PlaybackControl.setEnhancement` and report auto's look via `onAutoLook` → `model.autoLookMeasured`. Photos: `FullImageView` measures once per picture and renders off the main thread. AVKit: one `AVVideoComposition` per video whose `VideoEnhancer` reads the current mode per frame (`AdaptiveLook`: measured once a second, black/white frames held, first picture and seeks at once, gliding in between); a paused video is redrawn by a zero-tolerance seek. VLC: `VLCFrameOutput` takes VLC's decoded pictures through libVLC's video callbacks (`libvlc_video_set_callbacks`/`_format_callbacks`, looked up with `dlsym`; the native player via `-[VLCMediaPlayer libVLCMediaPlayer]`) into IOSurface-backed NV12 buffers (the video's own form: no colour conversion on the processor; BT.709 attachments for HD, BT.601 below; the compositor converts) and shows them on a layer, applying the `Look` with Core Image into BGRA buffers when it isn't neutral, so AVKit and VLC share one filter; auto measures the decoded picture once a second (no feedback from its own correction). No VLC OpenGL output at all: VLC's `macosx` output needs OpenGL, which CI runners (virtual Macs) lack and macOS deprecates. Media get `:no-osd` (VLC would draw messages into the picture). VLCKit supports only its shared `VLCLibrary`: a second instance lacks VLCKit's default options and plays nothing.
- **`ShortcutsHelpView.swift`** — F1 / "Schnellbild Help" cheat sheet (same
  content as the README keyboard tables; keep them in sync).
- **`ThumbnailView.swift` / `ThumbnailGridView.swift`** — `LazyVGrid`, thumbnails
  from QuickLook (`QLThumbnailGenerator`); videos QuickLook only has an icon for (AVI, MKV …) get a frame from VLC (`VLCThumbnails`, two at a time). `ThumbnailCache` keeps one image per
  file with the size it was made for (reused for smaller tiles, regenerated
  for larger; the full view's placeholder). Folder previews use their own
  `ThumbnailCache.previews`. `FolderTile` fans up to three previews of a
  folder's first media files (`BrowserModel.folderPreviewFiles`, listed once
  per folder via `FolderPreviewCache`). Folders with no photo or video at any depth (`BrowserModel.containsMedia`, stops at the first hit; hidden files and non-media like `Thumbs.db` don't count) are greyed out; the model keeps them in `emptyFolders`, and a `FileChange` forgets the folders around it. Tiles carry accessibility ids
  `tile.<name>`; their label starts with `selected` / `not selected`.
- **`FullImageView.swift`** — ImageIO downsample + zoom/pan/rotate (view-only;
  **never modifies files** — important user constraint).
- **`VideoDetailView.swift`** — native formats via AVKit; non-native fall back
  to VLCKit. Creates and registers the one `PlaybackControl` per file
  (`AVPlaybackControl` or `VLCPlaybackControl`) in its `.task(id: url)`.
- **Video zoom**: `VideoDetailView` scales, rotates and pans the player view like `FullImageView` (model `zoom`/`rotation`); a clear layer takes the drag only while zoomed (the player's control bar stays usable at fit). Trackpad pinch on videos goes through a `.magnify` event monitor in `ContentView`, since AVKit's view would take it. On videos `1` = fit.
- **`VLCVideoView.swift`** — `VLCPlaybackControl` (owns the `VLCMediaPlayer`,
  `import VLCKit`) and `VLCVideoView`, the `NSViewRepresentable` it draws into.
- **`MediaExtras.swift`** — GIF (`AnimatedImageView`), `InspectorView`,
  `MediaInfo`, `LoadingSpinner`.
- **Localization** — English is the source language; the UI follows the macOS language. Translations live in `Resources/Localization/<lang>.lproj/` (`Localizable.strings`, plus `Localizable.stringsdict` for the counted nouns "%lld folders / images / videos / results"); `build_app.sh` copies them into `Contents/Resources`, `project.yml` adds them to the UI-test build, and `Info.plist` lists them in `CFBundleLocalizations`. SwiftUI literals (`Text`, `Button`, `Label`, `.help`, menus) are looked up by their English text; strings built in code use `String(localized:)`, so interpolations become `%@` / `%lld` keys. **Every new or changed UI string needs an entry in every `.lproj`** (English key = value); `LocalizationTests` fails otherwise and checks the placeholders match. Key names in the F1 help (Return, Backspace …), file names and the accessibility labels the UI tests read (tile labels, zoom state) stay English. UI tests launch the app with `-AppleLanguages (en)`.

## VLCKit (the heavy dependency — read carefully)

AVI/MKV/WebM and other non-native formats play **in-app via vendored VLCKit
(LibVLC), as a fallback only**; native formats stay on AVKit.

- It's the **official VideoLAN macOS binary**, fetched + **SHA-256-verified**
  by `Scripts/fetch_vlckit.sh` (pinned to VideoLAN's published checksum
  `23f8f7bb…`, from `download.videolan.org/pub/cocoapods/prod/VLCKit-3.6.0-…tar.xz`).
- Vendored to **`Vendor/VLCKit.xcframework`** (gitignored; ~81 MB download,
  ~387 MB unpacked). `Package.swift` references it as a **local `binaryTarget`**
  (`path: "Vendor/VLCKit.xcframework"`), the executable depends on `"VLCKit"`,
  code does `import VLCKit`.
- **Deliberately NOT a third-party SPM repo.** The user is security-conscious;
  we audited the community wrapper, then chose: official binary + our own hash +
  local vendoring → minimal attack vector, no external repo in the trust path.
- **Mac App Store is ruled out** because of VLCKit: (1) sandbox + LibVLC plugin
  loading is fragile, (2) **LGPL/GPL conflicts with App Store terms** (the reason
  VLC itself was once pulled). If monetizing later: **Developer ID + notarization
  ($99/yr) + direct sale (e.g. Gumroad)**, never MAS.

## Build / test / run — gotchas that will bite you

- Needs a **full Xcode** (not just Command Line Tools). With only the CLT,
  `swift build` fails ("SwiftUIMacros … plugin not found": `@State` is a macro
  in the macOS 27 SDK). Without Xcode on the machine, build and test on CI.
- **`swift test` ALONE FAILS.** VLCKit's `binaryTarget` links into the `.xctest`
  bundle but SwiftPM doesn't embed it (install name `@loader_path/../Frameworks/…`).
  **Always use `./Scripts/test.sh`** — it fetches VLCKit, `swift build --build-tests`,
  copies `VLCKit.framework` into the test bundle, then `swift test --skip-build`.
- Any build needs `Vendor/VLCKit.xcframework` present → run
  `./Scripts/fetch_vlckit.sh` first (`test.sh` and `build_app.sh` call it for you).
- **`./Scripts/build_app.sh`** → `build/Schnellbild.app`: fetch VLCKit, render
  icon, `swift build -c release`, assemble bundle, **embed VLCKit.framework into
  `Contents/Frameworks` + add `@executable_path/../Frameworks` rpath**, sign
  inside out (Developer ID with `MACOS_SIGN_IDENTITY`, else ad hoc).
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
  history, rename, file actions via spy, playback via `PlayerSpy`, every key
  binding; `LocalizationTests.swift`) + XCUITests (`ReadmeScreenshots` is skipped in CI) in `UITests/*UITests.swift` (grid, search, navigation,
  full view, video incl. VLC, actions), sharing `UITestSupport.swift`. Media
  fixtures live in `UITests/Fixtures` (bundled as test resources; the dark,
  overexposed, even grey, 4K60 and broken ones are drawn by `swift Scripts/make_test_fixtures.swift UITests/Fixtures`).
  **`VisualUITests` measure what the screen shows**: the CI shell of the
  UI-test job answers "measure:<id>:<rect>" pasteboard requests with
  `screencapture` + `Scripts/measure_brightness.swift` (the test runner can't
  record the screen; XCUITest's own screenshot shows VLC's picture black).
  They check that videos (AVKit, and VLC via `--force-vlc`) are bright from
  the start, that VLC draws no messages over the video, that handing a 4K picture over from VLC costs under 3 ms (lost pictures are only reported: CI's virtual Macs vary too much), that AVKit and VLC show the same video with the same brightness, auto enhance and the exposure slider on videos and photos, and
  that broken files don't take the app down. Anything visual gets such a
  measured test, so it can't regress unnoticed. Launch switches for UI
  tests (only with `--ui-testing`; every argument starts with "-" and a
  value is joined with "=", since AppKit pairs "-name value" and takes an
  unpaired value for a file to open): `--open=<path>`, `--force-vlc` (every
  video through VLC), `--test-log=<path>` (the app logs what the screen
  doesn't show, e.g. each rename), `--search-delay=<ms>` (a search that stays
  running). Not covered
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
  `build_app.sh` → upload zip) and `ui-tests` (fetch+cache VLCKit → `xcodegen` →
  `xcodebuild` UI). **`paths-ignore: ['**.md', 'LICENSE']`** → doc-only pushes
  don't trigger CI. Both jobs cache `Vendor/` keyed on `fetch_vlckit.sh`'s hash.
- `.github/workflows/release.yml` (tag `v*`, or by hand): fetch VLCKit →
  `test.sh` → signing setup → `build_app.sh` → DMG. With the Apple secrets the
  app is signed with the Developer ID (Hardened Runtime, timestamp; every Mach-O
  inside VLCKit and its plugins first, inside out), the DMG signed and
  **submitted to Apple without waiting** (`Scripts/package_dmg.sh submit`),
  kept as artifact `macos-signed` (90 days). The job `release` creates the
  GitHub Release. Without secrets: ad-hoc signed DMG attached right away.
- `.github/workflows/mac-release.yml`: after every Release run, every 30 min
  and by hand. Finds the newest release without `Schnellbild.dmg`, fetches
  `macos-signed`, runs `package_dmg.sh finish` (scripts from the same commit):
  Apple still checking → green, the next run asks again; accepted → staple,
  check like Gatekeeper, attach to the release; rejected → artifact deleted.
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

## Current state & open threads (handover)

Version 0.4.0: folders + drag&drop, subfolder nav (Norton `..`),
keyboard-first (NSEvent monitor, F1 help), zoom/pan/pinch/rotate (view-only), video (AVKit + VLCKit fallback),
animated GIFs, slideshow, inspector, sort, reveal/open/trash, light/dark,
last-folder restore, always-visible recursive search over folder + file
names, back/forward/up history, folder and file rename, folder preview tiles, greyed-out empty folders, sort by name/kind/date modified/date taken/size, arrow keys that skim through videos, recursive slideshow with drop zones, auto enhance (exposure both ways, tone, sharpening) for photos and videos, video zoom.
Releases ship as a signed, notarized DMG.

Open / next-up:
- **Demo GIF** — storyboard ready in `docs/launch-storyboard.md`. User records it
  later, drops `docs/demo.gif`, uncomments the demo line near the top of README.
- **Launch posts** — `docs/launch.md` has ready Show HN + r/macapps copy; user
  posts when ready. Validation strategy: free + OSS first, gauge interest, then
  decide on paid (direct sale, not MAS).
- **Homebrew tap** — possible free distribution path for techies
  (`JohannesHoppe/homebrew-tap` + a cask pointing at the notarized DMG). Not built yet.
- **Universal build** — releases are built on an Apple-silicon runner and are
  arm64 only; Intel would need a universal `swift build`.
- **Speed benchmark** — "Schnellbild vs. Preview over the network" was offered to
  *prove* the speed claim (the GIF only sells the feel). Not built.
- Known limits (README "Status"): slideshow interval fixed at 3 s;
  `1` (100 %) is approximate; animated GIFs don't zoom/pan.
