# Building Schnellbild

> **Requirement:** a full **Xcode** install (not just the Command Line Tools: they have no macOS platform metadata and can't build SwiftUI).

```bash
# Activate Xcode (one-time):
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# In the project folder:
./Scripts/fetch_vlckit.sh   # vendors the official VLCKit once (~80 MB download)
swift build                 # compiles (checks the code)
./Scripts/build_app.sh      # → build/Schnellbild.app
open build/Schnellbild.app  # starts the app
```

`swift run` can't start the app: the executable looks for VLCKit in `../Frameworks` next to it (VLCKit's install name), where only the app bundle has it. `build_app.sh` embeds it there.

Video formats macOS can't play natively (AVI, MKV, WebM …) are handled by a vendored **VLCKit**: the official VideoLAN binary, fetched and SHA-256-verified by `Scripts/fetch_vlckit.sh` (gitignored). Native formats stay on AVKit.

## App bundle and DMG

```bash
./Scripts/build_app.sh      # → build/Schnellbild.app (icon, Info.plist, VLCKit embedded, ad-hoc signed)
./Scripts/package_dmg.sh dmg   # → dist/Schnellbild.dmg (needs dmgbuild, see Installer/requirements.txt)
```

The icon comes from `Scripts/make_icon.swift`, the DMG window's background from `Scripts/make_dmg_background.swift` (both CoreGraphics, no external tools).

## Tests

Unit tests run via SwiftPM. The script vendors VLCKit and copies it into the test bundle, since SwiftPM doesn't embed binary frameworks there:

```bash
./Scripts/test.sh
```

End-to-end UI tests use XCUITest, which needs an Xcode project generated from `project.yml` with [xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
export PATH="$(./Scripts/fetch_xcodegen.sh):$PATH"   # the version CI uses, checksum-verified
xcodegen generate
xcodebuild test -project Schnellbild.xcodeproj -scheme Schnellbild \
  -destination 'platform=macOS' -only-testing:SchnellbildUITests
```

CI runs both on every push to `main`.

## Screenshots

The README pictures come from the workflow **Screenshots** (`gh workflow run screenshots.yml`). On a clean GitHub runner it draws a sample library of photos and videos (`Scripts/make_sample_media.swift`, the same on every run), drives the app through its views (`UITests/ReadmeScreenshots.swift`) and photographs the window with its shadow, in light and dark mode. The artifact `screenshots` holds the PNGs for `docs/screenshots/`.

## Releases

Tagging `vX.Y.Z` builds the app, signs it with the Developer ID, packs the DMG and submits it to Apple for notarization; once Apple accepts it, the DMG is attached to the GitHub Release (`release.yml`, `mac-release.yml`). The workflow **DMG preview** photographs the DMG window in Finder.
