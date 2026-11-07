"""dmgbuild 1.6.7 settings; loaded with -D app=... -D background=....

Only Python's standard library is used here. The app's own icon is untouched;
Applications uses the system folder icon. No badge_icons/Pillow extra is needed.
Coordinates match packaging/dmg-background.swift's 680 x 440 point canvas.
"""
from pathlib import Path


if "defines" not in globals():
    raise ValueError("Load these settings with dmgbuild and -D app=... -D background=...")


def required_path(name):
    value = defines.get(name)
    if not isinstance(value, str) or not value:
        raise ValueError(f"Missing -D {name}=... setting")
    path = Path(value)
    if not path.is_absolute() or not path.exists():
        raise ValueError(f"{name} must be an existing absolute path")
    return path


app_path = required_path("app")
background_path = required_path("background")
if not app_path.is_dir() or app_path.name != "MachOView.app":
    raise ValueError("app must be a MachOView.app directory")
if not background_path.is_file():
    raise ValueError("background must be an image file")

# HFS+ and zlib-compressed UDZO are readable on both macOS 15 and macOS 26.
# Let dmgbuild size the filesystem from the bundle rather than guessing a limit.
format = "UDZO"
filesystem = "HFS+"
files = [(str(app_path), "MachOView.app")]
symlinks = {"Applications": "/Applications"}
background = str(background_path)

window_rect = ((160, 120), (680, 440))
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_toolbar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

arrange_by = None
icon_size = 100
text_size = 14
label_pos = "bottom"
show_icon_preview = False
icon_locations = {"MachOView.app": (170, 208), "Applications": (510, 208)}
