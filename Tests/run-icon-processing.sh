#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
make
build_dir=$(mktemp -d /tmp/dock-icon-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
clang $(gnustep-config --objc-flags) Tests/IconProcessing.m \
  obj/Dock.obj/ApplicationIconManager.m.o \
  obj/Dock.obj/RunningApplicationScanner.m.o \
  obj/Dock.obj/DockItem*.o \
  -o "$build_dir/icon-tests" $(gnustep-config --gui-libs)
"$build_dir/icon-tests"
