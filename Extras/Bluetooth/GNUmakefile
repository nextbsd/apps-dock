include $(GNUSTEP_MAKEFILES)/common.make

# The Bluetooth Dock extra: on or off, and the paired devices, through
# bluetoothd's MIG interface (org.nextbsd.bluetooth), as Bluetooth.app
# (nextbsd/apps-settings) does.
#
# bluetoothd's MIG client stubs aren't installed for apps, so the build
# makes them from mig/bluetooth.defs and mig/bluetooth_mig_types.h,
# copied unchanged from nextbsd-userland's src/Bluetooth (by way of
# apps-settings' Bluetooth/mig). Message ids never move, so an older copy
# keeps working with a newer bluetoothd.
BUNDLE_NAME = Bluetooth
BUNDLE_EXTENSION = .dockextra
BUNDLE_INSTALL_DIR = $(GNUSTEP_LIBRARY)/DockExtras
Bluetooth_PRINCIPAL_CLASS = DockBluetoothExtra
Bluetooth_OBJC_FILES = DockBluetoothExtra.m
Bluetooth_INCLUDE_DIRS = -I../.. -I../Common

include ../Common/Extra.make
Bluetooth_BUNDLE_LIBS += -lSystemConfiguration -lCoreFoundation \
	-llaunch -lsystem_kernel -lsystem_blocks

# BTClient.c and the MIG stubs use Mach, notify(3), CoreFoundation and
# SystemConfiguration, so they're compiled without GNUstep's header
# paths (as in ../Common/SystemC.make), and linked into the bundle.
MIG ?= mig
MIG_DIR = obj/mig
SYSTEM_DIR = obj/system
BT_SYSTEM_CFLAGS = -fPIC -fblocks -O2 -g -Wall -Wno-macro-redefined \
	-I$(MIG_DIR) -Imig -I.
BT_SYSTEM_OBJS = $(SYSTEM_DIR)/BTClient.o $(SYSTEM_DIR)/bluetoothUser.o
Bluetooth_OBJ_FILES += $(BT_SYSTEM_OBJS)

include $(GNUSTEP_MAKEFILES)/bundle.make

$(MIG_DIR)/bluetoothUser.c $(MIG_DIR)/bluetoothUser.h: mig/bluetooth.defs \
		mig/bluetooth_mig_types.h
	@mkdir -p $(MIG_DIR)
	cd $(MIG_DIR) && $(MIG) -I$(CURDIR)/mig \
		-header bluetoothUser.h -user bluetoothUser.c \
		-server /dev/null -sheader /dev/null $(CURDIR)/mig/bluetooth.defs

$(SYSTEM_DIR)/BTClient.o: BTClient.c BTClient.h $(MIG_DIR)/bluetoothUser.h
	@mkdir -p $(SYSTEM_DIR)
	$(CC) $(BT_SYSTEM_CFLAGS) -c $< -o $@

# MIG's output isn't -Wall clean.
$(SYSTEM_DIR)/bluetoothUser.o: $(MIG_DIR)/bluetoothUser.c
	@mkdir -p $(SYSTEM_DIR)
	$(CC) $(BT_SYSTEM_CFLAGS) -w -c $< -o $@

before-all:: $(BT_SYSTEM_OBJS)

after-clean::
	rm -rf $(MIG_DIR) $(SYSTEM_DIR)
