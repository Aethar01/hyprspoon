// wm/native/border.c: Rings around windows, drawn by WindowServer.
//
// Loaded by wm/border.lua as wm.native.border (build: make -C wm/native).
//
// Every window wm/border.lua lists gets a ring: the focused window's in the
// active colour, the rest in the inactive one, blending between the two as
// focus moves. Each ring is a window of our own (see Ring), ordered
// directly above the window it surrounds: anything stacked above that
// window covers the ring as well, and nothing below it can. (Directly above rather than below:
// macOS slots a window raised from an inactive app in just under the active
// app's windows, which would put it between a window and a ring below it.)
// WindowServer tells us when a window moves or resizes, and when any window
// is restacked, and the rings follow straight away, never waiting on a poll,
// a debounce or Lua.
//
// The rings are drawn and moved on a queue of their own, through a
// WindowServer connection of their own (as JankyBorders does): redrawing a
// big ring while a big window resizes can take WindowServer several
// milliseconds to answer, and none of that may hold up Hammerspoon's main
// thread, where Lua and the event taps run. Notifications only note which
// windows changed; a burst of them becomes one update at the latest bounds.
//
// SkyLight's window calls are private (the same ones JankyBorders uses).
// They are looked up when the module loads, which fails with an error
// rather than crashing if a macOS update removes one.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lauxlib.h"
#include "lua.h"
#include "preview.h"
#include "luacall.h"
#include "skylight.h"

// ---------------------------------------------------------------------------
// SkyLight
// ---------------------------------------------------------------------------

#define SL_FUNCS(X)                                                                    \
    X(int, SLSMainConnectionID, (void))                                                \
    X(CGError, SLSNewConnection, (int, int *))                                         \
    X(CGError, SLSReleaseConnection, (int))                                            \
    X(CGError, SLSGetEventPort, (int, mach_port_t *))                                  \
    X(CGEventRef, SLEventCreateNextEvent, (int))                                       \
    X(CGError, SLSRegisterNotifyProc, (void *, uint32_t, void *))                      \
    X(CGError, SLSRemoveNotifyProc, (void *, uint32_t, void *))                        \
    X(CGError, SLSRequestNotificationsForWindows, (int, uint32_t *, int))              \
    X(CGError, SLSNewWindow, (int, int, float, float, CFTypeRef, uint32_t *))          \
    X(CGError, SLSReleaseWindow, (int, uint32_t))                                      \
    X(CGError, SLSSetWindowTags, (int, uint32_t, uint64_t *, int))                     \
    X(CGError, SLSSetWindowShape, (int, uint32_t, float, float, CFTypeRef))            \
    X(CGError, SLSSetWindowResolution, (int, uint32_t, double))                        \
    X(CGError, SLSSetWindowOpacity, (int, uint32_t, bool))                             \
    X(CGError, SLSGetWindowBounds, (int, uint32_t, CGRect *))                          \
    X(CGError, SLSGetWindowLevel, (int, uint32_t, int64_t *))                          \
    X(CGError, CGSNewRegionWithRect, (CGRect *, CFTypeRef *))                          \
    X(CGError, CGSNewRegionWithRectList, (const CGRect *, int, CFTypeRef *))           \
    X(CGContextRef, SLWindowContextCreate, (int, uint32_t, CFDictionaryRef))           \
    X(CGError, SLSFlushWindowContentRegion, (int, uint32_t, void *))                   \
    X(CGError, SLSWindowSetShadowProperties, (uint32_t, CFDictionaryRef))              \
    X(CGError, SLSWindowFreezeWithOptions, (int, uint32_t, CFTypeRef))                 \
    X(CGError, SLSWindowThaw, (int, uint32_t))                                         \
    X(CGError, SLSDisableUpdate, (int))                                                \
    X(CGError, SLSReenableUpdate, (int))                                               \
    X(CFArrayRef, SLSCopySpacesForWindows, (int, int, CFArrayRef))                     \
    X(CGError, SLSMoveWindowsToManagedSpace, (int, CFArrayRef, uint64_t))              \
    X(CFTypeRef, SLSTransactionCreate, (int))                                          \
    X(CGError, SLSTransactionMoveWindowWithGroup, (CFTypeRef, uint32_t, CGPoint))      \
    X(CGError, SLSTransactionOrderWindow, (CFTypeRef, uint32_t, int, uint32_t))        \
    X(CGError, SLSTransactionSetWindowLevel, (CFTypeRef, uint32_t, int))               \
    X(CGError, SLSTransactionSetWindowTransform, (CFTypeRef, uint32_t, int, int,       \
                                                  CGAffineTransform))                  \
    X(CGError, SLSTransactionCommit, (CFTypeRef, int))

SL_FUNCS(SL_DECLARE)

// Optional: each window's corner radius (macOS 26 and later). Without it
// the configured radius is used.
static CFTypeRef (*SLSWindowQueryWindows)(int, CFArrayRef, uint32_t);
static CFTypeRef (*SLSWindowQueryResultCopyWindows)(CFTypeRef);
static bool (*SLSWindowIteratorAdvance)(CFTypeRef);
static CFArrayRef (*SLSWindowIteratorGetCornerRadii)(CFTypeRef);

static const char *loadSymbols(void) {
    slOpen();
    SL_FUNCS(SL_LOAD)
    SLSWindowQueryWindows = dlsym(RTLD_DEFAULT, "SLSWindowQueryWindows");
    SLSWindowQueryResultCopyWindows = dlsym(RTLD_DEFAULT, "SLSWindowQueryResultCopyWindows");
    SLSWindowIteratorAdvance = dlsym(RTLD_DEFAULT, "SLSWindowIteratorAdvance");
    SLSWindowIteratorGetCornerRadii = dlsym(RTLD_DEFAULT, "SLSWindowIteratorGetCornerRadii");
    return NULL;
}

enum { ORDER_OUT = 0, ORDER_ABOVE = 1 };

// ---------------------------------------------------------------------------
// Rings
// ---------------------------------------------------------------------------

typedef struct {
    uint32_t wid;    // our window
    CGContextRef ctx; // drawing into it; NULL until first drawn
    uint32_t target; // the window it surrounds; 0 when free
    CGRect bounds;   // the target's bounds it was last placed for
    bool drawn;      // drawn for bounds.size
    CGSize canvas;   // the window's size, the ring drawn in its top-left corner
    bool hidden;     // its target's app is hidden
    bool fills;      // its target fills a display (native full screen)
    bool shown;      // ordered in
    CGFloat radius;  // the target's corner radius
    bool resizing;   // hidden while the system resizes its target (see catchUp)
    bool previewing; // drawn around `preview` (a drag's frame), not the target
    CGRect preview;
    // How active it looks, 0 to 1, going from `from` to `to` over
    // `duration` from `start`.
    float mix, from, to;
    double start, duration;
    bool blending;
} Ring;

#define MAX_RINGS 128
static Ring rings[MAX_RINGS];
static int ringCount = 0;
static uint32_t active = 0; // the focused window, ringed or not

// Everything above, and the ring windows, belong to `queue` (and its own
// connection, drawCid). Hammerspoon's main connection (mainCid) is only for
// asking WindowServer for notifications, from the main thread.
static dispatch_queue_t queue = NULL;
static int drawCid = 0, mainCid = 0;

// WindowServer sends every connection events, and one that leaves them
// unread fills up until WindowServer times out on it, which stalls the
// screen. Nothing else reads drawCid's, so they're read and dropped here.
static dispatch_source_t drain = NULL;
static mach_port_t drainPort = MACH_PORT_NULL;

static void drainEvents(void *unused) {
    (void)unused;
    // The port's messages only say events are waiting; one left on the
    // port fires the source again at once, so take them off first.
    struct {
        mach_msg_header_t header;
        char body[4096];
    } message;
    for (;;) {
        mach_msg_return_t r = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(message),
            drainPort, 0, MACH_PORT_NULL);
        if (r == MACH_MSG_SUCCESS) mach_msg_destroy(&message.header);
        else if (r != MACH_RCV_TOO_LARGE) break;
    }
    CGEventRef event;
    while ((event = SLEventCreateNextEvent(drawCid))) CFRelease(event);
}

typedef struct {
    CGFloat active[4], inactive[4];
    CGFloat width, radius, resolution;
} RingStyle;

static RingStyle style = { { 0.42, 0.6, 0.73, 1 }, { 0.35, 0.35, 0.35, 0.67 }, 3, 12, 1 };

static double now(void) {
    return CFAbsoluteTimeGetCurrent();
}

static Ring *ringFor(uint32_t target) {
    if (!target) return NULL;
    for (int i = 0; i < ringCount; i++) {
        if (rings[i].target == target) return &rings[i];
    }
    return NULL;
}

// Room around the target for the ring, and a point to spare.
static CGFloat padding(void) {
    return style.width + 1;
}

static CGPathRef roundedRect(CGRect r, CGFloat radius) {
    radius = fmin(fmax(radius, 0), fmin(r.size.width, r.size.height) / 2);
    return CGPathCreateWithRoundedRect(r, radius, radius, NULL);
}

// The ring's four sides, as strips of the window that hold every pixel the
// ring can touch, corners and antialiasing included, in the context's
// coordinates (origin bottom-left).
static void strips(Ring *ring, CGRect out[4]) {
    CGFloat pad = padding();
    CGRect window = { { pad, ring->canvas.height - pad - ring->bounds.size.height }, ring->bounds.size };
    CGRect box = CGRectInset(window, -pad, -pad);
    CGFloat t = fmin(pad + ring->radius + 1, fmin(box.size.width, box.size.height) / 2);
    out[0] = CGRectMake(box.origin.x, box.origin.y, box.size.width, t);
    out[1] = CGRectMake(box.origin.x, CGRectGetMaxY(box) - t, box.size.width, t);
    out[2] = CGRectMake(box.origin.x, box.origin.y + t, t, box.size.height - 2 * t);
    out[3] = CGRectMake(CGRectGetMaxX(box) - t, box.origin.y + t, t, box.size.height - 2 * t);
}

// The strips as a region of the window, whose origin is top-left.
static CFTypeRef stripRegion(Ring *ring) {
    CGRect sides[4];
    strips(ring, sides);
    for (int i = 0; i < 4; i++) sides[i].origin.y = ring->canvas.height - CGRectGetMaxY(sides[i]);
    CFTypeRef region = NULL;
    CGSNewRegionWithRectList(sides, 4, &region);
    return region;
}

// The ring is everything between the target's outline (with its corner
// radius) and that outline grown by the width, filled even-odd in the
// colour `mix` of the way from inactive to active. `whole` clears the whole
// window first (its size changed); otherwise only the ring's strips are
// cleared, redrawn and sent to the screen. That saves less than it looks:
// CoreAnimation still copies the window's whole previous buffer for each
// update, so a fade costs Hammerspoon about 110ms of CPU per focus change,
// close to redrawing it all (measured). A layer-backed window, its colour
// animated by WindowServer, would cost next to nothing (untried here).
static void draw(Ring *ring, bool whole) {
    if (!ring->ctx) ring->ctx = SLWindowContextCreate(drawCid, ring->wid, NULL);
    CGContextRef ctx = ring->ctx;
    if (!ctx) return;
    CGFloat pad = padding();
    CGRect window = { { pad, ring->canvas.height - pad - ring->bounds.size.height }, ring->bounds.size };
    CGRect sides[4];
    strips(ring, sides);
    CGFloat c[4];
    for (int i = 0; i < 4; i++) c[i] = style.inactive[i] + (style.active[i] - style.inactive[i]) * ring->mix;
    CGPathRef outer = roundedRect(CGRectInset(window, -style.width, -style.width), ring->radius + style.width);
    CGPathRef inner = roundedRect(window, ring->radius);
    // Side by side, each under its own clip: an update's dirty area is what
    // one drawing call can reach.
    for (int side = 0; side < (whole ? 1 : 4); side++) {
        CGContextSaveGState(ctx);
        if (whole) {
            CGContextClearRect(ctx, (CGRect){ CGPointZero, ring->canvas });
        } else {
            CGContextClipToRect(ctx, sides[side]);
            CGContextClearRect(ctx, sides[side]);
        }
        if (c[3] > 0) {
            CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], c[3]);
            CGContextAddPath(ctx, outer);
            CGContextAddPath(ctx, inner);
            CGContextEOFillPath(ctx);
        }
        CGContextRestoreGState(ctx);
    }
    CGPathRelease(outer);
    CGPathRelease(inner);
    CGContextFlush(ctx);
    CFTypeRef dirty = whole ? NULL : stripRegion(ring);
    SLSFlushWindowContentRegion(drawCid, ring->wid, (void *)dirty);
    if (dirty) CFRelease(dirty);
}


// The window's corner radius as WindowServer has it, so the ring's inside
// follows the window's corners exactly; else the configured radius.
static CGFloat cornerRadius(uint32_t wid) {
    CGFloat radius = 0;
    if (SLSWindowQueryWindows && SLSWindowQueryResultCopyWindows && SLSWindowIteratorAdvance
        && SLSWindowIteratorGetCornerRadii) {
        CFArrayRef list = slWindowList(wid);
        CFTypeRef query = SLSWindowQueryWindows(drawCid, list, 0);
        CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
        if (iterator && SLSWindowIteratorAdvance(iterator)) {
            CFArrayRef radii = SLSWindowIteratorGetCornerRadii(iterator);
            if (radii && CFArrayGetCount(radii) > 0) {
                double value = 0;
                CFNumberGetValue(CFArrayGetValueAtIndex(radii, 0), kCFNumberDoubleType, &value);
                radius = value;
            }
            if (radii) CFRelease(radii);
        }
        if (iterator) CFRelease(iterator);
        if (query) CFRelease(query);
        CFRelease(list);
    }
    return radius > 0 ? radius : style.radius;
}

// Keeps the ring on the Space its target is on.
static void joinTargetSpace(Ring *ring) {
    CFArrayRef targets = slWindowList(ring->target);
    CFArrayRef spaces = SLSCopySpacesForWindows(drawCid, 0x7, targets);
    CFRelease(targets);
    if (!spaces) return;
    if (CFArrayGetCount(spaces) > 0) {
        uint64_t sid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(spaces, 0), kCFNumberSInt64Type, &sid);
        if (sid) {
            CFArrayRef ours = slWindowList(ring->wid);
            SLSMoveWindowsToManagedSpace(drawCid, ours, sid);
            CFRelease(ours);
        }
    }
    CFRelease(spaces);
}

static uint32_t createWindow(void) {
    CGRect frame = { CGPointZero, { 1, 1 } };
    CFTypeRef region = NULL;
    CGSNewRegionWithRect(&frame, &region);
    if (!region) return 0;
    uint32_t wid = 0;
    SLSNewWindow(drawCid, kCGBackingStoreBuffered, -9999, -9999, region, &wid);
    CFRelease(region);
    if (!wid) return 0;
    // As JankyBorders: kept out of window lists and Mission Control, and
    // never takes the mouse.
    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    SLSSetWindowResolution(drawCid, wid, style.resolution);
    SLSSetWindowTags(drawCid, wid, &tags, 64);
    SLSSetWindowOpacity(drawCid, wid, false);
    CFIndex density = 0;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberCFIndexType, &density);
    const void *keys[] = { CFSTR("com.apple.WindowShadowDensity") };
    const void *values[] = { value };
    CFDictionaryRef shadow = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SLSWindowSetShadowProperties(wid, shadow);
    CFRelease(shadow);
    CFRelease(value);
    return wid;
}

// Native full screen: the window covers its display, with nowhere to draw.
static bool fillsDisplay(CGRect bounds) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess) return false;
    for (uint32_t i = 0; i < count; i++) {
        if (CGRectEqualToRect(CGRectIntegral(bounds), CGDisplayBounds(displays[i]))) return true;
    }
    return false;
}

static void order(CFTypeRef t, Ring *ring) {
    bool show = !ring->hidden && !ring->fills && !ring->resizing;
    if (show) {
        int64_t level = 0;
        SLSGetWindowLevel(drawCid, ring->target, &level);
        SLSTransactionSetWindowLevel(t, ring->wid, (int)level);
        SLSTransactionOrderWindow(t, ring->wid, ORDER_ABOVE, ring->target);
    } else if (ring->shown) {
        SLSTransactionOrderWindow(t, ring->wid, ORDER_OUT, 0);
    }
    ring->shown = show;
}

// The ring's window is sized in steps, with room to spare: a window that
// resizes is then mostly only redrawn in a window that keeps its size.
// Reshaping a window on every frame of a resize makes WindowServer time out
// (thousands of times a minute, measured), hitching the whole screen.
#define STEP 200

static CGFloat stepUp(CGFloat length) {
    return (floor(length / STEP) + 2) * STEP;
}

// Puts the ring around its target's current bounds. `restack` also orders
// it just above the target, at the target's level. False if the target has
// no bounds (it has gone).
static bool place(Ring *ring, bool restack) {
    CGRect bounds = ring->preview;
    if (!ring->previewing && SLSGetWindowBounds(drawCid, ring->target, &bounds) != kCGErrorSuccess) return false;
    CGFloat pad = padding();
    CGRect frame = CGRectInset(bounds, -pad, -pad);
    bool resize = !ring->drawn || !CGSizeEqualToSize(bounds.size, ring->bounds.size);
    // A new size for the window when the ring outgrows it, or it has grown
    // far bigger than the ring.
    CGSize need = frame.size, have = ring->canvas;
    bool reshape = !ring->drawn || need.width > have.width || need.height > have.height
        || have.width > need.width + 3 * STEP || have.height > need.height + 3 * STEP;
    bool fills = fillsDisplay(bounds);
    if (fills != ring->fills) restack = true;
    ring->fills = fills;
    ring->bounds = bounds;

    // A reshape, its redraw and the move go to the screen together: without
    // SLSDisableUpdate around them WindowServer times out part-way through
    // (51 timeouts in 150 resizes, measured, against 2 with it) and can show
    // the reshaped ring window before it's redrawn.
    if (reshape) {
        SLSDisableUpdate(drawCid);
        ring->canvas = CGSizeMake(stepUp(need.width), stepUp(need.height));
        CGRect shape = { CGPointZero, ring->canvas };
        CFTypeRef region = NULL;
        CGSNewRegionWithRect(&shape, &region);
        SLSWindowFreezeWithOptions(drawCid, ring->wid, NULL);
        if (region) {
            SLSSetWindowShape(drawCid, ring->wid, frame.origin.x, frame.origin.y, region);
            CFRelease(region);
        }
        // A context made before the reshape keeps drawing at the old size.
        if (ring->ctx) CGContextRelease(ring->ctx);
        ring->ctx = NULL;
        draw(ring, true);
        SLSWindowThaw(drawCid, ring->wid);
    } else if (resize) {
        SLSWindowFreezeWithOptions(drawCid, ring->wid, NULL);
        draw(ring, true);
        SLSWindowThaw(drawCid, ring->wid);
    }
    ring->drawn = true;

    CFTypeRef t = SLSTransactionCreate(drawCid);
    if (t) {
        SLSTransactionMoveWindowWithGroup(t, ring->wid, frame.origin);
        if (reshape) {
            CGAffineTransform transform = CGAffineTransformIdentity;
            transform.tx = -frame.origin.x;
            transform.ty = -frame.origin.y;
            SLSTransactionSetWindowTransform(t, ring->wid, 0, 0, transform);
        }
        if (restack) order(t, ring);
        SLSTransactionCommit(t, 0);
        CFRelease(t);
    }
    if (reshape) SLSReenableUpdate(drawCid);
    return true;
}

// Every ring back directly above its window, in one transaction.
static void restackAll(void) {
    CFTypeRef t = SLSTransactionCreate(drawCid);
    if (!t) return;
    for (int i = 0; i < ringCount; i++) {
        if (rings[i].target) order(t, &rings[i]);
    }
    SLSTransactionCommit(t, 0);
    CFRelease(t);
}

static void freeRing(Ring *ring) {
    if (ring->shown) {
        CFTypeRef t = SLSTransactionCreate(drawCid);
        if (t) {
            SLSTransactionOrderWindow(t, ring->wid, ORDER_OUT, 0);
            SLSTransactionCommit(t, 0);
            CFRelease(t);
        }
    }
    ring->target = 0;
    ring->shown = false;
    ring->blending = false;
    ring->previewing = false;
    ring->resizing = false;
}

static Ring *newRing(uint32_t target) {
    Ring *ring = NULL;
    for (int i = 0; i < ringCount; i++) {
        if (!rings[i].target) {
            ring = &rings[i];
            break;
        }
    }
    if (!ring) {
        if (ringCount == MAX_RINGS) return NULL;
        uint32_t wid = createWindow();
        if (!wid) return NULL;
        ring = &rings[ringCount++];
        memset(ring, 0, sizeof(*ring));
        ring->wid = wid;
    }
    ring->target = target;
    ring->hidden = ring->fills = ring->shown = ring->blending = ring->previewing = ring->resizing = false;
    ring->drawn = false;
    ring->mix = target == active ? 1 : 0;
    ring->radius = cornerRadius(target);
    joinTargetSpace(ring);
    if (!place(ring, true)) {
        freeRing(ring);
        return NULL;
    }
    return ring;
}

// ---------------------------------------------------------------------------
// System resizes
// ---------------------------------------------------------------------------
//
// A ring following a window the system is resizing (its edge or corner
// dragged) makes WindowServer time out on every frame, hitching the whole
// screen; JankyBorders' border does the same. So the ring is hidden while
// the button is down, and drawn at the window's final size once it's up.
// Our own drags don't count: their ring follows the drag's frames instead.

static dispatch_source_t releaseCheck = NULL;
static bool releaseCheckRunning = false;

static bool buttonHeld(void) {
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft)
        || CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight);
}

static void checkRelease(void *unused) {
    (void)unused;
    if (buttonHeld()) return;
    dispatch_suspend(releaseCheck);
    releaseCheckRunning = false;
    for (int i = 0; i < ringCount; i++) {
        Ring *ring = &rings[i];
        if (!ring->target || !ring->resizing) continue;
        ring->resizing = false;
        place(ring, true);
    }
}

// The target of `ring` changed size: true if the system is resizing it
// (the ring is then hidden until the button comes up).
static bool systemResizing(Ring *ring) {
    if (ring->resizing) return true;
    if (!buttonHeld()) return false;
    CGRect bounds;
    if (SLSGetWindowBounds(drawCid, ring->target, &bounds) != kCGErrorSuccess
        || CGSizeEqualToSize(bounds.size, ring->bounds.size)) {
        return false;
    }
    ring->resizing = true;
    CFTypeRef t = SLSTransactionCreate(drawCid);
    if (t) {
        order(t, ring);
        SLSTransactionCommit(t, 0);
        CFRelease(t);
    }
    if (!releaseCheck) {
        releaseCheck = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(releaseCheck, DISPATCH_TIME_NOW, NSEC_PER_SEC / 33, NSEC_PER_SEC / 200);
        dispatch_source_set_event_handler_f(releaseCheck, checkRelease);
    }
    if (!releaseCheckRunning) {
        dispatch_resume(releaseCheck);
        releaseCheckRunning = true;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Blending between the colours
// ---------------------------------------------------------------------------

static dispatch_source_t blendTimer = NULL;
static bool blendTimerRunning = false;

// A frame of the fades: each fading ring redrawn in its new colour.
static void blendTick(void *unused) {
    (void)unused;
    double t = now();
    bool any = false;
    for (int i = 0; i < ringCount; i++) {
        Ring *ring = &rings[i];
        if (!ring->blending) continue;
        double p = ring->duration > 0 ? (t - ring->start) / ring->duration : 1;
        if (p >= 1) {
            ring->blending = false;
            ring->mix = ring->to;
        } else {
            ring->mix = ring->from + (ring->to - ring->from) * (float)p;
            any = true;
        }
        if (ring->target && ring->drawn) draw(ring, false);
    }
    if (!any && blendTimerRunning) {
        dispatch_suspend(blendTimer);
        blendTimerRunning = false;
    }
}

static void blend(Ring *ring, float to, double duration) {
    if (!ring || (ring->mix == to && !ring->blending)) return;
    ring->from = ring->mix;
    ring->to = to;
    ring->start = now();
    ring->duration = duration;
    ring->blending = true;
    if (duration <= 0) {
        blendTick(NULL);
        return;
    }
    if (!blendTimer) {
        blendTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(blendTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_SEC / 1000);
        dispatch_source_set_event_handler_f(blendTimer, blendTick);
    }
    if (!blendTimerRunning) {
        dispatch_resume(blendTimer);
        blendTimerRunning = true;
    }
}

// ---------------------------------------------------------------------------
// WindowServer notifications
// ---------------------------------------------------------------------------

// Hide, unhide and close, on the queue, in the order they came.
static void handleEvent(uint32_t event, uint32_t wid) {
    Ring *ring = ringFor(wid);
    if (!ring) return;
    switch (event) {
    case SL_EVENT_WINDOW_HIDE:
        ring->hidden = true;
        place(ring, true);
        break;
    case SL_EVENT_WINDOW_UNHIDE:
        ring->hidden = false;
        place(ring, true);
        break;
    case SL_EVENT_WINDOW_CLOSE:
        freeRing(ring);
        break;
    }
}

// What changed since the queue last looked, noted from the main thread.
#define MAX_NOTED 256
static os_unfair_lock notedLock = OS_UNFAIR_LOCK_INIT;
static struct {
    uint32_t moved[MAX_NOTED]; // moved or resized, each once
    int movedCount;
    struct { uint32_t event, wid; } other[MAX_NOTED]; // hide, unhide, close
    int otherCount;
    bool restack;  // a window was restacked or changed level
    struct { bool changed, on; uint32_t wid; CGRect frame; } preview; // the latest
    bool queued;   // catchUp is on the queue
} noted;

static void catchUp(void *unused) {
    (void)unused;
    os_unfair_lock_lock(&notedLock);
    uint32_t moved[MAX_NOTED];
    struct { uint32_t event, wid; } other[MAX_NOTED];
    int movedCount = noted.movedCount, otherCount = noted.otherCount;
    bool restack = noted.restack;
    __typeof__(noted.preview) preview = noted.preview;
    noted.preview.changed = false;
    memcpy(moved, noted.moved, sizeof(uint32_t) * movedCount);
    memcpy(other, noted.other, sizeof(other[0]) * otherCount);
    noted.movedCount = noted.otherCount = 0;
    noted.restack = noted.queued = false;
    os_unfair_lock_unlock(&notedLock);

    for (int i = 0; i < otherCount; i++) handleEvent(other[i].event, other[i].wid);
    if (preview.changed) {
        Ring *ring = ringFor(preview.wid);
        if (ring) {
            ring->previewing = preview.on;
            ring->preview = preview.frame;
            place(ring, false);
        }
    }
    for (int i = 0; i < movedCount; i++) {
        Ring *ring = ringFor(moved[i]);
        // A previewing ring stays on the drag's frame.
        if (!ring || ring->previewing || systemResizing(ring)) continue;
        place(ring, false);
    }
    // Any window restacked may have landed between a ring and its window.
    if (restack) {
        restackAll();
    }
}

// The RingPreview handed to drag.c (see preview.h).
static void previewRing(uint32_t wid, const CGRect *frame) {
    if (!queue) return;
    os_unfair_lock_lock(&notedLock);
    noted.preview.changed = true;
    noted.preview.on = frame != NULL;
    noted.preview.wid = wid;
    if (frame) noted.preview.frame = *frame;
    bool enqueue = !noted.queued;
    noted.queued = true;
    os_unfair_lock_unlock(&notedLock);
    if (enqueue) dispatch_async_f(queue, NULL, catchUp);
}

static void onWindowEvent(uint32_t event, void *data, size_t length, void *context) {
    (void)context;
    if (!data || length < sizeof(uint32_t)) return;
    uint32_t wid = *(uint32_t *)data;
    os_unfair_lock_lock(&notedLock);
    if (event == SL_EVENT_WINDOW_REORDER || event == SL_EVENT_WINDOW_LEVEL) {
        noted.restack = true;
    } else if (event == SL_EVENT_WINDOW_MOVE || event == SL_EVENT_WINDOW_RESIZE) {
        bool listed = false;
        for (int i = 0; i < noted.movedCount; i++) {
            if (noted.moved[i] == wid) {
                listed = true;
                break;
            }
        }
        if (!listed && noted.movedCount < MAX_NOTED) noted.moved[noted.movedCount++] = wid;
    } else if (noted.otherCount < MAX_NOTED) {
        noted.other[noted.otherCount].event = event;
        noted.other[noted.otherCount].wid = wid;
        noted.otherCount++;
    }
    bool enqueue = !noted.queued && queue;
    noted.queued = true;
    os_unfair_lock_unlock(&notedLock);
    if (enqueue) dispatch_async_f(queue, NULL, catchUp);
}

// Registered while a Lua state has the module loaded: Lua unloads the
// library when the state closes (reload), and SkyLight must not call into
// it after that.
static const uint32_t events[] = { SL_EVENT_WINDOW_CLOSE, SL_EVENT_WINDOW_MOVE, SL_EVENT_WINDOW_RESIZE,
    SL_EVENT_WINDOW_REORDER, SL_EVENT_WINDOW_LEVEL, SL_EVENT_WINDOW_UNHIDE, SL_EVENT_WINDOW_HIDE };
#define EVENT_COUNT (sizeof(events) / sizeof(events[0]))

static void registerEvents(bool on) {
    for (size_t i = 0; i < EVENT_COUNT; i++) {
        if (on) SLSRegisterNotifyProc((void *)onWindowEvent, events[i], NULL);
        else SLSRemoveNotifyProc((void *)onWindowEvent, events[i], NULL);
    }
}


// ---------------------------------------------------------------------------
// Lua API
// ---------------------------------------------------------------------------

// The focused window as last told by Lua, for active() (main thread).
static uint32_t activeAsked = 0;

// set({wid, ...}): ring exactly these windows.
static int l_set(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int n = (int)luaL_len(L, 1);
    if (n > MAX_RINGS) n = MAX_RINGS;
    uint32_t *wids = calloc(n > 0 ? n : 1, sizeof(uint32_t));
    int count = 0;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 1, i);
        uint32_t wid = (uint32_t)lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (wid) wids[count++] = wid;
    }
    dispatch_async(queue, ^{
        bool keep[MAX_RINGS] = { false };
        for (int i = 0; i < count; i++) {
            Ring *ring = ringFor(wids[i]);
            if (!ring) ring = newRing(wids[i]);
            if (ring) keep[ring - rings] = true;
        }
        for (int i = 0; i < ringCount; i++) {
            if (rings[i].target && !keep[i]) freeRing(&rings[i]);
        }
        free(wids);
    });
    return 0;
}

// focus(wid or nil, duration): blend the focused window's ring to the
// active colour and the previous one's back, over `duration` seconds.
static int l_focus(lua_State *L) {
    uint32_t wid = (uint32_t)luaL_optinteger(L, 1, 0);
    double requested = luaL_optnumber(L, 2, 0);
    activeAsked = wid;
    dispatch_async(queue, ^{
        if (wid == active) return;
        double duration = requested;
        Ring *previous = ringFor(active);
        Ring *next = ringFor(wid);
        // A native tab taking over its window's place: no blend.
        if (previous && next && CGRectEqualToRect(previous->bounds, next->bounds)) duration = 0;
        active = wid;
        blend(previous, 0, duration);
        blend(next, 1, duration);
    });
    return 0;
}

// previewer(): the function a drag calls with its frames (see preview.h),
// as a light userdata for frames.dragBegin.
static int l_previewer(lua_State *L) {
    lua_pushlightuserdata(L, (void *)previewRing);
    return 1;
}

// watch({wid, ...}): the windows to hear about (see skylight.h). Restacks of
// any of them may put it between a ring and its window.
static int l_watch(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    uint32_t wids[512];
    int count = luaWindowIds(L, 1, wids, 512);
    SLSRequestNotificationsForWindows(mainCid, wids, count);
    return 0;
}

// active(): the focused window, or nil.
static int l_active(lua_State *L) {
    if (activeAsked) lua_pushinteger(L, activeAsked);
    else lua_pushnil(L);
    return 1;
}

static void releaseAll(void) {
    for (int i = 0; i < ringCount; i++) {
        freeRing(&rings[i]);
        if (rings[i].ctx) CGContextRelease(rings[i].ctx);
        SLSReleaseWindow(drawCid, rings[i].wid);
    }
    ringCount = 0;
}

static void readColor(lua_State *L, const char *key, CGFloat *out) {
    if (lua_getfield(L, 1, key) == LUA_TTABLE) {
        for (int i = 0; i < 4; i++) {
            lua_rawgeti(L, -1, i + 1);
            out[i] = luaL_optnumber(L, -1, i == 3 ? 1 : 0);
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}

// style{ active = {r, g, b, a}, inactive = {r, g, b, a}, width =, radius =,
// resolution = }: drops the rings, for set() to draw them again.
static int l_style(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    __block RingStyle next = style;
    readColor(L, "active", next.active);
    readColor(L, "inactive", next.inactive);
    lua_getfield(L, 1, "width");
    next.width = luaL_optnumber(L, -1, next.width);
    lua_getfield(L, 1, "radius");
    next.radius = luaL_optnumber(L, -1, next.radius);
    lua_getfield(L, 1, "resolution");
    next.resolution = luaL_optnumber(L, -1, next.resolution);
    lua_pop(L, 3);
    dispatch_sync(queue, ^{
        releaseAll();
        style = next;
    });
    return 0;
}

static int l_stop(lua_State *L) {
    (void)L;
    activeAsked = 0;
    dispatch_sync(queue, ^{
        releaseAll();
        active = 0;
    });
    return 0;
}

// Collected with the Lua state (reload, quit), before Lua unloads the
// library: nothing may call into it afterwards, so the queue is drained.
static int l_gc(lua_State *L) {
    (void)L;
    registerEvents(false);
    dispatch_sync(queue, ^{
        if (releaseCheck) {
            if (!releaseCheckRunning) dispatch_resume(releaseCheck); // can't cancel a suspended source
            dispatch_source_cancel(releaseCheck);
            dispatch_release(releaseCheck);
            releaseCheck = NULL;
            releaseCheckRunning = false;
        }
        if (blendTimer) {
            if (!blendTimerRunning) dispatch_resume(blendTimer); // can't cancel a suspended source
            dispatch_source_cancel(blendTimer);
            dispatch_release(blendTimer);
            blendTimer = NULL;
            blendTimerRunning = false;
        }
        releaseAll();
        if (drain) {
            dispatch_source_cancel(drain);
            dispatch_release(drain);
            drain = NULL;
        }
    });
    dispatch_release(queue);
    queue = NULL;
    SLSReleaseConnection(drawCid);
    return 0;
}

int luaopen_wm_native_border(lua_State *L) {
    const char *missing = loadSymbols();
    if (missing) return luaL_error(L, "wm.native.border: SkyLight has no %s", missing);

    mainCid = SLSMainConnectionID();
    if (SLSNewConnection(0, &drawCid) != kCGErrorSuccess) return luaL_error(L, "wm.native.border: no WindowServer connection");
    queue = dispatch_queue_create("wm.border", DISPATCH_QUEUE_SERIAL);
    drainPort = MACH_PORT_NULL;
    if (SLSGetEventPort(drawCid, &drainPort) == kCGErrorSuccess && drainPort != MACH_PORT_NULL) {
        drain = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, drainPort, 0, queue);
        dispatch_source_set_event_handler_f(drain, drainEvents);
        dispatch_resume(drain);
        dispatch_async_f(queue, NULL, drainEvents);
    }
    ringCount = 0;
    active = activeAsked = 0;
    noted.movedCount = noted.otherCount = 0;
    noted.restack = noted.queued = noted.preview.changed = false;
    registerEvents(true);

    static const luaL_Reg funcs[] = {
        { "set", l_set },
        { "focus", l_focus },
        { "active", l_active },
        { "watch", l_watch },
        { "previewer", l_previewer },
        { "style", l_style },
        { "stop", l_stop },
        { NULL, NULL },
    };
    luaL_newlib(L, funcs);

    // A sentinel whose finalizer cleans up with the state.
    lua_newuserdata(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, l_gc);
    lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    lua_setfield(L, -2, "_sentinel");
    return 1;
}
