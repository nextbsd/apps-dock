#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
make
clang $(gnustep-config --objc-flags) Tests/MissingApplications.m \
  obj/Dock.obj/DockApplicationStore.m.o \
  obj/Dock.obj/DockItem.m.o \
  obj/Dock.obj/DockItem+Factory.m.o \
  obj/Dock.obj/DockItem+Icons.m.o \
  obj/Dock.obj/DockPreferences.m.o \
  obj/Dock.obj/RunningApplicationScanner.m.o \
  -o /tmp/dock-missing-tests $(gnustep-config --gui-libs)
xvfb-run -a /tmp/dock-missing-tests
