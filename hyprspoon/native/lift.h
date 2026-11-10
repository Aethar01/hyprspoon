// hyprspoon/native/lift.h: How a modifier-drag (drag.c) drags a picture of its
// window (slide.m) instead of the window itself (mouse.dragEffect, #26).
//
// hyprspoon.native.slide hands Lua its Lifter as a light userdata
// (slide.lifter()), and Lua passes it to frames.dragBegin. Both modules let
// go of it when their Lua state closes.

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

// Asked by the picture once it's up over the window, where the drag last
// had it: true if drag `serial` is still on and takes it (the window is
// parked out of sight by then, and the drag moves the picture from now
// on); false, and the picture goes. Any thread (slide.m asks from its own).
typedef bool (*LiftClaim)(unsigned serial);

typedef struct {
    // Drag `serial` of window `wid`, at `frame`, has begun: a picture of
    // the window is taken off the caller's thread (about 40ms), put up at
    // the frame last given to move(), and offered to `claim`. Main thread.
    void (*begin)(unsigned serial, uint32_t wid, CGRect frame, LiftClaim claim);
    // The frame drag `serial` has its window at now (unshrunk): the
    // picture follows it once it's up. Any thread (drag.c's tap's).
    void (*move)(unsigned serial, CGRect frame);
} Lifter;
