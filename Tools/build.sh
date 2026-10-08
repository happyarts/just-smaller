#!/bin/sh
# Builds the command-line optimizers Just Smaller runs, from the sources in
# Vendor/ (git submodules pinned to released versions; ECT to a master
# commit, since its last release lacks years of fixes; oxvg to a main commit
# with path and transform fixes that aren't released yet; zopfli to our fork,
# happyarts/zopfli) and Tools/. ECT, OxiPNG and libdeflate (through the
# libdeflater crate) are built from copies with our patches (Tools/*/patches)
# applied.
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
for dep in oxipng oxvg libwebp libjpeg-turbo jpegli ect libdeflater zopfli; do
	[ -n "$(ls -A "$ROOT/Vendor/$dep" 2>/dev/null)" ] ||
		git -C "$ROOT" submodule update --init --depth 1 "Vendor/$dep"
done
for dep in highway skcms libpng zlib lcms libjpeg-turbo; do
	[ -n "$(ls -A "$ROOT/Vendor/jpegli/third_party/$dep" 2>/dev/null)" ] ||
		git -C "$ROOT/Vendor/jpegli" submodule update --init --depth 1 "third_party/$dep"
done
# ECT: only libpng; its mozjpeg is for JPEG, which ect-png leaves out.
[ -n "$(ls -A "$ROOT/Vendor/ect/src/libpng" 2>/dev/null)" ] ||
	git -C "$ROOT/Vendor/ect" submodule update --init --depth 1 src/libpng
[ -n "$(ls -A "$ROOT/Vendor/libdeflater/libdeflate-sys/libdeflate" 2>/dev/null)" ] ||
	git -C "$ROOT/Vendor/libdeflater" submodule update --init --depth 1 libdeflate-sys/libdeflate
# A checkout that isn't at the commit this repository pins (a pull moved the
# pin) would build the old version or fail on a lockfile. It is left as it
# is — it may hold local work — so stop and say how to update it.
stale=$(git -C "$ROOT" submodule status -- Vendor/oxipng Vendor/oxvg Vendor/libwebp Vendor/libjpeg-turbo \
	Vendor/jpegli Vendor/ect Vendor/libdeflater Vendor/zopfli | sed -n 's/^+[0-9a-f]* \([^ ]*\).*/\1/p')
if [ -n "$stale" ]; then
	echo "Not at the pinned commit: $stale" >&2
	echo "Update with: git submodule update --depth 1 $stale" >&2
	exit 1
fi

log() { printf '%s\n' "$*" >&2; }
run() { # name, command… — output goes to build/work/NAME.log, shown on failure
	name=$1; shift
	"$@" >"$WORK/$name.log" 2>&1 || { tail -40 "$WORK/$name.log" >&2; log "error: building $name failed"; exit 1; }
}

# A copy of a pinned checkout (or a folder in it) with our patches applied, so
# the checkout stays at its pin. Renewed, in a fresh folder swapped in whole,
# only when the pin, a local change or a patch changes: builds stay incremental.
patched_copy() { # checkout dest patches-dir [folder]
	pc_stamp=$( { git -C "$1" rev-parse HEAD; git -C "$1" status --porcelain; git -C "$1" diff HEAD;
		git -C "$1" submodule status --recursive; git -C "$1" submodule --quiet foreach --recursive git diff HEAD;
		cat "$3"/*.patch; } | shasum | cut -c1-40)
	[ "$(cat "$2.stamp" 2>/dev/null)" = "$pc_stamp" ] && return
	pc_fresh=$(mktemp -d "$2.XXXXXX")
	rsync -a --exclude .git --exclude target --exclude tests/files "$1/${4:-.}/" "$pc_fresh"
	for pc_patch in "$3"/*.patch; do
		run "$(basename "$2")-patch" patch -p1 --forward -d "$pc_fresh" -i "$pc_patch"
	done
	rm -rf "$2" "$2.stamp"
	mv "$pc_fresh" "$2"
	echo "$pc_stamp" > "$2.stamp"
}

# System libraries from Homebrew must not leak into the tools.
CMAKE_COMMON="-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local -DBUILD_SHARED_LIBS=OFF"

# JPEG: libjpeg-turbo (actively maintained, current security fixes) for
# everything — our scan optimizer jpeg-scan, jpegcmp and jpegli's JPEG input.
log "libjpeg-turbo"
TURBO=$WORK/libjpeg-turbo
run turbo-configure cmake -S "$ROOT/Vendor/libjpeg-turbo" -B "$TURBO" $CMAKE_COMMON -DENABLE_SHARED=OFF \
	-DWITH_TURBOJPEG=OFF -DCMAKE_INSTALL_PREFIX="$TURBO/install"
run turbo cmake --build "$TURBO" -j "$JOBS" --target install

log "jpegcmp"
cc -O2 -mcpu=apple-m1 -mmacosx-version-min=26.0 -I"$TURBO/install/include" \
	"$ROOT/Tools/jpegcmp/main.c" "$TURBO/install/lib/libjpeg.a" -o "$OUT/jpegcmp"

log "jpeg-scan"
cc -O2 -mcpu=apple-m1 -mmacosx-version-min=26.0 -I"$TURBO/install/include" \
	"$ROOT/Tools/jpeg-scan/main.c" "$TURBO/install/lib/libjpeg.a" -o "$OUT/jpeg-scan"

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
ECT_SRC=$WORK/ect-src
patched_copy "$ROOT/Vendor/ect" "$ECT_SRC" "$ROOT/Tools/ect-png/patches" src
run ect-configure cmake -S "$ROOT/Tools/ect-png" -B "$WORK/ect-png" $CMAKE_COMMON -DECT_SRC="$ECT_SRC"
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
# OxiPNG with libdeflate levels 13-14 and a faster zopfli instead of the ones
# from crates.io: libdeflater (which brings libdeflate) from our patched copy,
# zopfli from our fork as it is checked out (Vendor/zopfli).
patched_copy "$ROOT/Vendor/libdeflater" "$WORK/libdeflater-src" "$ROOT/Tools/libdeflater/patches"
patched_copy "$ROOT/Vendor/oxipng" "$WORK/oxipng-src" "$ROOT/Tools/oxipng/patches"
cargo_tool oxipng "$WORK/oxipng-src/Cargo.toml" --locked --bin oxipng \
	--config "patch.crates-io.libdeflater.path=\"$WORK/libdeflater-src\"" \
	--config "patch.crates-io.libdeflate-sys.path=\"$WORK/libdeflater-src/libdeflate-sys\"" \
	--config "patch.crates-io.zopfli.path=\"$ROOT/Vendor/zopfli\""
# Only the OXVG optimiser and resvg, through our svg-tool: the oxvg command
# also carries a JSX compiler, a linter and a language server.
cargo_tool svg-tool "$ROOT/Tools/svg-tool/Cargo.toml" --locked
cargo_tool png-quantize "$ROOT/Tools/png-quantize/Cargo.toml" --locked

for tool in jpeg-scan jpegcmp cjpegli cwebp ect-png oxipng svg-tool png-quantize; do
	if [ -n "$ENTITLEMENTS" ]; then
		codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$OUT/$tool" 2>/dev/null
	else
		codesign --force --sign "$IDENTITY" --timestamp=none "$OUT/$tool" 2>/dev/null
	fi
done
log "tools in $OUT"
