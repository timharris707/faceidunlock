#!/usr/bin/env python3
"""Build the 1024 keyhole outline (KH_D) for the aperture icon: a round skull, a natural adult profile, and the unchanged slot.

Coordinates are the keyhole's own: skull circle centred on (0, 0) with radius 100, slot bottom at y 270.
The face is a chain of nodes (x, y, heading in, heading out, handle in, handle out); headings are degrees
with 0 pointing right and 90 pointing down, so each pair of neighbouring nodes becomes one smooth cubic.
"""
import math

# Unchanged parts of the original keyhole: slot left side and nape, slot right side and bottom.
SLOT_LEFT = "M-66,270 C-68,270 -69,268.6 -68.7,266.6 L-48,124 C-46.4,112 -48,89 -60,80 "
SLOT_RIGHT = "L68.7,266.6 C69,268.6 68,270 66,270 Z"
SKULL_R = 100
FOREHEAD_START = -38  # degrees on the skull circle where the forehead leaves it

# Face, top to bottom. A node with one heading is smooth; two headings make a soft corner.
FACE = [
    # forehead and brow
    (91, -36, 80, 80, 6, 9),
    (93, -15, 94, 94, 9, 7),
    # nasion: the shallow dip between brow and nose
    (91.4, 1.5, 72, 72, 6, 9),
    # nose: straight bridge into a round tip (one arc of radius 7.5 about (113, 45.5)), short underside
    (105, 21.3, 54.6, 54.6, 8, 8),
    (119.1, 41.2, 54.6, 54.6, 6, 4.95),
    (115.6, 52.5, 160, 160, 4.95, 5),
    # subnasale and upper lip
    (101.2, 58.3, 128, 128, 2.2, 2),
    (102.8, 65.5, 78, 78, 3.5, 2.5),
    (104.4, 71, 100, 100, 2.2, 2),
    # mouth line and lower lip
    (101.6, 77, 135, 62, 1.8, 1.8),
    (103.2, 83, 98, 98, 2.5, 4),
    # chin: soft hollow, round front, round underside
    (97.2, 93.5, 90, 90, 4.5, 5),
    (103, 106.5, 94, 94, 6, 6),
    (92, 120, 163, 163, 7.5, 14),
    # under the jaw to the throat, then into the slot
    (55, 127, 160, 160, 12, 4),
    (47, 138, 80.4, 80.4, 6, 0),
]


def _d(a):
    r = math.radians(a)
    return math.cos(r), math.sin(r)


def _f(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def face_path(start, start_heading, start_handle, nodes):
    """Return cubic segments from start through every node."""
    out = []
    px, py = start
    ph, phl = start_heading, start_handle
    for (x, y, hin, hout, lin, lout) in nodes:
        dx0, dy0 = _d(ph)
        dx1, dy1 = _d(hin)
        c1 = (px + phl * dx0, py + phl * dy0)
        c2 = (x - lin * dx1, y - lin * dy1)
        out.append(f"C{_f(c1[0])},{_f(c1[1])} {_f(c2[0])},{_f(c2[1])} {_f(x)},{_f(y)}")
        px, py, ph, phl = x, y, hout, lout
    return " ".join(out)


def keyhole(face=FACE, fs=FOREHEAD_START, first_handle=8):
    a = math.radians(fs)
    sx, sy = SKULL_R * math.cos(a), SKULL_R * math.sin(a)
    arc = f"A{SKULL_R},{SKULL_R} 0 1 1 {_f(sx)},{_f(sy)} "
    return SLOT_LEFT + arc + face_path((sx, sy), fs + 90, first_handle, face) + " " + SLOT_RIGHT


if __name__ == "__main__":
    print(keyhole())


# ---- 32 px keyhole, in the original 32 px drawing's own units (it is placed at translate(6.15 6.6) scale(0.6)).
# The skull and slot are the original 32 px ones; only the face between the forehead and the throat is new.
# Features are merged to what survives at this size: forehead, a straight bridge with a round tip,
# one soft lip curve, a round chin, and the line under the jaw.
KH32_HEAD = ("M12.6,24 L13.35,17.4 C13.4,16.9 13.2,16.5 12.9,16.1 C11.95,15.2 11,13.95 11,12.1 "
             "C11,9.25 13.05,7 15.75,7 C18.2,7 19.85,8.7 19.95,10.85 ")
KH32_SLOT = "L18.6,24 Z"
FACE32 = [
    (20.0, 11.4, 86, 86, 0.3, 0.6),
    (21.29, 13.04, 51.8, 51.8, 0.9, 0.34),
    (21.07, 13.82, 160, 160, 0.34, 0.3),
    (20.3, 14.1, 125, 125, 0.15, 0.2),
    (20.22, 14.75, 92, 92, 0.25, 0.4),
    (20.12, 15.75, 95, 95, 0.3, 0.3),
    (20.25, 16.6, 92, 92, 0.3, 0.3),
    (19.85, 17.3, 160, 160, 0.3, 0.6),
    (17.65, 17.85, 81.2, 81.2, 0.45, 0),
]


def keyhole32(face=FACE32):
    return KH32_HEAD + face_path((19.95, 10.85), 87.3, 0.25, face) + " " + KH32_SLOT


# ---- Menu-bar glyph keyhole, in the original glyph's own units (placed at translate(3.25 3.45) scale(0.62)).
# Original skull and slot; a smooth face with a soft nose, one lip curve and a round chin.
KHMB_HEAD = ("M6.05,16.25 L6.95,10.35 C7,10 6.85,9.7 6.55,9.4 C5.45,8.5 4.75,7.3 4.75,5.8 "
             "C4.75,3.45 6.55,1.75 8.8,1.75 C10.75,1.75 12.2,3.05 12.35,4.85 ")
KHMB_SLOT = "L11.45,16.25 Z"
FACEMB = [
    (12.42, 5.5, 88, 88, 0.25, 0.5),
    (13.58, 7.04, 51.1, 51.1, 0.8, 0.29),
    (13.39, 7.69, 160, 160, 0.29, 0.3),
    (12.6, 8.0, 120, 120, 0.15, 0.25),
    (12.72, 8.75, 93, 93, 0.35, 0.35),
    (12.66, 9.55, 95, 95, 0.3, 0.3),
    (12.05, 10.15, 162, 162, 0.35, 0.6),
    (10.45, 10.65, 79.9, 79.9, 0.35, 0),
]


def keyhole_mb(face=FACEMB):
    return KHMB_HEAD + face_path((12.35, 4.85), 85.2, 0.25, face) + " " + KHMB_SLOT
