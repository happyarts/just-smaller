# Test corpus

A local set of test images plus a runner that pushes them through the
`just-smaller` command and checks every result. The images never go into the
repository (image rights); they live in a `Testkorpus` folder next to the repository
(override with `JUST_SMALLER_CORPUS`).

```sh
Tests/corpus/fetch-real-images.py   # once: freely licensed files into download-cache/ (sources in the script)
Tests/corpus/build-corpus.sh        # assemble quick/ and full/ (offline, from the cache and this Mac)
Tests/corpus/run.sh --quick         # ~80 files, seconds — after every change
Tests/corpus/run.sh --full          # ~700 files, 1 GB, four minutes — before a release or a tool update
Tests/corpus/run.sh --private       # your own photos in Testkorpus/private, if you have that folder
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
  data differently depending on Huffman tables
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
- `full/real-multi-jpeg/`, `full/multi-jpeg/`: JPEGs that hold several images
  — iPhone and Pixel HDR photos with gain maps, ISO 21496-1 gain maps, MPO
  stereo pairs; ISO gain maps and portraits with depth and mattes written by
  Apple's frameworks (`multi-image.swift`)
- `full/real-photoprism/`: PhotoPrism's sample collection — photos from many
  cameras and phones (Canon, Nikon, Panasonic, Sony, GoPro, DJI, iPhone,
  Pixel, Samsung), motion photos, portraits, panoramas, damaged JPEGs.
  CC BY-NC-SA 4.0: for testing this engine only, never distributed.
- Phone photos from Wikimedia Commons that hold more than one image, found
  by reading the first 128 KB of photos in "Taken with …" categories, one
  request every two seconds (`fetch-real-images.py`).
- `full/real-unchanged/`, `full/unchanged/`: files that must stay byte for
  byte as they are (`unchanged-*`, like `broken-*`): multi-picture indexes
  that don't fit the file, a gain map found only through XMP, a motion photo
  (video after the images). All of them go into the quick tier too.

`build-corpus.sh` keeps the corpus lean (`dedup.py`): exact duplicates go,
and of JPEGs and PNGs of the same kind (encoder settings, segments or chunks,
size within a factor of two) three per folder stay.
