#!/bin/sh
# The Dock is never at the top in the Mac menu style; see
# Tests/NoTopDockInMacStyle.m. Needs no display.
set -eu
cd "$(dirname "$0")/.."
gmake
build_dir=$(mktemp -d /tmp/dock-no-top.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
objects=$(find obj/Dock.obj -name '*.o' ! -name main.m.o)
clang $(gnustep-config --objc-flags) Tests/NoTopDockInMacStyle.m $objects \
  -o "$build_dir/no-top" $(gnustep-config --gui-libs) \
  $(pkg-config --libs x11 xext 2>/dev/null) \
  $(pkg-config --libs WindowServerClient 2>/dev/null)
"$build_dir/no-top"
