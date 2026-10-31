#!/bin/sh
# Runs the unit tests with plain Lua; no Hammerspoon needed.
# (tests/performance.lua is a live benchmark, run inside Hammerspoon.)
set -e
cd "$(dirname "$0")/.."
for t in tests/*_test.lua; do
	lua "$t"
	echo "ok $t"
done

# Native query logic uses mocked AX and WindowServer calls, never real apps.
if [ "$(uname -s)" = Darwin ] && command -v pkg-config >/dev/null 2>&1 && pkg-config --exists lua; then
    native_tmp=$(mktemp -d /tmp/hyprspoon-native-tests.XXXXXX)
    trap 'rm -rf "$native_tmp"' EXIT HUP INT TERM
    clang -std=c11 -O2 -Wall -Wextra $(pkg-config --cflags lua) \
        tests/native_tabs_probe_test.c $(pkg-config --libs lua) \
        -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation \
        -o "$native_tmp/native_tabs_test"
    "$native_tmp/native_tabs_test"
    echo "ok tests/native_tabs_probe_test.c"
    clang -std=c11 -O2 -Wall -Wextra $(pkg-config --cflags lua) \
        tests/native_events_test.c $(pkg-config --libs lua) \
        -framework CoreGraphics -framework CoreFoundation \
        -o "$native_tmp/native_events_test"
    "$native_tmp/native_events_test"
    echo "ok tests/native_events_test.c"
fi
