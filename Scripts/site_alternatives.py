"""The "Schnellbild as an alternative to …" pages of the website, for build_site.py.

Data (site/alternatives/):
    rows.json             the comparison's rows in their groups (keys; the words are in i18n)
    schnellbild.json      Schnellbild's own value for every row
    products/<slug>.json  one compared program: facts, page kind, and per row its value,
                          the sources (evidence) and how they were found; "unverified" cells
                          aren't shown
    demand.json           monthly searches per site language ("<name> mac", "<name> for mac",
                          "<name> alternative"), which orders the lists in each language
    i18n/<lang>.json      the words: page texts, row labels, what Schnellbild does per row
                          (how) or why it leaves a row out (why), and per program its name,
                          summary, strengths, price, version and the notes of its partial cells.
                          English is the master; a missing key falls back to it and is reported.

Two kinds of pages: a program that runs on a Mac gets the full comparison ("matrix"); one
that doesn't gets a short page for people switching from it ("switcher"). One overview lists
them all by section, in the order of what people in that language search for.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "site" / "alternatives"

SECTIONS = ["image", "video", "comic", "files", "photos", "windows"]
# Where Schnellbild is stronger: the first rows of this order that it has and the other doesn't.
WE_WIN = ["free", "folder_browsing", "photos_videos_one_grid", "video_mkv_avi_webm", "archives_as_folders",
          "comics_cbz_cbr", "videos_in_archives", "dual_pane", "slideshow_recursive", "recursive_search",
          "auto_enhance_view", "video_skim_arrows", "undo_file_actions", "open_source", "no_network",
          "app_sandbox", "no_account_no_tracking", "quicklook_mkv_thumbnails", "wrong_extension_note",
          "custom_shortcuts", "keyboard_first", "boss_key"]
WE_WIN_COUNT = 7
# What switchers liked: the first rows of this order that both have.
LIKED = ["keyboard_paging", "folder_browsing", "thumbnail_grid", "img_modern_formats", "img_raw", "img_animated",
         "zoom_rotate", "archives_as_folders", "comics_cbz_cbr", "video_mkv_avi_webm", "subtitles_embedded",
         "audio_track_choice", "playback_speed", "video_skim_arrows", "slideshow", "slideshow_recursive",
         "file_info_exif", "dual_pane", "rename_trash", "move_copy", "recursive_search", "list_view",
         "bookmarks", "auto_enhance_view", "video_filters_enhance", "keyboard_first", "custom_shortcuts", "free"]
LIKED_COUNT = 8
SIMILAR_COUNT = 6
HOME_COUNT = 8
# The screenshot that shows what a section's visitors look for.
SECTION_SHOT = {"image": "grid", "video": "video", "comic": "archive-inside", "files": "dualpane",
                "photos": "grid", "windows": "grid"}
CATEGORY_KIND = {"image": "image", "both": "image", "video": "video", "comic": "comic",
                 "file-manager": "files", "photo-manager": "photos"}

SYMBOLS = {
    "yes": '<circle cx="10" cy="10" r="9"/><path class="g" d="M5.8 10.4l2.8 2.8 5.6-6"/>',
    "no": '<circle cx="10" cy="10" r="9"/><path class="g" d="M6.6 6.6l6.8 6.8M13.4 6.6l-6.8 6.8"/>',
    "partial": '<circle class="ring" cx="10" cy="10" r="8.2"/><path d="M10 1.8a8.2 8.2 0 0 0 0 16.4z"/>',
    "intentional": '<circle cx="10" cy="10" r="8.4"/><path class="g" d="M6 10h8"/>',
    "na": '<path class="g" d="M6 10h8"/>',
}


def fill(text, **values):
    for key, value in values.items():
        text = text.replace("{" + key + "}", str(value))
    return text


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def strings(value, where=""):
    """Every text in a JSON value, with where it is."""
    if isinstance(value, dict):
        for key, item in value.items():
            yield from strings(item, f"{where}.{key}" if where else key)
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from strings(item, f"{where}[{i}]")
    elif isinstance(value, str):
        yield where, value


class Alternatives:
    def __init__(self, ctx):
        """ctx: what build_site.py shares (esc, head, topbar, footer, shot, home_path, folder,
        json_ld, tr, LANGUAGES, SITE, DMG, VERSION, missing)."""
        self.c = ctx
        self.rows = load_json(DATA / "rows.json")
        self.keys = [r["key"] for g in self.rows["groups"] for r in g["rows"]]
        ours = load_json(DATA / "schnellbild.json")
        self.ours, self.version = ours["rows"], ours["version"]
        self.products = {p.stem: load_json(p) for p in sorted((DATA / "products").glob("*.json"))}
        self.demand = load_json(DATA / "demand.json")["demand"]
        english = load_json(DATA / "i18n" / "en.json")
        self.words = {code: self.load(code, english) for code in ctx["LANGUAGES"]}
        for code, words in self.words.items():
            for where, text in strings(words):
                if re.search("[–—]", text):
                    ctx["missing"].append(f"alternatives {code}: {where} has an em or en dash (see Working conventions)")
        for key in self.keys:
            if key not in self.ours:
                ctx["missing"].append(f"schnellbild.json: no row {key}")
        for slug, p in self.products.items():
            for key in self.keys:
                if key not in p["matrix"]:
                    ctx["missing"].append(f"products/{slug}.json: no row {key}")
            if slug not in english["products"]:
                ctx["missing"].append(f"alternatives en: no product {slug}")
            elif p["page"] == "matrix":
                for key in self.shown(slug):
                    if p["matrix"][key]["value"] == "partial" and key not in english["products"][slug].get("notes", {}):
                        ctx["missing"].append(f"alternatives en: products.{slug}.notes.{key}")

    def load(self, code, english):
        path = DATA / "i18n" / f"{code}.json"
        missing = self.c["missing"]
        if code == "en":
            return english
        if not path.exists():
            missing.append(f"alternatives {code}: no {path.name}")
            return english
        own = load_json(path)

        def merge(mine, master, where):
            if isinstance(master, dict):
                for extra in set(mine or {}) - set(master):
                    missing.append(f"alternatives {code}: {'.'.join(where + [extra])} is not in English")
                return {k: merge(mine.get(k) if isinstance(mine, dict) else None, v, where + [k]) for k, v in master.items()}
            if mine is None:
                missing.append(f"alternatives {code}: {'.'.join(where)}")
                return master
            if isinstance(master, list) and len(mine) != len(master):
                missing.append(f"alternatives {code}: {'.'.join(where)} has {len(mine)} entries, English {len(master)}")
            return mine
        return merge(own, english, [])

    # Paths

    def path(self, code, slug=None):
        base = "/" + self.c["folder"](code) + self.c["tr"][code]["alternativesSlug"] + "/"
        return base + (slug + "/" if slug else "")

    def link(self, code, slug):
        """The address of a page, for {alt:<slug>} in the site's texts."""
        return self.path(code, slug if slug in self.products else None)

    # Data

    def shown(self, slug):
        """The rows shown for a program: every one with a source."""
        cells = self.products[slug]["matrix"]
        return [k for k in self.keys if cells[k]["how"] != "unverified"]

    def kind(self, slug):
        p = self.products[slug]
        return p["section"] if p["section"] != "windows" else CATEGORY_KIND[p["category"]]

    def ranked(self, code, slugs):
        """Most searched in this language first, then in English, then by name."""
        own, english = self.demand.get(code, {}), self.demand["en"]
        return sorted(slugs, key=lambda s: (-own.get(s, 0), -english.get(s, 0), self.products[s]["short"].lower()))

    def name(self, code, slug):
        return self.words[code]["products"][slug]["name"]

    # Pieces

    def symbol(self, code, value):
        ui = self.words[code]["ui"]
        return (f'<svg class="v {value}" viewBox="0 0 20 20" aria-hidden="true">{SYMBOLS[value]}</svg>'
                f'<span class="sr">{self.c["esc"](ui[value])}</span>')

    def legend(self, code):
        ui = self.words[code]["ui"]
        esc = self.c["esc"]
        items = "".join(f'<li><svg class="v {v}" viewBox="0 0 20 20" aria-hidden="true">{SYMBOLS[v]}</svg>{esc(ui[v])}</li>'
                        for v in ["yes", "partial", "no", "intentional", "na"])
        return f'<ul class="legend" aria-label="{esc(ui["legendTitle"])}">{items}</ul>'

    def page_links(self, code, slugs, cls="alt-links"):
        esc = self.c["esc"]
        items = "".join(f'<li><a href="{self.path(code, s)}">{esc(self.name(code, s))}</a></li>' for s in slugs)
        return f'<ul class="{cls}">{items}</ul>'

    def similar(self, code, slug):
        """The most searched Mac programs of the same kind: what someone looking at this page could use."""
        kind = self.kind(slug)
        others = [s for s, p in self.products.items() if s != slug and self.kind(s) == kind and p["page"] == "matrix"]
        return self.ranked(code, others)[:SIMILAR_COUNT]

    def trademark(self, code, slug):
        ui = self.words[code]["ui"]
        vendor = self.words[code]["products"][slug]["vendor"]
        if not vendor:
            return ui["trademarkAll"]
        return fill(ui["trademark"], name=self.products[slug]["name"], vendor=vendor)

    def breadcrumbs(self, code, items):
        site = self.c["SITE"]
        return {"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": i, "name": name, "item": site + url} for i, (name, url) in enumerate(items, 1)]}

    def program(self, code, slug):
        """schema.org: the compared program, by its facts (no ratings)."""
        p = self.products[slug]
        data = {"@type": "SoftwareApplication", "name": p["name"], "url": p["website"],
                "operatingSystem": ", ".join(p["platforms"]), "applicationCategory": "MultimediaApplication"}
        vendor = self.words["en"]["products"][slug]["vendor"]
        if vendor:
            data["author"] = {"@type": "Organization", "name": vendor}
        return data

    def cta(self, code):
        t, ui, esc, dmg = self.c["tr"][code], self.words[code]["ui"], self.c["esc"], self.c["DMG"]
        return f"""<section class="cta alt-cta">
  <div class="wrap" data-reveal>
    <img class="icon" src="/icon.png" alt="" width="96" height="96">
    <h2>{esc(ui['ctaTitle'])}</h2>
    <p class="intro">{esc(ui['ctaText'])}</p>
    <div class="actions">
    <a class="button primary" href="{dmg}">{esc(t['download'])}<small>Schnellbild.dmg</small></a>
    <span class="button soon">{esc(t['store'])}<small>{esc(t['storeSoon'])}</small></span>
  </div>
  </div>
</section>"""

    def tail(self, code, slug):
        """Similar pages and the trademark note, at the end of a program's page."""
        ui, esc = self.words[code]["ui"], self.c["esc"]
        return f"""<div class="wrap alt">
  <h2 class="small">{esc(ui['similarTitle'])}</h2>
  {self.page_links(code, self.similar(code, slug))}
  <p class="all"><a href="{self.path(code)}">{esc(ui['allAlternatives'])} →</a></p>
  <p class="trademark">{esc(self.trademark(code, slug))}</p>
</div>"""

    def facts(self, code, slug):
        ui, esc = self.words[code]["ui"], self.c["esc"]
        w = self.words[code]["products"][slug]
        name = w["name"]
        tiles = [(ui["factPrice"], w["price"]), (ui["factVersion"], w["version"]),
                 (ui["factUpdated"], w["updated"]), (ui["factPlatforms"], w["platforms"])]
        body = "".join(f'<div class="fact"><span>{esc(label)}</span><b>{esc(value)}</b></div>' for label, value in tiles)
        return f'<div class="facts" aria-label="{esc(fill(ui["facts"], name=name))}">{body}</div>'

    # Pages

    def matrix_page(self, code, slug):
        c, esc = self.c, self.c["esc"]
        ui, words = self.words[code]["ui"], self.words[code]
        w = words["products"][slug]
        p = self.products[slug]
        name = w["name"]
        cells = p["matrix"]
        shown = self.shown(slug)
        rows_words = words["rows"]
        sep = ui.get("listSep", ", ")

        # Sources, numbered in the order they first appear
        sources = []
        def cite(urls):
            numbers = []
            for url in urls:
                if url not in sources:
                    sources.append(url)
                numbers.append(sources.index(url) + 1)
            return "".join(f'<a href="#s{n}" aria-label="{esc(fill(ui["source"], n=n))}">{n}</a>' for n in numbers)

        groups = []
        for group in self.rows["groups"]:
            body = []
            for row in group["rows"]:
                key = row["key"]
                if key not in shown:
                    continue
                ours = self.ours[key]["value"]
                rw = rows_words[key]
                ours_text = rw.get("why") if ours == "intentional" else rw.get("note")
                ours_cell = self.symbol(code, ours) + (f'<small>{esc(ours_text)}</small>' if ours_text else "")
                cell = cells[key]
                note = w.get("notes", {}).get(key) if cell["value"] == "partial" else None
                theirs = self.symbol(code, cell["value"])
                if cell.get("evidence"):
                    theirs += f'<span class="cite">{cite(cell["evidence"])}</span>'
                theirs += f'<small>{esc(note)}</small>' if note else ""
                body.append(f'<tr><th scope="row">{esc(rw["label"])}</th><td>{ours_cell}</td><td>{theirs}</td></tr>')
            if body:
                gid = "g-" + group["group"]
                groups.append(f'<tbody><tr class="group"><th colspan="3" scope="colgroup" id="{gid}">{esc(words["groups"][group["group"]])}</th></tr>'
                              + "".join(body) + "</tbody>")
        left_out = len(self.keys) - len(shown)
        shown_url = lambda u: re.sub(r"^https?://(www\.)?", "", u)
        source_list = "".join(f'<li id="s{i}"><a href="{esc(u)}">{esc(shown_url(u))}</a></li>'
                              for i, u in enumerate(sources, 1))

        theirs_win = "".join(f"<li>{esc(x)}</li>" for x in w["wins"])
        ours_win = "".join(f"<li>{esc(rows_words[k]['label'])}</li>" for k in
                           [k for k in WE_WIN if k in shown and cells[k]["value"] == "no" and self.ours[k]["value"] == "yes"][:WE_WIN_COUNT])
        file_manager = f'<p class="note">{esc(ui["fileManager"])}</p>' if p["category"] == "file-manager" else ""
        title = fill(ui["matrixSeoTitle"], name=name)
        description = fill(ui["matrixDescription"], name=name)
        path_of = lambda lang: self.path(lang, slug)
        url = c["SITE"] + path_of(code)
        crumbs = [("Schnellbild", c["home_path"](code)), (ui["breadcrumb"], self.path(code)), (name, path_of(code))]
        data = c["json_ld"]({"@graph": [
            {"@type": "WebPage", "@id": url, "url": url, "name": title, "description": description, "inLanguage": code,
             "isPartOf": {"@id": c["SITE"] + "/#website"},
             "about": [{"@type": "SoftwareApplication", "@id": c["SITE"] + c["home_path"](code) + "#app", "name": "Schnellbild"},
                       self.program(code, slug)]},
            self.breadcrumbs(code, crumbs)]})
        keywords = fill(ui["keywords"], name=name)
        table = f"""<table class="matrix">
    <caption class="sr">{esc(ui['matrixTitle'])}: Schnellbild, {esc(name)}</caption>
    <thead><tr><th scope="col">{esc(ui['colFeature'])}</th><th scope="col">Schnellbild</th><th scope="col">{esc(name)}</th></tr></thead>
    {''.join(groups)}
  </table>"""
        return c["head"](code, c["tr"][code], title, description, path_of, keywords=keywords, data=data) + \
            c["topbar"](code, c["tr"][code], path_of, sections=False) + f"""
<main class="alt-page">
<div class="wrap alt">
  <nav class="crumbs" aria-label="{esc(ui['breadcrumb'])}"><a href="{self.path(code)}">{esc(ui['breadcrumb'])}</a></nav>
  <h1>{esc(fill(ui['matrixH1'], name=name))}</h1>
  <p class="lead">{esc(fill(ui['matrixLead'], name=name))}</p>
  {self.facts(code, slug)}
  <h2>{esc(fill(ui['aboutTitle'], name=name))}</h2>
  <p>{esc(w['summary'])}</p>
  {file_manager}
  <div class="wins">
    <div><h3>{esc(fill(ui['theyWin'], name=name))}</h3><ul>{theirs_win}</ul></div>
    <div><h3>{esc(ui['weWin'])}</h3><ul>{ours_win}</ul></div>
  </div>
  <figure class="alt-shot">{c['shot'](SECTION_SHOT[p['section']], code, c['tr'][code]['shotAlt'])}</figure>
  <h2 id="matrix">{esc(ui['matrixTitle'])}</h2>
  {self.legend(code)}
  {table}
  <p class="method">{esc(fill(ui['asOf'], name=name, version=w['version'], ours=self.version))}{(' ' + esc(fill(ui['leftOut'], name=name, count=left_out, total=len(self.keys)))) if left_out else ''}</p>
  <h2 class="small">{esc(ui['sources'])}</h2>
  <ol class="sources">{source_list}</ol>
</div>
{self.cta(code)}
{self.tail(code, slug)}
</main>
""" + c["footer"](code, c["tr"][code])

    def switcher_page(self, code, slug):
        c, esc = self.c, self.c["esc"]
        ui, words = self.words[code]["ui"], self.words[code]
        w = words["products"][slug]
        p = self.products[slug]
        name = w["name"]
        cells = p["matrix"]
        shown = self.shown(slug)
        rows_words = words["rows"]
        has = lambda k: k in shown and cells[k]["value"] in ("yes", "partial")
        liked = [k for k in LIKED if has(k) and self.ours[k]["value"] == "yes"][:LIKED_COUNT]
        purpose = [k for k in self.keys if has(k) and self.ours[k]["value"] == "intentional"]
        liked_html = "".join(f'<li><strong>{esc(rows_words[k]["label"])}:</strong> {esc(rows_words[k]["how"])}</li>' for k in liked)
        purpose_html = "".join(f'<li><strong>{esc(rows_words[k]["label"])}:</strong> {esc(rows_words[k]["why"])}</li>' for k in purpose)
        ahead = "".join(f"<li>{esc(x)}</li>" for x in w["wins"])
        joke = fill(words["jokes"][self.kind(slug)], name=name)
        mac_note = f'<p class="note">{esc(w["macNote"])}</p>' if w.get("macNote") else ""
        title = fill(ui["switcherSeoTitle"], name=name)
        description = fill(ui["switcherDescription"], name=name)
        path_of = lambda lang: self.path(lang, slug)
        url = c["SITE"] + path_of(code)
        crumbs = [("Schnellbild", c["home_path"](code)), (ui["breadcrumb"], self.path(code)), (name, path_of(code))]
        data = c["json_ld"]({"@graph": [
            {"@type": "WebPage", "@id": url, "url": url, "name": title, "description": description, "inLanguage": code,
             "isPartOf": {"@id": c["SITE"] + "/#website"},
             "about": [{"@type": "SoftwareApplication", "@id": c["SITE"] + c["home_path"](code) + "#app", "name": "Schnellbild"},
                       self.program(code, slug)]},
            self.breadcrumbs(code, crumbs)]})
        purpose_block = f"<h2>{esc(ui['purposeTitle'])}</h2><ul class=\"how\">{purpose_html}</ul>" if purpose else ""
        return c["head"](code, c["tr"][code], title, description, path_of, keywords=fill(ui["keywords"], name=name), data=data) + \
            c["topbar"](code, c["tr"][code], path_of, sections=False) + f"""
<main class="alt-page">
<div class="wrap alt">
  <nav class="crumbs" aria-label="{esc(ui['breadcrumb'])}"><a href="{self.path(code)}">{esc(ui['breadcrumb'])}</a></nav>
  <h1>{esc(fill(ui['switcherH1'], name=name))}</h1>
  <p class="lead">{esc(joke)}</p>
  {self.facts(code, slug)}
  {mac_note}
  <h2>{esc(fill(ui['aboutTitle'], name=name))}</h2>
  <p>{esc(w['summary'])}</p>
  <h2>{esc(fill(ui['likedTitle'], name=name))}</h2>
  <ul class="how">{liked_html}</ul>
  <figure class="alt-shot">{c['shot'](SECTION_SHOT[self.kind(slug)], code, c['tr'][code]['shotAlt'])}</figure>
  <h2>{esc(fill(ui['aheadTitle'], name=name))}</h2>
  <ul>{ahead}</ul>
  {purpose_block}
</div>
{self.cta(code)}
{self.tail(code, slug)}
</main>
""" + c["footer"](code, c["tr"][code])

    def overview(self, code):
        c, esc = self.c, self.c["esc"]
        ui, words = self.words[code]["ui"], self.words[code]
        sep = ui.get("listSep", ", ")
        by_section = {s: self.ranked(code, [k for k, p in self.products.items() if p["section"] == s]) for s in SECTIONS}
        top = self.ranked(code, list(self.products))[:3]
        title = fill(ui["overviewSeoTitle"], names=sep.join(self.name(code, s) for s in top))
        description = fill(ui["overviewDescription"], count=len(self.products))
        path_of = lambda lang: self.path(lang)
        url = c["SITE"] + path_of(code)
        ranked = self.ranked(code, list(self.products))
        data = c["json_ld"]({"@graph": [
            {"@type": "CollectionPage", "@id": url, "url": url, "name": title, "description": description,
             "inLanguage": code, "isPartOf": {"@id": c["SITE"] + "/#website"},
             "mainEntity": {"@type": "ItemList", "numberOfItems": len(ranked), "itemListElement": [
                 {"@type": "ListItem", "position": i, "url": c["SITE"] + self.path(code, s), "name": self.name(code, s)}
                 for i, s in enumerate(ranked, 1)]}},
            self.breadcrumbs(code, [("Schnellbild", c["home_path"](code)), (ui["breadcrumb"], self.path(code))])]})
        sections = "".join(
            f"""
  <h2 id="{s}">{esc(words['sections'][s])}</h2>
  {f'<p>{esc(ui["overviewNoMac"])}</p>' if s == "windows" else ''}
  {self.page_links(code, by_section[s], "alt-links columns")}"""
            for s in SECTIONS if by_section[s])
        return c["head"](code, c["tr"][code], title, description, path_of, data=data) + \
            c["topbar"](code, c["tr"][code], path_of, sections=False) + f"""
<main class="alt-page">
<div class="wrap alt">
  <h1>{esc(ui['overviewTitle'])}</h1>
  {ui['overviewIntro']}{sections}
  <p class="trademark">{esc(ui['trademarkAll'])}</p>
</div>
{self.cta(code)}
</main>
""" + c["footer"](code, c["tr"][code])

    def top(self, code, count=HOME_COUNT):
        """The most searched programs in this language, for the home page."""
        return self.ranked(code, list(self.products))[:count]

    def pages(self):
        """{file: html} for every page, and the page kinds with their paths for the sitemap."""
        docs = ROOT / "docs"
        out = {}
        kinds = [lambda lang: self.path(lang)]
        for code in self.c["LANGUAGES"]:
            out[docs / self.path(code).lstrip("/") / "index.html"] = self.overview(code)
            for slug, p in self.products.items():
                page = self.matrix_page if p["page"] == "matrix" else self.switcher_page
                out[docs / self.path(code, slug).lstrip("/") / "index.html"] = page(code, slug)
        for slug in self.products:
            kinds.append(lambda lang, slug=slug: self.path(lang, slug))
        return out, kinds
