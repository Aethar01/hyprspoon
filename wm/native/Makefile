# Builds the native modules (wm.native.*) against Hammerspoon's own Lua
# headers; Lua's symbols are resolved from Hammerspoon when they load.
# A reload picks up a rebuilt module.

HS_HEADERS = /Applications/Hammerspoon.app/Contents/Frameworks/LuaSkin.framework/Headers
CFLAGS = -std=c11 -O2 -Wall -Wextra -arch arm64 -arch x86_64 -I$(HS_HEADERS)
LDFLAGS = -bundle -undefined dynamic_lookup -framework CoreFoundation -framework CoreGraphics \
	-framework ApplicationServices -framework Carbon

MODULES = border.so events.so hover.so frames.so

all: $(MODULES)

border.so: border.c skylight.h preview.h
events.so: events.c skylight.h luacall.h
hover.so: hover.c luacall.h
frames.so: frames.c drag.c focus.c frames.h luacall.h preview.h skylight.h

%.so:
	clang $(CFLAGS) $(LDFLAGS) $(filter %.c,$^) -o $@

clean:
	rm -f $(MODULES)

.PHONY: all clean
