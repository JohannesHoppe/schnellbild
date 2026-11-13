# App Store texts

What the App Store shows, one file per field and language (`en-US` is the primary language, `de-DE` the second). `Scripts/appstore_connect.swift` puts them into App Store Connect: `gh workflow run appstore.yml -f metadata=true` (also with `-f upload=true`, then it waits for the build and picks it for the version).

- `<locale>/name.txt` (30 characters), `subtitle.txt` (30), `promotional_text.txt` (170, can change without a new version), `description.txt` (4000), `keywords.txt` (100, commas count, no other apps or brands), `release_notes.txt` ("What's New", 4000, for every version but the first in the Store: write it anew for each version), `marketing_url.txt`, `privacy_url.txt`, `support_url.txt` (the page in that language; without the file the URL in `app.json`).
- The texts name no other apps, trademarks, prices or other places to get the app (Apple's App Review Guidelines on metadata).
- `review_notes.txt`: the notes for Apple's review (English, 4000): sandbox entitlements, how to try it, sample files, the boss key.
- `app.json`: bundle ID, categories, copyright, the URLs for a language without its own, where the screenshots are (`AppStore/screenshots/<lang>`, 2880 × 1800, made by `Scripts/make_store_screenshots.swift`).

The version is the app's own (`Resources/Info.plist`). Set by hand once in App Store Connect, not by the script: App Privacy ("Data Not Collected"), age rating (4+, every question "None"/"No"), price (base country Germany at 0,99 €, the other countries' prices set through the API), the license agreement (`AppStore/EULA.md`), and the review contact. The app is the same as the free DMG; the price is there for those who want to support the project.
