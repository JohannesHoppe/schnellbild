"""Tests of the checks that keep GPL code out of VLCKit
(Scripts/vlckit_licenses.py, Scripts/vlckit_contrib.py), on made-up symbol
tables and sources shaped like the real ones.

    python3 -I -m unittest discover -s Scripts/tests
"""
import importlib.util
import os
import tempfile
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


licenses = load("vlckit_licenses")
contrib = load("vlckit_contrib")

GPL2_HEADER = """/*
 *  libzvbi - Teletext packet decoder, packet 8/30
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License version 2 as
 *  published by the Free Software Foundation.
 */
"""
LGPL_HEADER = """/*
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 */
"""
DUAL_HEADER = """/*
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * ...
 * ALTERNATIVELY, this product may be distributed under the terms of
 * the GNU General Public License, in which case the provisions of the GPL are
 * required INSTEAD OF the above restrictions.
 */
"""


class GPLSymbols(unittest.TestCase):
    """vlckit_licenses.py --no-gpl: the symbols of GPL code in the binary."""

    def test_zvbi_and_ffmpegs_gpl_files_are_found(self):
        nm = """0000000000099874 T _vbi_decode_vps_pdc
00000000015656c4 T _vbi_decode_teletext_8302_pdc
0000000001378284 t _vlc_entry__codec_libzvbi
0000000000a19aa0 T _ff_ac3_exponent_min_neon
00000000007bfd60 t _ff_crc32_aarch64
0000000000a19aa0 T _ff_h264_idct_add_neon""".splitlines()
        found = licenses.gpl_symbols(nm)
        self.assertEqual(sorted(found["libzvbi"]),
                         ["_vbi_decode_teletext_8302_pdc", "_vbi_decode_vps_pdc", "_vlc_entry__codec_libzvbi"])
        # Whole names count also when the linker made them local
        self.assertEqual(sorted(found["FFmpeg (GPL files)"]), ["_ff_ac3_exponent_min_neon", "_ff_crc32_aarch64"])

    def test_local_names_that_only_look_like_a_gpl_librarys_api_are_not(self):
        nm = """0000000001a5e8d0 s _mpeg2_class
0000000000b6d060 t _dca_parse
0000000000b5b7b8 T _avpriv_dca_convert_bitstream
0000000000000000 U _vbi_decode_vps_pdc""".splitlines()
        self.assertEqual(licenses.gpl_symbols(nm), {})

    def test_an_external_mpeg2_or_x264_function_is_found(self):
        found = licenses.gpl_symbols(["0000 T _mpeg2_init", "0000 T _x264_encoder_open_164"])
        self.assertEqual(set(found), {"libmpeg2", "x264"})


class Headers(unittest.TestCase):
    """vlckit_contrib.states_gpl: a source file's licence header."""

    def test_gpl_alone(self):
        self.assertTrue(contrib.states_gpl(GPL2_HEADER))
        self.assertTrue(contrib.states_gpl("// SPDX-License-Identifier: GPL-2.0-or-later\n"))
        self.assertTrue(contrib.states_gpl("/* SPDX-License-Identifier: AGPL-3.0-only */\n"))
        self.assertTrue(contrib.states_gpl("under the terms of the GNU Affero General Public License"))

    def test_lgpl_permissive_and_dual(self):
        self.assertFalse(contrib.states_gpl(LGPL_HEADER))
        self.assertFalse(contrib.states_gpl("under the terms of the GNU Library General Public License"))
        self.assertFalse(contrib.states_gpl(DUAL_HEADER))
        self.assertFalse(contrib.states_gpl("// SPDX-License-Identifier: LGPL-2.1-or-later\n"))
        self.assertFalse(contrib.states_gpl("/* SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0 */\n"))
        self.assertFalse(contrib.states_gpl("// SPDX-License-Identifier: MIT\n"))
        self.assertFalse(contrib.states_gpl("/* Copyright (c) 2016, Alliance for Open Media. */\n"))


class Members(unittest.TestCase):
    def test_archive_members_keep_two_of_one_name_apart(self):
        nm = """
/x/lib/libavutil.a(crc.o):
0000000000000000 T _av_crc
0000000000000000 U _memcpy

/x/lib/libavutil.a(crc.o):
0000000000000000 T _ff_crc32_aarch64
"""
        self.assertEqual(contrib.archive_members(nm), [("crc.o", ["_av_crc"]), ("crc.o", ["_ff_crc32_aarch64"])])

    def test_the_names_an_object_can_come_from(self):
        self.assertEqual(contrib.member_stems("packet-830.o")[0], "packet-830")
        self.assertIn("packet-830", contrib.member_stems("libzvbi_la-packet-830.o"))
        self.assertEqual(contrib.member_stems("arena.cc.o")[0], "arena")
        self.assertIn("cdef_tmpl", contrib.member_stems("src_cdef_tmpl.c.o"))


class Contrib(unittest.TestCase):
    """vlckit_contrib.check and write_licences on a contrib tree made here."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = self.temp.name
        self.vlc = os.path.join(root, "vlc")
        self.build = os.path.join(self.vlc, "contrib", "contrib-aarch64")
        self.lib = os.path.join(self.vlc, "contrib", "aarch64-apple-darwin", "lib")
        os.makedirs(self.lib)

        def write(path, text):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
        self.write = write
        # FFmpeg: two crc.o, one LGPL C, one GPL assembly
        write(os.path.join(self.vlc, "contrib", "src", "ffmpeg", "rules.mak"), ".ffmpeg: ffmpeg\n")
        ffmpeg = os.path.join(self.build, "ffmpeg")
        write(os.path.join(ffmpeg, "COPYING.LGPLv2.1"), "GNU LESSER GENERAL PUBLIC LICENSE\n")
        write(os.path.join(ffmpeg, "libavutil", "crc.c"), LGPL_HEADER + "uint32_t av_crc(void) {}\n")
        write(os.path.join(ffmpeg, "libavutil", "aarch64", "crc.S"),
              GPL2_HEADER + "function ff_crc32_aarch64, export=1\n")
        # FreeType: its folder named otherwise than its package, its licence in docs
        write(os.path.join(self.vlc, "contrib", "src", "freetype2", "rules.mak"),
              "freetype: freetype-2.14.tar.xz .sum-freetype2\n.freetype2: freetype crossfile.meson\n")
        freetype = os.path.join(self.build, "freetype")
        write(os.path.join(freetype, "LICENSE.TXT"), "FREETYPE LICENSES\n")
        for extra in contrib.EXTRA_LICENCE_FILES["freetype2"]:
            write(os.path.join(freetype, extra), "The FreeType Project LICENSE\n")
        write(os.path.join(freetype, "include", "freetype", "freetype.h"), "/*\n * Copyright (C) 1996-2026 by\n */\n")
        write(os.path.join(freetype, "src", "base", "ftinit.c"), "/* FreeType Project License */\nvoid FT_Init_FreeType(void) {}\n")
        for name in ("libavutil.a", "libfreetype.a"):
            write(os.path.join(self.lib, name), "")
        self.nm = {
            "libavutil.a": "\n/l/libavutil.a(crc.o):\n0 T _av_crc\n\n/l/libavutil.a(crc.o):\n0 T _ff_crc32_aarch64\n",
            "libfreetype.a": "\n/l/libfreetype.a(src_base_ftinit.c.o):\n0 T _FT_Init_FreeType\n",
            "libzvbi.a": "\n/l/libzvbi.a(packet-830.o):\n0 T _vbi_decode_vps_pdc\n",
            "libnew.a": "\n/l/libnew.a(new.o):\n0 T _new_function\n",
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_check(self, binary, names=("libavutil.a", "libfreetype.a")):
        libraries = [os.path.join(self.lib, n) for n in names]
        return contrib.check(self.vlc, set(binary), libraries, self.build,
                             nm_archive=lambda path: self.nm[os.path.basename(path)])

    def test_a_linked_object_from_a_gpl_source_fails(self):
        problems, packages, _ = self.run_check({"_av_crc", "_ff_crc32_aarch64", "_FT_Init_FreeType"})
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("libavutil.a(crc.o)", problems[0])
        self.assertIn("libavutil/aarch64/crc.S states the GPL", problems[0])
        self.assertEqual(dict(packages), {"ffmpeg": ["libavutil.a"], "freetype2": ["libfreetype.a"]})

    def test_a_gpl_object_not_in_the_binary_passes(self):
        problems, _, report = self.run_check({"_av_crc", "_FT_Init_FreeType"})
        self.assertEqual(problems, [])
        self.assertIn("libavutil.a(crc.o) ffmpeg/libavutil/crc.c", report)
        self.assertIn("libfreetype.a(src_base_ftinit.c.o) freetype2/src/base/ftinit.c", report)

    def test_zvbi_and_an_unknown_library_fail(self):
        problems, _, _ = self.run_check({"_vbi_decode_vps_pdc", "_new_function"}, names=("libzvbi.a", "libnew.a"))
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any(p.startswith("libzvbi.a: never to be linked") for p in problems))
        self.assertTrue(any(p.startswith("libnew.a: not one of LIBRARIES") for p in problems))

    def test_an_object_whose_source_isnt_there_fails(self):
        self.nm["libfreetype.a"] = "\n/l/libfreetype.a(ftgone.o):\n0 T _FT_Gone\n"
        problems, _, _ = self.run_check({"_FT_Gone"}, names=("libfreetype.a",))
        self.assertEqual(len(problems), 1)
        self.assertIn("its source not found", problems[0])

    def test_the_licences_have_a_section_per_library_with_its_texts(self):
        out = os.path.join(self.temp.name, "licences.txt")
        packages = {"ffmpeg": ["libavutil.a"], "freetype2": ["libfreetype.a"]}
        missing = contrib.write_licences(out, self.vlc, self.build, packages, ["libavutil.a", "libfreetype.a"])
        self.assertEqual(missing, [])
        with open(out) as f:
            text = f.read()
        self.assertTrue(text.startswith("Third-party libraries in VLCKit"))
        self.assertIn("  libfreetype.a (freetype2)\n", text)
        rule = "=" * 80
        self.assertIn(f"{rule}\nffmpeg\n{rule}\n--- COPYING.LGPLv2.1\nGNU LESSER", text)
        # The credit the FreeType License asks for, with the version's year
        self.assertIn(f"{rule}\nfreetype2\n{rule}\nPortions of this software are copyright © 2026 The FreeType Project"
                      " (https://freetype.org). All rights reserved.\n\n--- LICENSE.TXT\n", text)
        self.assertIn("--- docs/FTL.TXT\nThe FreeType Project LICENSE", text)

    def test_a_library_without_a_licence_file_is_reported(self):
        os.remove(os.path.join(self.build, "freetype", "docs", "FTL.TXT"))
        os.remove(os.path.join(self.build, "ffmpeg", "COPYING.LGPLv2.1"))
        out = os.path.join(self.temp.name, "licences.txt")
        missing = contrib.write_licences(out, self.vlc, self.build,
                                         {"ffmpeg": ["libavutil.a"], "freetype2": ["libfreetype.a"]},
                                         ["libavutil.a", "libfreetype.a"])
        self.assertEqual(missing, ["ffmpeg", "freetype2"])


class Audit(unittest.TestCase):
    def test_no_library_is_both_audited_and_forbidden(self):
        self.assertEqual(set(contrib.LIBRARIES) & set(contrib.FORBIDDEN), set())
        self.assertIn("libzvbi.a", contrib.FORBIDDEN)

    def test_teletext_stays_through_vlcs_own_decoder(self):
        self.assertIn("codec_telx", licenses.REQUIRED)


if __name__ == "__main__":
    unittest.main()
