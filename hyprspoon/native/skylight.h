// hyprspoon/native/skylight.h: WindowServer (SkyLight) helpers shared by the native
// modules.
//
// SkyLight's calls are private. Each module lists the ones it uses as
// X(return type, name, (argument types)), declares them with SL_DECLARE and
// looks them up with SL_LOAD when it loads, so a call missing after a macOS
// update fails the require with its name instead of crashing.

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdbool.h>

#define SL_DECLARE(ret, name, args) static ret(*name) args;

// Inside a function returning const char *: returns the name of the first
// call that can't be found.
#define SL_LOAD(ret, name, args)                    \
    name = (ret(*) args)dlsym(RTLD_DEFAULT, #name); \
    if (!name) return #name;

static inline void slOpen(void) {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
}

// WindowServer notifications (SLSRegisterNotifyProc). The window events
// carry the window id as their payload; create and destroy carry
// { uint64_t space; uint32_t window; }.
enum {
    SL_EVENT_WINDOW_CLOSE = 804,
    SL_EVENT_WINDOW_MOVE = 806,
    SL_EVENT_WINDOW_RESIZE = 807,
    SL_EVENT_WINDOW_REORDER = 808,
    SL_EVENT_WINDOW_LEVEL = 811,
    SL_EVENT_WINDOW_UNHIDE = 815,
    SL_EVENT_WINDOW_HIDE = 816,
    SL_EVENT_WINDOW_CREATE = 1325,
    SL_EVENT_WINDOW_DESTROY = 1326,
    SL_EVENT_SPACE_CHANGE = 1401,
};

// A one-element CFArray of a window id, as SkyLight's list calls take.
static inline CFArrayRef slWindowList(uint32_t wid) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&n, 1, &kCFTypeArrayCallBacks);
    CFRelease(n);
    return list;
}

// WindowServer reports moves, resizes and restacks only of the windows a
// connection asks about (SLSRequestNotificationsForWindows), and each ask
// replaces the last. hyprspoon.native.events and hyprspoon.native.border both ask on
// Hammerspoon's connection, so Lua hands both the same list: the windows
// it manages (Util.watchWindows), as JankyBorders asks only about the
// windows it borders. With experimental.borderMask, border.m adds every
// other window on screen, and events.c leaves those out.
