#!/bin/sh
# Runs the unit tests with plain Lua; no Hammerspoon needed.
# (tests/performance.lua is a live benchmark, run inside Hammerspoon.)
set -e
cd "$(dirname "$0")/.."
for t in tests/*_test.lua; do
	lua "$t"
	echo "ok $t"
done
