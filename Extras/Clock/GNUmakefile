include $(GNUSTEP_MAKEFILES)/common.make

# The date and clock Dock extra (apps-dock#9).
BUNDLE_NAME = Clock
BUNDLE_EXTENSION = .dockextra
BUNDLE_INSTALL_DIR = $(GNUSTEP_LIBRARY)/DockExtras
Clock_PRINCIPAL_CLASS = DockClockExtra
Clock_OBJC_FILES = DockClockExtra.m DockClockCalendar.m
Clock_INCLUDE_DIRS = -I../.. -I../Common

include ../Common/Extra.make
include $(GNUSTEP_MAKEFILES)/bundle.make
