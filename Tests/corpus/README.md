# Test corpus

A local set of test images plus a runner that pushes them through the
`just-smaller` command and checks every result. The images never go into the
repository (image rights); they live in a `Testkorpus` folder next to the repository
(override with `JUST_SMALLER_CORPUS`).

```sh
Tests/corpus/fetch-real-images.py   # once: free photos/graphics (Kodak set, Wikimedia Commons) into download-cache/
Tests/corpus/build-corpus.sh        # assemble quick/ and full/ (offline, from the cache and this Mac)
Tests/corpus/run.sh --quick         # ~60 files, seconds — after every change
Tests/corpus/run.sh --full          # ~400+ files — before a release or a tool update
Tests/corpus/run.sh --quick -- --effort maximum   # pass options to just-smaller
```

`run.sh --update-baseline` records the result sizes; later runs report any file
that got bigger than its baseline, so compression regressions show up even when
everything is still lossless.

## What a run checks

- no file lost, no leftover files, nothing grew, no optimizer error
- raster images decode to identical pixels (`imgcmp.swift`, ImageIO, animation
  timeline aware: merged identical frames with the same total duration pass)
- JPEGs keep their DCT coefficients (`jpegcmp`): ImageIO decodes identical DCT
  data differently depending on Huffman tables, see docs/upstream-findings.md
- colour profile and EXIF orientation survive metadata stripping
- SVGs render the same (Quick Look thumbnail, ≤ 0.1 % antialiasing pixels)
- `broken-*` files are left byte-for-byte alone

The run works on a copy, deletes replaced originals instead of using the Trash,
and never touches any settings.

## Contents

- `full/edge/`: generated edge cases (`generate-edge-cases.py`): bit depths,
  palettes, alpha, interlacing, ICC profiles, EXIF orientation, CMYK,
  animations, broken and misnamed files, Unicode file names
- `full/png`, `jpeg`, … : resources from macOS and installed apps
- `full/photo/`: photos derived from the system desktop pictures
- `full/real-*`: downloaded freely licensed images
