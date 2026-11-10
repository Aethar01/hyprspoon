// hyprspoon/native/drag.c: Modifier-drags, followed from a native event tap.
//
// Part of hyprspoon.native.frames (with frames.c). hyprspoon/mouse.lua starts a drag on
// the mouse-down, having decided what it is (a move, or a resize from which
// edges); from then on this follows the pointer itself. Frames go out at
// most once per display refresh, the latest position always following on a
// trailing timer: pointer events come far faster (up to 1000 a second), and
// an app that took a new size for each would have WindowServer compositing
// far more often than the display shows. Each frame goes to frames.c (which
// the app gets as fast as it can take them), to the window's ring, and for
// moves to Lua for the drop preview.
//
// With mouse.dragEffect, a move drags a picture of the window instead, once
// one is up (see "The picture dragged instead" below).
//
// The tap runs on a thread of its own. A tap that can swallow events holds
// up the session's input until it returns, so on Hammerspoon's main thread
// every pointer event of a drag would wait for whatever Lua was doing.
// Everything about the drag in progress (`drag`, the tap, the trailing
// timer) belongs to that thread; Lua's calls reach it through runOnTap.

#include <dispatch/dispatch.h>
#include <math.h>
#include <os/lock.h>
#include <pthread.h>
#include <string.h>

#include "frames.h"
#include "lift.h"
#include "luacall.h"
#include "preview.h"

typedef struct {
    bool active;
    pid_t pid;
    uint32_t wid;
    bool move;
    CGRect frame;  // the window's frame when the drag began
    CGPoint start; // the pointer then
    char xBranch, yBranch; // 'a': the right/bottom edge follows, 'b': the left/top, 0: neither
    CGFloat minW, minH;
    CGRect last; // the frame last given
    bool given;  // a frame has been given
    double interval;     // seconds per display refresh
    double lastGiven;    // when the last frame was given
    CGPoint waiting;     // the latest pointer position not given yet
    bool haveWaiting;
    bool trailingArmed;
    RingPreview preview; // shows each frame in the window's ring, if given
    bool tellLua;        // moves go to Lua (onMove)
    const Lifter *lifter; // drags a picture of the window once it's up, if given
    unsigned serial;      // this drag, to the lifter
} Drag;

static Drag drag;

// ---------------------------------------------------------------------------
// The tap's thread
// ---------------------------------------------------------------------------

static pthread_t tapThread;
static bool tapThreadRunning = false; // main thread's view
static CFRunLoopRef tapLoop = NULL;
static CFRunLoopTimerRef trailing = NULL; // gives the waiting position
static bool quitting = false;
static CFMachPortRef tap = NULL;
static CFRunLoopSourceRef tapSource = NULL;

static const CFTimeInterval NEVER = 1e10;

static void giveWaiting(CFRunLoopTimerRef timer, void *info);

static void *tapThreadMain(void *ready) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    tapLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    // Repeating, so it isn't invalidated after firing; pace() sets each
    // fire date. It also keeps the run loop running between drags.
    trailing = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + NEVER, NEVER, 0, 0, giveWaiting, NULL);
    CFRunLoopAddTimer(tapLoop, trailing, kCFRunLoopCommonModes);
    dispatch_semaphore_signal((dispatch_semaphore_t)ready);
    while (!quitting) CFRunLoopRun();
    CFRunLoopTimerInvalidate(trailing);
    CFRelease(trailing);
    trailing = NULL;
    CFRelease(tapLoop);
    tapLoop = NULL;
    return NULL;
}

// Runs `block` on the tap's thread (starting it if need be) and waits for it.
static bool runOnTap(void (^block)(void)) {
    if (!tapThreadRunning) {
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        quitting = false;
        if (pthread_create(&tapThread, NULL, tapThreadMain, ready) != 0) {
            dispatch_release(ready);
            return false;
        }
        dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
        dispatch_release(ready);
        tapThreadRunning = true;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(tapLoop, kCFRunLoopCommonModes, ^{
        block();
        dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(tapLoop);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_release(done);
    return true;
}

// ---------------------------------------------------------------------------
// Moves to Lua, on the main thread
// ---------------------------------------------------------------------------
//
// Through a run loop source on the main run loop rather than a dispatch: a
// removed source is never called again, so nothing is left pending to run
// in this library after it's unloaded. Only the latest point is kept.

static LuaCallback onMove = LUA_CALLBACK_NONE;
static CFRunLoopSourceRef moveSource = NULL;
static os_unfair_lock moveLock = OS_UNFAIR_LOCK_INIT;
static CGPoint movePoint;
static bool moveWaiting = false;

static void deliverMove(void *info) {
    (void)info;
    os_unfair_lock_lock(&moveLock);
    CGPoint p = movePoint;
    bool waiting = moveWaiting;
    moveWaiting = false;
    os_unfair_lock_unlock(&moveLock);
    if (waiting && luaCallbackPush(&onMove)) {
        lua_pushnumber(onMove.L, p.x);
        lua_pushnumber(onMove.L, p.y);
        luaCallbackCall(&onMove, 2);
    }
}

// Tap thread.
static void tellMove(CGPoint p) {
    os_unfair_lock_lock(&moveLock);
    movePoint = p;
    moveWaiting = true;
    os_unfair_lock_unlock(&moveLock);
    CFRunLoopSourceSignal(moveSource);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

// Main thread.
static void stopTellingLua(void) {
    if (moveSource) {
        CFRunLoopSourceInvalidate(moveSource);
        CFRelease(moveSource);
        moveSource = NULL;
    }
    moveWaiting = false;
    luaCallbackClear(&onMove);
}

// ---------------------------------------------------------------------------
// The picture dragged instead (mouse.dragEffect, lift.h)
// ---------------------------------------------------------------------------
//
// A move with a Lifter begins with the window itself, as any other, so
// nothing waits for the picture (a capture takes about 40ms). Capturing
// the window under the pointer whenever the modifier goes down instead
// would cost that each time Option is held to type a character, mostly
// for nothing. The picture comes up over the window where the drag has it
// then, and claimLift() parks the window where
// Lua's Spaces.parkPoint says, as a window on another workspace waits;
// from then on the drag moves the picture, and the ring follows it, shrunk
// as it's drawn. Once the button's up, dragEnd gives the window the drag's
// last frame.
//
// The window's frames go out under liftLock, as does the park: a frame on
// its way can't follow the park and bring the window back.

enum { LIFT_NONE, LIFT_WAITING, LIFT_TAKEN };

static os_unfair_lock liftLock = OS_UNFAIR_LOCK_INIT;
static int liftState = LIFT_NONE;
static unsigned liftSerial = 0; // the drag waiting for its picture, or dragging it
static unsigned liftSerials = 0;
static pid_t liftPid = 0;
static uint32_t liftWid = 0;
static CGRect liftPark;  // where the window waits
static CGRect liftLast;  // the frame the drag last gave
static bool liftKept = false; // kept parked past dragEnd while the picture goes home
static CGFloat liftScale = 1;
static RingPreview liftPreview = NULL;

// `f` shrunk to `scale` about its middle, as the picture is drawn.
static CGRect shrunk(CGRect f, CGFloat scale) {
    CGFloat w = f.size.width * scale, h = f.size.height * scale;
    return CGRectMake(f.origin.x + (f.size.width - w) / 2, f.origin.y + (f.size.height - h) / 2, w, h);
}

// LiftClaim (lift.h), on slide.m's queue.
static bool claimLift(unsigned serial) {
    os_unfair_lock_lock(&liftLock);
    bool take = liftState == LIFT_WAITING && serial == liftSerial;
    if (take) {
        liftState = LIFT_TAKEN;
        framesSet(liftPid, liftWid, liftPark, 0, true);
        CGRect ring = shrunk(liftLast, liftScale);
        if (liftPreview) liftPreview(liftWid, &ring);
    }
    os_unfair_lock_unlock(&liftLock);
    return take;
}

// The drag with a picture is over (or Lua is closing): the window comes
// back from where it was parked to `frame` (NULL: the drag's last; always
// its own frame if dragEnd kept it parked). True if it was parked.
static bool unlift(const CGRect *frame) {
    os_unfair_lock_lock(&liftLock);
    bool taken = liftState == LIFT_TAKEN;
    if (taken) framesSet(liftPid, liftWid, frame && !liftKept ? *frame : liftLast, 0, true);
    liftKept = false;
    liftState = LIFT_NONE;
    liftPreview = NULL;
    os_unfair_lock_unlock(&liftLock);
    return taken;
}

// ---------------------------------------------------------------------------
// Following the pointer (tap thread)
// ---------------------------------------------------------------------------

// As Resize.resizeDrag and the move in mouse.lua's applyDrag.
static CGRect frameAt(CGPoint p) {
    CGFloat dx = p.x - drag.start.x, dy = p.y - drag.start.y;
    CGRect f = drag.frame;
    if (drag.move) {
        f.origin.x += dx;
        f.origin.y += dy;
        return f;
    }
    if (drag.xBranch == 'a') {
        f.size.width = fmax(drag.minW, f.size.width + dx);
    } else if (drag.xBranch == 'b') {
        CGFloat w = fmax(drag.minW, f.size.width - dx);
        f.origin.x += f.size.width - w;
        f.size.width = w;
    }
    if (drag.yBranch == 'a') {
        f.size.height = fmax(drag.minH, f.size.height + dy);
    } else if (drag.yBranch == 'b') {
        CGFloat h = fmax(drag.minH, f.size.height - dy);
        f.origin.y += f.size.height - h;
        f.size.height = h;
    }
    return f;
}

// A frame of a drag with a Lifter: to the window until the picture is
// up, then to the picture alone (see claimLift).
static void giveLifted(void) {
    os_unfair_lock_lock(&liftLock);
    bool lifted = liftState == LIFT_TAKEN;
    CGRect ring = lifted ? shrunk(drag.last, liftScale) : drag.last;
    liftLast = drag.last;
    if (!lifted) framesSet(drag.pid, drag.wid, drag.last, 0, drag.given);
    if (drag.preview) drag.preview(drag.wid, &ring);
    os_unfair_lock_unlock(&liftLock);
    drag.lifter->move(drag.serial, drag.last);
}

// After the first, the drag's frames go without asking the app where the
// window is: nothing else moves it meanwhile.
static void give(CGPoint p) {
    drag.last = frameAt(p);
    if (drag.lifter) {
        giveLifted();
    } else {
        framesSet(drag.pid, drag.wid, drag.last, 0, drag.given);
    }
    drag.given = true;
    drag.lastGiven = CFAbsoluteTimeGetCurrent();
    drag.haveWaiting = false;
    if (drag.preview && !drag.lifter) drag.preview(drag.wid, &drag.last);
    if (drag.move && drag.tellLua) tellMove(p);
}

static void giveWaiting(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    drag.trailingArmed = false;
    if (drag.active && drag.haveWaiting) give(drag.waiting);
}

// A pointer position: given now if a refresh has passed since the last,
// else when one has.
static void pace(CGPoint p) {
    double now = CFAbsoluteTimeGetCurrent();
    double wait = drag.lastGiven + drag.interval - now;
    if (wait <= 0) {
        give(p);
        return;
    }
    drag.waiting = p;
    drag.haveWaiting = true;
    if (drag.trailingArmed) return;
    CFRunLoopTimerSetNextFireDate(trailing, now + wait);
    drag.trailingArmed = true;
}

static void disarm(void) {
    if (trailing) CFRunLoopTimerSetNextFireDate(trailing, CFAbsoluteTimeGetCurrent() + NEVER);
    drag.trailingArmed = false;
    drag.haveWaiting = false;
}

static void removeTap(void) {
    if (!tap) return;
    CGEventTapEnable(tap, false);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, kCFRunLoopCommonModes);
    CFRelease(tapSource);
    CFMachPortInvalidate(tap);
    CFRelease(tap);
    tap = NULL;
    tapSource = NULL;
}

static void end(void) {
    disarm();
    drag.active = false;
    removeTap();
}

static CGEventRef onEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy;
    (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (tap) CGEventTapEnable(tap, true);
        return event;
    }
    if (!drag.active) return event;
    CGPoint p = CGEventGetLocation(event);
    if (type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) {
        pace(p);
        // Ours: the app under the pointer doesn't see the drag.
        return NULL;
    }
    // The button came up: the last position, and the release goes on to
    // hyprspoon/mouse.lua, which finishes the drag (and removes the tap: not from
    // inside its own callback).
    disarm();
    give(p);
    drag.active = false;
    CGEventTapEnable(tap, false);
    return event;
}

// ---------------------------------------------------------------------------
// Lua API (main thread)
// ---------------------------------------------------------------------------

// The ring follows the window again: once the app has the last frame.
static void endPreview(void) {
    if (drag.preview) drag.preview(drag.wid, NULL);
    drag.preview = NULL;
}

static char branch(lua_State *L, const char *key) {
    lua_getfield(L, 1, key);
    const char *s = lua_tostring(L, -1);
    char c = s && (s[0] == 'a' || s[0] == 'b') ? s[0] : 0;
    lua_pop(L, 1);
    return c;
}

static CGFloat number(lua_State *L, int index, const char *key, CGFloat fallback) {
    lua_getfield(L, index, key);
    CGFloat v = luaL_optnumber(L, -1, fallback);
    lua_pop(L, 1);
    return v;
}

// dragBegin{ pid =, wid =, mode = "move" | "resize", frame = {x, y, w, h},
// point = {x, y}, xBranch =, yBranch = ("a", "b" or nil), minW =, minH =,
// onMove = function(x, y), preview = border.previewer(), interval = seconds
// per display refresh, lift = slide.lifter(), liftScale =, park = {x, y} }:
// follows the pointer until dragEnd or the button comes up. A move with
// `lift` and `park` drags a picture of the window, shrunk to `liftScale`,
// once it's up, the window parked at `park` meanwhile. False if the tap
// can't be made.
static int l_begin(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    // Anything left of an earlier drag.
    if (tapThreadRunning) runOnTap(^{ end(); });
    unlift(NULL);
    endPreview();
    stopTellingLua();

    Drag next;
    memset(&next, 0, sizeof(next));
    next.pid = (pid_t)number(L, 1, "pid", 0);
    next.wid = (uint32_t)number(L, 1, "wid", 0);
    lua_getfield(L, 1, "mode");
    next.move = lua_tostring(L, -1) && strcmp(lua_tostring(L, -1), "move") == 0;
    lua_pop(L, 1);
    lua_getfield(L, 1, "frame");
    luaL_checktype(L, -1, LUA_TTABLE);
    int f = lua_gettop(L);
    next.frame = CGRectMake(number(L, f, "x", 0), number(L, f, "y", 0), number(L, f, "w", 0), number(L, f, "h", 0));
    lua_pop(L, 1);
    lua_getfield(L, 1, "point");
    luaL_checktype(L, -1, LUA_TTABLE);
    int p = lua_gettop(L);
    next.start = CGPointMake(number(L, p, "x", 0), number(L, p, "y", 0));
    lua_pop(L, 1);
    next.xBranch = branch(L, "xBranch");
    next.yBranch = branch(L, "yBranch");
    next.minW = number(L, 1, "minW", 0);
    next.minH = number(L, 1, "minH", 0);
    next.interval = number(L, 1, "interval", 1.0 / 60);
    lua_getfield(L, 1, "preview");
    next.preview = lua_islightuserdata(L, -1) ? (RingPreview)lua_touserdata(L, -1) : NULL;
    lua_pop(L, 1);
    CGPoint park = CGPointZero;
    lua_getfield(L, 1, "park");
    bool parks = lua_istable(L, -1);
    if (parks) {
        int t = lua_gettop(L);
        park = CGPointMake(number(L, t, "x", 0), number(L, t, "y", 0));
    }
    lua_pop(L, 1);
    lua_getfield(L, 1, "lift");
    next.lifter = next.move && parks && lua_islightuserdata(L, -1) ? (const Lifter *)lua_touserdata(L, -1) : NULL;
    lua_pop(L, 1);
    if (next.lifter) {
        if (++liftSerials == 0) liftSerials = 1;
        next.serial = liftSerials;
        CGFloat scale = fmin(1, fmax(0.1, number(L, 1, "liftScale", 1)));
        os_unfair_lock_lock(&liftLock);
        liftState = LIFT_WAITING;
        liftSerial = next.serial;
        liftPid = next.pid;
        liftWid = next.wid;
        liftPark = (CGRect){ park, next.frame.size };
        liftLast = next.frame;
        liftScale = scale;
        liftPreview = next.preview;
        os_unfair_lock_unlock(&liftLock);
    }
    lua_getfield(L, 1, "onMove");
    if (lua_isfunction(L, -1)) {
        luaCallbackSet(&onMove, L, lua_gettop(L));
        CFRunLoopSourceContext context;
        memset(&context, 0, sizeof(context));
        context.perform = deliverMove;
        moveSource = CFRunLoopSourceCreate(NULL, 0, &context);
        CFRunLoopAddSource(CFRunLoopGetMain(), moveSource, kCFRunLoopCommonModes);
        next.tellLua = true;
    }
    lua_pop(L, 1);

    __block bool ok = false;
    bool ran = runOnTap(^{
        drag = next;
        CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged)
            | CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventRightMouseUp);
        tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, onEvent, NULL);
        if (!tap) return;
        tapSource = CFMachPortCreateRunLoopSource(NULL, tap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), tapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(tap, true);
        drag.active = true;
        ok = true;
    });
    if (!ran || !ok) {
        unlift(&next.frame);
        stopTellingLua();
        drag.preview = NULL;
    } else if (next.lifter) {
        next.lifter->begin(next.serial, next.wid, next.frame, claimLift);
    }
    lua_pushboolean(L, ran && ok);
    return 1;
}

static void pushRect(lua_State *L, CGRect r) {
    lua_createtable(L, 0, 4);
    lua_pushnumber(L, r.origin.x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, r.origin.y);
    lua_setfield(L, -2, "y");
    lua_pushnumber(L, r.size.width);
    lua_setfield(L, -2, "w");
    lua_pushnumber(L, r.size.height);
    lua_setfield(L, -2, "h");
}

// dragEnd(x, y, home): stops following (at that point, if still dragging),
// waits for the app to take the last frame and returns it as {x, y, w, h},
// or nil if the drag never moved the window. A window parked for its
// picture (lift) is given that frame (or its own, if the drag never moved).
// With `home` (a drop that changes nothing), one parked stays parked while
// its picture goes back, and the second result is the frame it had as the
// drag began, where dragUnpark() puts it.
static int l_end(lua_State *L) {
    bool home = lua_toboolean(L, 3);
    bool hasPoint = lua_isnumber(L, 1) && lua_isnumber(L, 2);
    CGPoint point = hasPoint ? CGPointMake(lua_tonumber(L, 1), lua_tonumber(L, 2)) : CGPointZero;
    if (tapThreadRunning) {
        runOnTap(^{
            if (drag.active && hasPoint) give(point);
            end();
        });
    }
    stopTellingLua();
    if (home) {
        os_unfair_lock_lock(&liftLock);
        bool kept = liftState == LIFT_TAKEN;
        if (kept) {
            liftKept = true;
            liftLast = drag.frame;
            liftPreview = NULL;
        }
        os_unfair_lock_unlock(&liftLock);
        if (kept) {
            endPreview();
            if (drag.given) pushRect(L, drag.last); else lua_pushnil(L);
            pushRect(L, drag.frame);
            return 2;
        }
    }
    bool lifted = unlift(drag.given ? &drag.last : &drag.frame);
    if (!drag.given) {
        if (lifted) framesWait(drag.pid);
        endPreview();
        lua_pushnil(L);
        return 1;
    }
    framesWait(drag.pid);
    endPreview();
    pushRect(L, drag.last);
    return 1;
}

// dragUnpark(): a window dragEnd kept parked goes back to its own frame,
// and this waits for the app to take it. True if it was parked.
static int l_unpark(lua_State *L) {
    bool parked = unlift(NULL);
    if (parked) framesWait(liftPid);
    lua_pushboolean(L, parked);
    return 1;
}

void dragRegister(lua_State *L) {
    lua_pushcfunction(L, l_begin);
    lua_setfield(L, -2, "dragBegin");
    lua_pushcfunction(L, l_end);
    lua_setfield(L, -2, "dragEnd");
    lua_pushcfunction(L, l_unpark);
    lua_setfield(L, -2, "dragUnpark");
}

// Lua is closing: the thread stops and is joined, so nothing runs in this
// library once it's unloaded.
void dragStop(void) {
    if (tapThreadRunning) {
        runOnTap(^{
            end();
            quitting = true;
            CFRunLoopStop(CFRunLoopGetCurrent());
        });
        pthread_join(tapThread, NULL);
        tapThreadRunning = false;
    }
    // Not left parked.
    if (unlift(drag.given ? &drag.last : &drag.frame)) framesWait(liftPid);
    stopTellingLua();
    endPreview();
    drag.given = false;
}
