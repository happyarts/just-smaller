// Just Smaller runs on Apple Silicon only: the optimizers are built for arm64,
// and 16-bit floating point images are read with Float16, which Intel Macs lack.
#if !arch(arm64)
#error("JustSmallerKit builds for Apple Silicon (arm64) only")
#endif
