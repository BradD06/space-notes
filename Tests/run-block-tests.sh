#!/bin/sh
# Compiles the pure block logic (Blocks.swift, BlockStyles.swift) with the tests and runs them.
# Usage: Tests/run-block-tests.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../Space App/Space/Space/Editor"
out="${TMPDIR:-/tmp}/space-block-tests"
swiftc -O -o "$out" "$src/Blocks.swift" "$src/BlockStyles.swift" "$here/BlockTestsSupport.swift" "$here/main.swift"
"$out"
