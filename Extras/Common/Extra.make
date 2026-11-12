# Shared settings for the Dock extras' bundles.

# NextBSD's system libraries (notify(3), dispatch, SystemConfiguration,
# IOKit) live in /usr/lib/system.
SYSTEM_LIBDIR = /usr/lib/system
ADDITIONAL_LDFLAGS += -L$(SYSTEM_LIBDIR) -Wl,-rpath,$(SYSTEM_LIBDIR)
$(BUNDLE_NAME)_BUNDLE_LIBS += -lnotify -lsystem_dispatch
