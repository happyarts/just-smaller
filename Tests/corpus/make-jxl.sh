#!/bin/sh
# JPEG XL files for the corpus, made from its own JPEGs with our jxl-transcode
# (Tools/build.sh): with and without compressed metadata boxes, at a low
# effort (as other programs write them) and the usual one. Into full/jxl/;
# build-corpus.sh calls it, and it can add them to an existing corpus.
#
# usage: Tests/corpus/make-jxl.sh [CORPUS]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CORPUS=${1:-${JUST_SMALLER_CORPUS:-$(cd "$HERE/../../.." && pwd)/Testkorpus}}
TOOL=$HERE/../../build/tools/jxl-transcode
[ -x "$TOOL" ] || { echo >&2 "jxl-transcode missing — run Tools/build.sh (no JPEG XL files made)"; exit 0; }
mkdir -p "$CORPUS/full/jxl"
n=0
for f in "$CORPUS"/full/edge/jpeg-exif-gps-orientation.jpg "$CORPUS"/full/edge/jpeg-444.jpg \
	"$CORPUS"/full/edge/jpeg-progressive.jpg "$CORPUS"/full/real-photo-jpeg/*; do
	[ -f "$f" ] || continue
	n=$((n + 1)); [ $n -le 5 ] || break
	# Numbered in this order, so the quick tier (the first two of full/jxl)
	# gets the photo with a location: private data in a JPEG XL.
	name=$(printf '%02d-%s' $n "$(basename "${f%.*}")")
	"$TOOL" encode --effort 7 "$f" "$CORPUS/full/jxl/$name.jxl" 2>/dev/null || continue
	# brob boxes and effort 3, as other programs write them
	"$TOOL" encode --effort 3 --compress-boxes "$f" "$CORPUS/full/jxl/$name-e3-brob.jxl" 2>/dev/null || true
done
echo "full/jxl: $(ls "$CORPUS/full/jxl" | wc -l | tr -d ' ') JPEG XL files"
