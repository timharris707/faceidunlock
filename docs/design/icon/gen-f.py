#!/usr/bin/env python3
"""Write the aperture concept's 1024 master (icon.svg): one six-blade steel iris whose opening is a profile keyhole."""
import math, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from iris import iris
import head

OUT = os.path.join(HERE, "icon.svg")
CX, CY, R = 512, 506, 268
KH_T = "translate(500 512) scale(0.86) translate(0 -85)"
KH_D = head.keyhole()  # round skull, natural profile, original slot (see head.py)
TILE = ("M381.28,100 L642.72,100 C723.72,100 764.21,100 807.8,113.78 C855.31,128.8 895.2,168.69 910.22,216.2 "
        "C924,259.79 924,300.28 924,381.28 L924,642.72 C924,723.72 924,764.21 910.22,807.8 C895.2,855.31 855.31,895.2 807.8,910.22 "
        "C764.21,924 723.72,924 642.72,924 L381.28,924 C300.28,924 259.79,924 216.2,910.22 C168.69,895.2 128.8,855.31 113.78,807.8 "
        "C100,764.21 100,723.72 100,642.72 L100,381.28 C100,300.28 100,259.79 113.78,216.2 C128.8,168.69 168.69,128.8 216.2,113.78 "
        "C259.79,100 300.28,100 381.28,100 Z")

g = iris(CX, CY, R + 4, 26, 72, -75, 250)
n = len(g["wedges"])

clips, tones, shadows, lights = [], [], [], []
for i, w in enumerate(g["wedges"]):
    clips.append(f'    <clipPath id="w{i}"><path d="{w}"/></clipPath>')
    # each blade tilts a little, so it catches the top light by its angle; neighbours alternate slightly
    v = math.cos(math.radians(g["mid"][i] - 270)) + (0.25 if i % 2 else -0.25)
    if v >= 0:
        tones.append(f'      <path d="{w}" fill="#FFFFFF" fill-opacity="{0.05 + 0.13 * v:.3f}"/>')
    else:
        tones.append(f'      <path d="{w}" fill="#0A1222" fill-opacity="{0.05 + 0.13 * -v:.3f}"/>')
for i, e in enumerate(g["edges"]):
    under = (i - 1) % n
    shadows.append(f'      <path d="{e}" clip-path="url(#w{under})" stroke="#0A1020" stroke-opacity="0.5" stroke-width="26" fill="none" filter="url(#blur8)"/>')
    lit = 0.55 + 0.4 * max(0.0, math.cos(math.radians(g["mid"][i] - 270)))
    lights.append(f'      <path d="{e}" clip-path="url(#w{i})" stroke="#FFFFFF" stroke-opacity="{lit:.2f}" stroke-width="3" fill="none"/>')

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <!-- Aperture: one machined steel iris of six overlapping blades; its opening is a keyhole whose round top is a head in profile.
       Blade geometry from _work/iris.py (cx 512, cy 506, r 272, edges turn 72 degrees). -->
  <defs>
    <path id="tile" d="{TILE}"/>
    <path id="kh" transform="{KH_T}" d="{KH_D}"/>
    <clipPath id="tileClip"><use href="#tile"/></clipPath>
    <clipPath id="discClip"><circle cx="{CX}" cy="{CY}" r="{R}"/></clipPath>
    <clipPath id="khClip"><use href="#kh"/></clipPath>
{chr(10).join(clips)}
    <mask id="khMask" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <rect width="1024" height="1024" fill="#fff"/>
      <use href="#kh" fill="#000"/>
    </mask>
    <mask id="floorMask" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <use href="#kh" fill="#fff"/>
      <use href="#kh" transform="translate(0 -10)" fill="#000"/>
    </mask>

    <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#22304B"/>
      <stop offset="0.45" stop-color="#121B2E"/>
      <stop offset="1" stop-color="#070B14"/>
    </linearGradient>
    <radialGradient id="bgLift" cx="512" cy="150" r="620" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.08"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="tileRim" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.24"/>
      <stop offset="0.18" stop-color="#FFFFFF" stop-opacity="0.04"/>
      <stop offset="0.85" stop-color="#FFFFFF" stop-opacity="0"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.06"/>
    </linearGradient>
    <linearGradient id="metal" x1="0" y1="{CY - R}" x2="0" y2="{CY + R}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#E9ECF0"/>
      <stop offset="0.45" stop-color="#C3C9D1"/>
      <stop offset="1" stop-color="#7F8895"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="{CY - R}" x2="0" y2="{CY + R}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.95"/>
      <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.2"/>
      <stop offset="1" stop-color="#1E242E" stop-opacity="0.6"/>
    </linearGradient>
    <!-- bounding-box units: the keyhole path carries its own transform -->
    <linearGradient id="hole" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#03050A"/>
      <stop offset="1" stop-color="#0C1424"/>
    </linearGradient>
    <linearGradient id="wall" x1="0" y1="380" x2="0" y2="640" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#1E2633"/>
      <stop offset="1" stop-color="#3A4352"/>
    </linearGradient>
    <filter id="tileShadow" x="-20%" y="-20%" width="140%" height="150%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14" result="b1"/>
      <feOffset in="b1" dy="14" result="o1"/>
      <feComponentTransfer in="o1" result="s1"><feFuncA type="linear" slope="0.38"/></feComponentTransfer>
      <feGaussianBlur in="SourceAlpha" stdDeviation="2.5" result="b2"/>
      <feOffset in="b2" dy="2" result="o2"/>
      <feComponentTransfer in="o2" result="s2"><feFuncA type="linear" slope="0.30"/></feComponentTransfer>
      <feMerge><feMergeNode in="s1"/><feMergeNode in="s2"/></feMerge>
    </filter>
    <filter id="discShadow" x="-30%" y="-30%" width="160%" height="170%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="18" result="b1"/>
      <feOffset in="b1" dy="20" result="o1"/>
      <feComponentTransfer in="o1" result="s1"><feFuncA type="linear" slope="0.55"/></feComponentTransfer>
      <feGaussianBlur in="SourceAlpha" stdDeviation="3" result="b2"/>
      <feOffset in="b2" dy="4" result="o2"/>
      <feComponentTransfer in="o2" result="s2"><feFuncA type="linear" slope="0.4"/></feComponentTransfer>
      <feMerge><feMergeNode in="s1"/><feMergeNode in="s2"/></feMerge>
    </filter>
    <filter id="blur8" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="8"/></filter>
    <filter id="blur1" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="1"/></filter>
  </defs>

  <!-- tile -->
  <use href="#tile" fill="#000" filter="url(#tileShadow)"/>
  <use href="#tile" fill="url(#bg)"/>
  <use href="#tile" fill="url(#bgLift)"/>
  <g clip-path="url(#tileClip)"><use href="#tile" fill="none" stroke="url(#tileRim)" stroke-width="6"/></g>

  <!-- iris -->
  <circle cx="{CX}" cy="{CY}" r="{R}" fill="#000" mask="url(#khMask)" filter="url(#discShadow)"/>
  <g mask="url(#khMask)">
    <circle cx="{CX}" cy="{CY}" r="{R}" fill="url(#metal)"/>
    <g clip-path="url(#discClip)">
{chr(10).join(tones)}
{chr(10).join(shadows)}
{chr(10).join(lights)}
    </g>
    <circle cx="{CX}" cy="{CY}" r="{R - 5}" fill="none" stroke="#FFFFFF" stroke-opacity="0.25" stroke-width="2"/>
    <circle cx="{CX}" cy="{CY}" r="{R - 1.5}" fill="none" stroke="url(#rim)" stroke-width="3"/>
  </g>

  <!-- opening: fine chamfer, deep interior, the lit floor of the cut -->
  <use href="#kh" transform="translate(0 -2.5)" fill="#3A424E" opacity="0.7" filter="url(#blur1)" clip-path="url(#discClip)"/>
  <use href="#kh" transform="translate(0 3.5)" fill="#FFFFFF" opacity="0.85" filter="url(#blur1)" clip-path="url(#discClip)"/>
  <use href="#kh" fill="url(#hole)"/>
  <g clip-path="url(#khClip)">
    <rect x="0" y="0" width="1024" height="1024" fill="url(#wall)" mask="url(#floorMask)" filter="url(#blur1)"/>
  </g>
</svg>
'''
open(OUT, "w").write(svg)
print("wrote", OUT)
