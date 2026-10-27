// hyprspoon/native/events.c: Window moves and resizes, as WindowServer reports them.
//
// Loaded by hyprspoon/init.lua as hyprspoon.native.events (build: make -C hyprspoon/native).
//
// hs.window.filter hears of moves through accessibility notifications and
// holds each back half a second. WindowServer reports them as they happen;
// this hands them to Lua once per run loop pass, each window once however
// many moves it made in between.
//
// While a mouse button is down, though, Lua hears at most every 100ms, and
// once more when it comes up. A window being resized reports every frame,
// and WindowServer's notifications arrive on Hammerspoon's main thread,
// where Lua runs: busy with Lua on every frame, the main thread falls
// behind taking them, and the resize hitches the whole screen.

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <string.h>

#include "luacall.h"
#include "skylight.h"

#define SL_FUNCS(X)                                                       \
    X(int, SLSMainConnectionID, (void))                                   \
    X(CGError, SLSRegisterNotifyProc, (void *, uint32_t, void *))         \
    X(CGError, SLSRemoveNotifyProc, (void *, uint32_t, void *))           \
    X(CGError, SLSRequestNotificationsForWindows, (int, uint32_t *, int))

SL_FUNCS(SL_DECLARE)

static const char *loadSymbols(void) {
    slOpen();
    SL_FUNCS(SL_LOAD)
    return NULL;
}

static int cid = 0;
static LuaCallback onMoved = LUA_CALLBACK_NONE;

// Windows moved since the last delivery.
#define MAX_PENDING 256
static uint32_t pending[MAX_PENDING];
static int pendingCount = 0;

// Both fire on the main queue to deliver what's pending (`later` once the
// held-button wait is over); cancelled when Lua closes, so nothing runs in
// this library after it's unloaded.
static dispatch_source_t delivery = NULL;
static dispatch_source_t later = NULL;
static bool laterArmed = false;

#define HELD_INTERVAL 0.1
static double lastDelivered = 0;

static bool buttonHeld(void) {
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)
        || CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight);
}

static void deliver(void *unused) {
    (void)unused;
    if (pendingCount == 0) return;
    double now = CFAbsoluteTimeGetCurrent();
    double wait = lastDelivered + HELD_INTERVAL - now;
    if (wait > 0 && buttonHeld()) {
        if (!laterArmed) {
            dispatch_source_set_timer(later, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 1000);
            dispatch_resume(later);
            laterArmed = true;
        }
        return;
    }
    lastDelivered = now;
    uint32_t moved[MAX_PENDING];
    int count = pendingCount;
    memcpy(moved, pending, sizeof(uint32_t) * count);
    pendingCount = 0;
    for (int i = 0; i < count; i++) {
        if (!luaCallbackPush(&onMoved)) break;
        lua_pushinteger(onMoved.L, moved[i]);
        luaCallbackCall(&onMoved, 1);
    }
}

static void deliverLater(void *unused) {
    (void)unused;
    dispatch_suspend(later);
    laterArmed = false;
    deliver(NULL);
}

// A window whose moves aren't reported for now (one being dragged: its
// every frame would otherwise reach Lua). Main thread.
static uint32_t muted = 0;

static void note(uint32_t wid) {
    if (wid == muted) return;
    bool listed = false;
    for (int i = 0; i < pendingCount; i++) {
        if (pending[i] == wid) {
            listed = true;
            break;
        }
    }
    if (!listed && pendingCount < MAX_PENDING) pending[pendingCount++] = wid;
    if (delivery) dispatch_source_merge_data(delivery, 1);
}

static void onWindowEvent(uint32_t event, void *data, size_t length, void *context) {
    (void)event;
    (void)context;
    if (!data || length < sizeof(uint32_t)) return;
    uint32_t wid;
    memcpy(&wid, data, sizeof(uint32_t));
    // WindowServer calls from the main thread; anything else waits for it.
    if (pthread_main_np()) note(wid);
}

static const uint32_t events[] = { SL_EVENT_WINDOW_MOVE, SL_EVENT_WINDOW_RESIZE };
#define EVENT_COUNT (sizeof(events) / sizeof(events[0]))

static bool registered = false;

static void registerEvents(bool on) {
    if (on == registered) return;
    registered = on;
    for (size_t i = 0; i < EVENT_COUNT; i++) {
        if (on) SLSRegisterNotifyProc((void *)onWindowEvent, events[i], NULL);
        else SLSRemoveNotifyProc((void *)onWindowEvent, events[i], NULL);
    }
}

static void stop(void) {
    registerEvents(false);
    if (delivery) {
        dispatch_source_cancel(delivery);
        dispatch_release(delivery);
        delivery = NULL;
    }
    if (later) {
        // A suspended source can't be cancelled.
        if (!laterArmed) dispatch_resume(later);
        dispatch_source_cancel(later);
        dispatch_release(later);
        later = NULL;
        laterArmed = false;
    }
    luaCallbackClear(&onMoved);
    pendingCount = 0;
    muted = 0;
}

// ---------------------------------------------------------------------------
// Lua API
// ---------------------------------------------------------------------------

// start(onMoved): calls onMoved(windowId) as watched windows move or resize.
static int l_start(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    stop();
    luaCallbackSet(&onMoved, L, 1);
    delivery = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler_f(delivery, deliver);
    dispatch_resume(delivery);
    later = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler_f(later, deliverLater);
    laterArmed = false; // made suspended
    lastDelivered = 0;
    registerEvents(true);
    return 0;
}

// watch({wid, ...}): the windows to hear about (see skylight.h).
static int l_watch(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    uint32_t wids[512];
    int count = luaWindowIds(L, 1, wids, 512);
    SLSRequestNotificationsForWindows(cid, wids, count);
    return 0;
}

// mute(wid or nil): stops reporting that window's moves, until the next
// mute; then reports it once, as it is by then.
static int l_mute(lua_State *L) {
    uint32_t wid = (uint32_t)luaL_optinteger(L, 1, 0);
    uint32_t was = muted;
    muted = wid;
    if (was && was != wid) note(was);
    return 0;
}

static int l_stop(lua_State *L) {
    (void)L;
    stop();
    return 0;
}

// Collected with the Lua state (reload, quit), before Lua unloads the
// library: nothing may call into it afterwards.
static int l_gc(lua_State *L) {
    (void)L;
    stop();
    return 0;
}

int luaopen_hyprspoon_native_events(lua_State *L) {
    const char *missing = loadSymbols();
    if (missing) return luaL_error(L, "hyprspoon.native.events: SkyLight has no %s", missing);
    cid = SLSMainConnectionID();

    static const luaL_Reg funcs[] = {
        { "start", l_start },
        { "watch", l_watch },
        { "mute", l_mute },
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
