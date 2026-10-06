#!/bin/sh
# Runs a corpus tier through the just-smaller command and checks every result.
#
# usage: Tests/corpus/run.sh [--quick|--full] [--update-baseline] [-- extra just-smaller options]
#
# For each file: it must still exist, nothing new may appear next to it, it must
# not grow, raster images must decode pixel-identical (imgcmp.swift, via
# ImageIO), JPEGs must keep their DCT coefficients (jpegcmp), SVGs must render
# the same, and files named broken-* or unchanged-* must be left byte-for-byte
# alone; what a photo's Google container lists (images, a video) must lie
# where its directory says, the same images and bytes, and Ultra HDR results
# must decode in Google's libultrahdr as before (if built:
# build-ultrahdr.sh). Google's XMP in the JPEGs is read a second time by an
# independent reader (google-xmp.py) and must read the same. --private runs
# your own photos in Testkorpus/private (a folder or a link to one; never in
# a repository) the same way. Result sizes are compared with the last
# baseline so that a compression regression shows up even when everything is
# still lossless.
#
# Works on a copy; replaced originals are deleted (--no-trash), never moved to
# the Trash, and no settings are read or written.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/Tools/xcode-env.sh"
CORPUS=${JUST_SMALLER_CORPUS:-$(dirname "$ROOT")/Testkorpus}
TIER=quick; UPDATE=no
while [ $# -gt 0 ]; do
	case "$1" in
		--quick) TIER=quick ;; --full) TIER=full ;; --private) TIER=private ;;
		--update-baseline) UPDATE=yes ;;
		--) shift; break ;;
		*) echo >&2 "unknown option $1"; exit 2 ;;
	esac; shift
done
[ -d "$CORPUS/$TIER" ] || { echo >&2 "no corpus at $CORPUS/$TIER — run Tests/corpus/build-corpus.sh"; exit 2; }
TOOLS=$ROOT/build/tools
[ -x "$TOOLS/oxipng" ] || { echo >&2 "optimizers missing — run Tools/build.sh"; exit 2; }
(cd "$ROOT" && swift build -c release -q)
CLI=$ROOT/.build/release/just-smaller

# comparator, rebuilt when its source changes
BIN="$CORPUS/.bin"; mkdir -p "$BIN"
if [ ! -x "$BIN/imgcmp" ] || [ "$HERE/imgcmp.swift" -nt "$BIN/imgcmp" ]; then
	xcrun swiftc -O -o "$BIN/imgcmp" "$HERE/imgcmp.swift"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/just-smaller-corpus.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/orig" "$WORK/run"
if [ "$TIER" != quick ]; then
	find "$CORPUS/$TIER/" -type f ! -name '.*' -exec cp -p {} "$WORK/orig/" \;
else
	cp -pR "$CORPUS/quick/." "$WORK/orig/"
fi
cp -p "$WORK/orig/"* "$WORK/run/"

START=$(date +%s)
# Exit status 1 (some files skipped) is expected: the corpus has broken files.
STATUS=0
"$CLI" --tools "$TOOLS" --no-trash --json "$@" "$WORK/run" > "$WORK/results.jsonl" || STATUS=$?
ELAPSED=$(( $(date +%s) - START ))

RESULT=0
python3 - "$WORK" "$BIN/imgcmp" "$TOOLS/jpegcmp" "$CORPUS/baseline-$TIER.tsv" "$UPDATE" "$ELAPSED" "$STATUS" "$ROOT" <<'PY' || RESULT=$?
import json, os, re, subprocess, sys, collections, importlib.util, hashlib
work, imgcmp, jpegcmp, base_path, update, elapsed, status, root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("google_xmp", os.path.join(root, "Tests/corpus/google-xmp.py"))
google_xmp = importlib.util.module_from_spec(spec); spec.loader.exec_module(google_xmp)
# Built by Tests/corpus/build-ultrahdr.sh next to the comparator, if at all.
ultrahdr, uhdr_checked = os.path.join(os.path.dirname(imgcmp), "ultrahdr_app"), 0
orig, run = os.path.join(work, "orig"), os.path.join(work, "run")
raster = {".png", ".gif", ".webp", ".heic"}
baseline = {}
if os.path.exists(base_path):
    for line in open(base_path):
        n, s = line.rstrip("\n").split("\t"); baseline[n] = int(s)
fails, regress, per = [], [], collections.defaultdict(lambda: [0, 0, 0, 0])
# A crash or a run that did nothing must not pass: the tool has to exit
# normally and report every file exactly once.
if status not in ("0", "1", "2"):
    fails.append(("—", f"THE TOOL CRASHED OR WAS KILLED (exit status {status})"))
reported = [json.loads(l)["file"] for l in open(os.path.join(work, "results.jsonl")) if l.strip()]
# Every file the folder scan picks up (by extension, as FolderScanner.swift lists them).
scanned = set(re.findall(r'"(\w+)"', re.search(r"extensions: Set<String> = \[(.*?)\]",
              open(os.path.join(root, "Sources/JustSmallerKit/FolderScanner.swift")).read()).group(1)))
expected = sum(os.path.splitext(n)[1][1:].lower() in scanned for n in os.listdir(os.path.join(work, "orig")))
if len(reported) != expected or len(set(reported)) != len(reported):
    fails.append(("—", f"REPORTED {len(reported)} RESULTS ({len(set(reported))} FILES) FOR {expected} FILES"))
records = {}
for line in open(os.path.join(work, "results.jsonl")):
    r = json.loads(line)
    records[os.path.basename(r["file"])] = r
    if r["status"] == "failed" and not os.path.basename(r["file"]).startswith("broken"):
        fails.append((os.path.basename(r["file"]), "ERROR: " + r.get("reason", "")))
def jpeg_images(path):
    """Each JPEG in the file from its SOI to its EOI: the first, then those its
    multi-picture index (MPF) lists, found where the index says they start."""
    b = open(path, "rb").read()
    def end_of(i):
        i += 2
        while i + 1 < len(b) and b[i] == 0xFF:
            m = b[i + 1]
            if m == 0xFF: i += 1
            elif m == 0xD9: return i + 2
            elif 0xD0 <= m <= 0xD7 or m == 0x01: i += 2
            else:
                i += 2 + int.from_bytes(b[i + 2:i + 4], "big")
                if m == 0xDA:  # entropy-coded data up to the next marker
                    while (k := b.find(b"\xff", i)) >= 0 and k + 1 < len(b) and (b[k + 1] == 0 or 0xD0 <= b[k + 1] <= 0xD7):
                        i = k + 2
                    i = k if k >= 0 else len(b)
        return None
    # The index is an APP2 "MPF" segment among the first image's headers.
    starts, m, i = [0], -1, 2
    while b[i:i + 1] == b"\xff" and b[i + 1:i + 2] not in (b"\xda", b"\xd9", b""):
        if b[i + 1] == 0xE2 and b[i + 4:i + 8] == b"MPF\0": m = i + 4; break
        i += 2 + int.from_bytes(b[i + 2:i + 4], "big")
    if m > 0:
        t = m + 4; e = "big" if b[t:t + 2] == b"MM" else "little"
        rd = lambda at, n: int.from_bytes(b[at:at + n], e)
        ifd = t + rd(t + 4, 4)
        for k in range(rd(ifd, 2)):
            at = ifd + 2 + 12 * k
            if rd(at, 2) == 0xB002:
                entries = t + rd(at + 8, 4)
                starts += [t + rd(entries + 16 * n + 8, 4) for n in range(1, rd(at + 4, 4) // 16)]
    out = []
    for s in starts:
        if b[s:s + 2] != b"\xff\xd8" or (e := end_of(s)) is None: break
        out.append(b[s:e])
    return out
def render(p, outdir):
    subprocess.run(["qlmanage", "-t", "-s", "512", "-o", outdir, p], capture_output=True)
    return os.path.join(outdir, os.path.basename(p) + ".png")
names = sorted(os.listdir(orig))
extra = sorted(set(os.listdir(run)) - set(names))
if extra: fails.append(("—", "LEFTOVER FILES: " + ", ".join(extra)))
result = {}
for n in names:
    a, b = os.path.join(orig, n), os.path.join(run, n)
    ext = os.path.splitext(n)[1].lower()
    cat = per[ext or "(none)"]
    kind = ext
    with open(a, "rb") as fh: head = fh.read(4)
    if head[:3] == b"\xff\xd8\xff": kind = ".jpg"
    elif head == b"\x89PNG": kind = ".png"
    if not os.path.exists(b):
        fails.append((n, "LOST")); continue
    sa, sb = os.path.getsize(a), os.path.getsize(b); result[n] = sb
    cat[0] += 1; cat[1] += sa; cat[2] += sb
    same = open(a, "rb").read() == open(b, "rb").read()
    if (n.startswith("broken") or "unchanged-" in n) and not same: fails.append((n, "TOUCHED A FILE THAT MUST STAY AS IT IS"))
    # A file may grow only when private metadata had to go (the promise
    # beats the size); then its only tool is the metadata filter.
    tools = records.get(n, {}).get("tools", [])
    if sb > sa and tools != ["Metadata"]: fails.append((n, f"GREW {sa} -> {sb}"))
    # Also files that stay as they are now but got smaller before: a tool
    # that stopped working shows up here.
    if n in baseline and sb > baseline[n]:
        why = records.get(n, {}).get("reason") or "+".join(tools) or records.get(n, {}).get("status", "")
        regress.append((n, baseline[n], f"{sb}  ({why})"))
    if same: continue
    cat[3] += 1
    if kind in (".jpg", ".jpeg"):
        # ImageIO decodes identical DCT data differently depending on the
        # Huffman tables; the coefficients are the exact proof. jpegcmp reads
        # one image: a file that holds several is compared image by image.
        ia, ib = jpeg_images(a), jpeg_images(b)
        if len(ia) != len(ib): fails.append((n, f"IMAGES: {len(ia)} -> {len(ib)}"))
        for k, (x, y) in enumerate(zip(ia, ib)):
            pa, pb = os.path.join(work, "image-a.jpg"), os.path.join(work, "image-b.jpg")
            open(pa, "wb").write(x); open(pb, "wb").write(y)
            r = subprocess.run([jpegcmp, pa, pb], capture_output=True, text=True)
            if r.returncode != 0: fails.append((n, f"COEFFICIENTS (image {k + 1}): " + (r.stdout + r.stderr).strip()))
        # What Google's container lists after the photo (images, a motion
        # photo's video), read with the second reader: in the result each
        # item lies where its directory says, each JPEG with the same
        # coefficients, anything else byte for byte. An older motion photo's
        # video (no directory): everything after the photo stays.
        whole_a, whole_b = open(a, "rb").read(), open(b, "rb").read()
        tail = whole_a[len(ia[0]):] if ia else b""
        said = google_xmp.opinion(a)
        pa = google_xmp.placed(a) if said["listed"] is not None else None
        if pa is not None:
            pb = google_xmp.placed(b)
            if pb is None or [m for m, _, _ in pa] != [m for m, _, _ in pb]:
                fails.append((n, "CONTAINER ITEMS NOT WHERE ITS DIRECTORY SAYS"))
            else:
                for (m, sa, ea), (_, sb, eb) in zip(pa, pb):
                    if m != "image/jpeg":
                        if whole_a[sa:ea] != whole_b[sb:eb]: fails.append((n, f"CONTAINER ITEM CHANGED ({m})"))
                        continue
                    xa, xb = os.path.join(work, "item-a.jpg"), os.path.join(work, "item-b.jpg")
                    open(xa, "wb").write(whole_a[sa:ea]); open(xb, "wb").write(whole_b[sb:eb])
                    r = subprocess.run([jpegcmp, xa, xb], capture_output=True, text=True)
                    if r.returncode != 0: fails.append((n, "COEFFICIENTS (container item): " + (r.stdout + r.stderr).strip()))
        elif (said["listed"] is not None or said["motion"] and b"ftyp" in tail) and not whole_b.endswith(tail):
            fails.append((n, "WHAT FOLLOWS THE PHOTO CHANGED (GOOGLE CONTAINER)"))
        r = subprocess.run([imgcmp, "--tolerance", "255", a, b], capture_output=True, text=True)
        if "orientation" in r.stdout or "HDR" in r.stdout: fails.append((n, r.stdout.strip()))
        # Google's own decoder, a second opinion on HDR gain maps: an Ultra
        # HDR original and its result decode to the same HDR picture.
        if os.path.exists(ultrahdr) and subprocess.run([ultrahdr, "-m", "1", "-P", "-j", a], capture_output=True).returncode == 0:
            uhdr_checked += 1
            def decoded(path):
                out = os.path.join(work, "uhdr.raw")
                ok = subprocess.run([ultrahdr, "-m", "1", "-j", path, "-o", "2", "-z", out], capture_output=True, cwd=work).returncode == 0
                digest = hashlib.sha256(open(out, "rb").read()).hexdigest() if ok and os.path.exists(out) else None
                if os.path.exists(out): os.remove(out)
                return digest
            # An original it can't decode (Skia's edge cases) gives no opinion.
            if (da := decoded(a)) is None: uhdr_checked -= 1
            elif decoded(b) != da: fails.append((n, "ULTRA HDR DECODES DIFFERENTLY (libultrahdr)"))
    elif kind in raster:
        r = subprocess.run([imgcmp, a, b], capture_output=True, text=True)
        if r.returncode != 0: fails.append((n, "PIXELS: " + r.stdout.strip()))
    elif kind == ".svg":
        ra, rb = os.path.join(work, "ra"), os.path.join(work, "rb")
        os.makedirs(ra, exist_ok=True); os.makedirs(rb, exist_ok=True)
        r = subprocess.run([imgcmp, "--tolerance", "2", render(a, ra), render(b, rb)], capture_output=True, text=True)
        # Antialiasing may differ in a handful of edge pixels (0.1 % of the 512 px thumbnail).
        m = re.search(r"up to (\d+) pixels", r.stdout)
        if r.returncode != 0 and not (m and int(m.group(1)) <= 262):
            fails.append((n, "RENDER: " + r.stdout.strip()))
print(f"\n{'type':<8}{'files':>6}{'changed':>8}{'before':>12}{'after':>12}{'saved':>8}")
tot = [0, 0, 0, 0]
for ext, (c, sa, sb, ch) in sorted(per.items()):
    print(f"{ext:<8}{c:>6}{ch:>8}{sa:>12}{sb:>12}{(1 - sb / sa) * 100 if sa else 0:>7.1f}%")
    tot = [x + y for x, y in zip(tot, (c, sa, sb, ch))]
print(f"{'total':<8}{tot[0]:>6}{tot[3]:>8}{tot[1]:>12}{tot[2]:>12}{(1 - tot[2] / tot[1]) * 100 if tot[1] else 0:>7.1f}%   {elapsed}s")
if baseline:
    was = sum(baseline.get(n, result.get(n, 0)) for n in result); now = sum(result.values())
    print(f"vs baseline: {now - was:+d} bytes over {len(result)} files")
for n, old, new in regress: print(f"  REGRESSION {n}: {old} -> {new}")
for n, why in fails: print(f"  FAIL {n}: {why}")
if update == "yes":
    with open(base_path, "w") as f:
        for n in sorted(result): f.write(f"{n}\t{result[n]}\n")
    print(f"baseline written: {base_path}")
print(f"libultrahdr: {uhdr_checked} Ultra HDR results decoded as before" if os.path.exists(ultrahdr)
      else "libultrahdr: not built, no second opinion on gain maps (Tests/corpus/build-ultrahdr.sh)")
print("RESULT:", "PASS" if not fails else f"{len(fails)} FAILURE(S)")
sys.exit(1 if fails else 0)
PY

# Google's XMP in the originals, read a second time by an independent reader
# (google-xmp.py) and compared with the engine's.
if JUST_SMALLER_SECOND_OPINION="$WORK/orig" "$ROOT/Tools/test.sh" -q --filter GoogleXMPSecondOpinion > "$WORK/second-opinion.log" 2>&1; then
	echo "Google XMP, second opinion: same"
else
	grep -E "Expectation failed|error" "$WORK/second-opinion.log" | head -20
	echo "Google XMP, second opinion: DIFFERENT"
	echo "RESULT: FAILURE (the corpus check above passed, the second opinion did not)"; RESULT=1
fi
exit $RESULT
