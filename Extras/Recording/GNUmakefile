include $(GNUSTEP_MAKEFILES)/common.make

# The screen recording indicator (nextbsd/nextbsd#715): Screenshot.app's
# recording, its time and a stop button, while one runs.
BUNDLE_NAME = Recording
BUNDLE_EXTENSION = .dockextra
BUNDLE_INSTALL_DIR = $(GNUSTEP_LIBRARY)/DockExtras
Recording_PRINCIPAL_CLASS = DockRecordingExtra
Recording_OBJC_FILES = DockRecordingExtra.m
Recording_INCLUDE_DIRS = -I../.. -I../Common

include ../Common/Extra.make
include $(GNUSTEP_MAKEFILES)/bundle.make
