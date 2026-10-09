#!/bin/sh
# Assembles the local test corpus. Nothing it produces belongs in the repo:
# the images come from this Mac's system and app resources (no personal
# photos) plus generated edge cases, and they stay outside the working tree.
#
# usage: Tests/corpus/build-corpus.sh
#   JUST_SMALLER_CORPUS  where to put it (default: Testkorpus next to the repository)
#
# Produces two tiers:
#   quick/  ~30 files, one per format and edge case, for every change
#   full/   several hundred real-world files plus all edge cases
# Real photos come from download-cache/, filled by fetch-real-images.py.
set -eu
CORPUS=${JUST_SMALLER_CORPUS:-$(cd "$(dirname "$0")/../../.." && pwd)/Testkorpus}
HERE=$(cd "$(dirname "$0")" && pwd)

PY=""
for p in /Library/Frameworks/Python.framework/Versions/*/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
	if command -v "$p" >/dev/null 2>&1 && "$p" -c 'import PIL' 2>/dev/null; then PY=$p; break; fi
done
[ -n "$PY" ] || { echo >&2 "error: need a python3 with Pillow to generate the edge cases (pip install pillow)"; exit 1; }

echo "Corpus: $CORPUS"
rm -rf "$CORPUS/quick" "$CORPUS/full"
mkdir -p "$CORPUS/quick" "$CORPUS/full"

# --- generated edge cases -------------------------------------------------
"$PY" "$HERE/generate-edge-cases.py" "$CORPUS/full/edge"

# --- real files from this Mac ----------------------------------------------
# Deterministic: sorted, then every n-th, capped per format and by size.
collect() { # ext  maxcount  minbytes  maxbytes  dest
	mkdir -p "$CORPUS/full/$5"
	find /System/Library /Applications /Library/Desktop\ Pictures -type f -iname "*.$1" \
		-size +"$3"c -size -"$4"c 2>/dev/null | LC_ALL=C sort | awk -v n="$2" '
		{ a[NR] = $0 } END { step = NR > n ? NR / n : 1; for (i = 1; i <= NR && c < n; i += step) { print a[int(i)]; c++ } }' |
	while IFS= read -r f; do
		base=$(basename "$f" | tr -c 'A-Za-z0-9._\n-' '_')
		cp -p "$f" "$CORPUS/full/$5/$(printf '%s' "$f" | shasum | cut -c1-6)-$base" 2>/dev/null || true
	done
}
collect png  120 2000 3000000 png
collect jpg   60 2000 8000000 jpeg
collect jpeg  20 2000 8000000 jpeg
collect gif   40 2000 3000000 gif
collect svg   60 1000  500000 svg
collect webp  20 1000 3000000 webp
collect heic  12 1000 60000000 heic

# Photographs at realistic sizes, derived from the system desktop pictures.
mkdir -p "$CORPUS/full/photo"
find "/System/Library/Desktop Pictures" -iname "*.heic" -size -30000000c 2>/dev/null | LC_ALL=C sort | head -4 |
while IFS= read -r f; do
	b=$(basename "$f" .heic | tr -c 'A-Za-z0-9._\n-' '_')
	sips -s format jpeg -s formatOptions 92 -Z 2400 "$f" --out "$CORPUS/full/photo/$b-2400.jpg" >/dev/null 2>&1 || true
	sips -s format png -Z 1600 "$f" --out "$CORPUS/full/photo/$b-1600.png" >/dev/null 2>&1 || true
	sips -s format heic -Z 2400 "$f" --out "$CORPUS/full/photo/$b-2400.heic" >/dev/null 2>&1 || true
done

# --- real photographs and graphics downloaded by fetch-real-images.py ------
# Freely licensed (Kodak set, Wikimedia Commons); cached so a rebuild is offline.
if [ -d "$CORPUS/download-cache" ]; then
	for d in "$CORPUS/download-cache"/*/; do
		name=real-$(basename "$d"); mkdir -p "$CORPUS/full/$name"
		find "$d" -type f ! -name '.*' -exec cp -p {} "$CORPUS/full/$name/" \;
	done
else
	echo "note: no download-cache; run Tests/corpus/fetch-real-images.py for real photos"
fi

# --- JPEGs that hold several images, written by Apple's frameworks: the
# iPhone photos with an HDR gain map downloaded above again with an ISO
# 21496-1 gain map (Core Image), and photos as portraits with depth and
# mattes (ImageIO). And a motion photo: a video after the images, which must
# stay as it is.
if [ -d "$CORPUS/full/real-multi-jpeg" ]; then
	mkdir -p "$CORPUS/full/multi-jpeg" "$CORPUS/full/unchanged"
	MULTI=$(mktemp -d)/multi-image
	xcrun swiftc -O -o "$MULTI" "$HERE/multi-image.swift"
	for f in "$CORPUS/full/real-multi-jpeg"/apple_gainmap_*.jpg; do
		"$MULTI" iso "$f" "$CORPUS/full/multi-jpeg/iso-$(basename "$f")" || true
	done
	find "$CORPUS/full/real-photo-jpeg" -iname "*.jpg" -size -3000k | LC_ALL=C sort | head -2 | while IFS= read -r f; do
		"$MULTI" portrait "$f" "$CORPUS/full/multi-jpeg/portrait-$(basename "$f")" || true
	done
	rm -rf "$(dirname "$MULTI")"
	for f in "$CORPUS/full/real-multi-jpeg"/pixel-ultrahdr-*.jpg; do
		# ISO BMFF: an ftyp box and a media box, as a phone's video starts.
		{ cat "$f"; printf '\000\000\000\030ftypmp42\000\000\000\000mp42isom\000\000\020\000mdat'; head -c 4088 /dev/urandom; } \
			> "$CORPUS/full/unchanged/unchanged-motion-photo-$(basename "$f")"
		break
	done
fi

# --- rare codings: arithmetic, restart markers, 12 bit, lossless JPEG; SVG in UTF-16
# Rewritten losslessly from the real photos above and libjpeg-turbo's own test
# images, with the tools Tools/build.sh builds.
TURBO=$HERE/../../build/work/libjpeg-turbo/install/bin
TESTIMAGES=$HERE/../../Vendor/libjpeg-turbo/testimages
if [ -x "$TURBO/jpegtran" ] && [ -d "$CORPUS/full/real-photo-jpeg" ]; then
	mkdir -p "$CORPUS/full/rare-jpeg"
	n=0
	find "$CORPUS/full/real-photo-jpeg" -iname "*.jpg" -size +200k | LC_ALL=C sort | head -3 | while IFS= read -r f; do
		n=$((n + 1)); out=$CORPUS/full/rare-jpeg
		"$TURBO/jpegtran" -copy all -arithmetic "$f" > "$out/arithmetic-$n.jpg"
		"$TURBO/jpegtran" -copy all -progressive -arithmetic "$f" > "$out/arithmetic-progressive-$n.jpg"
		"$TURBO/jpegtran" -copy all -restart 1 "$f" > "$out/restart-row-$n.jpg"
		"$TURBO/jpegtran" -copy all -progressive -restart 7B "$f" > "$out/restart-progressive-$n.jpg"
	done
	cp -p "$TESTIMAGES/testimgari.jpg" "$TESTIMAGES/testimgint.jpg" "$TESTIMAGES/monkey12.jpg" "$CORPUS/full/rare-jpeg/"
	"$TURBO/cjpeg" -precision 12 -quality 90 "$TESTIMAGES/testorig.ppm" > "$CORPUS/full/rare-jpeg/precision-12.jpg"
	"$TURBO/cjpeg" -lossless 1 "$TESTIMAGES/testorig.ppm" > "$CORPUS/full/rare-jpeg/lossless.jpg"
	"$TURBO/cjpeg" -restart 3 -sample 2x2,1x1,1x1 -quality 85 "$TESTIMAGES/testorig.ppm" > "$CORPUS/full/rare-jpeg/restart-blocks.jpg"
else
	echo "note: run Tools/build.sh and fetch-real-images.py for the rare JPEG codings"
fi
if [ -d "$CORPUS/full/real-svg" ]; then
	mkdir -p "$CORPUS/full/svg-utf16"
	find "$CORPUS/full/real-svg" -iname "*.svg" | LC_ALL=C sort | head -3 | while IFS= read -r f; do
		b=$(basename "$f" .svg)
		sed 's/encoding="[Uu][Tt][Ff]-8"/encoding="UTF-16"/' "$f" | iconv -f UTF-8 -t UTF-16 > "$CORPUS/full/svg-utf16/$b-utf16.svg" || true
		sed 's/encoding="[Uu][Tt][Ff]-8"/encoding="UTF-16"/' "$f" | iconv -f UTF-8 -t UTF-16BE > "$CORPUS/full/svg-utf16/$b-utf16be.svg" || true
	done
fi

# --- JPEG XL, made from the JPEGs above (needs build/tools/jxl-transcode)
"$HERE/make-jxl.sh" "$CORPUS"

# --- fewer of a kind: files of the same kind (same encoder settings, same
# chunks, similar size) test the same thing; a few of each are enough.
"$PY" "$HERE/dedup.py" "$CORPUS/full"

# --- quick tier: the edge cases, everything that must stay unchanged, plus
# a few real files of each format
cp -p "$CORPUS/full/edge/"* "$CORPUS/quick/"
for d in unchanged real-unchanged; do
	[ -d "$CORPUS/full/$d" ] && cp -p "$CORPUS/full/$d/"* "$CORPUS/quick/"
done
for d in $(ls "$CORPUS/full" | grep -v -E "^(edge|unchanged|real-unchanged)$"); do
	[ -d "$CORPUS/full/$d" ] || continue
	ls "$CORPUS/full/$d" | LC_ALL=C sort | head -2 | while IFS= read -r f; do cp -p "$CORPUS/full/$d/$f" "$CORPUS/quick/$d-$f"; done
done

echo "quick: $(ls "$CORPUS/quick" | wc -l | tr -d ' ') files, $(du -sh "$CORPUS/quick" | cut -f1)"
echo "full:  $(find "$CORPUS/full" -type f | wc -l | tr -d ' ') files, $(du -sh "$CORPUS/full" | cut -f1)"
