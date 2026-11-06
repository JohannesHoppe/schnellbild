# dmgbuild settings: the DMG window shows the app on the left, the
# Applications folder on the right and an arrow between them
# (Resources/dmg-background*.png, drawn by Scripts/make_dmg_background.swift).
# Called by Scripts/package_dmg.sh from the repository root:
#   dmgbuild -s Installer/dmg-settings.py -D app=build/Schnellbild.app "Schnellbild 1.2.3" dist/Schnellbild.dmg
import os.path

APP = "Schnellbild.app"
app_path = defines.get("app", os.path.join("build", APP))  # noqa: F821 (set by dmgbuild)

format = "UDZO"
filesystem = "HFS+"
files = [app_path]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"
# dmgbuild picks up dmg-background@2x.png next to it for Retina displays
background = "Resources/dmg-background.png"

window_rect = ((200, 160), (600, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {APP: (160, 170), "Applications": (440, 170)}
