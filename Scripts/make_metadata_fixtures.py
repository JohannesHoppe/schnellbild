#!/usr/bin/env python3
"""Writes the fixtures of MetadataSourceTests into the folder given
(Tests/SchnellbildTests/Metadata): tiny MP4 / QuickTime files built box by box
(a GoPro GPMF track with GPS5, one with GPS9, Android's ©xyz, XMP in a uuid box
and in udta/XMP_), DJI flight logs in each known form, a Sony clip XML, XMP
sidecars and a GPX track. Every place is a public landmark or a road between
them, every time made up; no camera, phone or person took part. Standard
library only, the same bytes on every run:

    python3 -I Scripts/make_metadata_fixtures.py Tests/SchnellbildTests/Metadata
"""
import calendar
import os
import struct
import sys


def box(kind, *payload):
    data = b"".join(payload)
    return struct.pack(">I", 8 + len(data)) + kind + data


def full(version, flags=0):
    return struct.pack(">I", (version << 24) | flags)


MAC_EPOCH = 2082844800  # seconds from 1904-01-01 to 1970-01-01


def utc(year, month, day, hour, minute, second):
    return calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))


def mvhd(created):
    seconds = created + MAC_EPOCH
    return box(b"mvhd", full(0), struct.pack(">IIII", seconds, seconds, 1000, 0), b"\0" * 80)


def ftyp(brand=b"mp41"):
    return box(b"ftyp", brand, struct.pack(">I", 0), brand, b"isom")


# MARK: GPMF


def klv(key, kind, size, values_bytes, repeat):
    data = values_bytes
    pad = (-len(data)) % 4
    return key + struct.pack(">cBH", kind, size, repeat) + data + b"\0" * pad


def nest(key, *children):
    data = b"".join(children)
    return key + struct.pack(">cBH", b"\0", 4, len(data) // 4) + data


def gps5_payload(points, fix, utc_text, dop):
    scal = struct.pack(">5l", 10000000, 10000000, 1000, 1000, 100)
    samples = b"".join(struct.pack(">5l", round(lat * 1e7), round(lon * 1e7), round(alt * 1000), 1500, 1600)
                       for lat, lon, alt in points)
    stream = nest(b"STRM",
                  klv(b"STNM", b"c", 1, b"GPS (Lat., Long., Alt., 2D speed, 3D speed)", 44),
                  klv(b"GPSF", b"L", 4, struct.pack(">I", fix), 1),
                  klv(b"GPSU", b"U", 16, utc_text.encode(), 1),
                  klv(b"GPSP", b"S", 2, struct.pack(">H", dop), 1),
                  klv(b"SCAL", b"l", 4, scal, 5),
                  klv(b"GPS5", b"l", 20, samples, len(points)))
    accl = nest(b"STRM", klv(b"SCAL", b"s", 2, struct.pack(">h", 418), 1),
                klv(b"ACCL", b"s", 6, struct.pack(">3h", 4418, -628, -571) * 2, 2))
    return nest(b"DEVC", klv(b"DVID", b"L", 4, struct.pack(">I", 1), 1),
                klv(b"DVNM", b"c", 1, b"Camera", 6), accl, stream)


def gps9_payload(points, days, seconds, fix):
    scal = struct.pack(">9l", 10000000, 10000000, 1000, 1000, 100, 1, 1000, 100, 1)
    samples = b"".join(struct.pack(">7l2H", round(lat * 1e7), round(lon * 1e7), round(alt * 1000), 900, 950,
                                   days, round((seconds + i * 0.1) * 1000), 120, fix)
                       for i, (lat, lon, alt) in enumerate(points))
    stream = nest(b"STRM",
                  klv(b"STNM", b"c", 1, b"GPS (Lat., Long., Alt., 2D, 3D, days, secs, DOP, fix)", 54),
                  klv(b"SCAL", b"l", 4, scal, 9),
                  klv(b"TYPE", b"c", 1, b"lllllllSS", 9),
                  klv(b"GPS9", b"?", 32, samples, len(points)))
    return nest(b"DEVC", klv(b"DVID", b"L", 4, struct.pack(">I", 1), 1), stream)


def telemetry_movie(payloads, created, chunked=False):
    """ftyp, mdat with the payloads, moov with a GoPro-style 'meta' track."""
    head = ftyp()
    mdat_start = len(head) + 8
    offsets, at = [], mdat_start
    for p in payloads:
        offsets.append(at)
        at += len(p)
    mdat = box(b"mdat", *payloads)
    count = len(payloads)
    if chunked:  # two samples per chunk, one chunk of one at the end when odd
        chunks = offsets[::2]
        stsc_entries = [(1, 2, 1)] + ([(len(chunks), 1, 1)] if count % 2 else [])
    else:
        chunks = offsets
        stsc_entries = [(1, 1, 1)]
    stbl = box(b"stbl",
               box(b"stsd", full(0), struct.pack(">I", 1), box(b"gpmd", b"\0" * 6, struct.pack(">H", 1))),
               box(b"stts", full(0), struct.pack(">III", 1, count, 1001)),
               box(b"stsc", full(0), struct.pack(">I", len(stsc_entries)),
                   *[struct.pack(">III", *e) for e in stsc_entries]),
               box(b"stsz", full(0), struct.pack(">II", 0, count), *[struct.pack(">I", len(p)) for p in payloads]),
               box(b"stco", full(0), struct.pack(">I", len(chunks)), *[struct.pack(">I", o) for o in chunks]))
    track = box(b"trak",
                box(b"tkhd", full(0, 1), b"\0" * 80),
                box(b"mdia",
                    box(b"mdhd", full(0), struct.pack(">IIII", 0, 0, 1000, 1001 * count), b"\0" * 4),
                    box(b"hdlr", full(0), b"mhlr", b"meta", b"\0" * 12, b"GoPro MET\0"),
                    box(b"minf", box(b"gmhd", box(b"gpmd", b"\0" * 8)), stbl)))
    return head + mdat + box(b"moov", mvhd(created), track)


def route(start, step, count, alt=12.0):
    lat, lon = start
    return [(lat + step[0] * i, lon + step[1] * i, alt + i * 0.5) for i in range(count)]


XMP_PACKET = """<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:exif="http://ns.adobe.com/exif/1.0/"
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    exif:GPSLatitude="{lat}"
    exif:GPSLongitude="{lon}"
    exif:GPSAltitude="{alt}"
    exif:GPSAltitudeRef="0"
    exif:DateTimeOriginal="{taken}"
    xmp:CreateDate="2001-01-01T00:00:00Z"/>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"""


def main(folder):
    os.makedirs(folder, exist_ok=True)

    def write(name, data):
        with open(os.path.join(folder, name), "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))

    # GoPro, GPS5: two payloads without a lock, then a walk north-east from
    # the Geirangerfjord's ferry quay; the movie header's clock is two hours
    # ahead of UTC (cameras set to local time write that)
    payloads = []
    for i in range(10):
        points = route((62.1008 + i * 0.0002, 7.2059 + i * 0.0003), (0.00001, 0.000015), 18)
        fix = 0 if i < 2 else 3
        dop = 9999 if i < 2 else 180
        payloads.append(gps5_payload(points, fix, "2406011000%06.3f" % (i * 1.001), dop))
    write("gopro-gps5.mp4", telemetry_movie(payloads, utc(2024, 6, 1, 12, 0, 0)))
    write("gopro-chunked.mp4", telemetry_movie(payloads[:5], utc(2024, 6, 1, 12, 0, 0), chunked=True))

    # GoPro, GPS9 (HERO11 on): along the Champs-Élysées; 2025-07-01 09:30 UTC
    days = (utc(2025, 7, 1, 0, 0, 0) - utc(2000, 1, 1, 0, 0, 0)) // 86400
    payloads9 = [gps9_payload(route((48.8738 - i * 0.0004, 2.2950 + i * 0.0008), (-0.00002, 0.00004), 10, 35.0),
                              days, 9 * 3600 + 30 * 60 + i, 3) for i in range(6)]
    write("gopro-gps9.mp4", telemetry_movie(payloads9, utc(2025, 7, 1, 9, 30, 0)))

    # Android: moov/udta/©xyz at the Oslo Opera House
    xyz = b"+59.9075+010.7531/"
    write("android.mp4", ftyp() + box(b"moov", mvhd(utc(2023, 5, 4, 9, 8, 7)),
                                      box(b"udta", box(b"\xa9xyz", struct.pack(">HH", len(xyz), 0x15C7), xyz))))

    # XMP inside: the top-level uuid box (MP4), udta/XMP_ (QuickTime)
    uuid = bytes.fromhex("BE7ACFCB97A942E89C71999491E3AFAC")
    packet = XMP_PACKET.format(lat="41,24.1203N", lon="2,10.4097E", alt="1700/10", taken="2022-03-14T15:09:26+01:00")
    write("xmp-uuid.mp4", ftyp() + box(b"uuid", uuid, packet.encode()) + box(b"moov", mvhd(utc(2022, 3, 14, 14, 0, 0))))
    packet = XMP_PACKET.format(lat="35,39,31.2N", lon="139,42,3.6E", alt="40", taken="2021-11-02T08:15:00+09:00")
    write("xmp-udta.mov", ftyp(b"qt  ") + box(b"moov", mvhd(utc(2021, 11, 1, 23, 15, 0)),
                                              box(b"udta", box(b"XMP_", packet.encode()))))

    # A movie with nothing but its header, for the files beside it
    plain = ftyp() + box(b"moov", mvhd(utc(2020, 1, 2, 3, 4, 5)))
    write("plain.mp4", plain)

    # DJI flight logs, one per known form (Neuschwanstein, the Golden Gate, Uluru …)
    write("dji-phantom.SRT",
          "1\n00:00:01,000 --> 00:00:02,000\nHOME(10.7498,47.5576) 2018.07.03 10:15:03\n"
          "GPS(10.7498,47.5576,19) BAROMETER:20.1\nISO:100 Shutter:400 EV:-1/3 Fnum:F2.8 \n\n"
          "2\n00:00:02,000 --> 00:00:03,000\nHOME(10.7498,47.5576) 2018.07.03 10:15:04\n"
          "GPS(10.7502,47.5579,19) BAROMETER:20.6\nISO:100 Shutter:400 EV:-1/3 Fnum:F2.8 \n\n")
    write("dji-oldfirmware.SRT",
          "1\n00:00:01,000 --> 00:00:02,000\nHOME(-122.4783,37.8199) 2017.8.5 14:11:51\n"
          "GPS(-122.4783,37.8199,16) Hb:1.9 Hs:1.9\nISO:100 TV:60 EV: 0 IR:F2.8\n\n"
          "2\n00:00:02,000 --> 00:00:03,000\nHOME(-122.4783,37.8199) 2017.8.5 14:11:52\n"
          "GPS(-122.4785,37.8203,16) Hb:2.4 Hs:2.4\nISO:100 TV:60 EV: 0 IR:F2.8\n\n")
    write("dji-mini.SRT",
          "1\n00:00:00,000 --> 00:00:01,000\nF/2.8, SS 30.15, ISO 260, EV -1.7, GPS (131.0369, -25.3444, 17), "
          "D 221.21m, H 200.70m, H.S n/a, V.S n/a \n\n"
          "2\n00:00:01,000 --> 00:00:02,000\nF/2.8, SS 30.15, ISO 260, EV -1.7, GPS (131.0372, -25.3447, 17), "
          "D 221.18m, H 200.70m, H.S n/a, V.S n/a \n\n")
    write("dji-m300.SRT",
          "1\n00:00:00,000 --> 00:00:01,000\n2022.06.21 16:06:17\nGPS(36.5297,-6.2925,0.0M) BAROMETER:0.3M\n\n"
          "2\n00:00:01,000 --> 00:00:02,000\n2022.06.21 16:06:18\nGPS(36.5299,-6.2921,0.0M) BAROMETER:0.8M\n\n")
    write("dji-mavic2.SRT",
          "﻿1\n00:00:00,000 --> 00:00:00,040\n<font size=\"36\">FrameCnt : 1, DiffTime : 40ms\n"
          "2019-09-27 10:28:08,438,904\n[iso : 110] [shutter : 1/1250.0] [fnum : 280] [ev : 0] [ct : 5174] "
          "[color_md : default] [focal_len : 280] [latitude : 51.1789] [longtitude : -1.8262] </font>\n\n"
          "2\n00:00:00,040 --> 00:00:00,080\n<font size=\"36\">FrameCnt : 2, DiffTime : 40ms\n"
          "2019-09-27 10:28:08,478,931\n[iso : 110] [shutter : 1/1250.0] [fnum : 280] [ev : 0] [ct : 5174] "
          "[color_md : default] [focal_len : 280] [latitude : 51.1790] [longtitude : -1.8260] </font>\n\n")
    write("dji-air2s.SRT",
          "1\r\n00:00:00,000 --> 00:00:00,033\r\n<font size=\"36\">SrtCnt : 1, DiffTime : 33ms\r\n"
          "2022-08-07 13:40:40,774,808\r\n[iso : 100] [shutter : 1/80.0] [fnum : 280] [ev : 0] [ct : 5744] "
          "[color_md : default] [focal_len : 240] [latitude: 41.403600] [longitude: 2.174400] [altitude: 117.000000] </font>\r\n\r\n"
          "2\r\n00:00:00,033 --> 00:00:00,066\r\n<font size=\"36\">SrtCnt : 2, DiffTime : 33ms\r\n"
          "2022-08-07 13:40:40,808,164\r\n[iso : 100] [shutter : 1/80.0] [fnum : 280] [ev : 0] [ct : 5744] "
          "[color_md : default] [focal_len : 240] [latitude: 41.403700] [longitude: 2.174600] [altitude: 118.500000] </font>\r\n\r\n")
    write("dji-mavic3.SRT",
          "1\n00:00:00,000 --> 00:00:00,020\n<font size=\"28\">FrameCnt: 1, DiffTime: 20ms\n2021-12-25 12:27:52.373\n"
          "[iso: 220] [shutter: 1/8000.0] [fnum: 3.2] [ev: 0] [ct: 5115] [color_md : default] [focal_len: 24.00] "
          "[latitude: 27.1751] [longitude: 78.0421] [rel_alt: 2.400 abs_alt: 171.401] </font>\n\n"
          "2\n00:00:00,020 --> 00:00:00,040\n<font size=\"28\">FrameCnt: 2, DiffTime: 20ms\n2021-12-25 12:27:52.391\n"
          "[iso: 220] [shutter: 1/8000.0] [fnum: 3.2] [ev: 0] [ct: 5115] [color_md : default] [focal_len: 24.00] "
          "[latitude: 27.1753] [longitude: 78.0423] [rel_alt: 2.500 abs_alt: 171.501] </font>\n\n")
    write("dji-nofix.SRT",
          "1\n00:00:00,000 --> 00:00:00,033\n<font size=\"36\">SrtCnt : 1, DiffTime : 33ms\n2022-05-01 15:01:58,531,716\n"
          "[iso : 100] [shutter : 1/500.0] [fnum : 280] [ev : 0] [latitude: 0.000000] [longitude: 0.000000] [altitude: 0.000000] </font>\n\n")
    write("DJI_0001.MP4", plain)
    write("DJI_0001.SRT",
          "1\n00:00:00,000 --> 00:00:01,000\n2023.04.09 11:00:00\nGPS(52.5200,13.4050,0.0M) BAROMETER:30.0M\n\n"
          "2\n00:00:01,000 --> 00:00:02,000\n2023.04.09 11:00:01\nGPS(52.5205,13.4060,0.0M) BAROMETER:31.0M\n\n"
          "3\n00:00:02,000 --> 00:00:03,000\n2023.04.09 11:00:02\nGPS(52.5210,13.4070,0.0M) BAROMETER:32.0M\n\n")

    # Sony: a clip and its clip XML (the Kinkaku-ji, Kyoto)
    write("C0001.MP4", plain)
    write("C0001M01.XML", """<?xml version="1.0" encoding="UTF-8"?>
<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.00" xmlns:lib="urn:schemas-professionalDisc:lib:ver.2.00" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" lastUpdate="2024-11-30T10:08:55+09:00">
\t<Duration value="1395"/>
\t<CreationDate value="2024-11-30T10:08:55+09:00"/>
\t<Device manufacturer="Sony" modelName="ILCE-0000" serialNo="0"/>
\t<AcquisitionRecord>
\t\t<Group name="ExifGPS">
\t\t\t<Item name="VersionID" value="2.2.0.0"/>
\t\t\t<Item name="LatitudeRef" value="N"/>
\t\t\t<Item name="Latitude" value="35:2:21.600"/>
\t\t\t<Item name="LongitudeRef" value="E"/>
\t\t\t<Item name="Longitude" value="135:43:46.800"/>
\t\t\t<Item name="Status" value="A"/>
\t\t\t<Item name="MapDatum" value="WGS-84"/>
\t\t</Group>
\t</AcquisitionRecord>
</NonRealTimeMeta>
""")

    # XMP sidecars: Lightroom's attributes (name.xmp), darktable's elements (name.ext.xmp)
    write("lightroom.xmp", XMP_PACKET.format(lat="64,8.7576N", lon="21,56.1630W", alt="250/10",
                                             taken="2020-02-29T23:59:30.25-01:00"))
    write("darktable.xmp", """<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:e="http://ns.adobe.com/exif/1.0/" xmlns:darktable="http://darktable.sf.net/">
   <e:DateTimeOriginal>2019-08-10T06:30:00</e:DateTimeOriginal>
   <e:GPSLatitude>
    <rdf:Alt><rdf:li xml:lang="x-default">33,51,24.6S</rdf:li></rdf:Alt>
   </e:GPSLatitude>
   <e:GPSLongitude>151,12,54.0E</e:GPSLongitude>
   <e:GPSAltitude>5/1</e:GPSAltitude>
   <e:GPSAltitudeRef>1</e:GPSAltitudeRef>
   <e:GPSHPositioningError>12/2</e:GPSHPositioningError>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
""")

    # A GPX track: a walk through Bergen's Bryggen in two segments, a pause between
    points = []
    for i in range(30):
        points.append((60.3975 + i * 0.0001, 5.3240 + i * 0.0002, 5 + i, "2024-05-17T08:%02d:%02dZ" % (i // 6, (i % 6) * 10)))
    later = []
    for i in range(10):
        later.append((60.3950 - i * 0.0001, 5.3300, 3, "2024-05-17T09:%02d:00Z" % (30 + i)))

    def segment(pts):
        return "".join('      <trkpt lat="%.6f" lon="%.6f"><ele>%d</ele><time>%s</time></trkpt>\n' % p for p in pts)

    write("walk.gpx", """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="make_metadata_fixtures.py" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Bryggen</name>
    <trkseg>
""" + segment(points) + """    </trkseg>
    <trkseg>
""" + segment(later) + """    </trkseg>
  </trk>
</gpx>
""")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: make_metadata_fixtures.py <folder>")
    main(sys.argv[1])
