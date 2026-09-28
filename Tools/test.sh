#!/bin/sh
# Runs the unit and end-to-end tests (swift test) with a full Xcode, found by
# Tools/xcode-env.sh. Arguments go to swift test.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/Tools/xcode-env.sh"
cd "$ROOT"
exec swift test "$@"
