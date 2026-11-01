#!/usr/bin/env python3
"""Write the aperture concept's hand-tuned 32 px and 16 px drawings (icon-32.svg, icon-16.svg)."""
import math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from iris import iris
import head

D = HERE + "/"
TILE = ("M381.28,100 L642.72,100 C723.72,100 764.21,100 807.8,113.78 C855.31,128.8 895.2,168.69 910.22,216.2 "
        "C924,259.79 924,300.28 924,381.28 L924,642.72 C924,723.72 924,764.21 910.22,807.8 C895.2,855.31 855.31,895.2 807.8,910.22 "
        "C764.21,924 723.72,924 642.72,924 L381.28,924 C300.28,924 259.79,924 216.2,910.22 C168.69,895.2 128.8,855.31 113.78,807.8 "
        "C100,764.21 100,723.72 100,642.72 L100,381.28 C100,300.28 100,259.79 113.78,216.2 C128.8,168.69 168.69,128.8 216.2,113.78 "
        "C259.79,100 300.28,100 381.28,100 Z")
# the 32 px keyhole: the keyhole concept's skull and slot (17 px tall, reused here at 0.6) with the new face from head.py
KH32 = head.keyhole32()

def tones(g, strength):
    out = []
    for i, w in enumerate(g["wedges"]):
        v = math.cos(math.radians(g["mid"][i] - 270)) + (0.35 if i % 2 else -0.35)
        col, op = ("#FFFFFF", 0.06 + strength * v) if v >= 0 else ("#0A1222", 0.06 + strength * -v)
        out.append(f'    <path d="{w}" fill="{col}" fill-opacity="{op:.3f}"/>')
    return "\n".join(out)

# ---- 32 px: 26 px tile on whole pixels, 17 px iris, six blades as tones plus hairline edges, keyhole 10 px tall
g = iris(16, 16, 9, 1, 72, -75, 8.4)
edges = "\n".join(f'    <path d="{e}" fill="none" stroke="#1A2232" stroke-opacity="0.45" stroke-width="0.6"/>' for e in g["edges"])
svg32 = f'''<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
  <!-- Hand-tuned 32 px: 26 px tile on whole pixels; 17 px iris with six blade tones and hairline edges; profile keyhole 10 px tall (natural face from head.py), slot bottom on row 21. -->
  <defs>
    <path id="tile" transform="translate(-0.15534 -0.15534) scale(0.0315534)" d="{TILE}"/>
    <path id="kh" transform="translate(6.15 6.6) scale(0.6)" d="{KH32}"/>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#25344F"/>
      <stop offset="0.45" stop-color="#131C30"/>
      <stop offset="1" stop-color="#070B14"/>
    </linearGradient>
    <linearGradient id="rimT" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.26"/>
      <stop offset="0.15" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="metal" x1="0" y1="7.5" x2="0" y2="24.5" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#F0F2F5"/>
      <stop offset="0.5" stop-color="#C6CCD4"/>
      <stop offset="1" stop-color="#868F9C"/>
    </linearGradient>
    <clipPath id="tileClip"><use href="#tile"/></clipPath>
    <clipPath id="disc"><circle cx="16" cy="16" r="8.5"/></clipPath>
    <mask id="khMask" maskUnits="userSpaceOnUse" x="0" y="0" width="32" height="32">
      <rect width="32" height="32" fill="#fff"/>
      <use href="#kh" fill="#000"/>
    </mask>
    <filter id="soft" x="-30%" y="-30%" width="160%" height="160%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="0.6"/>
      <feOffset dy="0.7"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.55"/></feComponentTransfer>
    </filter>
    <filter id="tileShadow" x="-20%" y="-20%" width="140%" height="140%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="0.5"/>
      <feOffset dy="0.5"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.35"/></feComponentTransfer>
    </filter>
  </defs>
  <use href="#tile" fill="#000" filter="url(#tileShadow)"/>
  <use href="#tile" fill="url(#bg)"/>
  <g clip-path="url(#tileClip)"><use href="#tile" fill="none" stroke="url(#rimT)" stroke-width="63.4"/></g>
  <circle cx="16" cy="16" r="8.5" fill="#000" filter="url(#soft)"/>
  <g mask="url(#khMask)">
  <circle cx="16" cy="16" r="8.5" fill="url(#metal)"/>
  <g clip-path="url(#disc)">
{tones(g, 0.16)}
{edges}
  </g>
  </g>
  <use href="#kh" transform="translate(0 0.5)" fill="#FFFFFF" fill-opacity="0.55" clip-path="url(#disc)"/>
  <use href="#kh" fill="#060A12"/>
</svg>
'''
open(D + "icon-32.svg", "w").write(svg32)

# ---- 16 px: 14 px tile, 10 px iris with six blade tones only, keyhole on the pixel grid with a soft 1 px nose and round chin
g = iris(8, 8, 5.5, 0.5, 72, -75, 5.2)
svg16 = f'''<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <!-- Hand-tuned 16 px: 14 px tile on whole pixels (1 px margin); 10 px iris with six blade tones; keyhole drawn on the pixel grid (4 px round head, soft 1 px nose, round chin, 2 px slot). -->
  <defs>
    <path id="tile" transform="translate(-0.69903 -0.69903) scale(0.0169903)" d="{TILE}"/>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#293A5E"/>
      <stop offset="1" stop-color="#080C16"/>
    </linearGradient>
    <linearGradient id="metal" x1="0" y1="3" x2="0" y2="13" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#F4F6F8"/>
      <stop offset="1" stop-color="#97A0AC"/>
    </linearGradient>
    <clipPath id="disc"><circle cx="8" cy="8" r="5"/></clipPath>
    <mask id="khMask" maskUnits="userSpaceOnUse" x="0" y="0" width="16" height="16">
      <rect width="16" height="16" fill="#fff"/>
      <g fill="#000">
        <rect x="7" y="4" width="2" height="1"/>
        <rect x="6" y="5" width="4" height="2"/>
        <rect x="7" y="7" width="2" height="4"/>
      </g>
      <g fill="#000" fill-opacity="0.55">
        <rect x="6" y="4" width="1" height="1"/>
        <rect x="9" y="4" width="1" height="1"/>
        <rect x="6" y="7" width="1" height="1"/>
      </g>
      <!-- face: a fuller, rounder chin and a softer nose -->
      <rect x="9" y="7" width="1" height="1" fill="#000" fill-opacity="0.7"/>
      <rect x="10" y="6" width="1" height="1" fill="#000" fill-opacity="0.45"/>
    </mask>
  </defs>
  <use href="#tile" fill="url(#bg)"/>
  <g mask="url(#khMask)">
    <circle cx="8" cy="8" r="5" fill="url(#metal)"/>
    <g clip-path="url(#disc)">
{tones(g, 0.12)}
    </g>
  </g>
</svg>
'''
open(D + "icon-16.svg", "w").write(svg16)
# ---- menu-bar template glyph: lens ring around the keyhole, black on transparent
svgmb = f'''<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  <!-- Menu-bar template glyph: a plain 1.6 pt lens ring around a filled profile keyhole (the keyhole concept's glyph at 0.62, smooth face from head.py). Black on transparent. -->
  <circle cx="9" cy="9" r="7.6" fill="none" stroke="#000" stroke-width="1.6"/>
  <path transform="translate(3.25 3.45) scale(0.62)" d="{head.keyhole_mb()}" fill="#000"/>
</svg>
'''
open(D + "menubar.svg", "w").write(svgmb)
print("ok")
