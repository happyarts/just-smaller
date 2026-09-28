#!/bin/sh
# Builds the command-line optimizers Just Smaller runs, from the sources in
# Vendor/ (git submodules pinned to released versions; mozjpeg and ECT to a
# master commit, since their last releases lack years of fixes) and Tools/.
#
#     Tools/build.sh [OUTPUT_DIR] [CODE_SIGN_IDENTITY] [ENTITLEMENTS]
#
# OUTPUT_DIR defaults to build/tools. ENTITLEMENTS (a plist) is given when the
# tools go into a sandboxed app: they must inherit its sandbox. Everything is
# linked statically, so the tools only depend on macOS itself. Needs Rust (rustup) and CMake; without a
# CMake on the system a private copy is installed into .tools/.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/build/tools}
IDENTITY=${2:--}
ENTITLEMENTS=${3:-}
WORK=$ROOT/build/work
mkdir -p "$OUT" "$WORK"

export PATH="$ROOT/.tools/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=26.0
JOBS=$(sysctl -n hw.ncpu)

if ! command -v cargo >/dev/null; then
	echo "error: Rust not found. Install it with rustup: https://rustup.rs" >&2
	exit 1
fi
if ! command -v cmake >/dev/null; then
	echo "Installing a private CMake into .tools/ …" >&2
	python3 -m venv "$ROOT/.tools" && "$ROOT/.tools/bin/pip" install --quiet cmake
fi

# Fetch missing sources on first use (a checkout that is already there is left
# as it is); jpegli only needs a few of its submodules.
for dep in oxipng oxvg libwebp mozjpeg libjpeg-turbo jpegli ect; do
	[ -n "$(ls -A "$ROOT/Vendor/$dep" 2>/dev/null)" ] ||
		git -C "$ROOT" submodule update --init --depth 1 "Vendor/$dep"
done
for dep in highway skcms libpng zlib lcms; do
	[ -n "$(ls -A "$ROOT/Vendor/jpegli/third_party/$dep" 2>/dev/null)" ] ||
		git -C "$ROOT/Vendor/jpegli" submodule update --init --depth 1 "third_party/$dep"
done
# ECT: only libpng; its mozjpeg is for JPEG, which ect-png leaves out.
[ -n "$(ls -A "$ROOT/Vendor/ect/src/libpng" 2>/dev/null)" ] ||
	git -C "$ROOT/Vendor/ect" submodule update --init --depth 1 src/libpng

log() { printf '%s\n' "$*" >&2; }
run() { # name, command… — output goes to build/work/NAME.log, shown on failure
	name=$1; shift
	"$@" >"$WORK/$name.log" 2>&1 || { tail -40 "$WORK/$name.log" >&2; log "error: building $name failed"; exit 1; }
}

# System libraries from Homebrew must not leak into the tools.
CMAKE_COMMON="-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local -DBUILD_SHARED_LIBS=OFF"

# JPEG is split between two libjpeg flavours:
# - libjpeg-turbo (actively maintained, current security fixes) for
#   everything that reads untrusted JPEGs to check or decode them: jpegcmp
#   and jpegli's JPEG input;
# - mozjpeg only for jpegtran, for its scan optimization. Its output is
#   checked by the libjpeg-turbo based jpegcmp.
log "libjpeg-turbo"
TURBO=$WORK/libjpeg-turbo
run turbo-configure cmake -S "$ROOT/Vendor/libjpeg-turbo" -B "$TURBO" $CMAKE_COMMON -DENABLE_SHARED=OFF \
	-DWITH_TURBOJPEG=OFF -DCMAKE_INSTALL_PREFIX="$TURBO/install"
run turbo cmake --build "$TURBO" -j "$JOBS" --target install

log "mozjpeg"
MOZ=$WORK/mozjpeg
run mozjpeg-configure cmake -S "$ROOT/Vendor/mozjpeg" -B "$MOZ" $CMAKE_COMMON -DENABLE_SHARED=OFF \
	-DPNG_SUPPORTED=OFF -DWITH_TURBOJPEG=OFF -DCMAKE_INSTALL_PREFIX="$MOZ/install"
run mozjpeg cmake --build "$MOZ" -j "$JOBS" --target install
cp "$MOZ/install/bin/jpegtran" "$OUT/jpegtran"

log "jpegcmp"
cc -O2 -mcpu=apple-m1 -mmacosx-version-min=26.0 -I"$TURBO/install/include" \
	"$ROOT/Tools/jpegcmp/main.c" "$TURBO/install/lib/libjpeg.a" -o "$OUT/jpegcmp"

log "jpegli"
JPEGLI=$WORK/jpegli
run jpegli-configure cmake -S "$ROOT/Vendor/jpegli" -B "$JPEGLI" $CMAKE_COMMON -DBUILD_TESTING=OFF \
	-DJPEGLI_BUNDLE_LIBPNG=ON -DJPEGLI_ENABLE_SJPEG=OFF -DJPEGLI_ENABLE_SKCMS=ON \
	-DJPEG_INCLUDE_DIR="$TURBO/install/include" -DJPEG_LIBRARY="$TURBO/install/lib/libjpeg.a"
run jpegli cmake --build "$JPEGLI" -j "$JOBS" --target cjpegli
cp "$JPEGLI/tools/cjpegli" "$OUT/cjpegli"
# zlib's CMake renames zconf.h in its source tree; put it back so the submodule stays clean
git -C "$ROOT/Vendor/jpegli/third_party/zlib" checkout -- zconf.h 2>/dev/null || true

log "libwebp"
WEBP=$WORK/libwebp
run libwebp-configure cmake -S "$ROOT/Vendor/libwebp" -B "$WEBP" $CMAKE_COMMON \
	-DWEBP_BUILD_CWEBP=ON -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF \
	-DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
	-DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_LIBWEBPMUX=ON \
	-DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON \
	-DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON
run libwebp cmake --build "$WEBP" -j "$JOBS" --target cwebp
cp "$WEBP/cwebp" "$OUT/cwebp"

# ECT's PNG optimizer only (Tools/ect-png): no mozjpeg, gzip or zip code.
log "ect-png"
run ect-configure cmake -S "$ROOT/Tools/ect-png" -B "$WORK/ect-png" $CMAKE_COMMON -DECT_SRC="$ROOT/Vendor/ect/src"
run ect-png cmake --build "$WORK/ect-png" -j "$JOBS" --target ect-png
cp "$WORK/ect-png/ect-png" "$OUT/ect-png"

# Rust tools: an explicit target and Apple's ld as linker keep build scripts
# and proc-macros apart from target-only flags (oxvg's .cargo/config adds
# linker flags for its Node.js build that break proc-macros otherwise). Each
# gets its own target directory.
export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=/usr/bin/ld
cargo_tool() { # name manifest [cargo args…]
	name=$1 manifest=$2; shift 2
	log "$name"
	run "$name" cargo build --release --target aarch64-apple-darwin --manifest-path "$manifest" \
		--target-dir "$WORK/cargo-$name" "$@"
	cp "$WORK/cargo-$name/aarch64-apple-darwin/release/$name" "$OUT/$name"
}
cargo_tool oxipng "$ROOT/Vendor/oxipng/Cargo.toml" --locked --bin oxipng
# Only the OXVG optimiser and resvg, through our svg-tool: the oxvg command
# also carries a JSX compiler, a linter and a language server.
cargo_tool svg-tool "$ROOT/Tools/svg-tool/Cargo.toml" --locked
cargo_tool png-quantize "$ROOT/Tools/png-quantize/Cargo.toml" --locked

for tool in jpegtran jpegcmp cjpegli cwebp ect-png oxipng svg-tool png-quantize; do
	if [ -n "$ENTITLEMENTS" ]; then
		codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$OUT/$tool" 2>/dev/null
	else
		codesign --force --sign "$IDENTITY" --timestamp=none "$OUT/$tool" 2>/dev/null
	fi
done
log "tools in $OUT"
