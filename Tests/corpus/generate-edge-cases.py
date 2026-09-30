#!/usr/bin/env python3
"""Generates the edge-case part of the test corpus.

Each file exists because of a specific way an optimizer can go wrong; the name
says which. Deterministic: same output on every run.

usage: generate-edge-cases.py OUTDIR
"""
import os, random, struct, sys, zlib
from PIL import Image, ImageDraw, PngImagePlugin

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
random.seed(1234)
P = lambda name: os.path.join(out, name)
PROFILES = "/System/Library/ColorSync/Profiles"
def icc(name):
    path = os.path.join(PROFILES, name)
    return open(path, "rb").read() if os.path.exists(path) else None

def photo(w, h):
    """Smooth gradients plus shapes: compresses like a photo, not like a flat graphic."""
    im = Image.new("RGB", (w, h)); px = im.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = ((x * 7 + y * 3) % 256, (x * x // (w // 8 + 1)) % 256, (y * 5 + x) % 256)
    d = ImageDraw.Draw(im)
    for _ in range(25):
        x, y = random.randint(0, w - 40), random.randint(0, h - 40)
        d.ellipse([x, y, x + random.randint(10, 80), y + random.randint(10, 80)],
                  fill=(random.randint(0, 255), random.randint(0, 255), random.randint(0, 255)))
    return im

def screenshot(w, h):
    """Flat UI with text-like bars: what zopfli-style deflaters are best at."""
    im = Image.new("RGB", (w, h), (248, 248, 250)); d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w, 40], fill=(52, 84, 150))
    for r in range(h // 30):
        d.rectangle([20, 60 + r * 26, 20 + random.randint(100, w - 60), 72 + r * 26], fill=(45, 45, 50))
    return im

base = photo(480, 320)

# --- PNG ----------------------------------------------------------------------
base.save(P("png-rgb8.png"))
base.convert("RGBA").save(P("png-rgba8-opaque.png"))                  # alpha channel that can be dropped
base.convert("L").save(P("png-gray8.png"))
base.convert("I;16").save(P("png-gray16.png"))                         # 16-bit must not be reduced
base.convert("P", palette=Image.ADAPTIVE, colors=64).save(P("png-palette64.png"))
pal = base.convert("RGBA"); pal.putalpha(Image.linear_gradient("L").resize(pal.size))
pal.convert("P", palette=Image.ADAPTIVE, colors=128).save(P("png-palette-trns.png"), transparency=0)
def save_interlaced(image, path):
    """Adam7-interlaced RGB PNG; Pillow ignores interlace=True when writing."""
    w, h = image.size
    px = image.convert("RGB").tobytes()
    raw = b""
    for x0, y0, dx, dy in ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)):
        for y in range(y0, h, dy):
            if x0 < w:  # every row starts with filter type 0
                raw += b"\0" + b"".join(px[3 * (y * w + x):3 * (y * w + x) + 3] for x in range(x0, w, dx))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 1))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
save_interlaced(base, P("png-interlaced.png"))
base.save(P("png-icc-displayp3.png"), icc_profile=icc("Display P3.icc"))  # profile changes colours: must survive
info = PngImagePlugin.PngInfo(); info.add_text("Comment", "keep or strip, but decide on purpose")
base.save(P("png-text-chunk.png"), pnginfo=info)
screenshot(900, 600).save(P("png-screenshot.png"))
hidden = Image.new("RGBA", (64, 64)); hp = hidden.load()
for y in range(64):
    for x in range(64):
        hp[x, y] = (x * 4 % 256, y * 4 % 256, (x + y) * 2 % 256, 0 if x < 40 else 255)
hidden.save(P("png-rgb-under-transparency.png"))                      # data under alpha=0
Image.new("RGB", (1, 1), (255, 0, 0)).save(P("png-1x1.png"))
Image.new("RGBA", (32, 32), (0, 0, 0, 0)).save(P("png-fully-transparent.png"))

# --- JPEG ---------------------------------------------------------------------
base.save(P("jpeg-baseline-q95.jpg"), quality=95)
base.save(P("jpeg-progressive.jpg"), quality=90, progressive=True)
base.convert("L").save(P("jpeg-grayscale.jpg"), quality=90)
base.convert("CMYK").save(P("jpeg-cmyk.jpg"), quality=90)             # upstream #444: black after optimizing
base.save(P("jpeg-icc-displayp3.jpg"), quality=90, icc_profile=icc("Display P3.icc"))
exif = Image.Exif()
exif[0x010F] = "TestCam"; exif[0x0110] = "Model 1"; exif[0x0132] = "2024:05:01 12:00:00"
exif[0x0112] = 6                                                       # orientation: rotated 90°
gps = {1: "N", 2: (52.0, 31.0, 12.0), 3: "E", 4: (13.0, 24.0, 18.0)}
exif[0x8825] = gps                                                     # upstream #429: location data
base.save(P("jpeg-exif-gps-orientation.jpg"), quality=90, exif=exif.tobytes())
base.save(P("jpeg-444.jpg"), quality=90, subsampling=0)

# --- GIF ----------------------------------------------------------------------
base.convert("P", palette=Image.ADAPTIVE, colors=256).save(P("gif-still.gif"))
frames = []
for i in range(12):
    im = Image.new("RGB", (240, 160), (255, 255, 255)); d = ImageDraw.Draw(im)
    d.ellipse([10 + i * 15, 40, 70 + i * 15, 100], fill=(220, 40, 40))
    d.rectangle([0, 140, 240, 160], fill=(40, 90, 200))
    frames.append(im.convert("P", palette=Image.ADAPTIVE, colors=16))
frames[0].save(P("gif-anim-disposal-none.gif"), save_all=True, append_images=frames[1:], duration=80, loop=0, disposal=1)
frames[0].save(P("gif-anim-disposal-background.gif"), save_all=True, append_images=frames[1:], duration=80, loop=0, disposal=2)
frames[0].save(P("gif-anim-repeated-frames.gif"), save_all=True,       # optimizers merge these and add delays
               append_images=[frames[0]] * 4 + frames[1:], duration=60, loop=0)
base.convert("P", palette=Image.ADAPTIVE, colors=64).save(P("gif-interlaced.gif"), interlace=True)

# --- WebP ---------------------------------------------------------------------
base.save(P("webp-lossless.webp"), lossless=True, method=0)
base.convert("RGBA").save(P("webp-lossless-alpha.webp"), lossless=True, method=0)
base.save(P("webp-lossless-icc.webp"), lossless=True, method=0, icc_profile=icc("Display P3.icc"))  # VP8X container
hidden.save(P("webp-rgb-under-transparency.webp"), lossless=True, method=0, exact=True)
base.save(P("webp-lossy.webp"), quality=80)                             # must be left alone
frames[0].save(P("webp-animated.webp"), save_all=True, append_images=frames[1:], duration=80, lossless=True)

# --- SVG ----------------------------------------------------------------------
open(P("svg-editor-export.svg"), "w").write('''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!-- Created with a vector editor -->
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200" viewBox="0 0 200 200" version="1.1">
  <title>Accessible title that must survive</title>
  <desc>Description for screen readers</desc>
  <metadata>editor junk</metadata>
  <defs>
    <linearGradient id="g1" x1="0" x2="1"><stop offset="0" stop-color="#76c7ea"/><stop offset="1" stop-color="#a864e4"/></linearGradient>
    <linearGradient id="g2" x1="0" x2="1"><stop offset="0" stop-color="#76c7ea"/><stop offset="1" stop-color="#a864e4"/></linearGradient>
    <linearGradient id="unused"><stop offset="0" stop-color="#ff0000"/></linearGradient>
  </defs>
  <g id="layer1" transform="translate(0.000000,0.000000)">
    <rect x="10.000000" y="10.000000" width="180.000000" height="180.000000" style="fill:url(#g1);stroke:none" />
    <circle cx="100.000000" cy="100.000000" r="50.000000" style="fill:url(#g2);fill-opacity:1.000000" />
    <text x="100" y="190" text-anchor="middle" font-family="Helvetica" font-size="14">Text</text>
  </g>
</svg>
''')
open(P("svg-scalable-viewbox-only.svg"), "w").write(  # no width/height: removing viewBox would break it
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><rect x="5" y="5" width="90" height="40" rx="8" fill="#336699"/></svg>\n')

# --- files that must be left untouched ----------------------------------------
data = open(P("png-rgb8.png"), "rb").read()
open(P("broken-truncated.png"), "wb").write(data[: len(data) // 2])
open(P("broken-empty.png"), "wb").write(b"")
open(P("misnamed-png.jpg"), "wb").write(data)                  # content decides, not the extension
open(P("broken-text-named-gif.gif"), "w").write("not an image\n")
base.save(P("name Größe – äöü ✓.png"))                                  # spaces, umlauts, symbols

print(f"{len(os.listdir(out))} edge cases in {out}")
