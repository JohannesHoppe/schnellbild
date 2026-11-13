# Mac App Store: what is ready, what is left

One app, two ways out: free as the DMG on GitHub Releases, and for 0,99 € in the Mac App Store for those who want to support the project. Both are the same build (`Scripts/build_app.sh`): in the App Sandbox, with VLCKit built without VLC's GPL modules. Only the signature differs (`Scripts/sign_app.sh`): Developer ID and notarization for the DMG, Apple Distribution and an installer package for the App Store (workflow `appstore.yml`).

## Ready (in this repository)

- [x] VLCKit 3.7.5 without GPL modules (`Scripts/build_vlckit_lgpl.sh`, workflow `vlckit-lgpl.yml`, published as a pre-release, fetched by `Scripts/fetch_vlckit.sh`): 192 modules, all LGPL, none for network, playlists or stream output; all unit tests pass with it.
- [x] App Sandbox for the app and both extensions (`Sandbox/`); all UI tests run the app in it.
- [x] Folder access: grants as security-scoped bookmarks, "Allow Access…" for a folder outside them, Settings → Folder access to forget them.
- [x] Privacy manifests, one per bundle (`build_app.sh` puts them in): the app (`Sandbox/PrivacyInfo.xcprivacy`), the thumbnail extension (`Sandbox/Thumbnails.xcprivacy`), the media extension (`Sandbox/Formats.xcprivacy`), VLCKit.framework (`Sandbox/VLCKit.xcprivacy`). No tracking, no data collected; the reasons for UserDefaults, file timestamps, system boot time and disk space (VLCKit's `fstatfs`).
- [x] Toolchain keys in every Info.plist (`DTXcode`, `DTSDKName`, `BuildMachineOSBuild` …), written by `build_app.sh` from the Xcode it builds with, as Xcode does; an App Store build without a full Xcode stops.
- [x] Export compliance key: `ITSAppUsesNonExemptEncryption` = false in `Resources/Info.plist` (see "Export compliance" below).
- [x] App Store signing and installer package: `Scripts/sign_app.sh` (checks each profile against the entitlements first), `Scripts/package_appstore.sh`, workflow `appstore.yml` (upload with `altool --upload-package`, the app's Apple ID in `AppStore/metadata/app.json`).
- [x] About window and THIRD-PARTY-NOTICES.md describe the VLCKit build and offer its source; the About window credits the libraries inside VLCKit (FFmpeg and others) and links the privacy policy in the UI's language. `build_app.sh` copies the licenses of VLCKit's libraries into `Contents/Resources/Licenses/VLCKit-libraries` when `Vendor/VLCKit-licenses` is there.
- [x] License agreement: `AppStore/EULA.md`, with Apple's minimum terms, the LGPL's rights for VLCKit and the address of the legal notice.
- [x] Store texts in German and English (name, subtitle, promotional text, description, keywords, What's New, review notes): `AppStore/metadata/`, put into App Store Connect by `Scripts/appstore_connect.swift` (`appstore.yml -f metadata=true`). No trademarks of others, no prices, no other places to get the app.
- [x] Privacy policy: on the website, per language (https://schnellbild.haushoppe-its.de/privacy/, https://schnellbild.haushoppe-its.de/de/datenschutz/).
- [x] Screenshots, 2880 × 1800: `AppStore/screenshots/de` and `en` (made by `Scripts/make_store_screenshots.swift` from `docs/screenshots`).

## For Johannes (Apple Developer account, App Store Connect)

How to make the certificates, profiles and secrets again when they run out: `docs/SIGNING.md`.

1. [x] **Agreements:** App Store Connect → Business: Paid Apps Agreement, tax form, bank account.
2. [x] **DSA trader status** (App Store Connect → Business): declared as a trader, so the app can be offered in the EU; the address and contact details shown on the EU storefronts come from there.
3. [x] **Certificates:** "Apple Distribution" and "Mac Installer Distribution", each exported with its private key as .p12, same password.
4. [x] **App IDs:** `art.haushoppe.schnellbild`, `.thumbnails`, `.formatreader` (the last needs the Media Extension capability; `sign_app.sh` stops if its profile lacks it).
5. [x] **Provisioning profiles**, type "Mac App Store Connect", one per App ID.
6. [x] **GitHub secrets** in the environment `release` (`Scripts/set_signing_secrets.sh appstore …`); `appstore.yml` builds the signed package (artifact `appstore-package`).
7. [x] **App record** in App Store Connect: Schnellbild, bundle ID `art.haushoppe.schnellbild`, Apple ID 6834307395 (in `AppStore/metadata/app.json`).
8. [ ] **Website over HTTPS:** DNS record `schnellbild` CNAME `johanneshoppe.github.io` (DNS only, no proxy in front: GitHub issues the certificate itself), set. On 2026-11-13 GitHub Pages had no certificate for the domain yet (`https://schnellbild.haushoppe-its.de/` fails with a certificate for another name, `gh api repos/JohannesHoppe/schnellbild/pages` shows `"https_certificate": null`). Once GitHub has issued it (if it doesn't within a day: Settings → Pages, remove the custom domain and enter it again), tick "Enforce HTTPS" there and open both privacy URLs above. Apple's review opens them.
9. [ ] **Early TestFlight upload:** `gh workflow run appstore.yml -f upload=true` as soon as the package builds signed, before the texts are final: App Store Connect's checks of the upload (signature, profiles, entitlements, privacy manifests, toolchain keys, ITMS-91053 for a missing API reason) come only with an upload and arrive by email and in App Store Connect → TestFlight. Every upload needs a higher build number (`CFBundleVersion` in `Resources/Info.plist`); the version must be the one in App Store Connect.
10. [ ] **Metadata:** `gh workflow run appstore.yml -f metadata=true` (texts in both languages, screenshots, URLs, categories, copyright, review notes; with `-f upload=true` it picks the build too). What's New (`release_notes.txt`) shows only from the second version on: write it anew for each version.
11. [ ] **Review contact:** the secret `APPSTORE_REVIEW_CONTACT` in the environment `release` (JSON `{"firstName":…,"lastName":…,"phone":…,"email":…}`, kept out of the repository); `appstore_connect.swift` puts it into the review details.
12. [ ] **By hand in App Store Connect, once:**
    - **App Privacy:** "Data Not Collected".
    - **Age rating:** Apple's current questionnaire (with the 13+, 16+ and 18+ ratings and the questions on in-app controls and capabilities): every content question "None", no user-generated content shared with others, no messaging or chat, no unrestricted web access, no advertising, no gambling, no contests. Result: 4+.
    - **Content rights:** "Does your app contain, show, or access third-party content?" No: the app brings no content of its own beyond its interface; it shows only the user's own files.
    - **Export compliance** (asked with the first build unless the Info.plist key answers it): see below.
    - **Availability:** all countries except **China mainland** (an app there needs an ICP filing number, which Schnellbild has none of). **France:** with the encryption exempt (below) no declaration to the ANSSI is needed; App Store Connect asks for one only for non-exempt encryption.
    - **Price:** base country Germany at 0,99 €; the prices of the other countries are set through the App Store Connect API (not by `appstore_connect.swift`).
    - **License agreement:** App Information → License Agreement → custom, the text of `AppStore/EULA.md` (also published on the website). **Read it first**, and have it checked if in doubt; it is a draft, not legal advice.
13. [ ] **Submit:** pick the build in the version, then "Add for Review".

## Export compliance (answer for App Store Connect)

**To confirm by Johannes.** Schnellbild's purpose is showing pictures and videos. Its only cryptography: it decrypts the user's own password-protected ZIP archives (through the system's libarchive) and RAR archives (UnRAR's AES) with the password the user types, to show what is inside. It encrypts nothing, sends nothing and has no network access (App Sandbox without network entitlements); it doesn't use encryption for communication, authentication or copy protection of its own. Cryptography that is not the item's primary function (the decryption of files for viewing) falls under the exemptions of the U.S. Export Administration Regulations (Category 5, Part 2, Note 4), so the app uses no non-exempt encryption: `ITSAppUsesNonExemptEncryption` = false, no documentation to upload, no French declaration. With the key in the Info.plist App Store Connect doesn't ask; if it does anyway, the answer is that the app uses only exempt encryption and needs no export compliance documentation.

## Same bundle ID as the DMG

The DMG (Developer ID) and the App Store version share `art.haushoppe.schnellbild`, so they share the sandbox container (settings, folder grants, saved passwords). Untried: what the App Store does with a DMG copy already in `/Applications` (replace it, or refuse), whether macOS asks before one version opens the container the other made, and which copy's extensions macOS uses when both are on the Mac. Two copies with one bundle ID can confuse Launch Services, so a hint for users (website, FAQ): delete the DMG copy before installing from the App Store.

## Open risks

- **LGPL and the App Store:** VideoLAN ships LGPL VLC in the App Store; some (the Software Freedom Conservancy) hold the App Store's terms still conflict with copyleft. The custom EULA and the source offer address what the LGPL asks.
- **Disk space reason:** VLCKit calls `fstatfs` to tell a network share from a local disk (it buffers more on a share). None of Apple's reasons names that; the manifests declare E174.1 (the app behaves differently, in a way users notice, by what the call reports) as the closest. If the review questions it, the answer is that one.
- **Not yet tried in the sandbox:** network shares chosen in the open panel, F5/F6 between two granted folders, "Open with Default App", the media extension's opt-in. The UI tests open every file to the app (`Sandbox/UITests.entitlements`); the folder grants themselves need a person at the open panel.
