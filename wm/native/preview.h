// wm/native/preview.h: How a modifier-drag (drag.c) shows its frame in the
// window's ring (border.c) as the pointer moves, without waiting for the app.
//
// wm.native.border hands Lua the function as a light userdata
// (border.previewer()), and Lua passes it to frames.dragBegin. Both modules
// let go of it when their Lua state closes.

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

// Draws window `wid`'s ring around `frame` from now on, ignoring where the
// window itself is; with NULL, the ring follows the window again. Any
// thread (drag.c calls it from its tap's).
typedef void (*RingPreview)(uint32_t wid, const CGRect *frame);
