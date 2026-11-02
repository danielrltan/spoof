# dmgbuild settings: the app on the left, an arrow, Applications on the right.
import os.path

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = "builtin-arrow"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 200), (560, 340))
icon_size = 112
text_size = 13
icon_locations = {os.path.basename(app): (140, 150), "Applications": (420, 150)}
