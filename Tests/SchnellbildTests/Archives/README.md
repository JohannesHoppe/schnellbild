# Archive fixtures

- `*.rar`, `rar3-old.r00`, `rar3-old.r01`: from the test suite of [rarfile](https://github.com/markokr/rarfile) (`test/files`, commit d2f7df6), ISC license, see `LICENSE-rarfile.txt`. The protected ones use the password `password`.
- `deflate.7z`, `lzma2.7z`, `encrypted.7z`: from the test suite of [libarchive](https://github.com/libarchive/libarchive) 3.7.4 (`test_read_format_7zip_deflate.7z.uu`, `test_read_format_7zip_lzma2.7z.uu`, `test_read_format_7zip_encryption.7z.uu`, uudecoded), BSD 2-clause license.

ZIP archives are made by the tests themselves with `/usr/bin/zip`.
