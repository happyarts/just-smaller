# just-smaller (engine + CLI)

- `Tools/build.sh` builds all optimizers into `build/tools` (Rust via rustup,
  CMake; first run ~4 min). Submodules in `Vendor/` are pinned to release
  tags (ECT, oxvg: a master/main commit); build.sh only fetches missing ones and never moves
  a checkout — it stops when one isn't at its pinned commit (after a pull).
  ECT, OxiPNG and libdeflate are built from copies with
  `Tools/{ect-png,oxipng,libdeflater}/patches/*.patch` applied (the
  checkouts stay pinned). libdeflate comes with the libdeflater crate
  (`Vendor/libdeflater`), pinned to the version OxiPNG's Cargo.lock names.
  zopfli is `Vendor/zopfli`, our fork `happyarts/zopfli`: its `main` is
  upstream plus our changes as commits (no patches); changes go there and
  the submodule moves with them; branches for upstream PRs start from
  upstream's `main`. build.sh points OxiPNG at both (libdeflate levels 13
  and 14, `--zc`; a faster zopfli for `--zopfli`). A patch that
  went upstream is deleted when the pin moves past it; ECT's `1-simd-…` is
  fhanau/Efficient-Compression-Tool#161.
- `Tools/test.sh` runs `swift test` (tests use `build/tools`); it and the
  corpus runner find a full Xcode themselves (`Tools/xcode-env.sh`), also
  when `xcode-select` points at the Command Line Tools.
- `Tests/corpus/run.sh --quick|--full` checks every result on the local test
  corpus in `../Testkorpus` (never commit images). Before a commit: always
  build and `swift test`; `--quick` when a change can alter what a level
  produces (pipeline, OxiPNG, ECT, a tool); `--full` before a new baseline or
  for larger level changes. A change to zopfli alone (while no level uses
  `--zopfli`) needs byte comparisons of its output instead.
  `--update-baseline` after intended size changes.
  It also compares Google's XMP with a second reader (`google-xmp.py`).
  `Tests/corpus/bench.sh <folder>` times one job (`--cli` for another build):
  a change on the hot path must not slow plain files down.
- The promise: never damage an image, never change the format. Every result
  is verified (pixels / DCT coefficients / SVG rendering) or thrown away.
- Only MIT/BSD/Apache tools; no GPL.
- This repository is public: nothing private goes in here — and no research
  either. Measurements, tool comparisons, thresholds and the reasoning behind
  them live in the private app repo (`../just-smaller-app/docs/`); code
  comments here say what the code does, not how it was measured.
- Untrusted input never crashes the app: every read of a file's bytes goes
  through the readers in `Sources/JustSmallerKit/Structure/` (ByteView,
  JPEGMarkers, PNGChunks/RIFFChunks, TIFFReader, IPTCRecords, BMFFBoxes,
  GoogleXMP, MP4Metadata, MetadataRegions, Zlib with a size limit) — filters,
  detection and the structure check alike. Never decide anything by searching a whole file's bytes for a
  signature: any short sequence turns up by chance in compressed image data
  and Base64. Look where the format keeps it (a segment, chunk or box); a
  byte search may only pre-select what a real reader then confirms.
  Writers live next to their readers and follow the specification.
- A JPEG's parts (several images, leftover bytes, motion photo video) and
  what may change in them: only `JPEGLayout`. What stays byte for byte
  unread (a video, container entries) is looked into by the metadata check. The optimizer, the pipeline
  and the checks all ask it; a new JPEG rule goes there, never into one of them.
- Fuzzing on real files (off by default; a sample of two real files per
  format, seconds): `JUST_SMALLER_FUZZ=../Testkorpus Tools/test.sh --filter CorpusFuzz`.
  Before a release every file: add `JUST_SMALLER_FUZZ_ALL=1`.
  Cases that once broke a reader go into `HostileInputTests`.
