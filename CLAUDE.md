# just-smaller (engine + CLI)

- `Tools/build.sh` builds all optimizers into `build/tools` (Rust via rustup,
  CMake; first run ~4 min). Submodules in `Vendor/` are pinned to release
  tags, or to a branch commit (oxvg, our forks); build.sh fetches missing ones and moves a checkout
  to its pin (after a pull) when nothing in it would be lost — no changes, no
  commits that are only local; otherwise it stops. `Tools/update-forks.sh`
  moves the pins of our forks to their latest commits.
  OxiPNG, zopfli and libdeflater are our forks: `Vendor/oxipng`
  (happyarts/oxipng, branch `master`), `Vendor/zopfli` (happyarts/zopfli,
  `main`) and `Vendor/libdeflater` (happyarts/libdeflater, `master`, whose
  submodule libdeflate is happyarts/libdeflate, `master`). That branch is
  upstream's plus our changes as commits (no patches); changes go there and
  the submodule moves with them; branches for upstream PRs start from
  upstream's branch. build.sh builds OxiPNG as checked out and points it at
  libdeflater (libdeflate levels 13 and 14, `--zc`) and zopfli (faster, for
  `--zopfli`, used at Maximum). Our OxiPNG lock file names libdeflater (the
  version of our fork) and zopfli without a registry source, since the build
  replaces them. A commit that went upstream drops out when we move onto
  upstream; before such a rebase, tag the commit the engine pins
  (`pin-YYYY-MM-DD`) so older engine commits still build. Files a fork
  changes carry a one-line notice at the top (Apache-2.0 asks for it).
- `Tools/test.sh` runs `swift test` (tests use `build/tools`); it and the
  corpus runner find a full Xcode themselves (`Tools/xcode-env.sh`), also
  when `xcode-select` points at the Command Line Tools.
- `Tests/corpus/run.sh --quick|--full` checks every result on the local test
  corpus in `../Testkorpus` (never commit images). Before a commit: always
  build and `swift test`; `--quick` when a change can alter what a level
  produces (pipeline, OxiPNG, zopfli, a tool); `--full` before a new baseline
  or for larger level changes. The runner uses Balanced; zopfli only runs at
  Maximum (`run.sh --quick -- --effort maximum`). A change to converting
  (JPEG ↔ JPEG XL: FileConverter, jxl-transcode, jxl-pixels, the rules in
  JPEGLayout) runs `Tests/corpus/convert.sh --quick`, `--full` before a new
  baseline.
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
