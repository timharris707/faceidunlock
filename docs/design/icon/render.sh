#!/bin/zsh
# Renders one final concept folder: PNGs, preview.png, AppIcon.iconset (10 sizes) and AppIcon.icns.
# Usage: render.sh <folder with the SVGs>  (run gen-f.py and gen-f-small.py first)
set -euo pipefail
R=/opt/homebrew/bin/rsvg-convert
M=/opt/homebrew/bin/magick
F=/System/Library/Fonts/Helvetica.ttc
cd "$1"

$R -w 1024 -h 1024 icon.svg    -o icon-1024.png
$R -w 128  -h 128  icon.svg    -o icon-128.png
$R -w 32   -h 32   icon-32.svg -o icon-32.png
$R -w 16   -h 16   icon-16.svg -o icon-16.png
$R -w 36   -h 36   menubar.svg -o menubar-36.png

# Iconset: the hand-tuned 16 and 32 drawings for the two smallest sizes, the master for the rest.
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
cp icon-16.png AppIcon.iconset/icon_16x16.png
cp icon-32.png AppIcon.iconset/icon_16x16@2x.png
cp icon-32.png AppIcon.iconset/icon_32x32.png
$R -w 64   -h 64   icon.svg -o AppIcon.iconset/icon_32x32@2x.png
cp icon-128.png AppIcon.iconset/icon_128x128.png
$R -w 256  -h 256  icon.svg -o AppIcon.iconset/icon_128x128@2x.png
cp AppIcon.iconset/icon_128x128@2x.png AppIcon.iconset/icon_256x256.png
$R -w 512  -h 512  icon.svg -o AppIcon.iconset/icon_256x256@2x.png
cp AppIcon.iconset/icon_256x256@2x.png AppIcon.iconset/icon_512x512.png
cp icon-1024.png AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns AppIcon.iconset -o AppIcon.icns

# Preview: 1024 at 512; 128/32/16 at actual size; 32 and 16 enlarged; menu-bar glyph at 36 px on light and dark strips.
BG='#E3E3E6'
$M -size 300x60 xc:'#ECECEC' menubar-36.png -geometry +132+12 -composite .strip-light.png
$M -size 300x60 xc:'#1E1E1E' \( menubar-36.png -channel RGB -negate +channel \) -geometry +132+12 -composite .strip-dark.png
$M -size 1000x640 xc:"$BG" \
  \( icon-1024.png -filter Lanczos -resize 512x512 \) -geometry +24+40 -composite \
  icon-128.png -geometry +600+60 -composite \
  icon-32.png  -geometry +760+108 -composite \
  icon-16.png  -geometry +830+116 -composite \
  \( icon-32.png -filter point -resize 400% \) -geometry +600+240 -composite \
  \( icon-16.png -filter point -resize 800% \) -geometry +752+240 -composite \
  .strip-light.png -geometry +600+420 -composite \
  .strip-dark.png  -geometry +600+488 -composite \
  -font $F -pointsize 14 -fill '#55555A' \
  -annotate +600+38  '128 / 32 / 16 px (actual size)' \
  -annotate +600+228 '32 and 16 px enlarged' \
  -annotate +600+408 'menu-bar glyph, 36 px' \
  -depth 8 preview.png
rm -f .strip-light.png .strip-dark.png
