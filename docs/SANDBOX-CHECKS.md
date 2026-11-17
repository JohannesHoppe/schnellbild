# Checks by hand before a release

The UI tests on CI run the app as it ships, in the App Sandbox with the entitlements of `Sandbox/Schnellbild.entitlements` (`Scripts/check_entitlements.sh`), and grant their folders through the open panel. What a hosted runner can't do is checked by hand on a real Mac, with the build that goes out (a TestFlight or App Store build for the Store, the notarized DMG for the website), before each release. Each item: what to do, what must happen.

## Use My Location

1. Sort by distance (⌘6) with no place chosen yet: the sheet opens; click Use My Location.
2. macOS asks once whether Schnellbild may use the location; allow it.
3. The field gets the Mac's coordinates and the town nearby; the grid sorts by distance from there.
4. Deny it in System Settings → Privacy & Security → Location Services and try again: the sheet says "Schnellbild may not use your location …", nothing else happens.

## Archive passwords in the keychain

1. Open an archive with a password (`UITests/Fixtures/rar/photos-psw.rar`, password `secret`), type it, quit.
2. Open the app again and the archive: it opens without asking.
3. Keychain Access shows the item under Schnellbild; Settings → General → Forget Saved Passwords… removes it, and the archive asks again.
4. Do it once with the App Store build and once with the DMG: each finds the password it saved.

## A network share (SMB)

1. Connect a share in the Finder, open a folder on it with Open Folder…, browse, rename a file, move one to the Trash and undo that (the context menu).
2. Quit, disconnect the share, open the app: it says the folder isn't available, since its server isn't connected.
3. Connect the share again: the folder opens by itself, without asking for access again.
4. Drop a single photo from the share onto the window: it shows alone with "Allow Access…"; allowing the folder shows its neighbours.

## iCloud Drive

1. Open a folder in iCloud Drive whose files aren't downloaded (Optimize Mac Storage on).
2. Thumbnails appear as the files come down; a photo opens in the full view.
3. Quit and open again: the folder comes back without asking.

## The Photos library and other packages

1. Open the Pictures folder: "Photos Library" is one item, not a folder to walk into.
2. A search or a slideshow of Pictures doesn't go inside it.
