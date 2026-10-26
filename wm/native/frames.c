// wm/native/frames.c: Moving and resizing other apps' windows off the main
// thread.
//
// Loaded through Util.setFrame, Util.focusWindow and wm/mouse.lua as
// wm.native.frames (build: make -C wm/native).
//
// Moving another app's window is a set of accessibility calls that wait for
// that app to answer, so a busy or hung app stalls whoever asks, and
// Hammerspoon asks from its main thread, where Lua, hotkeys and every event
// tap run. Here each app gets a serial queue of its own: a slow app only
// holds up its own windows. Animations step on that queue too, eased like
// hs.window's (quadOut) and paced by the clock rather than Lua timers.
//
// Requests for a window coalesce: one still waiting is replaced by the next,
// and an animation still running stops for it, so an app that can't keep up
// skips to the latest frame instead of falling behind. An app's windows
// animate together, a step of each per frame: one at a time, a retile
// moved a terminal's other windows first and the focused one last.

#include <dispatch/dispatch.h>
#include <errno.h>
#include <math.h>
#include <os/lock.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "frames.h"

extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);

static double now(void) {
    return CFAbsoluteTimeGetCurrent();
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

// The latest request for a window, shared between the main thread (which
// makes them) and the app's queue (which carries them out).
typedef struct {
    uint32_t wid;
    pid_t pid;
    CGRect target;
    double duration;
    uint64_t generation; // bumped by each request
    bool pending;        // not yet taken up by the app's loop
    bool sole;           // see framesSet
    CGRect given;        // the frame last applied
    bool haveGiven;
} Request;

#define MAX_REQUESTS 512
static Request requests[MAX_REQUESTS];
static int requestCount = 0;
static os_unfair_lock requestsLock = OS_UNFAIR_LOCK_INIT;

// Set while Lua closes: runs return at once so the queues drain.
static atomic_bool stopping = false;

// With requestsLock held.
static Request *requestFor(uint32_t wid, bool create) {
    for (int i = 0; i < requestCount; i++) {
        if (requests[i].wid == wid) return &requests[i];
    }
    if (!create) return NULL;
    if (requestCount < MAX_REQUESTS) {
        Request *r = &requests[requestCount++];
        memset(r, 0, sizeof(*r));
        r->wid = wid;
        return r;
    }
    // Full: take over one that's done.
    for (int i = 0; i < requestCount; i++) {
        if (!requests[i].pending) {
            memset(&requests[i], 0, sizeof(requests[i]));
            requests[i].wid = wid;
            return &requests[i];
        }
    }
    return NULL;
}

static uint64_t generationOf(uint32_t wid) {
    os_unfair_lock_lock(&requestsLock);
    Request *r = requestFor(wid, false);
    uint64_t g = r ? r->generation : 0;
    os_unfair_lock_unlock(&requestsLock);
    return g;
}

// ---------------------------------------------------------------------------
// Apps
// ---------------------------------------------------------------------------

typedef struct {
    pid_t pid;
    dispatch_queue_t queue;
    // Used on the queue only.
    AXUIElementRef element;
    CFMutableDictionaryRef windows; // window id (CFNumber) -> AXUIElementRef
    // Under requestsLock: the window to raise (only the latest raise asked
    // for runs, see framesRaise), and whether the app's loop is on its queue.
    uint32_t raise;
    bool raiseQueued;
    bool running;
} App;

#define MAX_APPS 64
static App *apps[MAX_APPS]; // made and found on the main thread
static int appCount = 0;

static void releaseApp(void *context) {
    App *app = context;
    if (app->windows) CFRelease(app->windows);
    if (app->element) CFRelease(app->element);
    app->windows = NULL;
    app->element = NULL;
}

static void drop(App *app) {
    dispatch_sync_f(app->queue, app, releaseApp);
    dispatch_release(app->queue);
    free(app);
}

static App *appFor(pid_t pid, bool create) {
    for (int i = 0; i < appCount; i++) {
        if (apps[i]->pid == pid) return apps[i];
    }
    if (!create) return NULL;
    int slot = appCount;
    if (slot == MAX_APPS) {
        // Full: reuse the slot of an app that has quit.
        slot = -1;
        for (int i = 0; i < appCount; i++) {
            if (kill(apps[i]->pid, 0) != 0 && errno == ESRCH) {
                drop(apps[i]);
                slot = i;
                break;
            }
        }
        if (slot < 0) return NULL;
    } else {
        appCount++;
    }
    App *app = calloc(1, sizeof(App));
    app->pid = pid;
    char label[64];
    snprintf(label, sizeof(label), "wm.frames.%d", pid);
    app->queue = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
    apps[slot] = app;
    return app;
}

// ---------------------------------------------------------------------------
// Accessibility, on the app's queue
// ---------------------------------------------------------------------------

static CFNumberRef widNumber(uint32_t wid) {
    return CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
}

// The window's element, from the app's window list (read again when the
// window isn't in what was read last).
static AXUIElementRef windowElement(App *app, uint32_t wid) {
    if (!app->element) {
        app->element = AXUIElementCreateApplication(app->pid);
        AXUIElementSetMessagingTimeout(app->element, 1.0);
        app->windows = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
    }
    CFNumberRef key = widNumber(wid);
    AXUIElementRef win = (AXUIElementRef)CFDictionaryGetValue(app->windows, key);
    if (!win) {
        CFArrayRef list = NULL;
        if (AXUIElementCopyAttributeValue(app->element, kAXWindowsAttribute, (CFTypeRef *)&list)
                == kAXErrorSuccess && list) {
            CFDictionaryRemoveAllValues(app->windows);
            for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
                AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(list, i);
                CGWindowID id = 0;
                if (_AXUIElementGetWindow(w, &id) == kAXErrorSuccess && id) {
                    AXUIElementSetMessagingTimeout(w, 1.0);
                    CFNumberRef k = widNumber(id);
                    CFDictionarySetValue(app->windows, k, w);
                    CFRelease(k);
                }
            }
            CFRelease(list);
            win = (AXUIElementRef)CFDictionaryGetValue(app->windows, key);
        }
    }
    CFRelease(key);
    return win;
}

static void forgetWindow(App *app, uint32_t wid) {
    CFNumberRef key = widNumber(wid);
    CFDictionaryRemoveValue(app->windows, key);
    CFRelease(key);
}

static bool readFrame(AXUIElementRef win, CGRect *out) {
    CFTypeRef pos = NULL, size = NULL;
    bool ok = AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &pos) == kAXErrorSuccess
        && AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &size) == kAXErrorSuccess
        && AXValueGetValue(pos, kAXValueTypeCGPoint, &out->origin)
        && AXValueGetValue(size, kAXValueTypeCGSize, &out->size);
    if (pos) CFRelease(pos);
    if (size) CFRelease(size);
    return ok;
}

static void setPosition(AXUIElementRef win, CGPoint p) {
    AXValueRef v = AXValueCreate(kAXValueTypeCGPoint, &p);
    AXUIElementSetAttributeValue(win, kAXPositionAttribute, v);
    CFRelease(v);
}

static void setSize(AXUIElementRef win, CGSize s) {
    AXValueRef v = AXValueCreate(kAXValueTypeCGSize, &s);
    AXUIElementSetAttributeValue(win, kAXSizeAttribute, v);
    CFRelease(v);
}

static bool near(CGFloat a, CGFloat b) {
    return fabs(a - b) <= 1;
}

// Size, position, size (the second size for a window the first couldn't
// fully take where it was); only the one call when only one changed.
static void applyFrame(AXUIElementRef win, CGRect f, CGRect from) {
    bool moved = !near(f.origin.x, from.origin.x) || !near(f.origin.y, from.origin.y);
    bool resized = !near(f.size.width, from.size.width) || !near(f.size.height, from.size.height);
    if (moved && resized) {
        setSize(win, f.size);
        setPosition(win, f.origin);
        setSize(win, f.size);
    } else if (moved) {
        setPosition(win, f.origin);
    } else if (resized) {
        setSize(win, f.size);
    }
}

// A window easing towards its target, in its app's loop.
typedef struct {
    uint32_t wid;
    AXUIElementRef win; // retained: the app's window table may drop it
    CGRect from, target;
    double start, duration;
    uint64_t generation;
} Animation;

// A request taken up by the app's loop.
typedef struct {
    uint32_t wid;
    CGRect target, given;
    double duration;
    uint64_t generation;
    bool known;
} Taken;

#define MAX_ANIMATIONS 64

static void removeAnimation(Animation *anims, int *count, int i) {
    CFRelease(anims[i].win);
    anims[i] = anims[--*count];
}

static bool enhancedOff(App *app) {
    // With this on (VoiceOver, some automation tools), apps animate every
    // frame change themselves.
    CFTypeRef enhanced = NULL;
    bool restore = AXUIElementCopyAttributeValue(app->element, CFSTR("AXEnhancedUserInterface"), &enhanced)
            == kAXErrorSuccess && enhanced == kCFBooleanTrue;
    if (enhanced) CFRelease(enhanced);
    if (restore) AXUIElementSetAttributeValue(app->element, CFSTR("AXEnhancedUserInterface"), kCFBooleanFalse);
    return restore;
}

static void noteGiven(uint32_t wid, uint64_t generation, CGRect target) {
    os_unfair_lock_lock(&requestsLock);
    Request *r = requestFor(wid, false);
    if (r && r->generation == generation) {
        r->given = target;
        r->haveGiven = true;
    }
    os_unfair_lock_unlock(&requestsLock);
}

// An app's queue runs this while it has anything to do: it takes up new
// requests and raises, and steps every animation of the app's windows
// each frame, until all are done.
static void appLoop(void *context) {
    App *app = context;
    Animation anims[MAX_ANIMATIONS];
    int animCount = 0;
    Taken taken[MAX_ANIMATIONS];
    bool restore = false, checkedEnhanced = false;
    const double step = 1.0 / 60;
    double tick = now();

    for (;;) {
        int takenCount = 0;
        os_unfair_lock_lock(&requestsLock);
        bool stop = atomic_load(&stopping);
        for (int i = 0; i < requestCount && takenCount < MAX_ANIMATIONS && !stop; i++) {
            Request *r = &requests[i];
            if (!r->pending || r->pid != app->pid) continue;
            r->pending = false;
            taken[takenCount++] = (Taken){ r->wid, r->target, r->given, r->duration, r->generation,
                r->sole && r->haveGiven && r->duration <= 0 };
        }
        bool raise = app->raiseQueued && !stop;
        uint32_t raiseWid = app->raise;
        app->raiseQueued = false;
        if (stop || (takenCount == 0 && animCount == 0 && !raise)) {
            app->running = false;
            os_unfair_lock_unlock(&requestsLock);
            break;
        }
        os_unfair_lock_unlock(&requestsLock);

        if (raise) {
            AXUIElementRef win = windowElement(app, raiseWid);
            if (win) AXUIElementPerformAction(win, kAXRaiseAction);
        }

        for (int i = 0; i < takenCount; i++) {
            Taken *t = &taken[i];
            // A newer request for a window mid-animation takes over from
            // wherever the window is now.
            for (int j = 0; j < animCount; j++) {
                if (anims[j].wid == t->wid) removeAnimation(anims, &animCount, j--);
            }
            AXUIElementRef win = windowElement(app, t->wid);
            if (!win) continue;
            if (!checkedEnhanced) {
                restore = enhancedOff(app);
                checkedEnhanced = true;
            }
            CGRect from = t->given;
            if (!t->known && !readFrame(win, &from)) {
                forgetWindow(app, t->wid);
                continue;
            }
            if (t->duration > 0 && !CGRectEqualToRect(from, t->target) && animCount < MAX_ANIMATIONS) {
                if (animCount == 0) tick = now();
                CFRetain(win);
                anims[animCount++] = (Animation){ t->wid, win, from, t->target, now(), t->duration, t->generation };
            } else {
                applyFrame(win, t->target, from);
                noteGiven(t->wid, t->generation, t->target);
            }
        }

        double t = now();
        for (int i = 0; i < animCount; i++) {
            Animation *a = &anims[i];
            // Replaced: the new request is taken up on the next pass.
            if (generationOf(a->wid) != a->generation) {
                removeAnimation(anims, &animCount, i--);
                continue;
            }
            double p = (t - a->start) / a->duration;
            if (p >= 1) {
                // The steps went through every intermediate frame: finish
                // as a full set.
                setSize(a->win, a->target.size);
                setPosition(a->win, a->target.origin);
                setSize(a->win, a->target.size);
                noteGiven(a->wid, a->generation, a->target);
                removeAnimation(anims, &animCount, i--);
                continue;
            }
            double e = 1 - (1 - p) * (1 - p);
            CGRect f = {
                { a->from.origin.x + (a->target.origin.x - a->from.origin.x) * e,
                  a->from.origin.y + (a->target.origin.y - a->from.origin.y) * e },
                { a->from.size.width + (a->target.size.width - a->from.size.width) * e,
                  a->from.size.height + (a->target.size.height - a->from.size.height) * e },
            };
            setPosition(a->win, f.origin);
            setSize(a->win, f.size);
        }

        if (animCount > 0) {
            tick += step;
            double wait = tick - now();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
            else tick = now(); // the app is slower than the frame rate
        }
    }

    while (animCount > 0) removeAnimation(anims, &animCount, 0);
    if (restore) AXUIElementSetAttributeValue(app->element, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
}

// With requestsLock held: true if the app's loop must be put on its queue.
static bool wake(App *app) {
    if (app->running) return false;
    app->running = true;
    return true;
}

void framesSet(pid_t pid, uint32_t wid, CGRect target, double duration, bool sole) {
    App *app = appFor(pid, true);
    if (!app) return;
    os_unfair_lock_lock(&requestsLock);
    Request *r = requestFor(wid, true);
    bool start = false;
    if (r) {
        r->pid = pid;
        r->target = target;
        r->duration = duration;
        r->sole = sole;
        r->generation++;
        r->pending = true;
        start = wake(app);
    }
    os_unfair_lock_unlock(&requestsLock);
    if (start) dispatch_async_f(app->queue, app, appLoop);
}

// Raising waits for the app, which can take a busy app (a terminal
// mid-render) hundreds of milliseconds each: a raise per focus change as
// the pointer sweeps back and forth queued faster than Ghostty answered
// (7s of every 20 measured), and every other accessibility call to it,
// Hammerspoon's main thread's included, waited behind them. So a raise
// still waiting is replaced by the next one for the same app.
void framesRaise(pid_t pid, uint32_t wid) {
    App *app = appFor(pid, true);
    if (!app) return;
    os_unfair_lock_lock(&requestsLock);
    app->raise = wid;
    app->raiseQueued = true;
    bool start = wake(app);
    os_unfair_lock_unlock(&requestsLock);
    if (start) dispatch_async_f(app->queue, app, appLoop);
}

static void nothing(void *context) {
    (void)context;
}

void framesWait(pid_t pid) {
    App *app = appFor(pid, false);
    if (app) dispatch_sync_f(app->queue, NULL, nothing);
}

// ---------------------------------------------------------------------------
// Lua API
// ---------------------------------------------------------------------------

// set(pid, wid, x, y, w, h, duration)
static int l_set(lua_State *L) {
    pid_t pid = (pid_t)luaL_checkinteger(L, 1);
    uint32_t wid = (uint32_t)luaL_checkinteger(L, 2);
    CGRect f = { { luaL_checknumber(L, 3), luaL_checknumber(L, 4) },
                 { luaL_checknumber(L, 5), luaL_checknumber(L, 6) } };
    framesSet(pid, wid, f, luaL_optnumber(L, 7, 0), false);
    return 0;
}

// Collected with the Lua state (reload, quit), before Lua unloads the
// library: the queues are drained first, so nothing still runs in it.
static int l_gc(lua_State *L) {
    (void)L;
    dragStop();
    atomic_store(&stopping, true);
    for (int i = 0; i < appCount; i++) drop(apps[i]);
    appCount = 0;
    requestCount = 0;
    return 0;
}

int luaopen_wm_native_frames(lua_State *L) {
    atomic_store(&stopping, false);
    appCount = 0;
    requestCount = 0;

    static const luaL_Reg funcs[] = {
        { "set", l_set },
        { NULL, NULL },
    };
    luaL_newlib(L, funcs);
    dragRegister(L);
    focusRegister(L);

    lua_newuserdata(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, l_gc);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_setfield(L, -2, "_sentinel");
    return 1;
}
