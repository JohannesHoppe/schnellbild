---
name: lektorat
description: Lektorat für alle Texte, die Leute lesen (Website in 20 Sprachen, Alternativen-Seiten, README, App-Store-Texte, EULA, Texte der App). Verwenden, bevor ein solcher Text neu entsteht, übersetzt oder geändert committet wird, und wenn Johannes um ein Lektorat, um „AI-Floskeln prüfen“ oder um eine Bewertung nach seinen Kriterien bittet.
---

# Lektorat für Schnellbild-Texte

Schnellbilds Texte erscheinen unter dem Namen von Johannes Hoppe (HAUS HOPPE - ITS). Sie müssen nach ihm klingen, nicht nach einem Sprachmodell: Wer Modell-Output kennt, erkennt die Muster sofort, und dann kostet der Text Vertrauen. Die Regeln hier sind die Essenz seiner Schreibrichtlinie und Floskel-Liste (Original im Repo haushoppe-its.de: `docs/schreibrichtlinie.md`, `docs/ki-floskeln.md`), zugeschnitten auf Produkttexte in vielen Sprachen.

## So prüfst du

1. **Den ganzen Text lesen**, in der Master-Sprache (Englisch, bei deutschen Texten Deutsch) Satz für Satz.
2. **Suchen** nach den Wörtern und Mustern unten, in jeder Sprache (`grep -i` über die Dateien; für andere Sprachen die Entsprechungen selbst bilden).
3. **Im Kontext bewerten.** Ein Wort ist erst dann eine Floskel, wenn es nichts aussagt. „Die tatsächliche Größe der Datei“ ist Inhalt, „das ist tatsächlich wichtig“ ist Füllung.
4. **Ersetzen** durch die konkrete Aussage, meist kürzer. Bleibt nach dem Streichen nichts übrig, war der Satz überflüssig.
5. **Nachziehen:** Was in der Master-Sprache korrigiert ist, sinngemäß in allen Übersetzungen ändern, dann dort eigene Treffer suchen. Übersetzungen klingen natürlich, nicht Wort für Wort.
6. **Bauen und prüfen:** `python3 Scripts/build_site.py --check` (der Build schlägt bei Gedankenstrichen und beim Mittelpunkt fehl; die Texte der App prüft `LocalizationTests`), JSON gültig, Store-Grenzen eingehalten (`AppStore/metadata/README.md`).

## Harte Regeln

- **Nie „ehrlich“ als Etikett.** Unsere Texte nennen sich nie selbst ehrlich, fair, transparent, offen, aufrichtig, unvoreingenommen. Das Wort „honest“ (und „ehrlich“) schreiben wir nirgends, auch nicht in Überschriften, Entwürfen oder internen Notizen. Das legt nahe, andere Texte von uns seien es nicht. Die Fakten nennen, das Etikett weglassen: „Schnellbild und IINA nebeneinander“, nicht „fair nebeneinander“; „Was IINA besser kann“, nicht „ehrlich gesagt kann IINA …“. Das gilt in jeder Sprache: honest/honestly, fair/fairly, transparent, candid, unbiased; ehrlich, fair, offen gesagt; honnête/franchement, honesto/sinceramente, onesto/sinceramente, eerlijk, uczciwy/szczerze, ärlig, ærlig, rehellinen, upřímný/poctivý, dürüst, честный/честно, чесний/чесно, 正直/率直, 솔직/정직, 诚实/坦白, 誠實/坦白, 公平/公正.
- **Keine Gedankenstriche** (Halbgeviert- und Geviertstrich, U+2013 und U+2014) als Satzzeichen. Stattdessen Punkt, Komma, Doppelpunkt, Semikolon oder Klammer.
- **Kein Mittelpunkt „·“ als Trenner**, weder in Titeln noch in Aufzählungen oder Texten der App. Stattdessen Komma, Semikolon oder ein Zeilenumbruch. Trenner in Titeln ist „|“ („Formate | Schnellbild“). Einzige Ausnahme: der koreanische 가운뎃점 in Aufzählungen (이미지·동영상, ZIP·RAR), ein normales Satzzeichen des Koreanischen.
- **Kein Eigenlob, keine Beteuerung.** Nicht „sorgfältig geprüft“, „gemessen“, „bewiesen“, „belegt“, „nachgeprüft“, „verifiziert“ über die eigene Arbeit. Die Quelle verlinken, das reicht.
- **Keine unbelegten Superlative und keine Zahlen als Schmuck.** Eine Zahl nur, wenn sie stimmt und der Leser sie braucht.
- **Keine Kontrastfigur als Effekt:** „nicht X, sondern Y“, „nicht nur X, sondern auch Y“, „es geht nicht um X“, „Weniger X, mehr Y“, EN „it's not X, it's Y“, „not only … but also“, „rather than“. Sachlich ist sie erlaubt („liest nur, entpackt nichts“).
- **Nicht über andere Programme herziehen.** Vergleiche nennen, was jedes kann; Humor auf den Umsteiger-Seiten gilt dem Wechsel auf den Mac, nie dem alten Programm oder seinen Fans.

## Floskeln (Deutsch und Englisch; in anderen Sprachen die Entsprechungen)

- **Modewörter.** DE: nahtlos, ganzheitlich, umfassend, maßgeschneidert, essenziell, entscheidend, zentral, transformativ, tiefgreifend, wegweisend, bahnbrechend, visionär, disruptiv, skalierbar, präzise, sauber, strukturell; Mehrwert, Synergie, Wechselspiel, Zeugnis, Landschaft, Gamechanger; unterstreichen, verdeutlichen, hervorheben, erschließen, freischalten, ermöglichen, transformieren, eintauchen, auf das nächste Level heben. EN: delve, deep dive, crucial, pivotal, key, robust, seamless, comprehensive, holistic, tailored, meticulous, intricate, vibrant, groundbreaking, renowned; landscape, tapestry, testament, interplay; showcase, underscore, highlight, foster, enhance, bolster, garner, unlock, elevate, empower, streamline, effortless, powerful, blazing.
- **Einstiege, Übergänge, Schlüsse.** „In der heutigen Zeit“, „In einer Welt, in der“, „Egal, ob“, „Darüber hinaus“, „Zudem“, „Es ist wichtig zu beachten“, „Abschließend“, „Letztendlich“, „Kurz gesagt“, „Mit anderen Worten“, „Unterm Strich“; EN „Additionally“, „Moreover“, „It's worth noting“, „In summary“, „Overall“, „Ultimately“, „Whether you're … or …“. Kein Schlusssatz, der wiederholt, was darüber steht.
- **Bild statt Aussage.** „dient als“, „stellt dar“, „fungiert als“, „steht für“, wo „ist“ reicht; EN „serves as“, „stands as“, „represents“. Metaphern, die eine einfache Aussage verpacken („der rote Faden“, „die Brücke schlagen“, „Hand in Hand“). Aufgeblähte Bedeutung („spielt eine zentrale Rolle“, „ist ein Beleg für“).
- **Verstärker und Beteuerungen.** „wirklich“, „tatsächlich“ (als Verstärker), „echt“, „ganz“, „einfach“, „direkt“ (als Beteuerung); EN „really“, „truly“, „simply“, „just“ (als Füllung), „real-world“.
- **Form.** Dreierreihen, deren dritter Teil nur füllt; Spiegelsätze („Du sagst X, wir sagen Y“); gehäufte Spannen „von X bis Y“; Aphorismen als Absatzanfang; Emojis als Gliederung. Listen mit fettem Begriff und Doppelpunkt sind in der README als Nachschlage-Format in Ordnung, auf der Website sparsam.

## Erlaubt und gewollt (kein Befund)

- Johannes' eigene Formulierungen: der Slogan „der einfach nicht nervt / that just doesn't suck“, „Warum Schnellbild nicht nervt“, „Ordner statt Playlists“, die Fineprint mit 🖤, „Die einen schwören auf den Dark Mode, die anderen können ihn nicht ausstehen.“
- „Doch“/„Aber“ als Satzanfang, die rhetorische Frage mit sofortiger Antwort, die Doppelpunkt-Enthüllung („Der Grund: …“), „übrigens“, „keine Sorge“, trockener Humor.
- Die Suchwörter je Sprache in Titeln, Beschreibungen und Keywords (CLAUDE.md, „SEO and ASO per market“): sie bleiben, auch wenn sie sich wiederholen.

## Bericht

Je Befund: Datei und Schlüssel bzw. Zeile, wörtliches Zitat, verletzte Regel, Korrektur. Erst die Master-Sprache, dann die Zahl der Änderungen je Sprache, dann was bewusst stehen blieb und warum.
