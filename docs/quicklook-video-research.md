# What QuickLook Video teaches about Media Extensions

[QuickLook Video](https://github.com/Marginal/QuickLookVideo) by Jonathan Harris (GPL-2.0, since 2014, nearly all commits by its author) teaches macOS non-native video formats with Media Extensions since its version 3. Schnellbild is MIT: its code is studied here, not copied. Read in November 2026 at commit `e35feff`; issue and commit links point to that repository.

## How it is built

- **No VLC.** FFmpeg used as a library (libavformat, libavcodec), dav1d for AV1, zimg for colour conversion, each a git submodule built by `scripts/build*` into shared dylibs (`-fapplication-extension`).
- **FFmpeg cut down:** `--disable-network --disable-protocols --disable-muxers --disable-encoders --disable-filters --disable-bsfs --disable-avdevice --disable-autodetect`, then only what it needs enabled again (the file and pipe protocols, a PNG encoder, a few filters and muxers, VideoToolbox, AudioToolbox). It builds with `--enable-gpl`; in FFmpeg's configure that flag adds only a handful of obscure ADPCM decoders for this set, so the same build without it would be LGPL-2.1+ (dav1d is BSD-2-Clause, zimg WTFPL).
- **Parts of the app:** a format reader ("QLVideo Formats": FFmpeg demuxes through an AVIO context over `MEByteSource`), a video decoder ("QLVideo Codecs": FFmpeg or dav1d into `CVPixelBuffer`), a Spotlight importer (also FFmpeg), a contact-sheet service, a debug player that isn't shipped. No XPC of its own; the parts share an app group whose preferences, in the author's words, don't work in practice on macOS 26 (`formatreader/formatreader.swift:67`).
- **Codec routing** (`formatreader/videotrackreader.swift:20-31`): what VideoToolbox decodes and has a valid sample description goes to Apple; MPEG-1/2/4, VP8, VP9, AV1 and others get FourCCs its own decoder registers ("FFmpeg is more tolerant of poor encoding than CoreVideo"). The decoder also registers real FourCCs found in .avi/.mov that the reader never sees.
- **Distribution:** Mac App Store, GitHub releases, Homebrew cask. 3.x needs macOS 26 for thumbnails; 2.x (old Quick Look extensions) is kept for older systems.
- **Testing:** no CI, one unit test (`tests/tests.swift`: the reader is released and gone after reading, through a mock byte source because `MEByteSource` can't be made in a test).

## What makes thumbnails work

- The asking app must opt in: `MTRegisterProfessionalVideoWorkflowFormatReaders()` and `VTRegisterProfessionalVideoWorkflowVideoDecoders()` (its own app does so, `app/AppDelegate.swift:76-77`; Finder does; ForkLift from 4.7, Bloom from 1.5.36): [#191](https://github.com/Marginal/QuickLookVideo/issues/191), [#197](https://github.com/Marginal/QuickLookVideo/issues/197). Seen on Schnellbild's CI: with the opt-in, Quick Look made MKV and WebM thumbnails through its extensions on macOS 26, none on macOS 15.
- The user turns the extensions on in System Settings; its app checks it with a bundled WebM (`isPlayable`, then a thumbnail) because "No way to tell directly whether MediaExtensions are enabled", and opens that settings page when they are off.
- "Refresh": `qlmanage -r cache`, end `AudiovisualThumbnailExtension`, its extensions and Finder ([107f713](https://github.com/Marginal/QuickLookVideo/commit/107f71307f96e0b14e37edaad3f4f76231c7dcea)); the thumbnailer sometimes sees the extensions but doesn't use them, "a bug in macOS": [#172](https://github.com/Marginal/QuickLookVideo/issues/172), [#173](https://github.com/Marginal/QuickLookVideo/issues/173).
- VideoToolbox hardware decoding is required, else its decoder isn't loaded: `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)` ([0835ef7](https://github.com/Marginal/QuickLookVideo/commit/0835ef7)).
- Exported types conform to `public.movie`, not `com.apple.mediaextension-content`, and the reader lists other apps' identifiers for the same formats too (IINA, VLC, Infuse …), since a file's type depends on which app declared it (`formatreader/Info.plist`).
- Quick Look takes its thumbnail at 10 s; the reader turns that seek into a quarter of the length, with a further workaround for macOS 26.4 (`formatreader/packetdemuxer.swift:30`, [9308374](https://github.com/Marginal/QuickLookVideo/commit/9308374)).
- Cover art becomes the thumbnail; without any, the reader renders a frame and hands it over as PNG artwork (`formatreader/formatreader.swift:234-265`).
- A video-only AVI is read by AVFoundation itself, so only a decoder for its FourCC helps: [#203](https://github.com/Marginal/QuickLookVideo/issues/203).

## Pitfalls that apply to Schnellbild too

- **Files kept open, drives that can't be ejected:** retain cycles, then a deadlock when the reader's last reference went away on its own demux thread and its cleanup waited for that thread ([#188](https://github.com/Marginal/QuickLookVideo/issues/188), [#214](https://github.com/Marginal/QuickLookVideo/issues/214); `formatreader/packetdemuxer.swift:296-300`). Rule for any worker thread (also `VLCFrameGrab`): never wait for a thread from a cleanup that may run on that thread.
- **Memory growing to many GB** from the same cause ([#190](https://github.com/Marginal/QuickLookVideo/issues/190)).
- **Subtitles:** a text track from the reader made AVFoundation refuse files, later it was too slow; switched off ([#181](https://github.com/Marginal/QuickLookVideo/issues/181)).
- **Why the old Quick Look extensions went:** files locked for minutes, slow and blurry thumbnails, a thumbnailer stuck at 300 % CPU ([#108](https://github.com/Marginal/QuickLookVideo/issues/108), [#112](https://github.com/Marginal/QuickLookVideo/issues/112), [#137](https://github.com/Marginal/QuickLookVideo/issues/137)).

## For Schnellbild

- An LGPL-only FFmpeg built like the above (no network, no protocols but files, no encoders but PNG), as dylibs, carries the same obligations as VLCKit today with a far smaller attack surface; it would also play through AVKit everywhere, but only where the user has turned the extensions on.
- Thumbnails through it: macOS 26 only, the app must opt in; macOS 15 keeps Schnellbild's own Quick Look extension.
