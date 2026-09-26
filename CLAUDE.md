# just-smaller (engine + CLI)

- `Tools/build.sh` builds all optimizers into `build/tools` (Rust via rustup,
  CMake; first run ~4 min). Submodules in `Vendor/` are pinned to release
  tags (mozjpeg: master); build.sh only fetches missing ones and never moves
  a checkout.
- `swift build`, `swift test` (tests use `build/tools`).
- `Tests/corpus/run.sh --quick|--full` checks every result on the local test
  corpus in `../Testkorpus` (never commit images). Run it before commits that
  touch the engine or a tool; `--update-baseline` after intended size changes.
- The promise: never damage an image, never change the format. Every result
  is verified (pixels / DCT coefficients / SVG rendering) or thrown away.
- Only MIT/BSD/Apache tools; no GPL. Tool choices and measurements:
  `docs/tools-research.md`; bugs found in tools: `docs/upstream-findings.md`.
- This repository is public: nothing private goes in here.
