# RAR fixtures

Made with the official RAR 7.23 for macOS (rarlab.com, trial version) from Schnellbild's own fixtures: `beach.jpg` (= `dark.jpg`), `Day 1/sun.jpg` (= `bright.jpg`), `Day 1/big.jpg` (= `huge.jpg`), `clip.mp4`. The archives are plain data; RAR's license covers the program, not what it makes.

| File | Made with |
|---|---|
| `photos-rar5.rar` | `rar a -r` (RAR5, packed) |
| `photos-stored.rar` | `rar a -r -m0` (stored) |
| `photos-solid.rar` | `rar a -r -s` (solid) |
| `photos-psw.rar` | `rar a -r -psecret` (password `secret`) |
| `photos-hpsw.rar` | `rar a -r -hpsecret` (names encrypted too) |
| `photos-vols.part1.rar` … `part4` | `rar a -r -m0 -v120k` (volumes) |
| `photos-cut.rar.part` | the first 150 000 bytes of `photos-stored.rar` (a download in progress) |

RAR 7 makes RAR5 archives only; RAR4 is covered by the rarfile fixtures in `Tests/SchnellbildTests/Archives`.
