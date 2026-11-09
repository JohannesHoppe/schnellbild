# Third-party notices

Schnellbild itself is under the MIT License (see [LICENSE](LICENSE)). It is built with the components below. The app shows the same list in its About window, and ships the full license texts in `Schnellbild.app/Contents/Resources/Licenses`.

## In the app

| Component | Used for | License |
|---|---|---|
| [VLCKit](https://code.videolan.org/videolan/VLCKit) 3.6.0 (libVLC), © VideoLAN and the VLC authors | Playing the video formats macOS can't (AVI, MKV, WebM …) | [GNU LGPL 2.1](Resources/Licenses/VLCKit-LGPL-2.1.txt) or later |
| [UnRAR](https://www.rarlab.com/rar_add.htm) 7.3.2, © Alexander Roshal | Reading RAR archives | [UnRAR license](Resources/Licenses/UnRAR-license.txt) |
| [libarchive](https://www.libarchive.org), © Tim Kientzle and contributors | Reading ZIP and 7z archives | BSD 2-clause; the copy built into macOS, not shipped with the app |

**VLCKit** is the official binary from VideoLAN (`Scripts/fetch_vlckit.sh` checks its SHA-256), embedded unmodified as its own framework in `Contents/Frameworks` and loaded dynamically, so it can be replaced by another build of the same version. Its source is at the link above.

**UnRAR** is compiled from the unmodified official source (`Scripts/fetch_unrar.sh` checks its SHA-256); `Native/CArchives/rar_shim.cpp` is Schnellbild's own code around it. From its license: *UnRAR source code may be used in any software to handle RAR archives without limitations free of charge, but cannot be used to develop RAR (WinRAR) compatible archiver and to re-create RAR compression algorithm, which is proprietary.*

## Only for building and testing (not in the app)

| Component | Used for | License |
|---|---|---|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 | Generating the Xcode project for the UI tests | MIT |
| [dmgbuild](https://github.com/dmgbuild/dmgbuild) 1.6.7, [ds_store](https://github.com/al45tair/ds_store) 1.3.3, [mac_alias](https://github.com/al45tair/mac_alias) 2.2.3 | Making the DMG | MIT |
| Test archives from [rarfile](https://github.com/markokr/rarfile) | Unit tests of RAR reading | ISC ([text](Tests/SchnellbildTests/Archives/LICENSE-rarfile.txt)) |
| Test archives from [libarchive](https://github.com/libarchive/libarchive) 3.7.4 | Unit tests of 7z reading | BSD 2-clause |
