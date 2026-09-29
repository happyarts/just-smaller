# just-smaller (engine + CLI)

- `Tools/build.sh` builds all optimizers into `build/tools` (Rust via rustup,
  CMake; first run ~4 min). Submodules in `Vendor/` are pinned to release
  tags (ECT: a master commit); build.sh only fetches missing ones and never moves
  a checkout.
- `Tools/test.sh` runs `swift test` (tests use `build/tools`); it and the
  corpus runner find a full Xcode themselves (`Tools/xcode-env.sh`), also
  when `xcode-select` points at the Command Line Tools.
- `Tests/corpus/run.sh --quick|--full` checks every result on the local test
  corpus in `../Testkorpus` (never commit images). Run it before commits that
  touch the engine or a tool; `--update-baseline` after intended size changes.
- The promise: never damage an image, never change the format. Every result
  is verified (pixels / DCT coefficients / SVG rendering) or thrown away.
- Only MIT/BSD/Apache tools; no GPL.
- This repository is public: nothing private goes in here — and no research
  either. Measurements, tool comparisons, thresholds and the reasoning behind
  them live in the private app repo (`../just-smaller-app/docs/`); code
  comments here say what the code does, not how it was measured.
