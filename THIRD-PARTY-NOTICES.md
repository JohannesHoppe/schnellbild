# Third-party notices

Schnellbild's own source code is under the MIT License (see [LICENSE](LICENSE)). The app as distributed (`Schnellbild.app`, the DMG) also contains the components below. Each keeps its own license; the MIT License covers only Schnellbild's own code. The app shows the same list in its About window and ships the full license texts in `Schnellbild.app/Contents/Resources/Licenses`.

## In the app

| Component | Used for | License |
|---|---|---|
| [VLCKit](https://code.videolan.org/videolan/VLCKit) 3.7.5 (libVLC 3.0.24), © VideoLAN and the VLC authors | Playing the video formats macOS can't (AVI, MKV, WebM …) | [GNU LGPL 2.1](Resources/Licenses/VLCKit-LGPL-2.1.txt) or later |
| [UnRAR](https://www.rarlab.com/rar_add.htm) 7.2.7, © Alexander Roshal | Reading RAR archives | [UnRAR license](Resources/Licenses/UnRAR-license.txt) |
| [libarchive](https://www.libarchive.org), © Tim Kientzle and contributors | Reading ZIP and 7z archives | BSD 2-clause; the copy built into macOS, not shipped with the app |

**VLCKit** is built by us from VideoLAN's source, without VLC's modules under the GPL, so every part of it is under the GNU LGPL 2.1 or later: VLCKit 3.7.5 (tag `3.7.5`, commit `a213fd11`) with libVLC 3.0.24 (commit `6de05adc`), built with VideoLAN's own build script for Apple silicon, with one change: VLC's eight modules under the GPL are left out (the Dolby Surround decoder, mono downmix, the dummy interface, syslog logging, the RTSP video-on-demand server, stream output cycle and RTP, the rotate filter; Schnellbild uses none of them). How it is built: `Scripts/build_vlckit_lgpl.sh`; the build is published as a pre-release of this repository, and `Scripts/fetch_vlckit.sh` checks its SHA-256. It is embedded as its own framework in `Contents/Frameworks` and linked dynamically. The same VLCKit is in the DMG and in the Mac App Store version.

- **Source code:** VLCKit 3.7.5 at <https://code.videolan.org/videolan/VLCKit> (tag `3.7.5`), VLC at <https://code.videolan.org/videolan/vlc> (commit `6de05adc`), and our build script in this repository. On request we send a copy of exactly this source, for no more than the cost of sending it; write to us via the issues of this repository. This offer is valid for three years from each release of the app.
- **Replacing VLCKit:** the app's complete source is in this repository. Put the modified `VLCKit.xcframework` into `Vendor/` and run `SCHNELLBILD_OWN_VLCKIT=1 Scripts/build_app.sh`: with that variable the build uses the framework found there as it is, so the app can be rebuilt and run with a modified VLCKit. The Mac App Store version's license agreement allows changing VLCKit for your own use and reverse engineering to debug such changes, as the LGPL asks.

**UnRAR** is compiled from the official source (`Scripts/fetch_unrar.sh` checks its SHA-256) with one change: its error state (`ErrHandler` in `global.hpp`) is kept per thread (`thread_local`), so archives read at the same time don't see each other's errors; `Native/CArchives/rar_shim.cpp` is Schnellbild's own code around it. From its license: *UnRAR source code may be used in any software to handle RAR archives without limitations free of charge, but cannot be used to develop RAR (WinRAR) compatible archiver and to re-create RAR compression algorithm, which is proprietary.*

## No warranty

The components are provided by their authors "as is", without warranty of any kind; see their licenses for the exact terms. The same holds for Schnellbild itself (see [LICENSE](LICENSE)).

## Only for building and testing (not in the app)

| Component | Used for | License |
|---|---|---|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 | Generating the Xcode project for the UI tests | MIT |
| [dmgbuild](https://github.com/dmgbuild/dmgbuild) 1.6.7, [ds_store](https://github.com/al45tair/ds_store) 1.3.3, [mac_alias](https://github.com/al45tair/mac_alias) 2.2.3 | Making the DMG | MIT |
| Test archives from [rarfile](https://github.com/markokr/rarfile) | Unit tests of RAR reading | ISC ([text](Tests/SchnellbildTests/Archives/LICENSE-rarfile.txt)) |
| Test archives from [libarchive](https://github.com/libarchive/libarchive) 3.7.4 | Unit tests of 7z reading | BSD 2-clause |
| [RAR](https://www.rarlab.com) 7.23 for macOS (trial), © Alexander Roshal | Making the RAR test archives in `UITests/Fixtures/rar` once (see its README); not used by the build | RAR license (the archives it made are plain data) |
