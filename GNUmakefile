include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = DockWM

DockWM_OBJC_FILES = \
main.m \
AppController.m \
AppController+Applications.m \
AppController+DockViewDelegate.m \
AppController+Icons.m \
AppController+Launching.m \
AppController+Layout.m \
AppController+Preferences.m \
AppController+Recycler.m \
AppController+Scanning.m \
AppController+Settings.m \
AppController+X11Delegate.m \
AppController+WindowServer.m \
AppController+Extras.m \
DockExtrasController.m \
SettingsController+Panel.m \
SettingsController+Applications.m \
SettingsController+Updates.m \
SettingsController+Actions.m \
SettingsController.m \
DockPreferences.m \
RunningApplicationScanner.m \
RecyclerController.m \
DockApplicationStore.m \
ApplicationIconManager.m \
DockView+IconWindows.m \
DockView+Wiggle.m \
DockView+Layout.m \
DockView+Menus.m \
DockView+Tooltip.m \
DockView+Pasteboard.m \
DockView+Drawing.m \
DockView+Dragging.m \
DockView+Mouse.m \
DockView+Extras.m \
DockView.m \
DockItem+Icons.m \
DockItem+Factory.m \
DockItem.m \
X11DockManager+Events.m \
X11DockManager+Images.m \
X11DockManager+WindowMetadata.m \
X11DockManager+WindowFiltering.m \
X11DockManager+DockApps.m \
X11DockManager+IconManager.m \
X11DockManager+Layout.m \
X11DockManager+Activation.m \
X11DockManager.m \
WSDockManager.m

DockWM_APPLICATION_ICON = DockWM.tiff

DockWM_RESOURCE_FILES = \
Resources/DockWM.tiff \
Resources/GNUstep.tiff \
Resources/Recycler.GNUstep.xpm \
Resources/gnustep_whale.png \
Resources/GNUstep_circle.png

ADDITIONAL_OBJCFLAGS += $(shell pkg-config --cflags x11 xext 2>/dev/null)
DockWM_TOOL_LIBS += $(shell pkg-config --libs x11 xext 2>/dev/null)

# NextBSD's WindowServer (WSDockManager), where its client library is
# installed; elsewhere the Dock is built for X11 only.
ifeq ($(shell pkg-config --exists WindowServerClient 2>/dev/null && echo yes),yes)
ADDITIONAL_OBJCFLAGS += -DDOCK_HAVE_WINDOWSERVER \
	$(shell pkg-config --cflags WindowServerClient)
DockWM_TOOL_LIBS += $(shell pkg-config --libs WindowServerClient)
endif

# The Dock extras (Extras/), built and installed with the Dock. They
# use NextBSD's system libraries, and only the WindowServer Dock has a
# status area, so they're built where the Dock is built for WindowServer.
ifeq ($(shell pkg-config --exists WindowServerClient 2>/dev/null && echo yes),yes)
SUBPROJECTS = Extras
include $(GNUSTEP_MAKEFILES)/aggregate.make
endif

include $(GNUSTEP_MAKEFILES)/application.make
