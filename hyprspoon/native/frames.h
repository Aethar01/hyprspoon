// hyprspoon/native/frames.h: Shared between frames.c, drag.c and focus.c, built
// together as hyprspoon.native.frames.

#pragma once

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <dispatch/dispatch.h>

#include "lauxlib.h"
#include "lua.h"

// Gives window `wid` of app `pid` the frame `target`, eased over `duration`
// seconds (0: at once). Returns straight away; the accessibility calls run
// on the app's own queue. A later call for the same window replaces this
// one, mid-animation or not yet started. `sole` says nothing but these calls
// has moved the window since the last one (a drag in progress), so the
// frame it was last given stands in for asking the app where it is.
void framesSet(pid_t pid, uint32_t wid, CGRect target, double duration, bool sole);

// Waits until the app's queue has applied everything asked of it so far.
void framesWait(pid_t pid);

// Raises window `wid` of app `pid` (an accessibility call) on the app's
// queue, after whatever is already asked of it. A raise for the app still
// waiting is replaced by this one.
void framesRaise(pid_t pid, uint32_t wid);

// Drag API registered into the module table at the top of the stack, and
// its cleanup when Lua closes.
void dragRegister(lua_State *L);
void dragStop(void);

// focus() (focus.c), registered into the module table at the top of the stack.
void focusRegister(lua_State *L);

// Native-tab queries and a retained AXWindow omitted from AXWindows.
void tabsRegister(lua_State *L);
void framesShowTab(pid_t pid, uint32_t wid, uint32_t shown, CFStringRef title);
bool tabsSelect(pid_t pid, uint32_t shown, CFStringRef title);

// Schedule bounded discovery work on the same per-app worker as frames.
dispatch_queue_t framesWorker(pid_t pid);
void tabsCancel(void);
void tabsCancelApp(pid_t pid);
void tabsStop(void);

void tabsRemember(pid_t pid, uint32_t wid, AXUIElementRef element);
