# Just Smaller — engine and command-line tool

Makes images smaller without making them worse. This repository holds the
engine behind the Mac app [Just Smaller](https://markus-kaemmerer.de/justsmaller)
and a command-line tool built on it:

```sh
just-smaller photo.jpg screenshots/        # lossless, in place, originals to the Trash
just-smaller --lossy --suffix=-web *.png    # lossy, next to the originals
just-smaller --output ~/Desktop/small --json shoot/
```

By [Markus Kämmerer](https://markus-kaemmerer.de). Inspired by
[ImageOptim](https://github.com/ImageOptim/ImageOptim) by Kornel Lesiński.

## What it promises

- **Images are never damaged.** Every result is checked against the original
  before it replaces anything: pixels (colour managed, 16 bits per channel
  where needed, across the whole animation), dimensions, orientation and
  colour profile. JPEGs are compared by their DCT coefficients, SVGs are
  rendered and compared. A result that fails is thrown away.
- **Lossless by default.** Lossless results are pixel-identical to the
  original and marked as such.
- **The format never changes behind your back.** A PNG stays a PNG.
- **Private metadata is removed** (location, camera serial numbers, editing
  history) — never the colour profile or the orientation, which would change
  how the image looks. Files with Content Credentials (C2PA) are left alone,
  because any change would break their signature.
- **Originals go to the Trash**; permissions, tags and the creation date carry
  over, and files are swapped atomically.
- **No network access.** Nothing leaves the Mac.

## Formats and tools

| Format | Lossless | Lossy |
|---|---|---|
| PNG | own metadata filter + the PNG part of [ECT](https://github.com/fhanau/Efficient-Compression-Tool) (`Tools/ect-png`); animated PNGs: [OxiPNG](https://github.com/oxipng/oxipng) | palette reduction with [quantizr](https://github.com/DarthSim/quantizr) (`Tools/png-quantize`), then the same |
| JPEG | own metadata filter + jpegtran ([mozjpeg](https://github.com/mozilla/mozjpeg)), proven by comparing DCT coefficients (`Tools/jpegcmp`, [libjpeg-turbo](https://libjpeg-turbo.org)) | [jpegli](https://github.com/google/jpegli), only when the original is of higher quality than the target |
| WebP | cwebp ([libwebp](https://chromium.googlesource.com/webm/libwebp)), lossless files only | — |
| SVG | [OXVG](https://github.com/noahbald/oxvg) with exact geometry, checked by rendering with [resvg](https://github.com/linebender/resvg); files with scripts, animation or embedded HTML are left alone | OXVG with its default approximations |
| HEIC | — | Apple ImageIO, keeping HDR gain maps and depth data |
| GIF | comes in a later version | |

## Building

Needs a Mac with Apple Silicon and macOS 26 or later, Xcode 27, CMake and
[Rust](https://rust-lang.org/) via [rustup](https://rustup.rs/).

```sh
git clone --recurse-submodules https://github.com/happyarts/just-smaller.git
cd just-smaller
Tools/build.sh                 # builds the optimizers into build/tools (a few minutes)
swift build -c release         # builds the just-smaller command
swift test                     # unit and end-to-end tests against build/tools
```

The command looks for the optimizers in `--tools`, `$JUST_SMALLER_TOOLS`, a
`just-smaller-tools` folder next to it, or its own folder.

## Layout

| Path | What |
|---|---|
| `Sources/JustSmallerKit` | The engine: pipelines, verification, atomic replacement, folder scanning |
| `Sources/just-smaller` | The command-line tool |
| `Tools/build.sh` | Builds all optimizers from `Vendor/` (git submodules at release tags or a pinned commit) |
| `Tools/ect-png` | ECT's PNG optimizer on its own, without its JPEG, gzip and zip code (C++) |
| `Tools/svg-tool` | The OXVG optimiser and the resvg renderer, without the rest of either command (Rust) |
| `Tools/png-quantize` | Palette reduction with quantizr, keeping colour metadata (Rust) |
| `Tools/jpegcmp` | Compares two JPEGs' DCT coefficients (C, libjpeg-turbo) |
| `Tests/corpus` | Builds a local test corpus and runs the tool over it, checking every result |

## Licence

Just Smaller's own code is under the [Mozilla Public License 2.0](LICENSE).
The bundled optimizers keep their own licences: OxiPNG, OXVG, quantizr
(MIT); libwebp, jpegli, mozjpeg and libjpeg-turbo (BSD-style). They run as
separate programs.
