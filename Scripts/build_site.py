#!/usr/bin/env python3
"""Builds the website in docs/ (GitHub Pages) from site/i18n/<language>.json.

The page structure is here, once; the words are in one JSON file per language
(the app's languages, Resources/Localization). English is the master: a key
missing in another language falls back to it and is reported. The menu names
in the privacy policy come from the app's own translations, so they read as the
app shows them.

    python3 Scripts/build_site.py           # write docs/**/index.html
    python3 Scripts/build_site.py --check   # fail if docs/ isn't what the build gives
"""
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
I18N = ROOT / "site" / "i18n"
DOCS = ROOT / "docs"
SITE = "https://schnellbild.haushoppe-its.de"
REPO = "https://github.com/JohannesHoppe/schnellbild"
DMG = REPO + "/releases/latest/download/Schnellbild.dmg"
IMPRINT = "https://haushoppe-its.de/impressum/"

# The app's languages, in the order the README lists them.
LANGUAGES = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi",
             "cs", "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]
HERO_SHOT = "grid"
FEATURE_SHOTS = ["full", "video", "archives", "dualpane", "search", "adjust", "inspector", "help"]
HTML_FIELDS = {"text", "safeMore", "modelsText", "ossText", "intro", "appText", "stays",
               "siteText", "rightsText", "contactText"}

WHY_ICONS = [
    '<path d="M3 3l18 18"/><path d="M10.6 5.1A10.4 10.4 0 0 1 12 5c5 0 9 4.5 10 7a13 13 0 0 1-3.1 4.2M6.6 6.6A13 13 0 0 0 2 12c1 2.5 5 7 10 7a9.9 9.9 0 0 0 5.4-1.6"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
    '<path d="M20.6 13.4l-7.2 7.2a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
    '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
    '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
    '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
    '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/><path d="M5.6 5.6l3.6 3.6M14.8 14.8l3.6 3.6M18.4 5.6l-3.6 3.6M9.2 14.8l-3.6 3.6"/>',
]
GLOBE = '<svg class="i" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></svg>'

missing = []


def esc(text):
    return html.escape(text, quote=True)


def load(code, english):
    path = I18N / f"{code}.json"
    if not path.exists():
        missing.append(f"{code}: no {path.name}")
        return english
    data = json.loads(path.read_text(encoding="utf-8"))

    def merge(own, master, path):
        if isinstance(master, dict):
            return {k: merge(own.get(k) if isinstance(own, dict) else None, v, path + [k]) for k, v in master.items()}
        if own is None:
            missing.append(f"{code}: {'.'.join(path)}")
            return master
        if isinstance(master, list) and len(own) != len(master):
            missing.append(f"{code}: {'.'.join(path)} has {len(own)} entries, English {len(master)}")
        return own
    return merge(data, english, []) if code != "en" else data


def app_string(code, key):
    """The app's own translation of a UI string (Resources/Localization)."""
    path = ROOT / "Resources" / "Localization" / f"{code}.lproj" / "Localizable.strings"
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";$', line)
        if match and match.group(1) == key:
            return match.group(2).rstrip("…").rstrip()
    sys.exit(f"{code}.lproj has no {key!r}")


def folder(code):
    return "" if code == "en" else code.lower() + "/"


def home_path(code):
    return "/" + folder(code)


def privacy_path(code, t):
    return "/" + folder(code) + t["privacySlug"] + "/"


def shot(name, code, alt, extra=""):
    """A screenshot: the language's own (light) where there is one, else English, light or dark."""
    own = DOCS / "screenshots" / f"{name}-light-{code}.png"
    size = ' width="1072" height="752"' if name == HERO_SHOT else ' loading="lazy" decoding="async"'
    if code != "en" and own.exists():
        return f'<img src="/screenshots/{own.name}"{size} alt="{esc(alt)}"{extra}>'
    return (f'<picture><source media="(prefers-color-scheme: dark)" srcset="/screenshots/{name}-dark.png">'
            f'<img src="/screenshots/{name}-light.png"{size} alt="{esc(alt)}"{extra}></picture>')


def head(code, t, title, description, path_of):
    alternates = "\n".join(
        f'<link rel="alternate" hreflang="{c}" href="{SITE}{path_of(c)}">' for c in LANGUAGES)
    return f"""<!doctype html>
<html lang="{code}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(description)}">
<link rel="canonical" href="{SITE}{path_of(code)}">
{alternates}
<link rel="alternate" hreflang="x-default" href="{SITE}{path_of('en')}">
<link rel="icon" href="/icon.png">
<link rel="apple-touch-icon" href="/icon.png">
<meta property="og:title" content="Schnellbild">
<meta property="og:description" content="{esc(t['tagline'])}">
<meta property="og:image" content="{SITE}/screenshots/{HERO_SHOT}-light.png">
<meta property="og:url" content="{SITE}{path_of(code)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="color-scheme" content="light dark">
<link rel="stylesheet" href="/site.css">
<script src="/site.js" defer></script>
</head>
<body>"""


def topbar(code, t, path_of, sections=True):
    current = ' aria-current="true"'
    links = "".join(
        f'<a href="{path_of(c)}" hreflang="{c}" lang="{c}"{current if c == code else ""}>{esc(tr[c]["name"])}</a>'
        for c in LANGUAGES)
    nav = (f'<a class="section-link" href="#features">{esc(t["navFeatures"])}</a>'
           f'<a class="section-link" href="#safe">{esc(t["navSafety"])}</a>') if sections else ""
    return f"""<header class="bar">
  <div class="wrap top">
    <a class="brand" href="{home_path(code)}"><img src="/icon.png" alt="" width="32" height="32">Schnellbild</a>
    <nav>
      {nav}<a href="{REPO}">GitHub</a>
      <details class="lang">
        <summary aria-label="{esc(t['language'])}">{GLOBE}<span>{esc(t['name'])}</span></summary>
        <div class="lang-list">{links}</div>
      </details>
    </nav>
  </div>
</header>"""


def footer(code, t):
    return f"""<footer>
  <div class="wrap">
    <span>© 2026 HAUS HOPPE - ITS (Johannes Hoppe)</span>
    <nav>
      <a href="{privacy_path(code, t)}">{esc(t['footerPrivacy'])}</a>
      <a href="{IMPRINT}">{esc(t['footerImprint'])}</a>
      <a href="{REPO}">GitHub</a>
    </nav>
  </div>
</footer>
</body>
</html>
"""


def home(code, t):
    path_of = home_path
    stats = "".join(
        f'<div class="stat" data-reveal style="--i:{i}"><b>{esc(value)}</b><span>{esc(label)}</span></div>'
        for i, (value, label) in enumerate(t["stats"]))
    why = "".join(
        f'<div class="card" data-reveal style="--i:{i % 3}"><svg class="i" viewBox="0 0 24 24" aria-hidden="true">{WHY_ICONS[i]}</svg>'
        f'<h3>{esc(title)}</h3><p>{esc(text)}</p></div>'
        for i, (title, text) in enumerate(t["why"]))
    features = "".join(
        f"""
    <div class="feature">
      <div class="text" data-reveal><h3>{esc(f['title'])}</h3>{f['text']}</div>
      <div class="media" data-reveal><div data-parallax>{shot(name, code, f['alt'])}</div></div>
    </div>"""
        for name, f in zip(FEATURE_SHOTS, t["features"]))
    safe = "".join(f'<li data-reveal style="--i:{i}"><strong>{esc(a)}</strong> {esc(b)}</li>' for i, (a, b) in enumerate(t["safe"]))
    languages = ", ".join(
        f'<a href="{home_path(c)}" hreflang="{c}" lang="{c}">{esc(tr[c]["name"])}</a>' for c in LANGUAGES)
    buttons = f"""<div class="actions">
    <a class="button primary" href="{DMG}">{esc(t['download'])}<small>Schnellbild.dmg</small></a>
    <span class="button soon">{esc(t['store'])}<small>{esc(t['storeSoon'])}</small></span>
  </div>"""
    return head(code, t, t["title"], t["description"], path_of) + topbar(code, t, path_of) + f"""
<main>
<div class="hero">
  <div class="wrap">
    <img class="icon" src="/icon.png" alt="{esc(t['iconAlt'])}" width="128" height="128">
    <h1>Schnellbild</h1>
    <p class="tagline">{esc(t['tagline'])}</p>
    <p class="lead">{esc(t['lead'])}</p>
    {buttons}
    <p class="fineprint">{esc(t['fineprint'])}</p>
  </div>
  <div class="wrap wide"><div class="shot">{shot(HERO_SHOT, code, t['shotAlt'])}</div></div>
</div>

<div class="wrap stats">{stats}</div>

<section>
  <div class="wrap">
    <h2 data-reveal>{esc(t['whyTitle'])}</h2>
    <div class="cards">{why}</div>
  </div>
</section>

<section id="features">
  <div class="wrap">
    <h2 data-reveal>{esc(t['featuresTitle'])}</h2>{features}
  </div>
</section>

<section id="safe" class="safe">
  <div class="wrap narrow">
    <svg class="i big" viewBox="0 0 24 24" aria-hidden="true" data-reveal>{WHY_ICONS[4]}</svg>
    <h2 data-reveal>{esc(t['safeTitle'])}</h2>
    <p class="intro" data-reveal>{esc(t['safeIntro'])}</p>
    <ul class="checks">{safe}</ul>
    <p class="more" data-reveal>{t['safeMore']}</p>
  </div>
</section>

<section>
  <div class="wrap narrow">
    <h2 data-reveal>{esc(t['modelsTitle'])}</h2>
    <p class="intro" data-reveal>{t['modelsText']}</p>
    <h2 data-reveal>{esc(t['ossTitle'])}</h2>
    <p class="intro" data-reveal>{t['ossText']}</p>
    <p class="languages" data-reveal>{esc(t['languagesText'])} {languages}.</p>
  </div>
</section>

<section class="cta">
  <div class="wrap" data-reveal>
    <img class="icon" src="/icon.png" alt="" width="96" height="96">
    <h2>{esc(t['ctaTitle'])}</h2>
    <p class="intro">{esc(t['ctaText'])}</p>
    {buttons}
  </div>
</section>
</main>
""" + footer(code, t)


def privacy(code, t):
    p = t["privacy"]
    names = {"folderAccess": esc(app_string(code, "Folder access")),
             "forgetPasswords": esc(app_string(code, "Forget Saved Passwords…"))}
    stays = "".join(f"<li>{item.format(**names)}</li>" for item in p["stays"])
    path_of = lambda c: privacy_path(c, tr[c])
    return head(code, t, f"{p['title']} – Schnellbild", p["description"], path_of) + topbar(code, t, path_of, sections=False) + f"""
<main class="wrap narrow page">
  <h1>{esc(p['title'])}</h1>
  <p>{p['intro']}</p>
  <h2>{esc(p['appTitle'])}</h2>
  {p['appText']}
  <ul>{stays}</ul>
  <p>{esc(p['appOutro'])}</p>
  <h2>{esc(p['siteTitle'])}</h2>
  <p>{p['siteText']}</p>
  <h2>{esc(p['rightsTitle'])}</h2>
  <p>{esc(p['rightsText'])}</p>
  <h2>{esc(p['contactTitle'])}</h2>
  <p>{p['contactText']}</p>
</main>
""" + footer(code, t)


english = json.loads((I18N / "en.json").read_text(encoding="utf-8"))
tr = {code: load(code, english) for code in LANGUAGES}

pages = {}
for code in LANGUAGES:
    pages[DOCS / folder(code) / "index.html"] = home(code, tr[code])
    pages[DOCS / folder(code) / tr[code]["privacySlug"] / "index.html"] = privacy(code, tr[code])

for line in missing:
    print("missing, English used:", line, file=sys.stderr)

if "--check" in sys.argv:
    stale = [str(p.relative_to(ROOT)) for p, text in pages.items()
             if not p.exists() or p.read_text(encoding="utf-8") != text]
    if stale:
        sys.exit("docs/ is out of date, run python3 Scripts/build_site.py: " + ", ".join(stale))
    print(f"docs/ is up to date ({len(pages)} pages)")
else:
    for path, text in pages.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    print(f"{len(pages)} pages written")
    if missing:
        sys.exit(1)
