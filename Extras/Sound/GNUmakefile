include $(GNUSTEP_MAKEFILES)/common.make

# The sound Dock extra (apps-dock#8, #38): the output's volume and mute,
# kernel devices and Bluetooth headsets alike, through SNAudio.c, copied
# from Sound.app (nextbsd/apps-settings Sound/).
#
# A headset's name and volume come from bluetoothd's MIG interface, whose
# client stubs the build makes from the Bluetooth extra's copy of
# bluetooth.defs (../Bluetooth/mig).
BUNDLE_NAME = Sound
BUNDLE_EXTENSION = .dockextra
BUNDLE_INSTALL_DIR = $(GNUSTEP_LIBRARY)/DockExtras
Sound_PRINCIPAL_CLASS = DockSoundExtra
Sound_OBJC_FILES = DockSoundExtra.m
Sound_INCLUDE_DIRS = -I../.. -I../Common

include ../Common/Extra.make
Sound_BUNDLE_LIBS += -llaunch -lsystem_kernel -lsystem_blocks -lm

# SNAudio.c and the MIG stubs use Mach and notify(3), so they're compiled
# without GNUstep's header paths (as in ../Common/SystemC.make), and
# linked into the bundle.
MIG ?= mig
MIG_SRC = ../Bluetooth/mig
MIG_DIR = obj/mig
SYSTEM_DIR = obj/system
SOUND_SYSTEM_CFLAGS = -fPIC -fblocks -O2 -g -Wall -Wno-macro-redefined \
	-I$(MIG_DIR) -I$(MIG_SRC) -I.
SOUND_SYSTEM_OBJS = $(SYSTEM_DIR)/SNAudio.o $(SYSTEM_DIR)/bluetoothUser.o
Sound_OBJ_FILES += $(SOUND_SYSTEM_OBJS)

include $(GNUSTEP_MAKEFILES)/bundle.make

$(MIG_DIR)/bluetoothUser.c $(MIG_DIR)/bluetoothUser.h: \
		$(MIG_SRC)/bluetooth.defs $(MIG_SRC)/bluetooth_mig_types.h
	@mkdir -p $(MIG_DIR)
	cd $(MIG_DIR) && $(MIG) -I$(CURDIR)/$(MIG_SRC) \
		-header bluetoothUser.h -user bluetoothUser.c \
		-server /dev/null -sheader /dev/null \
		$(CURDIR)/$(MIG_SRC)/bluetooth.defs

$(SYSTEM_DIR)/SNAudio.o: SNAudio.c SNAudio.h $(MIG_DIR)/bluetoothUser.h
	@mkdir -p $(SYSTEM_DIR)
	$(CC) $(SOUND_SYSTEM_CFLAGS) -c $< -o $@

# MIG's output isn't -Wall clean.
$(SYSTEM_DIR)/bluetoothUser.o: $(MIG_DIR)/bluetoothUser.c
	@mkdir -p $(SYSTEM_DIR)
	$(CC) $(SOUND_SYSTEM_CFLAGS) -w -c $< -o $@

before-all:: $(SOUND_SYSTEM_OBJS)

after-clean::
	rm -rf $(MIG_DIR) $(SYSTEM_DIR)
