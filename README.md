# Just Smaller — engine and command-line tool

Makes images smaller without making them worse. This repository holds the
engine behind the Mac app [Just Smaller](https://markus-kaemmerer.de/justsmaller)
and a command-line tool built on it:

```sh
just-smaller photo.jpg screenshots/        # lossless, in place, originals to the Trash
just-smaller --lossy --suffix=-web *.png    # lossy, next to the originals
just-smaller --output ~/Desktop/small --json shoot/
just-smaller --to jxl photos/                # JPEG → JPEG XL without loss
just-smaller --to jpeg photo.jxl              # … and back, byte for byte
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
- **The format never changes behind your back.** A PNG stays a PNG. Only
  when asked (`--to jxl`), a JPEG becomes a JPEG XL: smaller, yet
  holding the very same DCT coefficients, and the JPEG can be rebuilt from it
  byte for byte (`--to jpeg`). It counts only when that rebuilding gives
  exactly the JPEG and a second, independent JPEG XL decoder shows the same
  picture. A JPEG XL viewer shows one image only, so HDR photos with a gain
  map, portraits with a depth map and motion photos stay JPEG.
- **Private metadata is removed** (location, camera serial numbers, editing
  history) — never the colour profile, the orientation or the resolution,
  which would change how the image looks or the size it is shown at. Files
  with Content Credentials (C2PA) are left alone, because any change would
  break their signature.
- **Originals go to the Trash**; permissions, tags and the creation date carry
  over, and files are swapped atomically.
- **No network access.** Nothing leaves the Mac.

## Formats and tools

| Format | Lossless | Lossy |
|---|---|---|
| PNG | own metadata filter + [OxiPNG](https://github.com/oxipng/oxipng) (our fork, [happyarts/oxipng](https://github.com/happyarts/oxipng)); at Maximum effort also OxiPNG with [Zopfli](https://github.com/zopfli-rs/zopfli) (our fork, [happyarts/zopfli](https://github.com/happyarts/zopfli)), not for animated PNGs | palette reduction with [quantizr](https://github.com/DarthSim/quantizr) (`Tools/png-quantize`), then the same |
| JPEG | own metadata filter + own scan optimizer (`Tools/jpeg-scan`: finds the progressive scan split that codes each image smallest, written with [libjpeg-turbo](https://libjpeg-turbo.org)), proven by comparing DCT coefficients (`Tools/jpegcmp`) | [jpegli](https://github.com/google/jpegli), only when the original is of higher quality than the target |
| WebP | cwebp ([libwebp](https://chromium.googlesource.com/webm/libwebp)), lossless files only | — |
| SVG | [OXVG](https://github.com/noahbald/oxvg) with exact geometry, checked by rendering with [resvg](https://github.com/linebender/resvg); files with scripts, animation or embedded HTML are left alone | OXVG with its default approximations |
| HEIC | own metadata filter: EXIF and XMP rewritten in their items, the coded image, HDR gain maps and depth data stay byte for byte | re-encoded with Apple ImageIO, the original's metadata put back; HDR gain maps, depth data and HDR brightness kept |
| GIF | comes in a later version | |
| JPEG XL | made from a JPEG: the JPEG rebuilt, filtered and stored anew (`Tools/jxl-transcode`), proven by the rebuilt JPEGs' coefficients and by decoding with jxl-rs; other JPEG XL files are left as they are for now | — |
| JPEG → JPEG XL (on request) | own metadata filter, then `Tools/jxl-transcode` ([libjxl](https://github.com/libjxl/libjxl)): the JPEG's coefficients coded anew, with what it takes to rebuild the JPEG; proven by rebuilding it, and by decoding with [jxl-rs](https://github.com/libjxl/jxl-rs) (`Tools/jxl-pixels`) | — |

## Building

Needs a Mac with Apple Silicon and macOS 26 or later, Xcode 27, CMake and
[Rust](https://rust-lang.org/) via [rustup](https://rustup.rs/).

```sh
git clone --recurse-submodules https://github.com/happyarts/just-smaller.git
cd just-smaller
Tools/build.sh                 # builds the optimizers into build/tools (a few minutes)
swift build -c release         # builds the just-smaller command
Tools/test.sh                  # unit and end-to-end tests against build/tools
```

`Tools/test.sh` runs `swift test` with a full Xcode even if `xcode-select`
points at the Command Line Tools (see `Tools/xcode-env.sh`). With Xcode
selected, plain `swift build` and `swift test` work too.

The command looks for the optimizers in `--tools`, `$JUST_SMALLER_TOOLS`, a
`just-smaller-tools` folder next to it, or its own folder.

## Layout

| Path | What |
|---|---|
| `Sources/JustSmallerKit` | The engine: pipelines, verification, atomic replacement, folder scanning |
| `Sources/just-smaller` | The command-line tool |
| `Tools/build.sh` | Builds all optimizers from `Vendor/` (git submodules at release tags or a pinned commit) |
| `Tools/test.sh`, `Tools/xcode-env.sh` | Runs the tests; finds a full Xcode for SwiftPM |
| `Vendor/oxipng` | OxiPNG from our fork `happyarts/oxipng` (its `master`): on larger images the evaluation chooses the PNG filters section by section among the strategies it tries (oxipng/oxipng#883), and only the candidates that evaluate best get the final compression; libdeflate levels 13 and 14 (`--zc`); with `--zopfli`, the zopfli options below; a filter strategy `Incremental` (`-f 10`) that chooses each line's filter by its cost in a running deflate stream |
| `Vendor/libdeflater` | The libdeflater crate OxiPNG compresses with, from our fork `happyarts/libdeflater` (its `master`), with libdeflate from our fork `happyarts/libdeflate`: compression levels 13 and 14 beyond libdeflate's 12 (costs with fractional bits, blocks split by the cost of the chosen items, matches searched near both ends of long matches, Huffman codes smoothed for run-length coding) |
| `Vendor/zopfli` | The zopfli crate OxiPNG uses with `--zopfli`, from our fork `happyarts/zopfli` (its `main`): the matches of the first pass are kept for later iterations (identical output); optional binary tree match finder, more Huffman code length choices for each dynamic block, parse passes with the real code lengths, the 1 MB chunks compressed on several threads (identical output), and blocks joined across those chunks where one block is smaller than two; buffers are allocated once and reused (identical output); minimum Rust version 1.88, as OxiPNG's |
| `Tools/svg-tool` | The OXVG optimiser and the resvg renderer, without the rest of either command (Rust) |
| `Tools/png-quantize` | Palette reduction with quantizr, keeping the metadata (Rust) |
| `Tools/jpegcmp` | Compares two JPEGs' DCT coefficients, or a JPEG's pixels with another decoder's (C, libjpeg-turbo) |
| `Tools/jxl-transcode` | JPEG to JPEG XL without loss and back, with libjxl (C++) |
| `Tools/jxl-pixels` | Decodes JPEG XL with jxl-rs, the decoder of Chrome and Firefox, for checking (Rust) |
| `Vendor/libjxl` | libjxl at a release tag, built as a small library: only Highway's NEON code paths, skcms |
| `Tests/corpus` | Builds a local test corpus and runs the tool over it, checking every result |

## Licence

Just Smaller's own code is under the [Mozilla Public License 2.0](LICENSE).
The bundled optimizers keep their own licences: OxiPNG, OXVG, quantizr,
libdeflate (MIT); libdeflater and Zopfli (Apache-2.0); libwebp, jpegli, libjpeg-turbo, libjxl and jxl-rs (BSD-style). They run as
separate programs.
