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
- Bundle id: `art.haushoppe.schnellbild`. Current version: **0.2.0** (released).
- Everything (code, comments, UI strings, docs, commits) is in **English**.
  The user converses in **German**.

## Architecture & key files

SwiftPM **executableTarget** `Schnellbild` (sources in `Schnellbild/*.swift`).
There is **no Xcode project for the app build**; `xcodegen` generates
`Schnellbild.xcodeproj` (gitignored) **only for the XCUITests**, from `project.yml`.

- **`BrowserModel.swift`** — `@MainActor ObservableObject`, the single source of
  truth. Holds `entries`/`allEntries`, `selection`, `mode` (.grid/.detail),
  `zoom`, `rotation`, search (`searchText`/`searchScope`/`searchActive`/
  `isSearching`), `showInspector`, `showHelp`, sort, `activePlayer` (AVPlayer).
  **All key bindings live in `handleKey(_:command:) -> Bool`** with the
  `KeyInput` enum — this is the unit-tested dispatch.
- **`ContentView.swift`** — one **local `NSEvent` keyDown monitor** dispatches
  *every* key through `model.handleKey` via `MainActor.assumeIsolated`. This is
  deliberate: SwiftUI focus kept losing Backspace/arrows, so keys are
  focus-independent now. F1 = keyCode 122 → `showHelp`. The monitor passes keys
  through when the first responder is `NSText` (search field) or `showHelp`.
  Hardware keyCodes: 51 Backspace, 53 Esc, 36/76 Return, 49 Space, 123 ←,
  124 →, 125 ↓, 126 ↑, 115 Home, 119 End, 122 F1.
- **`ShortcutsHelpView.swift`** — F1 / "Schnellbild Help" cheat sheet (same
  content as the README keyboard tables; keep them in sync).
- **`ThumbnailView.swift` / `ThumbnailGridView.swift`** — `LazyVGrid`, thumbnails
  from QuickLook (`QLThumbnailGenerator`), `NSCache`.
- **`FullImageView.swift`** — ImageIO downsample + zoom/pan/rotate (view-only;
  **never modifies files** — important user constraint).
- **`VideoDetailView.swift`** — native formats via AVKit; non-native fall back to…
- **`VLCVideoView.swift`** — `NSViewRepresentable` over VLCKit (`VLCMediaPlayer`);
  `import VLCKit`.
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

- Needs a **full Xcode** (not just Command Line Tools).
- **`swift test` ALONE FAILS.** VLCKit's `binaryTarget` links into the `.xctest`
  bundle but SwiftPM doesn't embed it (install name `@loader_path/../Frameworks/…`).
  **Always use `./Scripts/test.sh`** — it fetches VLCKit, `swift build --build-tests`,
  copies `VLCKit.framework` into the test bundle, then `swift test --skip-build`.
- Any build needs `Vendor/VLCKit.xcframework` present → run
  `./Scripts/fetch_vlckit.sh` first (`test.sh` and `build_app.sh` call it for you).
- **`./Scripts/build_app.sh`** → `build/Schnellbild.app`: fetch VLCKit, render
  icon, `swift build -c release`, assemble bundle, **embed VLCKit.framework into
  `Contents/Frameworks` + add `@executable_path/../Frameworks` rpath**, ad-hoc sign.
- After editing `project.yml` **or adding/removing a `.swift` file**, re-run
  `xcodegen generate` before the Xcode/UITest build (the app target embeds
  `Vendor/VLCKit.xcframework`).
- Tests: 27 unit (`BrowserModelTests.swift`, incl. `KeyBindingTests` for every
  binding) + 5 XCUITest (`UITests/SchnellbildUITests.swift`, incl. F1).
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
- `.github/workflows/release.yml`: on tag `v*` → fetch VLCKit → `test.sh` →
  `build_app.sh` → zip → publish GitHub Release. **Cut a release** by bumping
  the version (`Resources/Info.plist` *and* `project.yml`) then
  `git tag vX.Y.Z && git push origin vX.Y.Z`.

## Working conventions

- **Verify heavy / UI changes on CI, not locally.** Local runs of the app,
  XCUITests, code-signing, or `sudo` pop macOS dialogs (Gatekeeper, Touch ID,
  license) that interrupt the user.
  - Fine locally (no popups): `./Scripts/test.sh`, `swift build`.
  - Prefer CI (push → watch): running the `.app`, XCUITest, `build_app.sh`,
    anything that signs or launches a freshly-built bundle.
  - Only fall back to local launches when CI genuinely can't answer — say so first.
- The shipped `.app` is **ad-hoc signed, not notarized** → testers need
  `xattr -dr com.apple.quarantine Schnellbild.app` or right-click → Open.
  There is **no free Apple-trusted signing**; $99/yr is the only path that
  removes the Gatekeeper prompt for everyone. (Homebrew doesn't sign — it relies
  on notarized apps and on CLI downloads not getting the quarantine flag.)
- Use the **`gh` CLI** for all GitHub work, never WebFetch. Grep freely.
- Give honest, candid assessments — surface trade-offs and let the user decide,
  rather than cheerleading.
- This is a **public repo**: never write personal/identifying details (emails,
  private notes about the user) into tracked files.

## Current state & open threads (handover)

Done & released as **v0.2.0**: folders + drag&drop, subfolder nav (Norton `..`),
keyboard-first (NSEvent monitor, F1 help), search (⌘F, this-folder + recursive
subfolders), zoom/pan/pinch/rotate (view-only), video (AVKit + VLCKit fallback),
animated GIFs, slideshow, inspector, sort, reveal/open/trash, light/dark,
last-folder restore. App is installed at `/Applications/Schnellbild.app`
(quarantine already cleared). CI + release green.

Open / next-up:
- **Demo GIF** — storyboard ready in `docs/launch-storyboard.md`. User records it
  later, drops `docs/demo.gif`, uncomments the demo line near the top of README.
- **Launch posts** — `docs/launch.md` has ready Show HN + r/macapps copy; user
  posts when ready. Validation strategy: free + OSS first, gauge interest, then
  decide on paid (Developer ID + direct sale, not MAS).
- **Homebrew tap** — discussed as the free "like Homebrew" distribution path for
  techies (`JohannesHoppe/homebrew-tap` + a cask). **NOT yet verified** whether a
  tap cask launches an *unsigned* app without the Gatekeeper prompt on current
  macOS — verify before promising it. Not built yet.
- **Speed benchmark** — "Schnellbild vs. Preview over the network" was offered to
  *prove* the speed claim (the GIF only sells the feel). Not built.
- Known limits (README "Status"): not notarized; slideshow interval fixed at 3 s;
  `1` (100 %) is approximate; animated GIFs don't zoom/pan.
