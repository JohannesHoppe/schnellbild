#!/usr/bin/env python3
"""Wraps one H.264 picture (an Annex B stream of SPS, PPS and an IDR slice,
as ffmpeg writes it with -f h264) into an AVC HEIF still, ".avci"
(ISO/IEC 23008-12 HEIF; ISO/IEC 14496-15 for the avcC box), for the
visual check (Scripts/make_video_fixtures.sh visual; ffmpeg writes no
HEIF). The file: ftyp (avci, mif1), meta (hdlr pict, pitm, iloc, iinf with
one 'avc1' item, iprp: avcC, ispe, colr nclx BT.709 / sRGB / limited), mdat
(the slice's NAL units, each after its 4-byte length).

    make_avci.py <in.h264> <out.avci> <width> <height>
"""
import struct
import sys


def box(kind, payload):
    return struct.pack(">I", 8 + len(payload)) + kind + payload


def full_box(kind, version, flags, payload):
    return box(kind, struct.pack(">I", version << 24 | flags) + payload)


def nal_units(stream):
    """The NAL units of an Annex B stream, without their start codes."""
    units, at = [], 0
    starts = []
    while True:
        found = stream.find(b"\x00\x00\x01", at)
        if found < 0:
            break
        starts.append(found + 3)
        at = found + 3
    for i, start in enumerate(starts):
        end = starts[i + 1] - 3 if i + 1 < len(starts) else len(stream)
        unit = stream[start:end]
        # A four-byte start code leaves a zero at the end of the unit before it
        while i + 1 < len(starts) and unit.endswith(b"\x00"):
            unit = unit[:-1]
        units.append(unit)
    return units


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    source, target = sys.argv[1], sys.argv[2]
    width, height = int(sys.argv[3]), int(sys.argv[4])
    with open(source, "rb") as f:
        units = nal_units(f.read())
    sps = [u for u in units if u[0] & 0x1F == 7]
    pps = [u for u in units if u[0] & 0x1F == 8]
    slices = [u for u in units if u[0] & 0x1F in (1, 5)]
    if len(sps) != 1 or len(pps) != 1 or not slices or slices[0][0] & 0x1F != 5:
        sys.exit("expected one SPS, one PPS and an IDR picture")
    sps, pps = sps[0], pps[0]
    data = b"".join(struct.pack(">I", len(u)) + u for u in slices)

    avcc = box(b"avcC", bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]) + struct.pack(">H", len(sps)) + sps
               + bytes([1]) + struct.pack(">H", len(pps)) + pps)
    ispe = full_box(b"ispe", 0, 0, struct.pack(">II", width, height))
    # nclx: BT.709 primaries, sRGB transfer, BT.709 matrix, limited range
    colr = box(b"colr", b"nclx" + struct.pack(">HHHB", 1, 13, 1, 0))
    ipco = box(b"ipco", avcc + ispe + colr)
    # item 1: avcC essential, ispe, colr
    ipma = full_box(b"ipma", 0, 0, struct.pack(">IHB", 1, 1, 3) + bytes([0x81, 0x02, 0x03]))
    iprp = box(b"iprp", ipco + ipma)
    hdlr = full_box(b"hdlr", 0, 0, struct.pack(">I", 0) + b"pict" + bytes(12) + b"\x00")
    pitm = full_box(b"pitm", 0, 0, struct.pack(">H", 1))
    infe = full_box(b"infe", 2, 0, struct.pack(">HH", 1, 0) + b"avc1" + b"\x00")
    iinf = full_box(b"iinf", 0, 0, struct.pack(">H", 1) + infe)
    ftyp = box(b"ftyp", b"avci" + struct.pack(">I", 0) + b"avcimif1miaf")

    def meta(offset):
        # iloc v0: offset and length 4 bytes, no base offset; one extent
        iloc = full_box(b"iloc", 0, 0, bytes([0x44, 0x00]) + struct.pack(">HHHHII", 1, 1, 0, 1, offset, len(data)))
        return full_box(b"meta", 0, 0, hdlr + pitm + iloc + iinf + iprp)

    offset = len(ftyp) + len(meta(0)) + 8
    with open(target, "wb") as f:
        f.write(ftyp + meta(offset) + box(b"mdat", data))


if __name__ == "__main__":
    main()
