#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
make
build_dir=$(mktemp -d /tmp/dock-x11-icon-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
clang $(gnustep-config --objc-flags) Tests/X11IconPersistence.m \
  obj/Dock.obj/ApplicationIconManager.m.o \
  obj/Dock.obj/DockApplicationStore.m.o \
  obj/Dock.obj/DockPreferences.m.o \
  obj/Dock.obj/RunningApplicationScanner.m.o \
  obj/Dock.obj/DockItem*.o \
  -o "$build_dir/icon-tests" $(gnustep-config --gui-libs)
xvfb-run -a "$build_dir/icon-tests"
