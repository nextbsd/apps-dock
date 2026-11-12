# C sources that use NextBSD's CoreFoundation, SystemConfiguration or
# IOKit headers are compiled without GNUstep's header paths, whose
# CoreFoundation (gnustep-corebase) would be found first. List them in
# SYSTEM_C_FILES; their objects are linked into the bundle.

SYSTEM_C_OBJS = $(patsubst %.c,obj/system/%.o,$(SYSTEM_C_FILES))
$(BUNDLE_NAME)_OBJ_FILES += $(SYSTEM_C_OBJS)

obj/system/%.o: %.c $(wildcard *.h)
	@mkdir -p obj/system
	$(CC) -fPIC -fblocks -O2 -g -Wall -c $< -o $@

before-all:: $(SYSTEM_C_OBJS)

after-clean::
	rm -rf obj/system
