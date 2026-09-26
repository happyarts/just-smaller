# Tools research: what to use, what Apple gives us, what to build

Status: 2026-09-27, macOS 27 on an M1 Max. Measurements marked **(measured)** were
run on this machine; everything else is from the sources linked at the end.

The goal is fixed (smaller files, never a damaged image, never a silent format
change), the tools are not. For each job we pick, in this order:

1. an **Apple framework**, when its quality is at least on par — no dependency,
   no licence question, maintained by Apple;
2. a **well-maintained, permissively licensed tool** (MIT/BSD/Apache);
3. **our own Swift code**, when the job is small and well-defined (container
   and metadata handling, verification);
4. no GPL tools: they would bind the app's licence and block a Mac App Store
   release.

## Summary

| Job | Today | Licence | Recommendation |
|---|---|---|---|
| PNG lossless | oxipng 10.2.1 (+ zopfli on "Thorough") | MIT | keep — best measured, actively maintained |
| PNG lossy (palette) | quantizr 1.4 via own `png-quantize` | MIT | **done:** same size as pngquant, higher SSIMULACRA2, twice as fast (see below); exoquant is unmaintained |
| JPEG lossless | jpegtran from mozjpeg 4.1.5 | BSD (IJG) | keep for now: 1.1 points more savings than libjpeg-turbo 3.2 (see below); plan: own scan optimiser on libjpeg-turbo 3.2 |
| JPEG lossy | jpegli | BSD | **done:** jpegli (Google, active): up to 28 % smaller than mozjpeg and 12 % smaller than Apple's encoder at the same visual quality |
| JPEG metadata | own filter | — | **own Swift marker filter** (drop APPn/COM, keep ICC, write a minimal EXIF with the orientation) |
| GIF | — (later version) | — | no maintained permissive optimizer exists (gifsicle is GPL-2; rusty_gif is an encoder, not an optimizer) → **own optimizer** in Swift: frame cropping, transparency for unchanged pixels, LZW re-encoding |
| WebP lossless | cwebp (libwebp) | BSD | keep; ImageIO can only read WebP **(measured)** |
| WebP lossy / animated | — (left alone) | — | **own chunk filter** to strip EXIF/XMP without re-encoding; recompression only as opt-in lossy |
| SVG | oxvg 0.0.8 | MIT | keep; 41 % vs 19 % (svgcleaner) on the corpus, 100 % of the W3C suite without visual change; svgo (Node) is not an option for a native app |
| HEIC | ImageIO re-encode (lossy mode) | Apple | keep; **add lossless metadata stripping via ImageIO** — works without re-encoding **(measured)** |
| AVIF | — | — | **ImageIO writes AVIF (measured)** → lossy recompression possible, opt-in; lossless metadata editing is *not* supported for AVIF **(measured)** |
| JPEG XL | — | — | ImageIO reads only **(measured)**; libjxl (BSD) would be needed; low priority |
| DNG | — | — | ImageIO reads DNG, cannot write it **(measured)**; lossless DNG recompression needs Adobe's DNG SDK (own licence) or a raw pipeline; dnglab is LGPL. Research item, not a quick win |
| TIFF | — | — | ImageIO writes TIFF (LZW/Deflate) → lossless recompression is an Apple-only job, cheap to add |
| Perceptual quality ("visually lossless" auto mode) | — | — | **SSIMULACRA2** (BSD) or butteraugli (Apache); **not** DSSIM (AGPL) |
| Verification | own (ImageIO + vImage, jpegcmp on libjpeg-turbo 3.2) | — | keep |

## Apple frameworks

### ImageIO on macOS 27 **(measured)**

`CGImageDestinationCopyTypeIdentifiers` / `CGImageSourceCopyTypeIdentifiers`:

- **Write:** JPEG, PNG, GIF, HEIC/HEICS, **AVIF**, TIFF, JPEG 2000, ICNS, ICO,
  BMP, PDF, PSD, OpenEXR, TGA, KTX/KTX2, ASTC, PVR, DDS.
- **Read only:** **WebP**, **JPEG XL**, HEIF (generic), **DNG and all camera raw
  formats**, MPO, DICOM, Radiance, PICT, SGI, CUR.

ImageIO's encoders are fine for HEIC and AVIF (Apple's own formats, hardware
assisted). For JPEG and PNG they are not competitive: the JPEG encoder needs
11–13 % more bytes than jpegli for the same visual quality (measured, see
below), cannot recompress losslessly, and the PNG encoder does no filter
search or palette reduction.

### Lossless metadata editing **(measured)**

`CGImageDestinationCopyImageSource` with `kCGImageMetadataShouldExcludeGPS`:

| Format | Works | GPS removed | Orientation + ICC kept | Pixels identical | Size |
|---|---|---|---|---|---|
| JPEG | yes | yes | yes | yes | **+2.7 KB** (adds XMP) |
| HEIC | yes | yes | yes | yes | +44 bytes |
| PNG | yes | **no** (option ignored) | yes | yes | ±0 |
| AVIF | **no** ("not supported for lossless metadata modification") | — | — | — | — |

So: use it for **HEIC** (lossless-mode privacy stripping, which HEIC has no
other way to get), not for JPEG (our own marker filter is smaller and exact)
and not for PNG (oxipng `--strip safe` does it). Removing individual EXIF tags
(serial numbers) needs `CGImageMetadataRemoveTagWithPath`, not
`SetValueMatchingImageProperty` with `kCFNull` — the latter was silently
ignored in the test.

### Other frameworks worth using

- **Accelerate / vImage** — fast pixel comparison and colour conversion for
  verification (today plain CoreGraphics + byte compare).
- **App Intents** — Shortcuts actions ("Optimize Images"), Spotlight, and the
  basis for automation without our own scripting layer.
- **Finder integration** — an Action Extension or Quick Action for "Optimize
  with Just Smaller" in Finder's context menu and preview pane; NSServices as the
  cheap fallback.
- **FSEvents** (via `DispatchSource`/`FSEventStream`) — watch folders.
- **NSPasteboard** — optional clipboard optimisation (Clop's signature
  feature).
- **QuickLookThumbnailing** — already used for the list thumbnails.
- **Vision** — could tell screenshots/text from photos to pick lossless vs
  lossy per image in an automatic mode; later.

## Our own code

Small, well-defined jobs where a dependency costs more than it saves:

- **JPEG marker filter** — walk the markers, keep SOF/DHT/DQT/SOS/…, the ICC
  profile (APP2) and, when stripping, write a minimal EXIF APP1 with only the
  orientation. Replaces jpegoptim's metadata role and the "keep EXIF on rotated
  photos" stopgap. A few hundred lines, fully testable.
- **WebP chunk filter** — drop EXIF/XMP chunks and fix the VP8X flags; gives
  lossy and animated WebP a lossless privacy option.
- **Verification** — already ours; extend to AVIF/HEIC structure checks.
- **Pipeline, scheduling, atomic replace** — already ours.

Not worth building ourselves: PNG deflate optimisation (oxipng), JPEG entropy
coding (libjpeg-turbo/jpegli), SVG optimisation (oxvg).

Worth building later: a GIF optimiser (no permissive one exists) and a JPEG
progressive-scan optimiser on libjpeg-turbo (see the jpegtran comparison).

## Licences

Everything bundled is MIT or BSD-style: OxiPNG, OXVG, quantizr (MIT); libwebp,
jpegli, mozjpeg, libjpeg-turbo (BSD). Avoided on purpose: pngquant/libimagequant
(GPL-3 or commercial), gifsicle (GPL-2), jpegoptim (GPL-3), gifski and DSSIM
(AGPL), libheif+x265 (LGPL/GPL — ImageIO covers HEIC anyway), dnglab (LGPL).

## What others do

| App | Formats | Notable features | Engine | Price |
|---|---|---|---|---|
| ImageOptim (1.x) | JPEG, PNG, GIF, SVG | drag & drop, lossless by default, CLI | mozjpeg, pngquant, zopfli, … | free, GPL |
| Clop | PNG, JPEG, GIF, HEIC, TIFF, WebP, video, PDF | clipboard auto-optimise, watch folders, Finder button, Shortcuts, CLI, downscale hotkeys, SDK | pngquant, jpegoptim, gifsicle, ffmpeg, libvips, gifski | €15, GPL-3 |
| Optimage | JPEG, PNG, APNG, GIF, SVG, WebP, HEIC, PDF, video, … | perceptual metrics ("visually lossless"), no-reference quality check to avoid double compression, Lanczos resize, auto sRGB conversion, CLI, Finder/Sketch | own encoders | $15 |
| Zipic | up to 12 incl. AVIF, JPEG XL, TIFF, ICNS, PDF, APNG | folder monitoring, Shortcuts, URL scheme, Raycast, clipboard, notch drop zone, 6 levels | — | $20–30 |
| Squash | JPEG, PNG, WebP, HEIC | presets, resize, convert, watermark, EXIF editing, Shortcuts | — | subscription |
| Compresto | images, video, GIF, PDF | folder monitoring, menu bar, Raycast, URL scheme | — | $49 |
| JPEGmini | JPEG, HEIC→JPEG | perceptual JPEG recompression, Lightroom/Photoshop plugins | own | $59–89 |
| ImageCrush | JPEG, PNG, WebP, HEIC, AVIF | resize, crop, presets, rename, watermark | Apple frameworks | $15 |
| Squoosh | many (web) | side-by-side before/after comparison with live codec settings | wasm codecs | free |
| TinyPNG | PNG, JPEG, WebP, AVIF | cloud API, WordPress plugin | cloud | subscription |

What stands out:

- **Nobody verifies results.** Our "never damage an image" check (pixels,
  colour profile, orientation, animation timing) is a real differentiator
  — ImageOptim 1.x itself shipped the colour-profile and orientation bugs we
  found.
- **Automation is where the paid apps compete**: watch folders, clipboard,
  Shortcuts, Finder, CLI, URL schemes.
- **"Visually lossless" auto mode** (Optimage, JPEGmini) is the premium
  compression feature: pick the lowest quality whose perceptual score stays
  above a threshold, per image.
- **Modern formats**: AVIF and JPEG XL appear in most current competitors.
- **Before/after comparison** (Squoosh) is the best way to build trust in
  lossy settings.
- Resize/crop/watermark/rename (Squash, ImageCrush) is photo-prep, not
  optimisation — outside our scope except for an opt-in "downscale".


## jpegli vs. jpegoptim vs. mozjpeg (measured 2026-09-26)

Tools: jpegli from google/jpegli (June 2026), mozjpeg 4.1.5,
jpegoptim 1.5.6. Quality measured with SSIMULACRA2
against the decoded source; compared is the size each encoder needs for the
**same visual quality**, interpolated per image.

**Pristine source** (24 Kodak PNGs — what a PNG/HEIC → JPEG conversion would
start from), size relative to mozjpeg:

| SSIMULACRA2 | 90 | 88 | 85 | 80 | 75 | 70 |
|---|---|---|---|---|---|---|
| jpegli | **78.7 %** | 80.9 % | 83.9 % | 92.6 % | 97.1 % | 98.2 % |

**Recompressing existing JPEGs** (16 Wikimedia photos, the everyday case),
size relative to jpegoptim:

| SSIMULACRA2 | 92 | 90 | 88 | 85 | 80 | 75 | 70 |
|---|---|---|---|---|---|---|---|
| jpegli alone | 135.5 % | 132.6 % | 116.4 % | 103.2 % | 97.7 % | 99.1 % | 99.1 % |
| **jpegli + quality rule** | **98.1 %** | **99.4 %** | **99.2 %** | **99.8 %** | **97.7 %** | **99.1 %** | **99.1 %** |
| mozjpeg cjpeg | 157.8 % | 150.1 % | 133.6 % | 114.9 % | 106.1 % | 102.0 % | 101.0 % |

jpegoptim's advantage at high quality isn't its encoder but a rule: it
estimates the source's quality from the quantization tables and, when that is
already below the target, doesn't re-encode (no generation loss) but only
optimizes losslessly. With the same rule, jpegli matches or slightly beats
jpegoptim everywhere. Encoding speed: jpegli 0.09 s per photo, mozjpeg 0.33 s,
jpegoptim 0.62 s.

The quality estimate (fit the standard IJG table scaled to Q = 1…100) is exact
for libjpeg-made files (fit error 0) and plausible for most others; files with
custom tables (some cameras, Photoshop) fit badly and need a conservative
fallback, e.g. comparing the average quantizer step instead.

**Decided and built:** replace jpegoptim by jpegli plus our own quality rule
(Swift, from the DQT segment). Same savings, 7× faster, and one GPL-3
dependency less (jpegli is BSD-3-Clause). jpegli is also the encoder for any
future opt-in conversion to JPEG. Lossless JPEG stays with jpegtran + jpegcmp.

## PNG palette reduction: quantizr vs pngquant (measured 2026-09-27)

68 truecolour PNGs from the corpus, 256 colours, full dithering, then OxiPNG:

| | size (of original) | SSIMULACRA2 median | mean, 47 images without alpha | time |
|---|---|---|---|---|
| pngquant 3 (libimagequant) | 34.2 % | 79.4 | 80.8 | 9.5 s |
| **quantizr 1.4** | **34.0 %** | **82.3** | **83.4** | **4.3 s** |

quantizr scores higher on 38 of 68 images. (SSIMULACRA2 isn't meaningful for
images with transparency; those were compared visually and look the same.)
Our `png-quantize` wraps it and carries the colour metadata over (iCCP, sRGB,
gAMA, cHRM, cICP, pHYs); HDR PNGs (PQ/HLG, mDCV, cLLI) are left alone.

Neither weights errors by where the eye notices them most (smooth areas such
as sky); both minimise a uniform colour error. The quality gate after
quantising catches the bad cases; perceptual weighting is a later improvement.

## Lossless JPEG: mozjpeg vs libjpeg-turbo jpegtran (measured 2026-09-27)

122 JPEGs from the corpus, `-copy all -optimize -progressive`:

| | saved | time |
|---|---|---|
| **mozjpeg 4.1.5 jpegtran** | **6.97 %** | 12.0 s |
| libjpeg-turbo 3.2 jpegtran | 5.81 % | 4.5 s |
| libjpeg-turbo 3.2, best of 6 scan scripts | 6.34 % | — |
| libjpeg-turbo, baseline with optimized Huffman only | ~2 % | — |

Both only rewrite the entropy coding; the DCT coefficients stay identical.
mozjpeg is a fork of libjpeg-turbo that adds one thing that matters here:
it tries many progressive scan layouts per image (where to split the
frequency bands, how many refinement passes) and keeps the smallest.
libjpeg-turbo uses one fixed layout. Trying a few layouts with libjpeg-turbo's
`-scans` closes half the gap.

mozjpeg's last release (4.1.5) is based on libjpeg-turbo 3.0; libjpeg-turbo
3.2 (June 2026) is actively maintained and gets security fixes. So: decoding
and verification use libjpeg-turbo 3.2; jpegtran from mozjpeg stays for its
extra savings until our own scan optimiser (mozjpeg's algorithm is BSD, it can
be ported onto libjpeg-turbo 3.2) matches it. Every result is proven by
comparing coefficients, so a bug in mozjpeg's jpegtran can't damage a file.

libjpeg-turbo 3.2's PNG support (via libspng) is only for cjpeg/djpeg input
and output; it doesn't optimise PNGs. It converts between YCbCr, RGB and CMYK
but has no ICC colour management — profile conversion is ColorSync's job.

## JPEG encoders at the same visual quality (measured 2026-09-27)

24 Kodak PNGs, each encoder swept over its quality setting, size interpolated
per image to the same SSIMULACRA2 score, relative to jpegli:

| SSIMULACRA2 | 70 | 80 | 85 | 90 |
|---|---|---|---|---|
| **jpegli** | **100 %** | **100 %** | **100 %** | **100 %** |
| Apple ImageIO | 111 % | 111 % | 113 % | 112 % |
| mozjpeg cjpeg | 101 % | 108 % | 119 % | 128 % |
| libjpeg-turbo cjpeg (optimized, progressive) | 112 % | 110 % | 111 % | 115 % |

Speed is not a reason to prefer Apple's encoder: all four encode the 24
images in 0.3–0.7 s (mozjpeg up to 2.3 s at high quality). jpegli wins where
we use it (SSIMULACRA2 80–90); mozjpeg's tuning pays off only at low quality.

## What imgproxy does

imgproxy (the most widely used image-processing server) builds on libvips
with mozjpeg's encoder settings (trellis quantisation, optimised scans) for
JPEG and quantizr/libimagequant for PNG palettes. Its "autoquality" picks a
quality per image by aiming at a target score (DSSIM or a trained model) —
the same idea as our visually-lossless mode, which aims at SSIMULACRA2
(BSD, and the metric JPEG XL and AVIF development use) instead of DSSIM (AGPL).

## Benchmarks still to run

1. AVIF/HEIC: ImageIO re-encode savings vs quality loss on real photos.
2. TIFF: ImageIO LZW/Deflate recompression savings.
3. Own scan optimiser on libjpeg-turbo 3.2 vs mozjpeg jpegtran.

## Sources

- Competitors: [Clop](https://lowtechguys.com/clop/), [Optimage](https://optimage.app),
  [ImageCrush comparison](https://www.imagecrush.io/blog/best-image-optimizers-for-mac),
  [Zipic comparison](https://zipic.app/blog/best-image-compression-software-mac/),
  [compresto.app: ImageOptim alternatives](https://compresto.app/blog/imageoptim-alternatives),
  [apps.deals comparison](https://blog.apps.deals/imageoptim-alternatives-mac)
- JPEG: [Introducing Jpegli (Google)](https://opensource.googleblog.com/2024/04/introducing-jpegli-new-jpeg-coding-library.html),
  [Users prefer Jpegli (arXiv 2403.18589)](https://arxiv.org/abs/2403.18589),
  [google/jpegli](https://github.com/google/jpegli)
- PNG quantizers: [quantizr](https://github.com/DarthSim/quantizr),
  [exoquant-rs](https://github.com/exoticorn/exoquant-rs),
  [libimagequant licensing](https://pngquant.org/lib/)
- Servers: [imgproxy](https://github.com/imgproxy/imgproxy), [libvips](https://github.com/libvips/libvips)
- SVG: [oxvg](https://github.com/noahbald/oxvg), [oxvg optimiser wiki](https://github.com/noahbald/oxvg/wiki/Optimiser)
- GIF: [gifsicle](https://github.com/kohler/gifsicle), [rusty_gif](https://github.com/Remade-With-Rust/rusty_gif)
- DNG: [DNG 1.7 / JPEG XL in rawspeed](https://github.com/darktable-org/rawspeed/pull/971),
  [dnglab recompression idea](https://github.com/dnglab/dnglab/issues/119)
- Metrics: [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2)
- Maintenance status: GitHub API, 2026-09-26 (libjpeg-turbo 3.2.0 released
  2026-06-30; mozjpeg's last tag v4.1.5, master still active; oxvg v0.0.8
  2026-09-18; jpegoptim v1.5.6 2025-09-15; gifsicle last push 2026-01-31).
