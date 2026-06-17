# Schnellbild

Ein **schneller** Datei-/Bild-Viewer für macOS. Ordner öffnen, Thumbnails sehen,
ein Bild groß, per Tastatur durchblättern. Mehr nicht — aber das ohne Hängen,
auch über Netzwerk-Volumes.

Entstanden aus dem Frust über Viewer, die übers Netzwerk lahmen, während
**macOS Preview** flüssig bleibt. Schnellbild macht es genau wie Preview:
wenig lesen, parallel laden, aggressiv cachen, nie den UI-Thread blockieren.

## Warum schnell? (Die vier Tricks)

1. **Trittbrett auf das System.** Thumbnails kommen von Apples
   `QLThumbnailGenerator` (QuickLook). Das Framework zieht automatisch
   **eingebettete Previews** (EXIF-Thumbnail, JPEG-im-RAW) — wenige KB statt
   zig MB über Netz — und kann **jedes Format**, das QuickLook kennt (JPEG, PNG,
   HEIC, RAW, PSD, PDF …), inklusive Drittanbieter-Plugins. Der persistente
   Cache liegt im System; wir schreiben **null Cache-Code**.

2. **Lazy & parallel.** Das Grid (`LazyVGrid`) lädt nur sichtbare Kacheln. Das
   System drosselt die Thumbnail-Erzeugung selbst nebenläufig.

3. **Großansicht heruntergerechnet.** Das Vollbild lädt das echte Bild, aber via
   `ImageIO` (`CGImageSourceCreateThumbnailAtIndex`) direkt auf Bildschirmgröße
   gesampelt — kein 8000px-Monster im RAM. Als Platzhalter erscheint sofort das
   schon vorhandene Thumbnail.

4. **Nichts blockiert den Main-Thread.** Verzeichnis-Scan und Voll-Dekodierung
   laufen in `Task.detached`.

## Bauen & Starten

> **Voraussetzung:** vollständiges **Xcode** (nicht nur die Command Line Tools —
> die haben keine macOS-Platform-Metadaten und können SwiftUI nicht bauen).

```bash
# Xcode aktiv schalten (einmalig):
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# Im Projektordner:
swift build
swift run        # startet die App
# …oder in Xcode öffnen:
open Package.swift
```

## Tastatur

| Taste | Im Grid | In der Großansicht |
|---|---|---|
| ← / ↑ | vorheriges Bild | vorheriges Bild |
| → / ↓ | nächstes Bild | nächstes Bild |
| Leertaste | öffnen | nächstes Bild |
| Return | öffnen | zurück zum Grid |
| Esc | — | zurück zum Grid |
| Pos1 / Ende | erstes / letztes Bild | — |
| ⌘O | Ordner öffnen | Ordner öffnen |

## Status

**MVP / früher Stand.** Open Folder → Thumbnail-Grid → Großansicht →
Tastatur-Navigation steht. Bekannte offene Punkte:

- Tastatur-Fokus in SwiftUI ist erfahrungsgemäß zickig — muss auf echtem Gerät
  feinjustiert werden.
- Noch keine `.app`-Bundle-Verpackung, kein Icon, keine Sandbox-Entitlements.
- Grid-Navigation per ↑/↓ springt aktuell ±1 (nicht zeilenweise).

## Lizenz

TBD.
