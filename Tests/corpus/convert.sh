#!/bin/sh
# Runs a corpus tier through `just-smaller --to jxl` and back with `--to jpeg`,
# and checks every result.
#
# usage: Tests/corpus/convert.sh [--quick|--full|--private] [--update-baseline] [-- extra just-smaller options]
#
# For each JPEG: it is reported once and never fails with an error. Converted:
# the JPEG is gone (replaced) and a JPEG XL with its name is there, smaller;
# rebuilt from it the JPEG has the original's DCT coefficients (jpegcmp), and
# jxl-rs (jxl-pixels) shows what libjpeg shows of the original. Not converted:
# the JPEG is byte for byte as it was, nothing new next to it, and the reason
# is counted. Files named broken-* are never converted. Then the JPEG XL files
# go back with --to jpeg: each must give a JPEG with the original's name and
# coefficients. Sizes are compared with the last baseline
# (baseline-convert-TIER.tsv), so a JPEG that stops converting, or converts
# larger, shows up.
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
[ -x "$TOOLS/jxl-transcode" ] || { echo >&2 "optimizers missing — run Tools/build.sh"; exit 2; }
(cd "$ROOT" && swift build -c release -q)
CLI=$ROOT/.build/release/just-smaller

WORK=$(mktemp -d "${TMPDIR:-/tmp}/just-smaller-convert.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
mkdir -p "$WORK/orig" "$WORK/run"
# Only what a conversion picks up in a folder: files named as JPEGs.
find "$CORPUS/$TIER/" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.jpe' \) ! -name '.*' -exec cp -p {} "$WORK/orig/" \;
cp -p "$WORK/orig/"* "$WORK/run/"

START=$(date +%s)
STATUS=0
"$CLI" --tools "$TOOLS" --no-trash --json --to jxl "$@" "$WORK/run" > "$WORK/to-jxl.jsonl" || STATUS=$?
ELAPSED=$(( $(date +%s) - START ))
# Back: only the JPEG XL files, into their own folder.
mkdir -p "$WORK/jxl" "$WORK/back"
find "$WORK/run" -name '*.jxl' -exec cp -p {} "$WORK/jxl/" \;
BACK=0
"$CLI" --tools "$TOOLS" --no-trash --json --to jpeg --output "$WORK/back" "$WORK/jxl" > "$WORK/to-jpeg.jsonl" || BACK=$?

RESULT=0
python3 - "$WORK" "$TOOLS" "$CORPUS/baseline-convert-$TIER.tsv" "$UPDATE" "$ELAPSED" "$STATUS" "$BACK" <<'PY' || RESULT=$?
import json, os, re, subprocess, sys, collections, unicodedata
work, tools, base_path, update, elapsed, status, back_status = sys.argv[1:]
orig, run, jxl_dir, back = (os.path.join(work, d) for d in ("orig", "run", "jxl", "back"))
jpegcmp, transcode, pixels = (os.path.join(tools, t) for t in ("jpegcmp", "jxl-transcode", "jxl-pixels"))
nfc = lambda s: unicodedata.normalize("NFC", s)
fails, regress = [], []
baseline = {}
if os.path.exists(base_path):
    for line in open(base_path):
        n, s = line.rstrip("\n").split("\t"); baseline[nfc(n)] = int(s)
for what, s in (("--to jxl", status), ("--to jpeg", back_status)):
    if s not in ("0", "1", "2"): fails.append(("—", f"{what}: THE TOOL CRASHED OR WAS KILLED (exit status {s})"))

names = sorted(os.listdir(orig))
records = {}
for line in open(os.path.join(work, "to-jxl.jsonl")):
    r = json.loads(line); n = os.path.basename(r["file"])
    if n in records: fails.append((n, "REPORTED TWICE"))
    records[n] = r
if set(records) != set(names):
    fails.append(("—", f"REPORTED {len(records)} OF {len(names)} FILES"))

# The same checks as in the engine, done again from outside, with the
# engine's own limits for its own conversions.
LIMIT_MEAN, LIMIT_BLOCK, LIMIT_MAX = 1.5, 4, 40
def stem(n): return os.path.splitext(n)[0]
result, reasons = {}, collections.Counter()
converted = before = after = 0
for n in names:
    a, r = os.path.join(orig, n), records.get(n, {})
    jxl = os.path.join(run, stem(n) + ".jxl")
    if r.get("status") == "failed": fails.append((n, "ERROR: " + r.get("reason", "")))
    if r.get("status") != "optimized":
        reasons[re.sub(r":.*", "", r.get("reason", "?"))] += 1
        # A check that failed is worth a look, file by file.
        if r.get("status") == "rejected" or "couldn’t be filtered" in r.get("reason", ""):
            print(f"  rejected {n}: {r.get('reason')}")
        b = os.path.join(run, n)
        if not os.path.exists(b) or open(a, "rb").read() != open(b, "rb").read():
            fails.append((n, "NOT CONVERTED, BUT TOUCHED"))
        if os.path.exists(jxl): fails.append((n, "NOT CONVERTED, BUT A JPEG XL APPEARED"))
        continue
    if n.startswith("broken"): fails.append((n, "CONVERTED A BROKEN FILE"))
    if os.path.exists(os.path.join(run, n)): fails.append((n, "CONVERTED, BUT THE JPEG IS STILL THERE"))
    if not os.path.exists(jxl): fails.append((n, "CONVERTED, BUT NO JPEG XL")); continue
    sa, sb = os.path.getsize(a), os.path.getsize(jxl)
    result[n] = sb; converted += 1; before += sa; after += sb
    if sb >= sa: fails.append((n, f"JPEG XL NOT SMALLER {sa} -> {sb}"))
    if nfc(n) in baseline and sb > baseline[nfc(n)]: regress.append((n, baseline[nfc(n)], sb))
    rebuilt, ppm = os.path.join(work, "rebuilt.jpg"), os.path.join(work, "pixels.ppm")
    if subprocess.run([transcode, "decode", jxl, rebuilt], capture_output=True).returncode != 0:
        fails.append((n, "CAN'T BE REBUILT")); continue
    c = subprocess.run([jpegcmp, a, rebuilt], capture_output=True, text=True)
    if c.returncode != 0: fails.append((n, "REBUILT COEFFICIENTS: " + (c.stdout + c.stderr).strip()))
    if subprocess.run([pixels, jxl, ppm], capture_output=True).returncode != 0:
        fails.append((n, "JXL-RS CAN'T DECODE IT")); continue
    p = subprocess.run([jpegcmp, "--pixels", a, ppm], capture_output=True, text=True)
    m = re.search(r"mean ([0-9.]+) block ([0-9.]+) max (\d+)", p.stdout)
    if not m or float(m[1]) > LIMIT_MEAN or float(m[2]) > LIMIT_BLOCK or int(m[3]) > LIMIT_MAX:
        fails.append((n, "SHOWN DIFFERENTLY: " + (p.stdout + p.stderr).strip()))
extra = sorted(set(os.listdir(run)) - set(names) - {stem(n) + ".jxl" for n in result})
if extra: fails.append(("—", "LEFTOVER FILES: " + ", ".join(extra)))

# Back to JPEG: every JPEG XL, each to a JPEG with the original's coefficients.
backs = {}
for line in open(os.path.join(work, "to-jpeg.jsonl")):
    r = json.loads(line); backs[stem(os.path.basename(r["file"]))] = r
for n in result:
    r = backs.get(stem(n))
    if not r or r.get("status") != "optimized":
        fails.append((n, "NOT BACK TO JPEG: " + (r or {}).get("reason", "not reported"))); continue
    c = subprocess.run([jpegcmp, os.path.join(orig, n), r["result"]], capture_output=True, text=True)
    if c.returncode != 0: fails.append((n, "BACK, COEFFICIENTS: " + (c.stdout + c.stderr).strip()))

print(f"\n{len(names)} JPEGs: {converted} converted, {len(names) - converted} stayed JPEG   {elapsed}s")
if converted:
    print(f"converted: {before} -> {after} bytes, {(1 - after / before) * 100:.1f}% smaller")
for why, k in reasons.most_common(): print(f"  {k:4}  {why}")
if baseline:
    gone = sorted(n for n in baseline if n not in {nfc(x) for x in result})
    if gone: print(f"  no longer converted: {', '.join(gone)}")
    was = sum(baseline.get(nfc(n), result[n]) for n in result)
    print(f"vs baseline: {sum(result.values()) - was:+d} bytes over {len(result)} files")
for n, old, new in regress: print(f"  REGRESSION {n}: {old} -> {new}")
for n, why in fails: print(f"  FAIL {n}: {why}")
if update == "yes":
    with open(base_path, "w") as f:
        for n in sorted(result): f.write(f"{n}\t{result[n]}\n")
    print(f"baseline written: {base_path}")
print("RESULT:", "PASS" if not fails else f"{len(fails)} FAILURE(S)")
sys.exit(1 if fails else 0)
PY
exit $RESULT
