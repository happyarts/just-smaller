#!/bin/sh
# Moves the pins of our forks to their latest commits, checks the result and
# commits the new pins.
#
#     Tools/update-forks.sh [--no-commit]
#
# Our forks are happyarts/oxipng (master), happyarts/zopfli (main) and
# happyarts/libdeflater (master) with happyarts/libdeflate (master) inside it.
# libdeflate's pin lives in libdeflater: when libdeflate moved, a commit in
# libdeflater takes it along and is pushed to its master first.
#
# Then the tools are built and checked as for any change to a level: the unit
# tests and the quick corpus at Balanced and at Maximum (zopfli runs only
# there). If all of that passes, the new pins are committed here (not pushed);
# otherwise they stay as staged, uncommitted changes to look at. A fork checkout that
# holds local work is never moved.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMMIT=yes
[ "${1:-}" = "--no-commit" ] && COMMIT=no

say() { printf '%s\n' "$*" >&2; }
# Nothing in it would be lost: no changes, and the commit it is at lies on its
# remote or a tag; other local branches stay as they are (as in build.sh).
movable() {
	[ -z "$(git -C "$1" status --porcelain --ignore-submodules=all)" ] &&
		[ -z "$(git -C "$1" log --oneline -1 HEAD --not --remotes --tags 2>/dev/null)" ]
}
latest() { # checkout branch — fetches the branch's last commit, prints its hash
	git -C "$1" fetch -q --depth 1 origin "$2" && git -C "$1" rev-parse FETCH_HEAD
}
changes() { # checkout old new — the commits in between, or just the two ends
	git -C "$1" fetch -q --shallow-exclude="$2" origin "$3" 2>/dev/null || true
	git -C "$1" log --format='    %h %s' "$2..$3" 2>/dev/null || echo "    $(echo "$2" | cut -c1-7) → $(echo "$3" | cut -c1-7)"
}

git -C "$ROOT" diff --cached --quiet || { say "The index of $ROOT holds staged changes; commit or unstage them first."; exit 1; }
LIBDEFLATE=Vendor/libdeflater/libdeflate-sys/libdeflate
for path in Vendor/oxipng Vendor/zopfli Vendor/libdeflater $LIBDEFLATE; do
	movable "$ROOT/$path" || { say "$path holds local work; it stays as it is. Nothing was changed."; exit 1; }
done

SUMMARY=""
# libdeflate first: its pin is part of libdeflater.
DEFLATER=$ROOT/Vendor/libdeflater
new=$(latest "$DEFLATER" master)
git -C "$DEFLATER" checkout -q "$new"
pinned=$(git -C "$DEFLATER" ls-tree HEAD libdeflate-sys/libdeflate | awk '{print $3}')
newest=$(latest "$ROOT/$LIBDEFLATE" master)
if [ "$pinned" != "$newest" ]; then
	say "libdeflate: $pinned → $newest, committed in libdeflater and pushed"
	SUMMARY="$SUMMARY
- libdeflate (in libdeflater):
$(changes "$ROOT/$LIBDEFLATE" "$pinned" "$newest")"
	git -C "$ROOT/$LIBDEFLATE" checkout -q "$newest"
	git -C "$DEFLATER" checkout -q -B master "$new"
	git -C "$DEFLATER" add libdeflate-sys/libdeflate
	git -C "$DEFLATER" commit -q -m "libdeflate: the latest of our fork ($(echo "$newest" | cut -c1-7))"
	git -C "$DEFLATER" push -q origin master
	git -C "$DEFLATER" checkout -q --detach
else
	git -C "$DEFLATER" submodule update -q --init --depth 1 libdeflate-sys/libdeflate
fi

for entry in Vendor/libdeflater:master Vendor/oxipng:master Vendor/zopfli:main; do
	path=${entry%%:*} branch=${entry#*:}
	old=$(git -C "$ROOT" ls-tree HEAD "$path" | awk '{print $3}')
	new=$(latest "$ROOT/$path" "$branch")
	[ "$path" = Vendor/libdeflater ] && new=$(git -C "$ROOT/$path" rev-parse HEAD) # with libdeflate's commit, if any
	[ "$old" = "$new" ] && continue
	git -C "$ROOT/$path" checkout -q "$new"
	say "$path: $(echo "$old" | cut -c1-7) → $(echo "$new" | cut -c1-7)"
	SUMMARY="$SUMMARY
- ${path#Vendor/}:
$(changes "$ROOT/$path" "$old" "$new")"
done

if git -C "$ROOT" diff --quiet -- Vendor/oxipng Vendor/zopfli Vendor/libdeflater; then
	say "All forks are at their latest commits already."
	exit 0
fi

# Staged, so that build.sh builds the new pins rather than moving the checkouts back
git -C "$ROOT" add Vendor/oxipng Vendor/zopfli Vendor/libdeflater
say "Building and checking …"
"$ROOT/Tools/build.sh" >/dev/null
"$ROOT/Tools/test.sh" -q >/dev/null 2>&1 || { say "Unit tests failed (Tools/test.sh). The new pins stay uncommitted."; exit 1; }
for effort in balanced maximum; do
	out=$("$ROOT/Tests/corpus/run.sh" --quick -- --effort "$effort" 2>&1) || {
		printf '%s\n' "$out" | grep -E "FAIL|RESULT" >&2
		say "Corpus at $effort failed. The new pins stay uncommitted."
		exit 1
	}
	printf '%s\n' "$out" | grep -E "REGRESSION|vs baseline|RESULT" | sed "s/^/  $effort: /" >&2
done

[ "$COMMIT" = yes ] || { say "Checked; not committed (--no-commit)."; exit 0; }
git -C "$ROOT" add Vendor/oxipng Vendor/zopfli Vendor/libdeflater
git -C "$ROOT" commit -q -m "Forks: the latest of ours
$SUMMARY"
say "Committed: $(git -C "$ROOT" log --oneline -1). Not pushed."
