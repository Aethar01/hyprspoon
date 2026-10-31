# Builds the native modules (hyprspoon.native.*) against Hammerspoon's own Lua
# headers; Lua's symbols are resolved from Hammerspoon when they load.
# A reload picks up a rebuilt module.
#
# Override the paths if Hammerspoon lives elsewhere, e.g.
#   make HS_APP=~/Applications/Hammerspoon.app

HS_APP ?= /Applications/Hammerspoon.app
HS_HEADERS ?= $(HS_APP)/Contents/Frameworks/LuaSkin.framework/Headers
CFLAGS = -std=c11 -O2 -Wall -Wextra -arch arm64 -arch x86_64 -I$(HS_HEADERS)
LDFLAGS = -bundle -undefined dynamic_lookup -framework CoreFoundation -framework CoreGraphics \
	-framework ApplicationServices -framework Carbon

MODULES = border.so events.so hover.so frames.so slide.so

all: $(MODULES)

# Objective-C for CoreAnimation, its objects retained by hand (no ARC).
border.so: border.m skylight.h preview.h luacall.h
	clang $(CFLAGS) $(LDFLAGS) -framework Foundation -framework QuartzCore border.m -o $@
slide.so: slide.m skylight.h luacall.h
	clang $(CFLAGS) $(LDFLAGS) -framework Foundation -framework QuartzCore slide.m -o $@
events.so: events.c skylight.h luacall.h
hover.so: hover.c luacall.h
frames.so: frames.c drag.c focus.c tabs.c frames.h luacall.h preview.h skylight.h

%.so:
	clang $(CFLAGS) $(LDFLAGS) $(filter %.c,$^) -o $@

clean:
	rm -f $(MODULES)

.PHONY: all clean
