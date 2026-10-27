// hyprspoon/native/hover.c: The window under the pointer, for focus follows mouse.
//
// Loaded by hyprspoon/ffm.lua as hyprspoon.native.hover (build: make -C hyprspoon/native).
//
// A listen-only event tap watches the pointer move and finds the window
// under it in the snapshot hyprspoon/focus.lua builds, calling Lua only when that
// window changes. Without a current snapshot (windows moved, appeared or
// changed focus since) every move goes to Lua, which builds one and hands
// it over.

#include <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <string.h>
#include <unistd.h>

#include "luacall.h"

typedef struct {
    uint32_t id;
    pid_t pid;
    CGRect frame;
    bool floating;
} Entry;

#define MAX_ENTRIES 256
#define MAX_UNMANAGED 32
static Entry entries[MAX_ENTRIES]; // front to back
static int entryCount = 0;
static CGRect unmanaged[MAX_UNMANAGED]; // pointer here focuses nothing (PiP)
static int unmanagedCount = 0;
static bool haveSnapshot = false;
static CFAbsoluteTime expires = 0;

static uint32_t last = 0; // the window last reported under the pointer
static int64_t warpMarker = 0;
static LuaCallback onMove = LUA_CALLBACK_NONE;
static CFMachPortRef tap = NULL;
static CFRunLoopSourceRef tapSource = NULL;

// Matches Util.pointInFrame: the right and bottom edges are outside.
static bool inside(CGPoint p, CGRect r) {
    return p.x >= r.origin.x && p.x < r.origin.x + r.size.width
        && p.y >= r.origin.y && p.y < r.origin.y + r.size.height;
}

// Focus.snapshotEntryAt: the topmost window under the point, except that a
// float under it wins over a tile of another app; nothing over PiP.
static uint32_t windowAt(CGPoint p) {
    for (int i = 0; i < unmanagedCount; i++) {
        if (inside(p, unmanaged[i])) return 0;
    }
    Entry *top = NULL;
    for (int i = 0; i < entryCount; i++) {
        if (inside(p, entries[i].frame)) {
            top = &entries[i];
            break;
        }
    }
    if (!top || top->floating) return top ? top->id : 0;
    for (int i = 0; i < entryCount; i++) {
        if (entries[i].floating && inside(p, entries[i].frame) && entries[i].pid != top->pid) {
            return entries[i].id;
        }
    }
    return top->id;
}

static void report(CGPoint p) {
    if (!luaCallbackPush(&onMove)) return;
    lua_pushnumber(onMove.L, p.x);
    lua_pushnumber(onMove.L, p.y);
    luaCallbackCall(&onMove, 2);
}

static CGEventRef onEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (tap) CGEventTapEnable(tap, true);
        return event;
    }
    if (type != kCGEventMouseMoved) return event;
    // Keyboard warps chose their window already.
    if (warpMarker && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == warpMarker) {
        return event;
    }
    CGPoint p = CGEventGetLocation(event);
    if (!haveSnapshot || CFAbsoluteTimeGetCurrent() > expires) {
        haveSnapshot = false;
        report(p);
        // Lua usually hands a snapshot over while handling it.
        if (haveSnapshot) last = windowAt(p);
        return event;
    }
    uint32_t id = windowAt(p);
    if (id != last) {
        last = id;
        report(p);
    }
    return event;
}

static void stop(void) {
    if (tap) {
        CGEventTapEnable(tap, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, kCFRunLoopCommonModes);
        CFRelease(tapSource);
        CFMachPortInvalidate(tap);
        CFRelease(tap);
        tap = NULL;
        tapSource = NULL;
    }
    luaCallbackClear(&onMove);
    haveSnapshot = false;
    last = 0;
}

// ---------------------------------------------------------------------------
// Lua API
// ---------------------------------------------------------------------------

// start(onMove, warpMarker): calls onMove(x, y) when the pointer moves onto
// another window (or off them), or on every move while there's no
// snapshot. Moves posted with `warpMarker` as their source user data are
// skipped. False if the tap can't be made (no accessibility permission).
static int l_start(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    stop();
    warpMarker = luaL_optinteger(L, 2, 0);
    tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventMouseMoved), onEvent, NULL);
    if (!tap) {
        lua_pushboolean(L, false);
        return 1;
    }
    tapSource = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    luaCallbackSet(&onMove, L, 1);
    lua_pushboolean(L, true);
    return 1;
}

static CGRect readRect(lua_State *L, int index) {
    CGRect r = CGRectZero;
    lua_getfield(L, index, "x");
    r.origin.x = lua_tonumber(L, -1);
    lua_getfield(L, index, "y");
    r.origin.y = lua_tonumber(L, -1);
    lua_getfield(L, index, "w");
    r.size.width = lua_tonumber(L, -1);
    lua_getfield(L, index, "h");
    r.size.height = lua_tonumber(L, -1);
    lua_pop(L, 4);
    return r;
}

// snapshot(entries, unmanaged, ttl): the windows front to back, each
// { id =, pid =, floating =, frame = {x, y, w, h} }, the frames over which
// nothing is focused, and how many seconds the snapshot holds.
static int l_snapshot(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    entryCount = 0;
    lua_Integer n = luaL_len(L, 1);
    for (lua_Integer i = 1; i <= n && entryCount < MAX_ENTRIES; i++) {
        lua_rawgeti(L, 1, i);
        Entry *e = &entries[entryCount++];
        lua_getfield(L, -1, "id");
        e->id = (uint32_t)lua_tointeger(L, -1);
        lua_getfield(L, -2, "pid");
        e->pid = (pid_t)lua_tointeger(L, -1);
        lua_getfield(L, -3, "floating");
        e->floating = lua_toboolean(L, -1);
        lua_getfield(L, -4, "frame");
        e->frame = lua_istable(L, -1) ? readRect(L, lua_gettop(L)) : CGRectZero;
        lua_pop(L, 5);
    }
    unmanagedCount = 0;
    if (lua_istable(L, 2)) {
        n = luaL_len(L, 2);
        for (lua_Integer i = 1; i <= n && unmanagedCount < MAX_UNMANAGED; i++) {
            lua_rawgeti(L, 2, i);
            unmanaged[unmanagedCount++] = readRect(L, lua_gettop(L));
            lua_pop(L, 1);
        }
    }
    expires = CFAbsoluteTimeGetCurrent() + luaL_optnumber(L, 3, 1);
    haveSnapshot = true;
    return 0;
}

// invalidate(): the snapshot is out of date; send every move to Lua again.
static int l_invalidate(lua_State *L) {
    (void)L;
    haveSnapshot = false;
    return 0;
}

// forget(): report the window under the pointer on the next move even if
// it's the one reported last.
static int l_forget(lua_State *L) {
    (void)L;
    last = 0;
    return 0;
}

static int number(CFDictionaryRef info, CFStringRef key, CFNumberType type, void *out) {
    CFNumberRef n = CFDictionaryGetValue(info, key);
    return n && CFNumberGetValue(n, type, out);
}

// Whether `pid` is Notification Centre. While a banner shows it keeps a
// transparent, click-through window over the whole screen, above the
// windows (layer 21), which would otherwise pass for a popup everywhere.
// By path: its window's owner name is localized. Not UserNotificationCenter,
// whose dialogs are real.
static bool isNotificationCenter(pid_t pid) {
    static pid_t known = 0;
    if (pid == known) return true;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) <= 0 || !strstr(path, "/NotificationCenter.app/")) return false;
    known = pid;
    return true;
}

// Whether `bounds` spans the whole display under `p`.
static bool coversDisplay(CGPoint p, CGRect bounds) {
    CGDirectDisplayID display;
    uint32_t count = 0;
    if (CGGetDisplaysWithPoint(p, 1, &display, &count) != kCGErrorSuccess || count == 0) return false;
    return CGRectContainsRect(bounds, CGDisplayBounds(display));
}

// topAt(x, y): the frontmost window on screen under the point, as its id,
// its owner's pid and its level (0 for normal windows, 101 for menus).
// Skips Hammerspoon's own (rings, highlights), invisible ones, the
// cursor's and Notification Centre's. Nothing if there's none. One
// WindowServer query, ~1ms.
static int l_topAt(lua_State *L) {
    CGPoint p = { luaL_checknumber(L, 1), luaL_checknumber(L, 2) };
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return 0;
    pid_t self = getpid();
    int found = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list) && !found; i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
        int32_t pid = 0, layer = 0, id = 0;
        double alpha = 1;
        CGRect bounds;
        CFDictionaryRef b = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!number(info, kCGWindowOwnerPID, kCFNumberSInt32Type, &pid) || pid == self) continue;
        number(info, kCGWindowLayer, kCFNumberSInt32Type, &layer);
        number(info, kCGWindowAlpha, kCFNumberDoubleType, &alpha);
        number(info, kCGWindowNumber, kCFNumberSInt32Type, &id);
        if (alpha <= 0 || layer >= kCGScreenSaverWindowLevel) continue;
        if (!b || !CGRectMakeWithDictionaryRepresentation(b, &bounds) || !inside(p, bounds)) continue;
        if (layer > 0 && isNotificationCenter(pid)) continue;
        // The Dock keeps an invisible window over each whole display (macOS 27):
        // not a menu, and it would stop every window from taking focus.
        if (layer > 0 && coversDisplay(p, bounds)) continue;
        lua_pushinteger(L, id);
        lua_pushinteger(L, pid);
        lua_pushinteger(L, layer);
        found = 3;
    }
    CFRelease(list);
    return found;
}

static int l_stop(lua_State *L) {
    (void)L;
    stop();
    return 0;
}

static int l_gc(lua_State *L) {
    (void)L;
    stop();
    return 0;
}

int luaopen_hyprspoon_native_hover(lua_State *L) {
    static const luaL_Reg funcs[] = {
        { "start", l_start },
        { "snapshot", l_snapshot },
        { "invalidate", l_invalidate },
        { "forget", l_forget },
        { "topAt", l_topAt },
        { "stop", l_stop },
        { NULL, NULL },
    };
    luaL_newlib(L, funcs);

    lua_newuserdata(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, l_gc);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_setfield(L, -2, "_sentinel");
    return 1;
}
