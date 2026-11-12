include $(GNUSTEP_MAKEFILES)/common.make

# The battery Dock extra (apps-dock#7).
BUNDLE_NAME = Battery
BUNDLE_EXTENSION = .dockextra
BUNDLE_INSTALL_DIR = $(GNUSTEP_LIBRARY)/DockExtras
Battery_PRINCIPAL_CLASS = DockBatteryExtra
Battery_OBJC_FILES = DockBatteryExtra.m
Battery_INCLUDE_DIRS = -I../.. -I../Common
SYSTEM_C_FILES = DockBatterySource.c

include ../Common/Extra.make
include ../Common/SystemC.make
Battery_BUNDLE_LIBS += -lIOKit -lCoreFoundation
include $(GNUSTEP_MAKEFILES)/bundle.make
