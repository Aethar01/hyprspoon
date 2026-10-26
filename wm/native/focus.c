// wm/native/focus.c: Focusing a window without waiting for its app.
//
// Part of wm.native.frames (with frames.c). hs.window:focus() works through
// accessibility, which waits for the window's app to answer; a busy app
// (a terminal mid-render) takes hundreds of milliseconds, all of it on
// Hammerspoon's main thread (measured: Ghostty's median 105ms, up to
// 700ms). As yabai does, the app is brought to the front and the window
// made its key window by WindowServer instead, which doesn't wait for the
// app. Only the raise needs accessibility, and goes on the app's queue in
// frames.c.

#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <dlfcn.h>
#include <string.h>

#include "frames.h"
#include "skylight.h"

#define SL_FUNCS(X)                                                                  \
    X(CGError, _SLPSSetFrontProcessWithOptions, (ProcessSerialNumber *, uint32_t, uint32_t)) \
    X(CGError, SLPSPostEventRecordTo, (ProcessSerialNumber *, uint8_t *))

SL_FUNCS(SL_DECLARE)

static bool loaded = false;

static const char *loadSymbols(void) {
    slOpen();
    SL_FUNCS(SL_LOAD)
    return NULL;
}

// The front process becomes the window's app, as if the user chose it.
enum { USER_GENERATED = 0x200 };

// Tells the app that `wid` is its key window: the event records a click on
// it would send (as yabai's window_manager_make_key_window).
static void makeKeyWindow(ProcessSerialNumber *psn, uint32_t wid) {
    uint8_t bytes[0xf8];
    memset(bytes, 0, sizeof(bytes));
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &wid, sizeof(uint32_t));
    memset(bytes + 0x20, 0xff, 0x10);
    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(psn, bytes);
    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(psn, bytes);
}

// focus(pid, wid, raise): brings the window's app to the front with the
// window as its key window, raising it too if `raise`. False if this macOS
// lacks the calls (focus it through accessibility instead).
static int l_focus(lua_State *L) {
    pid_t pid = (pid_t)luaL_checkinteger(L, 1);
    uint32_t wid = (uint32_t)luaL_checkinteger(L, 2);
    bool raise = lua_toboolean(L, 3);
    if (!loaded) {
        lua_pushboolean(L, false);
        return 1;
    }
    ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = GetProcessForPID(pid, &psn);
#pragma clang diagnostic pop
    if (status != noErr) {
        lua_pushboolean(L, false);
        return 1;
    }
    _SLPSSetFrontProcessWithOptions(&psn, wid, USER_GENERATED);
    makeKeyWindow(&psn, wid);
    if (raise) framesRaise(pid, wid);
    lua_pushboolean(L, true);
    return 1;
}

void focusRegister(lua_State *L) {
    loaded = loadSymbols() == NULL;
    lua_pushcfunction(L, l_focus);
    lua_setfield(L, -2, "focus");
}
