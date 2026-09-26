# Upstream findings

Bugs and gaps found in third-party tools while building Just Smaller, collected
for upstream reports or pull requests later. Each entry should be reproducible
from what is written here.

Status: `open` = not reported yet.

## cwebp (libwebp) — webmproject/libwebp

- **`-o` after `--` is silently ignored, exit status 0** — `open`
  `cwebp -lossless -o out.webp -- in.webp` works, but
  `cwebp -lossless -- in.webp -o out.webp` writes nothing and still exits 0:
  `--` makes the next argument the input and stops option parsing, so the
  trailing `-o` is dropped. A missing output with a success status is easy to
  mistake for success. Suggest: error out on arguments after the input file.
  (`examples/cwebp.c`, the `"--"` branch of the argument loop.)

- **Lossless mode silently discards RGB under fully transparent pixels** — `open`
  (documentation/defaults, not strictly a bug) Without `-exact`, `-lossless`
  zeroes the colour of alpha=0 pixels. On a 64×64 image with data under a
  transparent mask, 4095 of 4096 pixels changed. That is surprising for a mode
  called lossless; at least the help text for `-lossless` could point at `-exact`.

## oxvg — noahbald/oxvg

- **No merging of duplicate gradient definitions** — `open` (feature request)
  Files that define the same `linearGradient` several times (common in exports
  where each shape gets its own copy) keep every copy. svgcleaner merged them;
  on 16 real SVGs that was worth ~5% on top of oxvg (e.g. a Zoom icon: 1970 B
  with oxvg alone, 1201 B with the duplicates merged).

- **Malformed config file panics** — `open`
  `Config::load()` in `crates/oxvg/src/config.rs` panics when `oxvgrc.json`
  (working directory) or `config.json` (config dir) exists but can't be parsed.
  A readable error and non-zero exit would be friendlier, especially since the
  file is picked up implicitly from the working directory.

- **Breaks quoted font-family lists.** `font-family="'Liberation Sans',
  sans-serif"` becomes `font-family="Liberation Sans sans-serif"` (quotes and
  comma dropped), which browsers read as one unknown family and fall back to
  the default serif font. Seen on Wikimedia charts
  (`Center_Squeeze_Example_Bar_Graph_FPTP_AMZ_Percent.svg`,
  `Chart_of_number_of_works_in_the_field_of_Physics_in_the_OpenAlex_database_by_year.svg`),
  also with the default preset. Apple's CoreSVG (Quick Look thumbnails) happens
  to render the broken value with a sans-serif font, WebKit doesn't.
- **`convertPathData.straightCurves` collapses tiny sub-paths** even with a
  positional tolerance of 1e-5: small islands on
  `Isle_of_Man_topographic_map-en.svg` (Wikimedia) disappear.
- **Visible changes on a complex illustration** with the exact-geometry config
  (`Sutton_Hoo_helmet_fig1_-_reconstructed-known.svg`, Wikimedia): a black
  blot on the headdress and changed shading on spears and figures. Cause not
  isolated yet.
- The output repeats `xmlns:svg="http://www.w3.org/2000/svg"` on many
  elements when the source declares that prefix (seen on the chart above;
  harmless, but bloats the output). Cause not investigated.

## ImageOptim (upstream) — ImageOptim/ImageOptim

- **Files lost after optimization** (#412, #442, #443) — fixed in the fork
  [happyarts/ImageOptim](https://github.com/happyarts/ImageOptim), commit "Fix files disappearing after optimization". `saveResult` moved the
  original to a hidden dot-file and returned on the first failure without
  rollback. Could be offered upstream as a PR.
- **Competing workers race instead of chaining** — `open`
  Workers in `runLater` (`Job.m`) only depend on the last `runFirst` worker,
  not on each other, so they may all start from the original and the result
  depends on timing. Harmless while they compete, wrong when a tool is meant
  to work on another's output.
- **`ZopfliWorker` passes `--lossy_transparent` unconditionally** — `open`
  Discards colour under transparent pixels even with `LossyEnabled = NO`.
  (Removed in the fork; still true upstream.)

- **"Strip metadata" removes colour profiles** (#403, #410). jpegtran runs
  with `-copy none`, jpegoptim with `--strip-all` and cwebp with
  `-metadata none`, so Display P3 / Adobe RGB images lose their ICC profile
  and are shown with shifted colours (max. 115–118 levels on the P3 test
  images). Fixed in the fork with `-copy icc`, `--keep-icc`, `-metadata icc`.
- **"Strip metadata" rotates photos** (#429). The EXIF orientation tag goes
  with the rest of EXIF, so portrait photos from phones end up sideways.
  Stopgap in the fork: EXIF is kept on rotated JPEGs. Just Smaller writes a
  minimal EXIF block with only the orientation.

## Apple ImageIO

- **ImageIO reports no colour profile for palette PNGs.** A palette PNG with
  an iCCP chunk decodes to an indexed colour space whose *base* is the profile;
  `CGColorSpace.name` and `sips -g profile` show nothing. Colours are right,
  only tools that look at the top-level space get it wrong.

## Not bugs (checked, keep for reference)

- gifsicle `-O2`/`-O3` reduce the frame count of some animations (85 → 59).
  That is identical consecutive frames being merged with their delays added:
  compared along the timeline the output is identical. Not a bug.
- `NSFileManager replaceItemAtURL:` with default options resets POSIX
  permissions (0640 came out as 0600) while keeping xattrs. Apple API
  behaviour; worked around with `copyfile(COPYFILE_METADATA)` +
  `UsingNewMetadataOnly`.
- **ImageIO decodes identical JPEG data differently.** A JPEG rewritten with
  optimized Huffman tables (same DCT coefficients, `jpegtran -copy all
  -optimize`) decodes up to ~136 levels apart in ImageIO, while libjpeg
  (Pillow) gives bit-identical pixels. ImageIO apparently picks a different
  decode path (upsampling) depending on the entropy coding. Worth a Feedback
  to Apple at some point; for us it means lossless JPEG checks compare the
  DCT coefficients (jpegcmp), not ImageIO's pixels.
- **oxipng `--strip safe` drops gAMA and cHRM.** By design its "display" set
  is only cICP, iCCP, sRGB, pHYs and the APNG chunks, but colour-managed
  viewers (ImageIO) apply gAMA/cHRM: old Photoshop exports with gamma 1/1.8
  look different without them. Just Smaller passes an explicit `--keep` list.
  Could still be raised upstream as a question.
- **oxipng drops iCCP/sRGB when it reduces an image to grayscale** (the RGB
  profile would be invalid). The gray then renders slightly differently in
  colour-managed viewers; Just Smaller's check rejects those results.
- **oxipng `-a` is lossy** by its own description (it rewrites the colour of
  fully transparent pixels). Just Smaller only uses it in lossy mode; lossless
  PNG and WebP results must keep those pixels exactly.
- **jpegtran normalizes the sampling factor of single-component JPEGs**
  (2×2 → 1×1). Meaningless for grayscale, the coefficients stay identical.

