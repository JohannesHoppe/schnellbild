# Schnellbild — project guide & session handover

Read this first. It's the durable memory between sessions. Keep it accurate —
update it when the facts change.

## What this is

A **fast, lean macOS image/video viewer** (SwiftUI, macOS 14+) — "Phiewer but
minimal". Core promise: stays fast **even over network volumes**, where most
viewers (and sometimes Preview) stall. It does what Preview does well: read
little, load in parallel, cache via the system, never block the main thread.

- Repo: <https://github.com/JohannesHoppe/schnellbild> — **public, MIT**,
  © 2026 HAUS HOPPE - ITS (Johannes Hoppe).
- Bundle id: `art.haushoppe.schnellbild`. Current version: **0.3.0**.
- Everything (code, comments, UI strings, docs, commits) is in **English**.
  The user converses in **German**.

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
    from a tree walk; debounced via `searchDebounce`. The model owns the
    results (`searchResults`); batches are appended via `appendSearchBatch`,
    which replays the changes made during that walk (`searchChanges`, reset
    per search), so late batches never revive old paths.
  - **`FileChange`** (`.moved` / `.removed`) is the one mechanism for changes
    the app makes on disk: `apply(_:)` runs it over every list the model holds
    (folder entries, search results, pending selection, history) and keeps
    the selection. Rename and trash only create the change.
  - Paths are compared with `canonicalPath`: pure string work (standardized,
    `/private/var` → `/var`), no file system access, because it runs per entry
    on the main thread and must stay fast on network volumes.
  - `open(folder:)` records history; `navigateBack/Forward` restore folder,
    query, selection and the **remembered search results** (not searched
    again), so "Back" from a result folder shows the same, stable list. A
    search left before it finished is searched again instead.
  - Renaming a folder (`renameFolder`) never navigates: folder, query and
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
- **`RenameFolderView.swift`** — the F2 rename sheet (`model.renameFolder`).
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
- **`ShortcutsHelpView.swift`** — F1 / "Schnellbild Help" cheat sheet (same
  content as the README keyboard tables; keep them in sync).
- **`ThumbnailView.swift` / `ThumbnailGridView.swift`** — `LazyVGrid`, thumbnails
  from QuickLook (`QLThumbnailGenerator`). `ThumbnailCache` keeps one image per
  file with the size it was made for (reused for smaller tiles, regenerated
  for larger; the full view's placeholder). Folder previews use their own
  `ThumbnailCache.previews`. `FolderTile` fans up to three previews of a
  folder's first media files (`BrowserModel.folderPreviewFiles`, listed once
  per folder via `FolderPreviewCache`). Tiles carry accessibility ids
  `tile.<name>`; their label starts with `selected` / `not selected`.
- **`FullImageView.swift`** — ImageIO downsample + zoom/pan/rotate (view-only;
  **never modifies files** — important user constraint).
- **`VideoDetailView.swift`** — native formats via AVKit; non-native fall back
  to VLCKit. Creates and registers the one `PlaybackControl` per file
  (`AVPlaybackControl` or `VLCPlaybackControl`) in its `.task(id: url)`.
- **`VLCVideoView.swift`** — `VLCPlaybackControl` (owns the `VLCMediaPlayer`,
  `import VLCKit`) and `VLCVideoView`, the `NSViewRepresentable` it draws into.
- **`MediaExtras.swift`** — GIF (`AnimatedImageView`), `InspectorView`,
  `MediaInfo`, `LoadingSpinner`.

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
  (positions must match the settings file).
- After editing `project.yml` **or adding/removing a `.swift` file**, re-run
  `xcodegen generate` before the Xcode/UITest build (the app target embeds
  `Vendor/VLCKit.xcframework`).
- Tests: 98 unit (`Tests/SchnellbildTests/BrowserModelTests.swift`: search,
  history, rename, file actions via spy, playback via `PlayerSpy`, every key
  binding) + 56 XCUITest in `UITests/*UITests.swift` (grid, search, navigation,
  full view, video incl. VLC, actions), sharing `UITestSupport.swift`. Media
  fixtures live in `UITests/Fixtures` (bundled as test resources). Not covered
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

- **Work directly on `main`, no feature branches.** There is a single developer; commit and push to `main`, CI runs on every push.
- **Verify heavy / UI changes on CI, not locally.** Local runs of the app,
  XCUITests, code-signing, or `sudo` pop macOS dialogs (Gatekeeper, Touch ID,
  license) that interrupt the user.
  - Fine locally (no popups): `./Scripts/test.sh`, `swift build`.
  - Prefer CI (push → watch): running the `.app`, XCUITest, `build_app.sh`,
    anything that signs or launches a freshly-built bundle.
  - Only fall back to local launches when CI genuinely can't answer — say so first.
- Releases are **Developer ID signed and notarized** (see CI & release). CI
  builds (`ci.yml`) stay ad-hoc signed.
- Use the **`gh` CLI** for all GitHub work, never WebFetch. Grep freely.
- Give honest, candid assessments — surface trade-offs and let the user decide,
  rather than cheerleading.
- This is a **public repo**: never write personal/identifying details (emails,
  private notes about the user) into tracked files.

## Current state & open threads (handover)

Version 0.3.0: folders + drag&drop, subfolder nav (Norton `..`),
keyboard-first (NSEvent monitor, F1 help), zoom/pan/pinch/rotate (view-only), video (AVKit + VLCKit fallback),
animated GIFs, slideshow, inspector, sort, reveal/open/trash, light/dark,
last-folder restore, always-visible recursive search over folder + file
names, back/forward/up history, folder rename, folder preview tiles.
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
