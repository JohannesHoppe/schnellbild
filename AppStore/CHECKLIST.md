# Mac App Store: what is ready, what is left

Schnellbild's App Store variant is the same app as the DMG, built differently (`SCHNELLBILD_APPSTORE=1 Scripts/build_app.sh`, workflow `appstore.yml`):

| | DMG (GitHub Releases) | Mac App Store |
|---|---|---|
| VLCKit | VideoLAN's binary (LGPL, 8 modules GPL) | built by us without the GPL modules (`Scripts/build_vlckit_lgpl.sh`) |
| App Sandbox | no (Hardened Runtime) | yes: app and both extensions |
| Folders | every folder | folders the user chooses or drops, kept across launches (`FolderAccess`); Pictures, Movies, Downloads without asking |
| Signing | Developer ID, notarized | Apple Distribution, installer package |
| License agreement | MIT, LICENSE | custom EULA (`AppStore/EULA.md`) |

## Ready (in this repository)

- [x] VLCKit 3.6.0 without GPL modules: 235 modules, all LGPL; all unit tests pass with it (every video format gives a frame).
- [x] Folder access in the sandbox: grants as security-scoped bookmarks, "Allow Access…" for a folder outside them, Settings → Folder access to forget them. Outside the sandbox nothing changes.
- [x] Entitlements: `AppStore/Schnellbild.entitlements`, `AppStore/SchnellbildThumbnails.entitlements`, `FormatReader/FormatReader.entitlements`.
- [x] Privacy manifest `AppStore/PrivacyInfo.xcprivacy`: no tracking, no data collected; reasons for settings, file dates, time since boot.
- [x] Build, signing, installer package: `Scripts/build_app.sh`, `Scripts/sign_appstore.sh`, `Scripts/package_appstore.sh`; CI `appstore.yml` (UI tests in the sandbox on macOS 15 and 26, then the package).
- [x] About window: in the App Store build it names the VLCKit built without GPL modules and where its build is; THIRD-PARTY-NOTICES.md describes that build and offers its source.
- [x] EULA draft: `AppStore/EULA.md`.

## For Johannes (Apple Developer account, App Store Connect)

1. **Agreements:** App Store Connect → Business: accept the Paid Apps Agreement, enter tax forms and bank account (needed for a paid app).
2. **Certificates** (developer.apple.com → Certificates): "Apple Distribution" (or "Mac App Distribution") and "Mac Installer Distribution". Export each with its private key as .p12, same password.
3. **App IDs:** `art.haushoppe.schnellbild` and `art.haushoppe.schnellbild.thumbnails` (the format reader's `art.haushoppe.schnellbild.formatreader` exists, with its Media Extension capability).
4. **Provisioning profiles**, type "Mac App Store Connect" (distribution), one per App ID: app, thumbnails, format reader.
5. **GitHub secrets** (base64 for files): `APPSTORE_APP_P12`, `APPSTORE_INSTALLER_P12`, `APPSTORE_CERT_PASSWORD`, `APPSTORE_PROFILE_APP`, `APPSTORE_PROFILE_THUMBNAILS`, `APPSTORE_PROFILE_FORMATREADER`. Then `appstore.yml` builds a signed package (artifact `appstore-package`).
6. **App record** in App Store Connect: name (Schnellbild, if free), primary language, bundle ID `art.haushoppe.schnellbild`, SKU, category Photography, price (e.g. tier for 0.99 €/1 €).
7. **Metadata:** description, keywords, screenshots (1280×800 up to 2880×1800; the README's are a start), support URL, **privacy policy URL** (required, even with no data collected), age rating, App Privacy: "Data Not Collected".
8. **License agreement:** fill in the address in `AppStore/EULA.md`, have it checked, paste it as custom EULA.
9. **Upload** the package with Transporter, then pick the build in App Store Connect; first TestFlight, then submit for review. Review notes: the app reads only folders the user chooses; no account, no network.

## Open risks

- **VLCKit built with Xcode 16.0** (macOS 15.0 SDK): VLC 3.0's libraries in VLCKit 3.6.0 break with the macOS 26 SDK. Whether App Store Connect accepts an embedded framework built with an older SDK is unknown. The lasting fix is a newer VLCKit (3.7.x: zlib 1.3.x, libpng 1.6.5x), for the DMG too.
- **LGPL and the App Store:** VideoLAN ships LGPL VLC in the App Store; some (the Software Freedom Conservancy) hold the App Store's terms still conflict with copyleft. The custom EULA and the source offer address what the LGPL asks.
- **Disk space API:** VLCKit calls `fstatfs` (whether a file is on a network share). None of Apple's reasons fits; VLC for iOS declares none for it either. If App Store Connect warns (ITMS-91053), the manifest needs an entry.
- **Not yet tried in the sandbox:** network shares chosen in the open panel, F5/F6 between two granted folders, "Open with Default App", the media extension's opt-in. The sandbox UI tests open everything (`Sandbox-UITests.entitlements`); the folder grants themselves need a person at the open panel.
