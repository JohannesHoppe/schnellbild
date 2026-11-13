# Signing: certificates, profiles, secrets

Everything Apple needs to sign Schnellbild, where it lives, when it runs out, and how to make it again. Apple's portal is easy to get wrong; follow the steps in order and let `Scripts/set_signing_secrets.sh` check the files before they go up.

## What there is

| What | Kind (Apple's name) | Used by | GitHub secret (environment `release`) | Runs out |
|---|---|---|---|---|
| DMG: app | Developer ID Application | `release.yml` | `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` | 2027-02-01 |
| DMG: format reader | Provisioning profile "Developer ID" for `art.haushoppe.schnellbild.formatreader` | `release.yml` | `MACOS_PROFILE_FORMATREADER` | with its certificate |
| DMG: notarization | App Store Connect API key (.p8) | `release.yml`, `mac-release.yml` | `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | never (until revoked) |
| Store: app and extensions | Apple Distribution | `appstore.yml` | `APPSTORE_APP_P12`, `APPSTORE_CERT_PASSWORD` | 2027-11-12 |
| Store: installer package | Mac Installer Distribution (shows as "3rd Party Mac Developer Installer") | `appstore.yml` | `APPSTORE_INSTALLER_P12` (same password) | 2027-11-12 |
| Store: profiles | 3 × "Mac App Store Connect" for `art.haushoppe.schnellbild`, `.thumbnails`, `.formatreader` | `appstore.yml` | `APPSTORE_PROFILE_APP`, `APPSTORE_PROFILE_THUMBNAILS`, `APPSTORE_PROFILE_FORMATREADER` | 2027-11-12 |

All secrets are in the GitHub environment `release` (only `main` and tags `v*` get them). Team ID `87884AP46G`. The App IDs (developer.apple.com → Identifiers) don't run out.

A profile contains the certificate it was made for. **A new certificate always needs new profiles**, made with that certificate.

## Rules that save hours

- **One signing request per certificate.** Two certificates made from the same `.certSigningRequest` share one private key, and Keychain Access then exports the same certificate for both (the Store package failed for exactly that). If it happened anyway: `Scripts/set_signing_secrets.sh p12 <cert>.cer <other>.p12 <new>.p12` makes the right .p12 from the downloaded certificate and that key.
- **A .p12 is made, not downloaded:** download the `.cer`, double-click it (it pairs with its key in the keychain), then export it from Keychain Access as .p12.
- **Export from "My Certificates"**, the certificate's line (with the ▸ and the key under it), and check the name in the export dialog before saving.
- The installer certificate is called "3rd Party Mac Developer Installer: …" in the keychain, not "Mac Installer Distribution".
- Don't double-click profiles; they are only uploaded.
- The script checks every file by its content (certificate name and team, App ID, profile made for that certificate) and uploads nothing if one is wrong.

## Making the Mac App Store files again (before 2027-11-12)

In the browser (developer.apple.com) and Keychain Access, macOS in English.

1. **Two signing requests.** Keychain Access → menu Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority… → your Apple account's email, Common Name `Johannes Hoppe`, CA Email empty, "Saved to disk" → save as `distribution.certSigningRequest`. Do it again and save as `installer.certSigningRequest`.
2. **Certificates.** <https://developer.apple.com/account/resources/certificates/list> → "+" → "Apple Distribution" → Continue → choose `distribution.certSigningRequest` → Continue → Download → double-click the `.cer`. Again with "+" → "Mac Installer Distribution" and `installer.certSigningRequest`. Apple allows only a few of each: revoke the old ones there once the new ones work (the app in the Store keeps working).
3. **Export.** Keychain Access → login → My Certificates → right-click "Apple Distribution: Johannes Hoppe (87884AP46G)" → Export … → Personal Information Exchange (.p12) → `distribution.p12`, a password. Same for "3rd Party Mac Developer Installer: Johannes Hoppe (87884AP46G)" → `installer.p12`, **the same password**.
4. **Profiles.** <https://developer.apple.com/account/resources/profiles/list> → "+" → Distribution: "Mac App Store Connect" → Continue → App ID `art.haushoppe.schnellbild` → the new Apple Distribution certificate → name `Schnellbild App Store` → Generate → Download. The same for `art.haushoppe.schnellbild.thumbnails` (`Schnellbild Thumbnails App Store`) and `art.haushoppe.schnellbild.formatreader` (`Schnellbild Formats App Store`). (Or edit the existing profiles, pick the new certificate, save, download.)
5. **Secrets.** In the folder with the files, in the repository's checkout or with its path:
   ```bash
   Scripts/set_signing_secrets.sh appstore distribution.p12 installer.p12 \
     Schnellbild_App_Store.provisionprofile \
     Schnellbild_Thumbnails_App_Store.provisionprofile \
     Schnellbild_Formats_App_Store.provisionprofile
   ```
6. **Check.** `gh workflow run appstore.yml`: the log shows "Signing for the Mac App Store with: Apple Distribution: …" and "Signing product with identity "3rd Party Mac Developer Installer: …"".
7. Put the .p12 files and the password into the password manager; delete the rest.

## Making the Developer ID files again (before 2027-02-01)

1. One new signing request (as above) → developer.apple.com → Certificates → "+" → "Developer ID Application" (the "G2 Sub-CA" one) → Download → double-click → export from My Certificates as `developer_id.p12`.
2. Profiles → the format reader's Developer ID profile (`art.haushoppe.schnellbild.formatreader`, type "Developer ID") → Edit → the new certificate → Save → Download. (Without it the DMG ships the format reader unsigned for its entitlement, and macOS won't run it.)
3. `Scripts/set_signing_secrets.sh developer-id developer_id.p12 <formatreader-developer-id>.provisionprofile`
4. The next release signs with it. Check the release run's log ("Signing with: Developer ID Application: …") and that `mac-release.yml` attaches the notarized DMG.

The notarization key (`NOTARY_KEY_*`) doesn't run out. If it is ever revoked: App Store Connect → Users and Access → Integrations → App Store Connect API → a new "Developer" key, then `gh secret set NOTARY_KEY_P8 --env release -R JohannesHoppe/schnellbild < AuthKey_<ID>.p8` and the same for `NOTARY_KEY_ID` (`--body <ID>`) and `NOTARY_ISSUER_ID` (the issuer ID shown on that page).

## Agreements

App Store Connect → Business: the "Paid Apps" agreement needs the tax form (W-8BEN for a person in Germany: line 6a the 11-digit tax identification number; treaty article 12(1), 0 %, "Income from the sale of applications") and the bank account. Apple asks to accept new versions of the agreements from time to time; until they are accepted, uploads or sales stop.
