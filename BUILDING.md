# Building Schnellbild

> **Requirement:** a full **Xcode** install (not just the Command Line Tools: they have no macOS platform metadata and can't build SwiftUI).

```bash
# Activate Xcode (one-time):
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# In the project folder:
./Scripts/fetch_vlckit.sh   # vendors our VLCKit build once (~70 MB download)
swift build                 # compiles (checks the code)
./Scripts/build_app.sh      # → build/Schnellbild.app
open build/Schnellbild.app  # starts the app
```

`swift run` can't start the app: the executable looks for VLCKit in `../Frameworks` next to it (VLCKit's install name), where only the app bundle has it. `build_app.sh` embeds it there.

Video formats macOS can't play natively (AVI, MKV, WebM …) are handled by a vendored **VLCKit**: our build of VideoLAN's source without VLC's GPL modules and without its network modules (`Scripts/build_vlckit_lgpl.sh`, published as a pre-release of this repository), fetched and SHA-256-verified by `Scripts/fetch_vlckit.sh` (gitignored). Native formats stay on AVKit.

## App bundle and DMG

```bash
./Scripts/build_app.sh      # → build/Schnellbild.app (icon, Info.plist, VLCKit embedded, ad-hoc signed)
./Scripts/package_dmg.sh dmg   # → dist/Schnellbild.dmg (needs dmgbuild, see Installer/requirements.txt)
```

The icon comes from `Scripts/make_icon.swift`, the DMG window's background from `Scripts/make_dmg_background.swift` (both CoreGraphics, no external tools).

## Downloads

Everything the app's build, its tests and CI fetch comes from this repository's own releases, each file checked against its pinned SHA-256: VLCKit (`fetch_vlckit.sh`), the UnRAR source (`fetch_unrar.sh`), the LibRaw source (`fetch_libraw.sh`), the map and globe data (`fetch_map.sh`, `fetch_globe.sh`), XcodeGen (`fetch_xcodegen.sh`) and the Python wheels `dmgbuild` needs (release workflow, `Installer/requirements.txt`) from the pre-release `build-deps`. Only when our copy can't be reached does a script ask the original source, with the same pin: rarlab.com for UnRAR, libraw.org for LibRaw, XcodeGen's GitHub release, PyPI for the wheels (`--require-hashes`). The scripts that make the data (`build_map_data.py`, `build_globe_data.py`) take their inputs from the archive releases `map-source-…` and `globe-source-…` the same way.

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

CI runs them against the bundle `build_app.sh` makes (`TEST_RUNNER_SCHNELLBILD_APP=<path to Schnellbild.app>` before `xcodebuild`), so the app runs in the App Sandbox exactly as it ships; the Xcode build alone gets Xcode's own exceptions for testing (read access to the whole disk). The tests keep their folders in `/Users/Shared/SchnellbildUITests` (make it first) and open them to the app through the open panel; the tests of other volumes want a disk image mounted at `/Volumes/SchnellbildUITests` (`hdiutil create -size 64m -fs APFS -volname SchnellbildUITests x.dmg && hdiutil attach x.dmg`).

CI runs both on every push to `main` that changes something the build or the tests read (`ci.yml`'s `paths`; `CIPathsTests` checks the list).

## Screenshots

The README pictures come from the workflow **Screenshots** (`gh workflow run screenshots.yml`). On a clean GitHub runner it draws a sample library of photos and videos (`Scripts/make_sample_media.swift`, the same on every run), drives the app through its views (`UITests/ReadmeScreenshots.swift`) and photographs the window with its shadow, in light and dark mode. `-f language=<lang>` takes one of the app's languages (`en`, `de`, `pt-BR`, `zh-Hans` …), `-f language=all` every one; each language's PNGs land in the artifact `screenshots-<lang>`. The repository keeps screenshots only as WebP:

```bash
gh run download <run id> -n screenshots-en -D shots/en       # one folder per language
python3 Scripts/make_site_images.py import shots/*          # lossless WebP masters into docs/screenshots/
python3 Scripts/make_site_images.py shots                   # the sizes the website loads
python3 Scripts/build_site.py --check
```

## Releases

Tagging `vX.Y.Z` first checks that the tag is the version in `Resources/Info.plist` and `project.yml` (`Scripts/check_release_version.sh`; bump both before tagging), then builds the app, signs it with the Developer ID, packs the DMG and submits it to Apple for notarization; once Apple accepts it, the DMG is attached to the GitHub Release (`release.yml`, `mac-release.yml`). The workflow **DMG preview** photographs the DMG window in Finder.
