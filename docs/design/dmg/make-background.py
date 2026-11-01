# Installer-window background for the release disk image, at 1x and 2x: a warm golden-hour gradient with soft
# window-light bands, the mark and name, an arrow from the app to a dashed Applications target, and one
# instruction line. The band behind Finder's icon labels is held mid-tone (relative luminance about 0.18) so the
# labels read in light mode (black text) and dark mode (white text). Run from the repo root:
#   uv run --with pillow --with fonttools --with brotli python docs/design/dmg/make-background.py
# Needs site/fonts/archivo.woff2 (the website's font, in the private repo) and macOS's SF font.
import io
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageEnhance

OUT = 'docs/design/dmg'
SF = '/System/Library/Fonts/SFNS.ttf'
_ttf = io.BytesIO()
_font = TTFont('site/fonts/archivo.woff2'); _font.flavor = None; _font.save(_ttf)
ARCHIVO = io.BytesIO(_ttf.getvalue())
# the web mark: the app icon zoomed to the iris, corners rounded (site/_source/README.md)
_icon = Image.open('docs/design/icon/icon-1024.png').convert('RGBA').crop((212, 206, 812, 806))
_mask = Image.new('L', _icon.size, 0)
ImageDraw.Draw(_mask).rounded_rectangle([0, 0, 599, 599], radius=132, fill=255)
_icon.putalpha(Image.composite(_icon.getchannel('A'), Image.new('L', _icon.size, 0), _mask))
MARK = _icon
APP = (170, 220)          # icon centres in points; dmgbuild gets the same numbers
APPS = (470, 220)

def lum(rgb):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = rgb
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)

def render(scale):
    W, H = 640 * scale, 448 * scale   # 420 pt of content under the title bar, plus spare gradient below
    P = lambda v: round(v * scale)
    # warm golden-hour gradient: deep at the top for the header, bronze through the icon band, a little deeper
    # at the bottom for the instruction line
    stops = [(0.0, (34, 25, 17)), (0.30, (92, 66, 38)), (0.52, (152, 113, 64)), (0.80, (138, 101, 56)), (1.0, (96, 69, 39))]
    grad = Image.new('RGB', (1, H))
    for y in range(H):
        t = y / (H - 1)
        for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                k = (t - t0) / (t1 - t0)
                k = k * k * (3 - 2 * k)
                grad.putpixel((0, y), tuple(round(a + (b - a) * k) for a, b in zip(c0, c1)))
                break
    bg = grad.resize((W, H)).convert('RGBA')
    # soft diagonal bands of window light, like the sun on the wall in the film
    light = Image.new('L', (W, H), 0)
    ld = ImageDraw.Draw(light)
    for i, (x, w, a) in enumerate([(-0.10, 0.10, 34), (0.08, 0.05, 26), (0.30, 0.13, 30), (0.55, 0.06, 22), (0.78, 0.11, 28)]):
        x0, x1 = x * W, (x + w) * W
        ld.polygon([(x0, 0), (x1, 0), (x1 - 0.55 * H, H), (x0 - 0.55 * H, H)], fill=a)
    light = light.filter(ImageFilter.GaussianBlur(10 * scale))
    bg.alpha_composite(Image.merge('RGBA', [Image.new('L', (W, H), 255), Image.new('L', (W, H), 226), Image.new('L', (W, H), 170), light]))
    d = ImageDraw.Draw(bg)
    # header: mark + name
    ARCHIVO.seek(0)
    name_font = ImageFont.truetype(ARCHIVO, P(30))
    name_font.set_variation_by_axes([760, 112])
    mark = MARK.resize((P(48), P(48)), Image.LANCZOS)
    tw = d.textlength('Face ID Unlock', font=name_font)
    total = P(48) + P(14) + tw
    x0 = (W - total) / 2
    hy = P(64)
    shadow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    sdw = ImageDraw.Draw(shadow)
    sdw.text((x0 + P(48) + P(14), hy), 'Face ID Unlock', font=name_font, fill=(0, 0, 0, 150), anchor='lm')
    bg.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(P(6))))
    bg.alpha_composite(mark, (round(x0), round(hy - P(24))))
    d.text((x0 + P(48) + P(14), hy), 'Face ID Unlock', font=name_font, fill=(255, 250, 240), anchor='lm')

    # dashed target around Applications
    tx0, ty0, tx1, ty1 = P(APPS[0] - 72), P(APPS[1] - 70), P(APPS[0] + 72), P(APPS[1] + 86)
    dash = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dash)
    dd.rounded_rectangle([tx0, ty0, tx1, ty1], radius=P(22), outline=(255, 250, 240, 170), width=max(2, P(2)))
    # punch gaps into the outline for a dashed look
    gaps = Image.new('L', (W, H), 255)
    gd = ImageDraw.Draw(gaps)
    step, gap = P(14), P(7)
    for x in range(tx0, tx1, step):
        gd.rectangle([x, ty0 - P(3), x + gap, ty0 + P(3)], fill=0); gd.rectangle([x, ty1 - P(3), x + gap, ty1 + P(3)], fill=0)
    for y in range(ty0, ty1, step):
        gd.rectangle([tx0 - P(3), y, tx0 + P(3), y + gap], fill=0); gd.rectangle([tx1 - P(3), y, tx1 + P(3), y + gap], fill=0)
    dash.putalpha(Image.composite(dash.getchannel('A'), Image.new('L', (W, H), 0), gaps))
    bg.alpha_composite(dash)

    # arrow from the app to Applications
    ay = P(APP[1])
    ax0, ax1 = P(APP[0] + 70), P(APPS[0] - 88)
    arrow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrow)
    sw = P(5)
    ad.line([(ax0, ay), (ax1 - P(4), ay)], fill=(255, 250, 240, 235), width=sw)
    ad.line([(ax1 - P(18), ay - P(16)), (ax1, ay)], fill=(255, 250, 240, 235), width=sw)
    ad.line([(ax1 - P(18), ay + P(16)), (ax1, ay)], fill=(255, 250, 240, 235), width=sw)
    for (px, py) in [(ax0, ay), (ax1 - P(18), ay - P(16)), (ax1 - P(18), ay + P(16)), (ax1, ay)]:
        ad.ellipse([px - sw / 2, py - sw / 2, px + sw / 2, py + sw / 2], fill=(255, 250, 240, 235))
    sh = arrow.copy(); sh.putalpha(arrow.getchannel('A').point(lambda v: v * 0.5))
    bg.alpha_composite(Image.merge('RGBA', [Image.new('L', (W, H), 0)] * 3 + [sh.getchannel('A')]).filter(ImageFilter.GaussianBlur(P(4))))
    bg.alpha_composite(arrow)

    # instruction line
    body = ImageFont.truetype(SF, P(15))
    try: body.set_variation_by_name('Semibold')
    except Exception: pass
    line = 'Drag Face ID Unlock to Applications to install'
    sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).text((W / 2, P(372)), line, font=body, fill=(0, 0, 0, 170), anchor='mm')
    bg.alpha_composite(sh.filter(ImageFilter.GaussianBlur(P(4))))
    ImageDraw.Draw(bg).text((W / 2, P(372)), line, font=body, fill=(255, 250, 240), anchor='mm')

    # report the label band's luminance (Finder draws labels about 62 pt below each icon centre)
    rgb = bg.convert('RGB')
    for name, (cx, cy) in (('app', APP), ('Applications', APPS)):
        box = rgb.crop((P(cx - 50), P(cy + 54), P(cx + 50), P(cy + 70))).resize((1, 1), Image.BOX).getpixel((0, 0))
        print(f'  {scale}x label band under {name}: rgb {box}, relative luminance {lum(box):.3f}')
    return rgb

for s, suffix in ((1, ''), (2, '@2x')):
    render(s).save(f'{OUT}/background{suffix}.png', optimize=True)
print('wrote background.png and background@2x.png')
