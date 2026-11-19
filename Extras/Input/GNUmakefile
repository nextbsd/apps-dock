include $(GNUSTEP_MAKEFILES)/common.make

# The Input Dock extra: the keyboard layout in use (EN, ΕΛ), and a menu
# to switch to another, through WindowServer. It shows when there are
# two layouts or more; Keyboard.app (nextbsd/apps-settings) sets them.
# Moved here from apps-settings' Keyboard/InputMenu, so every extra
# ships with the Dock.
BUNDLE_NAME = Input
BUNDLE_EXTENSION = .dockextra
BUNDLE_INSTALL_DIR = $(GNUSTEP_LIBRARY)/DockExtras
Input_PRINCIPAL_CLASS = DockInputExtra
Input_OBJC_FILES = DockInputExtra.m DockInputConnection.m
Input_INCLUDE_DIRS = -I../.. -I../Common

include ../Common/Extra.make

# WindowServer's client library (the Extras are only built where it is).
ADDITIONAL_OBJCFLAGS += $(shell pkg-config --cflags WindowServerClient 2>/dev/null)
Input_BUNDLE_LIBS += $(shell pkg-config --libs WindowServerClient 2>/dev/null || echo -lWindowServerClient)

include $(GNUSTEP_MAKEFILES)/bundle.make
