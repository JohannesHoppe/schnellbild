#!/usr/bin/env python3
"""Builds the website in docs/ (GitHub Pages) from site/i18n/<language>.json.

The page structure is here, once; the words are in one JSON file per language
(the app's languages, Resources/Localization). English is the master: a key
missing in another language falls back to it and is reported. The menu names
in the privacy policy come from the app's own translations, so they read as the
app shows them.

    python3 Scripts/build_site.py           # write docs/**/index.html and the files below
    python3 Scripts/build_site.py --check   # fail if docs/ isn't what the build gives

Besides the pages it writes docs/404.html, sitemap.xml (every page with its other
languages; a page's lastmod changes when its HTML does), robots.txt and
site.webmanifest. Each page carries what search engines and link previews read:
title and description (seoTitle, seoDescription), canonical and hreflang, Open
Graph and Twitter tags with the language's preview image docs/og/<lang>.jpg, and
schema.org data (the app on the home page, breadcrumbs on the privacy policy).
The icons and preview images come from Scripts/make_site_images.py.
"""
import html
import datetime
import json
import plistlib
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
VERSION = plistlib.loads((ROOT / "Resources" / "Info.plist").read_bytes())["CFBundleShortVersionString"]

# The app's languages, in the order the README lists them.
LANGUAGES = ["en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "sv", "da", "nb", "fi",
             "cs", "tr", "ru", "uk", "ja", "ko", "zh-Hans", "zh-Hant"]
HERO_SHOT = "grid"
FEATURE_SHOTS = ["full", "video", "archives", "dualpane", "search", "adjust", "inspector", "help"]

WHY_ICONS = [
    '<path d="M3 3l18 18"/><path d="M10.6 5.1A10.4 10.4 0 0 1 12 5c5 0 9 4.5 10 7a13 13 0 0 1-3.1 4.2M6.6 6.6A13 13 0 0 0 2 12c1 2.5 5 7 10 7a9.9 9.9 0 0 0 5.4-1.6"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
    '<path d="M20.6 13.4l-7.2 7.2a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
    '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
    '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
    '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M8.5 12l2.5 2.5 4.5-5"/>',
    '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/><path d="M5.6 5.6l3.6 3.6M14.8 14.8l3.6 3.6M18.4 5.6l-3.6 3.6M9.2 14.8l-3.6 3.6"/>',
]
# GitHub's mark (Octicons "mark-github"), drawn in the link's colour
OCTOCAT = ('<svg class="mark" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>')
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
            for extra in set(own or {}) - set(master):
                missing.append(f"{code}: {'.'.join(path + [extra])} is not in English")
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
    size = ' width="1072" height="752"' + (' fetchpriority="high"' if name == HERO_SHOT else ' loading="lazy" decoding="async"')
    if code != "en" and own.exists():
        return f'<img src="/screenshots/{own.name}"{size} alt="{esc(alt)}"{extra}>'
    return (f'<picture><source media="(prefers-color-scheme: dark)" srcset="/screenshots/{name}-dark.png">'
            f'<img src="/screenshots/{name}-light.png"{size} alt="{esc(alt)}"{extra}></picture>')


# Open Graph wants a territory: the one each language is most at home in.
OG_LOCALES = {"en": "en_US", "de": "de_DE", "fr": "fr_FR", "es": "es_ES", "it": "it_IT", "pt-BR": "pt_BR",
              "nl": "nl_NL", "pl": "pl_PL", "sv": "sv_SE", "da": "da_DK", "nb": "nb_NO", "fi": "fi_FI",
              "cs": "cs_CZ", "tr": "tr_TR", "ru": "ru_RU", "uk": "uk_UA", "ja": "ja_JP", "ko": "ko_KR",
              "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"}
THEME = {"light": "#fbfbfd", "dark": "#000000"}  # the page background of site.css
ORGANIZATION = {"@type": "Organization", "@id": SITE + "/#organization", "name": "HAUS HOPPE - ITS",
                "url": "https://haushoppe-its.de"}


def hero_shot_url(code):
    own = DOCS / "screenshots" / f"{HERO_SHOT}-light-{code}.png"
    return f"{SITE}/screenshots/{own.name if code != 'en' and own.exists() else HERO_SHOT + '-light.png'}"


def json_ld(data):
    text = json.dumps({"@context": "https://schema.org", **data}, ensure_ascii=False, indent=1)
    return '<script type="application/ld+json">\n' + text.replace("</", "<\\/") + "\n</script>"


def app_data(code, t):
    """schema.org data of the home page: the app, the website, who makes it."""
    url = SITE + home_path(code)
    app = {
        "@type": "SoftwareApplication", "@id": url + "#app", "name": "Schnellbild",
        "description": t["seoDescription"], "inLanguage": code, "url": url,
        "operatingSystem": "macOS 15 or later", "processorRequirements": "Apple silicon (arm64)",
        "applicationCategory": "MultimediaApplication", "applicationSubCategory": "Photography",
        "softwareVersion": VERSION, "downloadUrl": DMG,
        "image": SITE + "/icon-512.png", "screenshot": hero_shot_url(code),
        "featureList": [f["title"] for f in t["features"]],
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "EUR", "url": DMG},
        "isAccessibleForFree": True, "license": "https://opensource.org/license/mit",
        "author": {"@id": ORGANIZATION["@id"]}, "publisher": {"@id": ORGANIZATION["@id"]},
        "sameAs": REPO,
    }
    website = {"@type": "WebSite", "@id": SITE + "/#website", "name": "Schnellbild", "url": SITE + "/",
               "inLanguage": LANGUAGES, "publisher": {"@id": ORGANIZATION["@id"]}}
    return json_ld({"@graph": [app, website, ORGANIZATION]})


def breadcrumbs(code, t):
    items = [("Schnellbild", SITE + home_path(code)), (t["privacy"]["title"], SITE + privacy_path(code, t))]
    return json_ld({"@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": i, "name": name, "item": url} for i, (name, url) in enumerate(items, 1)]})


def head(code, t, title, description, path_of=None, share_title=None, keywords=None, data="",
         robots="index, follow, max-image-preview:large", canonical=None):
    """The head of a page; path_of gives a language's version of it (canonical, hreflang)."""
    url = SITE + path_of(code) if path_of else (SITE + canonical if canonical else None)
    links = f'<link rel="canonical" href="{url}">\n' if url else ""
    if path_of:
        links = f'<link rel="canonical" href="{url}">\n' + "".join(
            f'<link rel="alternate" hreflang="{lang}" href="{SITE}{path_of(c)}">\n'
            for lang, c in [(c, c) for c in LANGUAGES] + [("x-default", "en")])
    share_title = share_title or title
    image_alt = f"Schnellbild: {t['tagline']}"
    alternates = "".join(f'\n<meta property="og:locale:alternate" content="{OG_LOCALES[c]}">' for c in LANGUAGES if c != code)
    og_url = f'\n<meta property="og:url" content="{url}">' if url else ""
    keywords = f'\n<meta name="keywords" content="{esc(keywords)}">' if keywords else ""
    return f"""<!doctype html>
<html lang="{code}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(description)}">{keywords}
<meta name="robots" content="{robots}">
{links}<link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png">
<link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/site.webmanifest">
<meta name="theme-color" media="(prefers-color-scheme: light)" content="{THEME['light']}">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="{THEME['dark']}">
<meta name="color-scheme" content="light dark">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Schnellbild">
<meta property="og:title" content="{esc(share_title)}">
<meta property="og:description" content="{esc(description)}">{og_url}
<meta property="og:locale" content="{OG_LOCALES[code]}">{alternates}
<meta property="og:image" content="{SITE}/og/{code}.jpg">
<meta property="og:image:type" content="image/jpeg">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{esc(image_alt)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(share_title)}">
<meta name="twitter:description" content="{esc(description)}">
<meta name="twitter:image" content="{SITE}/og/{code}.jpg">
<meta name="twitter:image:alt" content="{esc(image_alt)}">
{data + chr(10) if data else ""}<link rel="stylesheet" href="/site.css">
<script src="/site.js" defer></script>
</head>
<body>"""


def topbar(code, t, path_of, sections=True):
    current = ' aria-current="page"'
    links = "".join(
        f'<a href="{path_of(c)}" hreflang="{c}" lang="{c}"{current if c == code else ""}>{esc(tr[c]["name"])}</a>'
        for c in LANGUAGES)
    nav = (f'<a class="section-link" href="#features">{esc(t["navFeatures"])}</a>'
           f'<a class="section-link" href="#safe">{esc(t["navSafety"])}</a>') if sections else ""
    return f"""<header class="bar">
  <div class="wrap top">
    <a class="brand" href="{home_path(code)}"><img src="/icon.png" alt="" width="32" height="32">Schnellbild</a>
    <nav>
      {nav}<a class="github" href="{REPO}">{OCTOCAT}GitHub</a>
      <details class="lang">
        <summary aria-label="{esc(t['language'])}: {esc(t['name'])}">{GLOBE}<span>{esc(t['name'])}</span></summary>
        <div class="lang-list">{links}</div>
      </details>
    </nav>
  </div>
</header>"""


def footer(code, t):
    return f"""<footer>
  <div class="wrap">
    <span>© 2026 <a href="https://haushoppe-its.de/">HAUS HOPPE - ITS</a> (Johannes Hoppe)</span>
    <nav aria-label="{esc(t['footerPrivacy'])}, {esc(t['footerImprint'])}">
      <a href="{privacy_path(code, t)}">{esc(t['footerPrivacy'])}</a>
      <a href="/eula/">{esc(t['footerEula'])}</a>
      <a href="{IMPRINT}">{esc(t['footerImprint'])}</a>
      <a class="github" href="{REPO}">{OCTOCAT}GitHub</a>
    </nav>
  </div>
</footer>
</body>
</html>
"""


def fineprint(text):
    """The line under the buttons, broken after its first clause (the semicolon, or the first sentence)."""
    match = re.search(r"[;；]|。|\. ", text)
    if not match:
        return esc(text)
    return esc(text[:match.end()].rstrip()) + "<br>" + esc(text[match.end():].lstrip())


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
    return head(code, t, t["seoTitle"], t["seoDescription"], path_of, share_title=t["title"],
                keywords=t["keywords"], data=app_data(code, t)) + topbar(code, t, path_of) + f"""
<main>
<div class="hero">
  <div class="wrap">
    <img class="icon" src="/icon.png" alt="{esc(t['iconAlt'])}" width="128" height="128">
    <h1>Schnellbild</h1>
    <p class="tagline">{esc(t['tagline'])}</p>
    <p class="lead">{esc(t['lead'])}</p>
    {buttons}
    <p class="fineprint">{fineprint(t['fineprint'])}</p>
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
    <p class="more-features" data-reveal><a href="{REPO}#features">{esc(t['featuresMore'])} →</a></p>
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
    names = {"{folderAccess}": esc(app_string(code, "Forget Folder Access…")),
             "{forgetPasswords}": esc(app_string(code, "Forget Saved Passwords…"))}

    def fill(item):
        for placeholder, name in names.items():
            item = item.replace(placeholder, name)
        return item
    stays = "".join(f"<li>{fill(item)}</li>" for item in p["stays"])
    path_of = lambda c: privacy_path(c, tr[c])
    return head(code, t, f"{p['title']} · Schnellbild", p["description"], path_of,
                data=breadcrumbs(code, t)) + topbar(code, t, path_of, sections=False) + f"""
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
  <p>{p['rightsText']}</p>
  <h2>{esc(p['contactTitle'])}</h2>
  <p>{p['contactText']}</p>
</main>
""" + footer(code, t)


def not_found(t):
    """docs/404.html, which GitHub Pages serves for every address it doesn't have: English, not indexed."""
    homes = "".join(f'<li><a href="{home_path(c)}" hreflang="{c}" lang="{c}">{esc(tr[c]["name"])}</a></li>' for c in LANGUAGES)
    return head("en", t, "Page not found · Schnellbild", "This page doesn't exist. Schnellbild, the image and video viewer for macOS, is on its home page.",
                robots="noindex") + topbar("en", t, home_path, sections=False) + f"""
<main class="wrap narrow page">
  <h1>Page not found</h1>
  <p>There is nothing at this address. Schnellbild's home page, in every language:</p>
  <ul class="homes">{homes}</ul>
</main>
""" + footer("en", t)


def markdown(text):
    """The little Markdown AppStore/EULA.md uses: # and ## headings, paragraphs (their line breaks kept), <https://…> links."""
    blocks = []
    for block in re.split(r"\n\s*\n", text.strip()):
        # A line break inside a paragraph stays one (the address)
        line = "<br>".join(esc(part) for part in block.splitlines())
        line = re.sub(r"&lt;(https://[^&\s]+)&gt;", r'<a href="\1">\1</a>', line)
        if line.startswith("## "):
            blocks.append(f"<h2>{line[3:]}</h2>")
        elif line.startswith("# "):
            blocks.append(f"<h1>{line[2:]}</h1>")
        else:
            blocks.append(f"<p>{line}</p>")
    return "\n  ".join(blocks)


def eula(t):
    """/eula/: the license agreement of the Mac App Store version (AppStore/EULA.md), in English as Apple gets it."""
    text = (ROOT / "AppStore" / "EULA.md").read_text(encoding="utf-8")
    return head("en", t, "License Agreement · Schnellbild",
                "The license agreement (EULA) of Schnellbild in the Mac App Store.", canonical="/eula/") + \
        topbar("en", t, home_path, sections=False) + f"""
<main class="wrap narrow page">
  {markdown(text)}
</main>
""" + footer("en", t)


def sitemap(pages):
    """Every page with its other languages. A page's lastmod stays until its HTML changes."""
    path = DOCS / "sitemap.xml"
    before = dict(re.findall(r"<loc>([^<]+)</loc>\s*<lastmod>([^<]+)</lastmod>", path.read_text(encoding="utf-8"))) if path.exists() else {}
    today = datetime.date.today().isoformat()
    entries = []
    for kind in ("home", "privacy"):
        path_of = home_path if kind == "home" else (lambda c: privacy_path(c, tr[c]))
        for code in LANGUAGES:
            loc = SITE + path_of(code)
            file = DOCS / path_of(code).lstrip("/") / "index.html"
            unchanged = file.exists() and file.read_text(encoding="utf-8") == pages[file]
            lastmod = before[loc] if unchanged and loc in before else today
            alternates = "".join(
                f'\n    <xhtml:link rel="alternate" hreflang="{lang}" href="{SITE}{path_of(c)}"/>'
                for lang, c in [(c, c) for c in LANGUAGES] + [("x-default", "en")])
            entries.append(f"  <url>\n    <loc>{loc}</loc>\n    <lastmod>{lastmod}</lastmod>{alternates}\n  </url>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(entries) + "\n</urlset>\n")


def manifest(t):
    return json.dumps({
        "name": "Schnellbild", "short_name": "Schnellbild", "description": t["seoDescription"], "lang": "en",
        "start_url": "/", "display": "browser", "theme_color": THEME["light"], "background_color": THEME["light"],
        "icons": [{"src": f"/icon-{size}.png", "sizes": f"{size}x{size}", "type": "image/png"} for size in (192, 512)],
    }, ensure_ascii=False, indent=2) + "\n"


english = json.loads((I18N / "en.json").read_text(encoding="utf-8"))
tr = {code: load(code, english) for code in LANGUAGES}

pages = {}
for code in LANGUAGES:
    pages[DOCS / folder(code) / "index.html"] = home(code, tr[code])
    pages[DOCS / folder(code) / tr[code]["privacySlug"] / "index.html"] = privacy(code, tr[code])
    if not (DOCS / "og" / f"{code}.jpg").exists():
        missing.append(f"{code}: docs/og/{code}.jpg (python3 Scripts/make_site_images.py og)")

pages[DOCS / "eula" / "index.html"] = eula(tr["en"])
pages[DOCS / "404.html"] = not_found(tr["en"])
pages[DOCS / "site.webmanifest"] = manifest(tr["en"])
pages[DOCS / "robots.txt"] = f"User-agent: *\nAllow: /\n\nSitemap: {SITE}/sitemap.xml\n"
pages[DOCS / "sitemap.xml"] = sitemap(pages)

for line in missing:
    print("missing, English used:", line, file=sys.stderr)

# Pages the build doesn't make (a language's old privacy slug) would stay online.
orphans = sorted(str(p.relative_to(ROOT)) for p in DOCS.rglob("index.html") if p not in pages)

if "--check" in sys.argv:
    stale = [str(p.relative_to(ROOT)) for p, text in pages.items()
             if not p.exists() or p.read_text(encoding="utf-8") != text]
    if stale:
        sys.exit("docs/ is out of date, run python3 Scripts/build_site.py: " + ", ".join(stale))
    if orphans or missing:
        sys.exit("docs/ has pages the build doesn't make: " + ", ".join(orphans) if orphans else "translations are missing")
    print(f"docs/ is up to date ({len(pages)} pages)")
else:
    for path, text in pages.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    print(f"{len(pages)} pages written")
    for orphan in orphans:
        print("not made by the build, delete it:", orphan, file=sys.stderr)
    if missing or orphans:
        sys.exit(1)
