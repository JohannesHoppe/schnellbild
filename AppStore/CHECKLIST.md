# Mac App Store: what is ready, what is left

One app, two ways out: free as the DMG on GitHub Releases, and for 1 € in the Mac App Store for those who want to support the project. Both are the same build (`Scripts/build_app.sh`): in the App Sandbox, with VLCKit built without VLC's GPL modules. Only the signature differs (`Scripts/sign_app.sh`): Developer ID and notarization for the DMG, Apple Distribution and an installer package for the App Store (workflow `appstore.yml`).

## Ready (in this repository)

- [x] VLCKit 3.7.5 without GPL modules (`Scripts/build_vlckit_lgpl.sh`, workflow `vlckit-lgpl.yml`, published as a pre-release, fetched by `Scripts/fetch_vlckit.sh`): 236 modules, all LGPL; all unit tests pass with it.
- [x] App Sandbox for the app and both extensions (`Sandbox/`); all UI tests run the app in it.
- [x] Folder access: grants as security-scoped bookmarks, "Allow Access…" for a folder outside them, Settings → Folder access to forget them.
- [x] Privacy manifest `Sandbox/PrivacyInfo.xcprivacy`: no tracking, no data collected.
- [x] App Store signing and installer package: `Scripts/sign_app.sh`, `Scripts/package_appstore.sh`, workflow `appstore.yml`.
- [x] About window and THIRD-PARTY-NOTICES.md describe the VLCKit build and offer its source.
- [x] EULA draft: `AppStore/EULA.md`.
- [x] Store texts in German and English (name, subtitle, promotional text, description, keywords, review notes): `AppStore/metadata/`, put into App Store Connect by `Scripts/appstore_connect.swift` (`appstore.yml -f metadata=true`).
- [x] Privacy policy: `PRIVACY.md` (URL: https://github.com/JohannesHoppe/schnellbild/blob/main/PRIVACY.md).
- [x] Screenshots, 2880 × 1800: `AppStore/screenshots/de` and `en` (made by `Scripts/make_store_screenshots.swift` from `docs/screenshots`).

## For Johannes (Apple Developer account, App Store Connect)

Steps 1–5 are done (2026-11-13; the signed package builds). How to make the certificates, profiles and secrets again when they run out: `docs/SIGNING.md`.

1. [x] **Agreements:** App Store Connect → Business: Paid Apps Agreement, tax form, bank account.
2. [x] **Certificates:** "Apple Distribution" and "Mac Installer Distribution", each exported with its private key as .p12, same password.
3. [x] **App IDs:** `art.haushoppe.schnellbild`, `.thumbnails`, `.formatreader`.
4. [x] **Provisioning profiles**, type "Mac App Store Connect", one per App ID.
5. [x] **GitHub secrets** in the environment `release` (`Scripts/set_signing_secrets.sh appstore …`); `appstore.yml` builds the signed package (artifact `appstore-package`).
6. **App record** in App Store Connect: name (Schnellbild, if free), primary language, bundle ID `art.haushoppe.schnellbild`, SKU, category Photography, price (e.g. tier for 0.99 €/1 €).
7. **Metadata:** `gh workflow run appstore.yml -f metadata=true` (texts in both languages, screenshots, URLs, categories, copyright, review notes). By hand, once: App Privacy "Data Not Collected", age rating 4+, price, review contact.
8. **License agreement:** fill in the address in `AppStore/EULA.md`, have it checked, paste it as custom EULA.
9. **Upload:** `gh workflow run appstore.yml -f upload=true` (the version in App Store Connect must equal the app's, e.g. 0.9.0; every upload needs a higher build number, `CURRENT_PROJECT_VERSION` / `CFBundleVersion`), then pick the build in App Store Connect; first TestFlight, then submit for review. Review notes: the app reads only folders the user chooses; no account, no network.

## Open risks

- **LGPL and the App Store:** VideoLAN ships LGPL VLC in the App Store; some (the Software Freedom Conservancy) hold the App Store's terms still conflict with copyleft. The custom EULA and the source offer address what the LGPL asks.
- **Disk space API:** VLCKit calls `fstatfs` (whether a file is on a network share). None of Apple's reasons fits; VLC for iOS declares none for it either. If App Store Connect warns (ITMS-91053), the manifest needs an entry.
- **Not yet tried in the sandbox:** network shares chosen in the open panel, F5/F6 between two granted folders, "Open with Default App", the media extension's opt-in. The UI tests open every file to the app (`Sandbox/UITests.entitlements`); the folder grants themselves need a person at the open panel.
- **The same bundle ID in both:** the DMG (Developer ID) and the App Store version (Apple's signature) share `art.haushoppe.schnellbild` and so the container. Whether macOS asks before one opens the container the other made is untried.
