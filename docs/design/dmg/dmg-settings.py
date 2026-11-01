# dmgbuild settings for the release disk image: ModelDeck's drag-to-Applications window, app on the left and
# Applications on the right over background.png (with background@2x.png for Retina). scripts/notarize.sh runs
# it from the repo root with -D app=<path to the stapled app>.
app = defines['app']  # noqa: F821 (dmgbuild supplies defines)
format = 'UDZO'
filesystem = 'HFS+'
files = [app]
symlinks = {'Applications': '/Applications'}
icon = app + '/Contents/Resources/AppIcon.icns'
background = 'docs/design/dmg/background.png'
window_rect = ((200, 120), (640, 448))  # the frame: 420 pt of content under the title bar
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 96
text_size = 13
label_pos = 'bottom'
arrange_by = None
icon_locations = {'Face ID Unlock.app': (170, 220), 'Applications': (470, 220)}
