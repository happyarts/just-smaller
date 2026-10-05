#!/bin/sh
# Builds Google's libultrahdr decoder (ultrahdr_app, Apache-2.0) next to the
# test corpus, for the corpus runner's second opinion on HDR gain maps: an
# Ultra HDR JPEG and its result must decode to the same HDR picture. A test
# tool only — never part of the engine or the app. Needs the network once
# (the source and its libjpeg-turbo) and CMake.
#
# usage: Tests/corpus/build-ultrahdr.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/Tools/xcode-env.sh"
CORPUS=${JUST_SMALLER_CORPUS:-$(dirname "$ROOT")/Testkorpus}
TAG=v2.0.2
BIN="$CORPUS/.bin"; SRC="$BIN/libultrahdr-src"
command -v cmake >/dev/null || PATH="$ROOT/.tools/bin:$PATH"
command -v cmake >/dev/null || { echo >&2 "CMake missing: run Tools/build.sh once (it installs one into .tools), or brew install cmake"; exit 2; }
mkdir -p "$BIN"
if [ ! -d "$SRC" ]; then
	git clone -q --depth 1 --branch "$TAG" https://github.com/google/libultrahdr "$SRC"
fi
[ "$(git -C "$SRC" describe --tags)" = "$TAG" ] || { echo >&2 "$SRC is not at $TAG"; exit 2; }
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DUHDR_BUILD_DEPS=ON \
	-DUHDR_ENABLE_HEIF=OFF -DUHDR_ENABLE_INSTALL=OFF -Wno-dev --log-level=ERROR > /dev/null
cmake --build "$SRC/build" -j 8 --target ultrahdr_app > /dev/null
cp "$SRC/build/ultrahdr_app" "$BIN/ultrahdr_app"
echo "built $BIN/ultrahdr_app ($TAG)"
