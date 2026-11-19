# dmgbuild settings for the FrameBoost installer window (660 x 400, drag app onto "Programme")
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]
icon = defines.get("volicon")

background = defines["background"]
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 112
icon_locations = {
    app_name: (165, 200),
    "Applications": (495, 200),
}
