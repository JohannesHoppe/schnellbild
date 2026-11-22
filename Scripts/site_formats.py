"""The formats pages of the website (/formats/, /de/formate/ …) and the format
names in the home page's texts, from one list: site/formats.json.

site/formats.json holds every format the app shows, in the order the page
shows them: its id (the row's anchor), group (the table's sections), kind
(picture, document, video, archive), the full name, the abbreviation, the
extensions, macOS's type identifier where macOS declares one (`uti`) and
notes (keys into the language's `formats.notes`). Entries with `parts` are
the volumes of split archives: shown, though the app reads their later
parts only through the first. The names macOS itself gives the types, in
every language, are in site/formats-macos.json (Scripts/format_names.sh).
The words are `formats` in site/i18n/<lang>.json.

`{fmt:<id>}` in a text of site/i18n becomes the format's name in the style
the language writes it ("Graphics Interchange Format (GIF, .gif)"), linked to
its row on the language's formats page; `{formats}` is that page's address.

The list is held to what the app shows: FormatListTests (Swift, the app's
own sets on the running macOS) and `app_extensions` here (the same sets read
from the Swift sources, for build_site.py and Scripts/tests). build_site.py
also fails when the README's format tables leave an extension out.

    python3 Scripts/site_formats.py readme   # the README's format tables, from the list
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIST = ROOT / "site" / "formats.json"
MACOS = ROOT / "site" / "formats-macos.json"
GROUPS = ["photo", "pro", "texture", "document", "raw", "video", "archive"]
KINDS = ["picture", "document", "video", "archive"]


def load():
    formats = json.loads(LIST.read_text(encoding="utf-8"))["formats"]
    macos = json.loads(MACOS.read_text(encoding="utf-8"))["names"]
    return formats, macos


def last_extension(ext):
    """"zip.001" is a ".001", "part1.rar" a ".rar"."""
    return ext.rsplit(".", 1)[-1]


def listed_extensions(formats):
    """Every extension the list names, as the app sees it (the last one)."""
    return {last_extension(ext) for f in formats for ext in f["ext"]}


def shown_abbr(f):
    """The abbreviation, where it says more than the extensions: "AVCHD" for .mts .m2ts.
    Left out where it is the extension in capitals ("GIF", "TIFF" beside .tiff) or
    names only extensions ("HEIF / HEIC"); a hyphen stays part of it, "MPEG-PS" isn't .mpeg."""
    abbr = f.get("abbr")
    if not abbr:
        return None
    extensions = {ext.casefold() for ext in f["ext"]}
    parts = [part for part in re.split(r"[\s/]+", abbr.casefold()) if part]
    return None if all(part in extensions for part in parts) else abbr


def _strings(block):
    return set(re.findall(r'"([^"\\]+)"', block))


def _declaration(source, name):
    """The string literals of `static let <name> … = [ … ]` (a Set's or a dictionary's keys)."""
    match = re.search(r"static let " + name + r"\b[^=]*=\s*(?:Set<String>\()?\[(.*?)\n?\s*\]", source, re.S)
    if not match:
        sys.exit(f"site_formats.py: no {name} in the Swift sources")
    return re.sub(r"//.*", "", match.group(1))


def app_extensions(root=ROOT):
    """The extensions the app shows a file by, read from its Swift sources, with
    their kind: picture, video or archive. The ones only some macOS versions'
    ImageIO reads count as shown (the list notes the version)."""
    model = (root / "Schnellbild" / "BrowserModel.swift").read_text(encoding="utf-8")
    decoders = (root / "Schnellbild" / "PictureDecoders.swift").read_text(encoding="utf-8")
    previews = (root / "Schnellbild" / "EmbeddedPreview.swift").read_text(encoding="utf-8")
    archives = (root / "Schnellbild" / "Archives.swift").read_text(encoding="utf-8")
    pictures = (_strings(_declaration(model, "imageExtensions")) | _strings(_declaration(model, "systemImageExtensions"))
                | _strings(_declaration(decoders, "ownExtensions")) | _strings(_declaration(decoders, "librawOnly"))
                | _strings(_declaration(previews, "postScriptExtensions")) | {"ai"})
    zip_documents = re.search(r"static let zipEntries[^=]*=\s*\[(.*?)\n    \]", previews, re.S).group(1)
    pictures |= set(re.findall(r'^\s*"([a-z0-9]+)":', zip_documents, re.M))
    videos = _strings(_declaration(model, "videoExtensions")) | {"ts"}
    archive = set(re.findall(r'"([a-z0-9]+)":\s*\.', _declaration(archives, "formats"))) | {"001"}
    kinds = {ext: "picture" for ext in pictures}
    kinds.update({ext: "video" for ext in videos})
    kinds.update({ext: "archive" for ext in archive})
    return kinds


def differences(formats, root=ROOT):
    """What the list and the app disagree on, as lines."""
    app = app_extensions(root)
    problems = [f"formats.json lacks .{ext}, which the app shows" for ext in sorted(set(app) - listed_extensions(formats))]
    for f in formats:
        if f.get("parts"):
            continue
        for ext in f["ext"]:
            kind = app.get(last_extension(ext))
            if kind is None:
                problems.append(f"formats.json: {f['id']} lists .{ext}, which the app doesn't show")
            elif kind != ("picture" if f["kind"] == "document" else f["kind"]):
                problems.append(f"formats.json: {f['id']} is a {f['kind']}, the app shows .{ext} as a {kind}")
    return problems


def readme_section(text):
    """The README's "Supported file formats" section."""
    match = re.search(r"^### Supported file formats\n(.*?)(?=^## )", text, re.S | re.M)
    return match.group(1) if match else ""


def readme_missing(formats, text):
    """The extensions the README's format tables don't name (as `.ext`)."""
    section = readme_section(text)
    return [ext for f in formats for ext in f["ext"] if f"`.{ext}`" not in section]


# Notes the README says elsewhere (the Finder previews, the archives' section)
README_SKIPS = {"thumbnails", "mediaExtension", "password", "rar", "sevenZip", "parts"}


def readme_tables(formats, words):
    """The README's tables: per group a row, each format as "Full name (`.ext`; note)",
    with the abbreviation first where it says more than the extensions ("(AVCHD, `.mts` …")."""
    def item(f):
        exts = " ".join(f"`.{ext}`" for ext in f["ext"])
        notes = "".join(f"; {words['notes'][n]}" for n in f.get("notes", []) if n not in README_SKIPS)
        name = words["names"].get(f["id"]) or f["name"]
        abbr = shown_abbr(f)
        return f"{name} ({abbr}, {exts}{notes})" if abbr and abbr != name else f"{name} ({exts}{notes})"
    lines = []
    for group in GROUPS:
        members = [f for f in formats if f["group"] == group]
        lines.append(f"| {words['groups'][group]} | " + ", ".join(item(f) for f in members) + " |")
    return "\n".join(lines)


class Formats:
    """The formats pages, given the build's helpers (as site_alternatives.Alternatives)."""

    def __init__(self, ctx):
        self.ctx = ctx
        self.formats, self.macos = load()
        self.by_id = {f["id"]: f for f in self.formats}
        missing = ctx["missing"]
        for f in self.formats:
            if f["group"] not in GROUPS or f["kind"] not in KINDS:
                missing.append(f"formats.json: {f['id']} has an unknown group or kind")
        for code in ctx["LANGUAGES"]:
            w = ctx["tr"][code]["formats"]
            for f in self.formats:
                if not (f.get("name") or w["names"].get(f["id"])):
                    missing.append(f"formats {code}: no name for {f['id']}")
                for note in f.get("notes", []):
                    if note not in w["notes"]:
                        missing.append(f"formats {code}: notes.{note}")
            for where, text in self.texts(w):
                if re.search("[–—]", text):
                    missing.append(f"formats {code}: {where} has an em or en dash (see Working conventions)")
        for uti, names in self.macos.items():
            for code, name in names.items():
                if re.search("[–—]", name):
                    missing.append(f"formats-macos.json: {uti} in {code} has an em or en dash")

    @staticmethod
    def texts(words, where="formats"):
        if isinstance(words, dict):
            for key, value in words.items():
                yield from Formats.texts(value, f"{where}.{key}")
        elif isinstance(words, list):
            for i, value in enumerate(words):
                yield from Formats.texts(value, f"{where}[{i}]")
        else:
            yield where, str(words)

    def path(self, code):
        t = self.ctx["tr"][code]
        return "/" + self.ctx["folder"](code) + t["formatsSlug"] + "/"

    def name(self, code, f):
        return self.ctx["tr"][code]["formats"]["names"].get(f["id"]) or f["name"]

    def label(self, code, f, ext_html=False):
        """The format's name with its extensions (and its abbreviation where it says more
        than they do), as the language writes it."""
        esc = self.ctx["esc"]
        w = self.ctx["tr"][code]["formats"]
        name, abbr = self.name(code, f), shown_abbr(f)
        exts = " ".join((f"<code>.{esc(e)}</code>" if ext_html else f".{esc(e)}") for e in f["ext"])
        style = w["nameStyle"] if abbr and abbr != name else w["nameStyleBare"]
        return style.replace("{name}", esc(name)).replace("{abbr}", esc(abbr or "")).replace("{ext}", exts)

    def links(self, code, text):
        """{fmt:<id>} in a text becomes the linked name of that format."""
        def link(match):
            f = self.by_id.get(match.group(1))
            if not f:
                self.ctx["missing"].append(f"{code}: no format {match.group(1)} (site/formats.json)")
                return match.group(0)
            return f'<a href="{self.path(code)}#{f["id"]}">{self.label(code, f)}</a>'
        return re.sub(r"\{fmt:([A-Za-z0-9]+)\}", link, text).replace("{formats}", self.path(code))

    def row_name(self, code, f):
        """The name in the table: with the abbreviation where it says more than the
        extensions, in the language's brackets ("… High Definition (AVCHD)")."""
        esc = self.ctx["esc"]
        name, abbr = self.name(code, f), shown_abbr(f)
        if not abbr or abbr == name:
            return esc(name)
        return self.ctx["tr"][code]["formats"]["nameStyleBare"].replace("{name}", esc(name)).replace("{ext}", esc(abbr))

    def macos_name(self, code, f):
        """macOS's own name of the type in the language, unless it only repeats the name or
        abbreviation, or macOS has no translation of it (the English name on another page)."""
        names = self.macos.get(f.get("uti", ""), {})
        name = names.get(code)
        if not name or name.casefold() in {self.name(code, f).casefold(), (f.get("abbr") or "").casefold()}:
            return None
        if code != "en" and name == names.get("en"):
            return None
        return name

    def counts(self):
        return len(self.formats), len({ext for f in self.formats for ext in f["ext"]})

    def table(self, code):
        esc = self.ctx["esc"]
        w = self.ctx["tr"][code]["formats"]
        columns = w["columns"]
        head = "".join(f'<th scope="col">{esc(c)}</th>' for c in columns)
        bodies = []
        for group in GROUPS:
            rows = []
            for f in (f for f in self.formats if f["group"] == group):
                macos = self.macos_name(code, f)
                macos = f'<small>{esc(w["macos"].replace("{name}", macos))}</small>' if macos else ""
                exts = " ".join(f"<code>.{esc(e)}</code>" for e in f["ext"])
                notes = "; ".join(esc(w["notes"][n]) for n in f.get("notes", []))
                cells = [(columns[1], exts), (columns[2], esc(w["kinds"][f["kind"]])), (columns[3], notes)]
                empty = ' class="empty"'
                # The value in a span of its own: on phones the cell is a grid of the label and the value
                tds = "".join(f'<td data-label="{esc(label)}"{"" if value else empty}><span>{value}</span></td>' for label, value in cells)
                rows.append(f'<tr id="{f["id"]}"><th scope="row">{self.row_name(code, f)}{macos}</th>{tds}</tr>')
            bodies.append(f'<tbody><tr class="group"><th colspan="{len(columns)}" scope="colgroup" id="{group}">{esc(w["groups"][group])}</th></tr>'
                          + "".join(rows) + "</tbody>")
        return (f'<table class="formats" id="formats-table"><caption class="sr">{esc(w["title"])}</caption>'
                f'<thead><tr>{head}</tr></thead>' + "".join(bodies) + "</table>")

    def data(self, code, url):
        ctx = self.ctx
        t = ctx["tr"][code]
        w = t["formats"]
        home = ctx["SITE"] + ctx["home_path"](code)
        items = []
        for i, f in enumerate(self.formats, 1):
            abbr, macos = shown_abbr(f), self.macos_name(code, f)
            term = {"@type": "DefinedTerm", "@id": f"{url}#{f['id']}", "name": self.name(code, f),
                    "alternateName": ([abbr] if abbr else []) + [f".{e}" for e in f["ext"]] + ([macos] if macos else []),
                    "description": w["groups"][f["group"]], "inDefinedTermSet": {"@id": url + "#formats"}}
            items.append({"@type": "ListItem", "position": i, "item": term})
        page = {"@type": "WebPage", "@id": url, "url": url, "name": w["title"], "description": w["description"],
                "inLanguage": code, "isPartOf": {"@id": ctx["SITE"] + "/#website"}, "about": {"@id": home + "#app"},
                "breadcrumb": ctx["breadcrumb_list"]([("Schnellbild", home), (w["short"], url)]),
                "mainEntity": {"@type": "DefinedTermSet", "@id": url + "#formats", "name": w["title"], "hasDefinedTerm": [i["item"] for i in items]}}
        return ctx["json_ld"](page)

    def page(self, code):
        ctx = self.ctx
        esc, t = ctx["esc"], ctx["tr"][code]
        w = t["formats"]
        url = ctx["SITE"] + self.path(code)
        count, extensions = self.counts()
        lead = w["lead"].replace("{count}", str(count)).replace("{extensions}", str(extensions))
        jump = "".join(f'<li><a href="#{g}">{esc(w["groups"][g])}</a></li>' for g in GROUPS)
        path_of = self.path
        return ctx["head"](code, t, w["seoTitle"], w["description"], path_of, share_title=w["title"],
                           keywords=w["keywords"], data=self.data(code, url)) + ctx["topbar"](code, t, path_of, sections=False) + f"""
<main class="wrap formats-page">
  <p class="crumbs"><a href="{ctx['home_path'](code)}">Schnellbild</a> › {esc(w['short'])}</p>
  <h1>{esc(w['title'])}</h1>
  <p class="lead">{esc(lead)}</p>
  <nav aria-label="{esc(w['jump'])}"><ul class="alt-links">{jump}</ul></nav>
  {self.table(code)}
  <p class="after">{esc(w['after'])}</p>
  <div class="actions"><a class="button primary" href="{ctx['DMG']}">{esc(t['download'])}<small>Schnellbild.dmg</small></a></div>
</main>
""" + ctx["footer"](code, t)

    def pages(self):
        ctx = self.ctx
        pages = {}
        for code in ctx["LANGUAGES"]:
            html = self.page(code)
            for f in self.formats:
                for ext in f["ext"]:
                    if f"<code>.{ext}</code>" not in html:
                        ctx["missing"].append(f"formats {code}: the page doesn't show .{ext}")
            pages[ctx["DOCS"] / ctx["folder"](code) / ctx["tr"][code]["formatsSlug"] / "index.html"] = html
        return pages


if __name__ == "__main__" and sys.argv[1:] == ["readme"]:
    formats, _ = load()
    words = json.loads((ROOT / "site" / "i18n" / "en.json").read_text(encoding="utf-8"))["formats"]
    print(readme_tables(formats, words))
