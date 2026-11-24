#!/usr/bin/env python3
"""Makes the screenshots' world trip: real photographs from Wikimedia Commons
under CC0 or in the public domain, taken at places around the Mediterranean
and beyond, so the Atlas view's globe shows photo pins spread over the Earth.

  python3 -I Scripts/build_world_photos.py

Each original is downloaded from Commons (checked against Commons' SHA-1),
reduced to 2048 pixels on its long side and given the place and time Commons
records for it (its GPS and DateTimeOriginal) by `swift Scripts/tag_photo.swift`
(ImageIO), into build/world-photos/ with LICENSES.txt: every photo's title,
author, licence and file page. They are published as the pre-release
RELEASE_TAG of this repository (never latest); Scripts/fetch_world_photos.sh
downloads them for the screenshots, checked against the SHA-256 pinned in
Scripts/world_photos.env. The photographs themselves stay as they were taken:
only their size and the place and time in their metadata are set.
"""

import hashlib
import os
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "build", "world-photos-cache")
OUT = os.path.join(ROOT, "build", "world-photos")
UA = "SchnellbildScreenshotFixtures/1.0 (https://github.com/JohannesHoppe/schnellbild)"

# (file name in the library, Commons title, original URL, Commons SHA-1, licence, author, latitude, longitude, taken (local))
PHOTOS = [
    ("Lisbon-Rossio.jpg", "File:Pérola do Rossio 03.jpg",
     "https://upload.wikimedia.org/wikipedia/commons/3/37/P%C3%A9rola_do_Rossio_03.jpg",
     "729d164d078c6cee96a584a277e4ee707991d0e4", "CC0 1.0", "DiogoBaptista", 38.713622, -9.138714, "2024:09:19 19:28:37"),
    ("Paris-Eiffel-Tower.jpg", "File:Eiffel Tower, Paris, France (Unsplash PM4VZZn-YyM).jpg",
     "https://upload.wikimedia.org/wikipedia/commons/e/e4/Eiffel_Tower%2C_Paris%2C_France_%28Unsplash_PM4VZZn-YyM%29.jpg",
     "6c1383c98d3e9493399b3c169e360440a88851e2", "CC0 1.0", "John Towner", 48.858370, 2.294481, "2016:08:22 12:00:00"),
    ("Rome-Colosseum.jpg", "File:Roman Colosseum (9809462534).jpg",
     "https://upload.wikimedia.org/wikipedia/commons/8/88/Roman_Colosseum_%289809462534%29.jpg",
     "92017b0ec5fa1ecb03da0e7d0fb1c76509687933", "CC0 1.0", "Gary Todd", 41.890222, 12.492270, "2000:06:10 01:00:00"),
    ("Athens-Parthenon.jpg", "File:Athens Acropolis Parthenon (28443572165).jpg",
     "https://upload.wikimedia.org/wikipedia/commons/9/9a/Athens_Acropolis_Parthenon_%2828443572165%29.jpg",
     "db8bf57d5c539a10cdd92a379b5bcf482cdd1cc0", "CC0 1.0", "Gary Todd", 37.971483, 23.726048, "2016:07:19 21:43:00"),
    ("Istanbul-Hagia-Sophia.jpg", "File:Hagia Sophia Istanbul 2013 9.jpg",
     "https://upload.wikimedia.org/wikipedia/commons/7/7c/Hagia_Sophia_Istanbul_2013_9.jpg",
     "f381ef1325c571ad9ba4b29bb96693c516230117", "Public domain", "Karelj", 41.008472, 28.979917, "2013:08:23 12:00:00"),
    ("Bergen-Bryggen.jpg", "File:Bryggen - 5003 Bergen Norway.jpg",
     "https://upload.wikimedia.org/wikipedia/commons/c/c0/Bryggen_-_5003_Bergen_Norway.jpg",
     "041baa9064657a6bc0fae9678417671a6fcddcbf", "CC0 1.0", "Spudgun67", 60.397268, 5.323265, "2023:03:20 10:50:45"),
    ("Moscow-Red-Square.jpg", "File:20190218 183517 February 2019 in Moscow.jpg",
     "https://upload.wikimedia.org/wikipedia/commons/4/4e/20190218_183517_February_2019_in_Moscow.jpg",
     "6f2e882ee9b0b635e7b4ab386a4ac45264ebb267", "CC0 1.0", "Rakoon", 55.753889, 37.620833, "2019:02:18 18:35:17"),
    ("Dubai-Burj-Khalifa-View.jpg", "File:Dubai, View from Burj Khalifa, 2018.jpg",
     "https://upload.wikimedia.org/wikipedia/commons/4/4e/Dubai%2C_View_from_Burj_Khalifa%2C_2018.jpg",
     "7b2e15beb8c22a80a79fc88f87718f8b28bbcb8d", "CC0 1.0", "Ubahnverleih", 25.197164, 55.274339, "2018:03:01 10:27:38"),
    ("Petra-Royal-Tombs.jpg", "File:Royal tomb and Uneishu’s tomb 2025.jpg",
     "https://upload.wikimedia.org/wikipedia/commons/5/5a/Royal_tomb_and_Uneishu%E2%80%99s_tomb_2025.jpg",
     "2df668853e06caa76b7a098b0c68b3fe4e77a7b9", "CC0 1.0", "ほっきー", 30.328386, 35.446247, "2025:08:08 14:20:09"),
]


def page(title):
    return "https://commons.wikimedia.org/wiki/" + urllib.request.quote(title.replace(" ", "_"))


def main():
    os.makedirs(CACHE, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    tag = os.path.join(ROOT, "Scripts", "tag_photo.swift")
    notice = ["Schnellbild's world trip: photographs for the screenshots of the Atlas view.",
              "Each is from Wikimedia Commons, reduced to 2048 pixels on its long side, with",
              "the place and time Commons records for it written into its metadata.", ""]
    for name, title, url, sha1, licence, author, lat, lon, taken in PHOTOS:
        original = os.path.join(CACHE, hashlib.sha1(url.encode()).hexdigest() + ".jpg")
        if not os.path.exists(original):
            print(f"==> {title}")
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=300) as r, open(original + ".part", "wb") as f:
                f.write(r.read())
            os.replace(original + ".part", original)
        got = hashlib.sha1(open(original, "rb").read()).hexdigest()
        if got != sha1:
            sys.exit(f"!! {title}: SHA-1 {got}, Commons says {sha1}")
        subprocess.run(["swift", tag, original, os.path.join(OUT, name), str(lat), str(lon), taken], check=True)
        notice += [f"{name}", f"  {title} by {author}, {licence}", f"  {page(title)}", ""]
    # UTF-8 whatever the locale: the names are not all ASCII, and the file's SHA-256 is pinned
    with open(os.path.join(OUT, "LICENSES.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(notice))
    for name in sorted(os.listdir(OUT)):
        p = os.path.join(OUT, name)
        print(hashlib.sha256(open(p, "rb").read()).hexdigest(), name)


if __name__ == "__main__":
    main()
