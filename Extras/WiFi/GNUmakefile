include $(GNUSTEP_MAKEFILES)/common.make

# The Wi-Fi Dock extra (apps-dock#6).
BUNDLE_NAME = WiFi
BUNDLE_EXTENSION = .dockextra
BUNDLE_INSTALL_DIR = $(GNUSTEP_LIBRARY)/DockExtras
WiFi_PRINCIPAL_CLASS = DockWiFiExtra
WiFi_OBJC_FILES = DockWiFiExtra.m
WiFi_INCLUDE_DIRS = -I../.. -I../Common
SYSTEM_C_FILES = DockWiFiSource.c

include ../Common/Extra.make
include ../Common/SystemC.make
WiFi_BUNDLE_LIBS += -lSystemConfiguration -lCoreFoundation
include $(GNUSTEP_MAKEFILES)/bundle.make
