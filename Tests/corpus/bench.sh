#!/bin/sh
# Times the just-smaller command on a folder of images: one job, three runs
# on fresh copies, the fastest counts. Prints the time and the sizes of the
# results, so two builds can be compared — speed must stay, sizes must be
# the same.
#
# usage: Tests/corpus/bench.sh [--cli PATH] <folder> [-- extra just-smaller options]
#   --cli    another build to time (default: this checkout, built for release)
#
#   Tests/corpus/bench.sh ../Testkorpus/full/real-photo-jpeg
#   cp -R .build/release/just-smaller* /tmp/before/   # keep a build to compare with
#   Tests/corpus/bench.sh --cli /tmp/before/just-smaller ../Testkorpus/full/real-photo-jpeg -- --lossy
#
# The command needs its resource bundle (just-smaller_JustSmallerKit.bundle)
# next to it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/Tools/xcode-env.sh"
CLI=
if [ "${1:-}" = --cli ]; then CLI=$2; shift 2; fi
[ $# -ge 1 ] || { echo >&2 "usage: $0 [--cli PATH] <folder> [-- options]"; exit 2; }
FOLDER=$1; shift
[ "${1:-}" = -- ] && shift
if [ -z "$CLI" ]; then
	(cd "$ROOT" && swift build -c release -q)
	CLI=$ROOT/.build/release/just-smaller
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/just-smaller-bench.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

best=
for run in 1 2 3; do
	rm -rf "$WORK/run" && mkdir "$WORK/run"
	find "$FOLDER" -type f ! -name '.*' -exec cp -p {} "$WORK/run/" \;
	start=$(python3 -c 'import time; print(time.time())')
	# Exit status 1: some files skipped, as expected; anything else is a failure.
	STATUS=0
	"$CLI" --tools "$ROOT/build/tools" --no-trash --json --jobs 1 "$@" "$WORK/run" > "$WORK/results.jsonl" || STATUS=$?
	[ $STATUS -le 1 ] || { echo >&2 "just-smaller failed (exit $STATUS)"; exit 1; }
	end=$(python3 -c 'import time; print(time.time())')
	t=$(python3 -c "print(f'{$end - $start:.2f}')")
	echo "run $run: $t s"
	best=$(python3 -c "print(min(x for x in [$t, ${best:-$t}]))")
done
python3 - "$WORK/results.jsonl" "$best" <<'PY'
import json, sys
results = [json.loads(line) for line in open(sys.argv[1])]
before = sum(r.get("originalSize") or r.get("size") or 0 for r in results)
after = sum(r.get("size") or 0 for r in results)
print(f"fastest: {sys.argv[2]} s   files: {len(results)}   before: {before}   after: {after}")
PY
