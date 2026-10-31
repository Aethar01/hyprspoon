// hyprspoon/native/border.m: Rings around windows, drawn by WindowServer.
//
// Loaded by hyprspoon/border.lua as hyprspoon.native.border (build: make -C hyprspoon/native).
//
// Every window hyprspoon/border.lua lists gets a ring: the focused window's in the
// active colour, the rest in the inactive one, blending between the two as
// focus moves. Each ring is a window of our own (see Ring), ordered just
// above the window it surrounds, at its level. WindowServer tells us when a
// window moves or resizes, and when any window is restacked, and the rings
// follow straight away, never waiting on a poll, a debounce or Lua.
//
// Each ring's window shows a CoreAnimation layer: a border with the
// window's corner radius, which WindowServer draws, resizes and fades
// itself. Nothing is drawn here: a fade is one animation handed over, where
// redrawing the ring for each of its frames cost Hammerspoon about 100ms of
// CPU per focus change (measured), and a resize is a new layer size. The
// price: WindowServer draws such a window above the normal windows whatever
// its place in the stacking, so a ring shows over windows that cover its
// own (which also shows where windows are while rearranging), unless
// masked (see Masks).
//
// The rings are moved on a queue of their own, through a WindowServer
// connection of their own (as JankyBorders does), so none of it holds up
// Hammerspoon's main thread, where Lua and the event taps run.
// Notifications only note which windows changed; a burst of them becomes
// one update at the latest bounds.
//
// Experimental (experimental.borderMask in hyprspoon/state.lua): each
// ring's layer gets a mask cutting out the windows above its own (see
// Masks), from one snapshot of the windows on screen per update.
//
// SkyLight's window calls are private (the same ones JankyBorders uses).
// They are looked up when the module loads, which fails with an error
// rather than crashing if a macOS update removes one.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lauxlib.h"
#include "lua.h"
#include "preview.h"
#include "luacall.h"
#include "skylight.h"

// CoreAnimation's link to a WindowServer window (private).
@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(uint32_t)cid options:(NSDictionary *)options;
@property (retain) CALayer *layer;
@end

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
    X(CGError, SLSRegisterConnectionNotifyProc, (int, void *, uint32_t, void *))       \
    X(CGError, SLSRemoveConnectionNotifyProc, (int, void *, uint32_t, void *))         \
    X(CGError, SLSRequestNotificationsForWindows, (int, uint32_t *, int))              \
    X(CGError, SLSNewWindowWithOpaqueShapeAndContext, (int, int, CFTypeRef, CFTypeRef,  \
                                                       int, uint64_t *, float, float,  \
                                                       int, uint32_t *, void *))       \
    X(CGError, SLSReleaseWindow, (int, uint32_t))                                      \
    X(CGError, SLSSetWindowTags, (int, uint32_t, uint64_t *, int))                     \
    X(CGError, SLSSetWindowShape, (int, uint32_t, float, float, CFTypeRef))            \
    X(CGError, SLSSetWindowResolution, (int, uint32_t, double))                        \
    X(CGError, SLSSetWindowOpacity, (int, uint32_t, bool))                             \
    X(CGError, SLSGetWindowBounds, (int, uint32_t, CGRect *))                          \
    X(CGError, SLSGetWindowLevel, (int, uint32_t, int64_t *))                          \
    X(CGError, CGSNewRegionWithRect, (CGRect *, CFTypeRef *))                          \
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
    CAContext *context;
    CALayer *root;   // the window's content, its origin top-left
    CALayer *layer;  // the ring: a border around the target's outline
    uint32_t target; // the window it surrounds; 0 when free
    CGRect bounds;   // the target's bounds it was last placed for
    bool drawn;      // laid out for bounds.size
    CGSize canvas;   // the window's size, the ring drawn in its top-left corner
    bool hidden;     // its target's app is hidden
    bool fills;      // its target fills a display (native full screen)
    bool shown;      // ordered in
    CGFloat radius;  // the target's corner radius
    bool resizing;   // hidden while the system resizes its target (see catchUp)
    bool previewing; // drawn around `preview` (a drag's frame), not the target
    CGRect preview;
    CALayer *mask;   // its mask's layers (see Masks), made when first needed
    uint64_t maskKey; // what the mask was last worked out from; 0 for none
    // How active it looks, 0 to 1, going from `from` to `to` over
    // `duration` from `start` (see mixAt).
    float from, to;
    double start, duration;
} Ring;

#define MAX_RINGS 128
static Ring rings[MAX_RINGS];
static int ringCount = 0;
static uint32_t active = 0; // the focused window, ringed or not
static bool overview = false; // Mission Control or Exposé is up: no rings

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

// The ring's colour `mix` of the way from inactive to active (retained).
static CGColorRef colorAt(float mix) {
    CGFloat c[4];
    for (int i = 0; i < 4; i++) c[i] = style.inactive[i] + (style.active[i] - style.inactive[i]) * mix;
    return CGColorCreateSRGB(c[0], c[1], c[2], c[3]);
}

// How active the ring looks at time `t`.
static float mixAt(Ring *ring, double t) {
    double p = ring->duration > 0 ? (t - ring->start) / ring->duration : 1;
    return p >= 1 ? ring->to : ring->from + (ring->to - ring->from) * (float)p;
}

// Changes to layers outside a transaction would wait for a run loop this
// queue doesn't have, and would animate.
// Strings for objects that can outlive this library: a reload unloads it
// while CoreAnimation still holds finished fades, and releasing one then
// read its key path from the unloaded image's constant strings (the crash
// that came with reloads). So they're made at load, on the heap.
static NSString *borderColorKey = nil, *fadeKey = nil;

static void beginChanges(void) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
}

static void commitChanges(void) {
    [CATransaction commit];
    [CATransaction flush];
}

// See Masks.
static bool snapshotTaken;
static void maskRing(Ring *ring);
static bool seenLevel(uint32_t wid, int64_t *level);

// The ring around the target's outline: inside, the target's corner
// radius; outside, that grown by the width. The target sits `padding` in
// from the window's top-left corner.
static void layout(Ring *ring) {
    CGFloat pad = padding(), w = style.width;
    beginChanges();
    ring->root.frame = (CGRect){ CGPointZero, ring->canvas };
    ring->layer.frame = CGRectMake(pad - w, pad - w, ring->bounds.size.width + 2 * w, ring->bounds.size.height + 2 * w);
    ring->layer.borderWidth = w;
    ring->layer.cornerRadius = ring->radius + w;
    // Its mask changes with it, in the same transaction.
    if (snapshotTaken) maskRing(ring);
    commitChanges();
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

// The ring's window, showing its layers, kept out of window lists and
// Mission Control and never taking the mouse (as JankyBorders). False if
// WindowServer won't make one.
static bool makeWindow(Ring *ring) {
    CGRect frame = { CGPointZero, { 1, 1 } }, none = CGRectZero;
    CFTypeRef region = NULL, opaque = NULL;
    CGSNewRegionWithRect(&frame, &region);
    CGSNewRegionWithRect(&none, &opaque);
    beginChanges();
    CAContext *context = [[CAContext contextWithCGSConnection:(uint32_t)drawCid options:@{}] retain];
    CALayer *root = [[CALayer alloc] init];
    root.geometryFlipped = YES;
    CALayer *layer = [[CALayer alloc] init];
    layer.cornerCurve = kCACornerCurveCircular;
    CGColorRef color = colorAt(0);
    layer.borderColor = color;
    CGColorRelease(color);
    [root addSublayer:layer];
    context.layer = root;
    commitChanges();
    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    uint32_t wid = 0;
    // Type 3 is a window whose content is a CoreAnimation context.
    if (region && opaque) {
        SLSNewWindowWithOpaqueShapeAndContext(drawCid, 3, region, opaque, 13, &tags, -9999, -9999, 64, &wid, context);
    }
    if (region) CFRelease(region);
    if (opaque) CFRelease(opaque);
    if (!wid) {
        [layer release];
        [root release];
        [context release];
        return false;
    }
    SLSSetWindowResolution(drawCid, wid, style.resolution);
    SLSSetWindowTags(drawCid, wid, &tags, 64);
    SLSSetWindowOpacity(drawCid, wid, false);
    CFIndex density = 0;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberCFIndexType, &density);
    CFStringRef key = CFStringCreateWithCString(NULL, "com.apple.WindowShadowDensity", kCFStringEncodingUTF8);
    const void *keys[] = { key };
    const void *values[] = { value };
    CFDictionaryRef shadow = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SLSWindowSetShadowProperties(wid, shadow);
    CFRelease(shadow);
    CFRelease(key);
    CFRelease(value);
    ring->wid = wid;
    ring->context = context;
    ring->root = root;
    ring->layer = layer;
    return true;
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
    bool show = !overview && !ring->hidden && !ring->fills && !ring->resizing;
    if (show) {
        int64_t level = 0;
        if (!seenLevel(ring->target, &level)) SLSGetWindowLevel(drawCid, ring->target, &level);
        SLSTransactionSetWindowLevel(t, ring->wid, (int)level);
        SLSTransactionOrderWindow(t, ring->wid, ORDER_ABOVE, ring->target);
    } else if (ring->shown) {
        SLSTransactionOrderWindow(t, ring->wid, ORDER_OUT, 0);
    }
    ring->shown = show;
}

// The ring's window is sized in steps, with room to spare: a window that
// resizes then mostly only resizes the layer, in a window that keeps its size.
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

    // A reshape, its new layout and the move go to the screen together:
    // without SLSDisableUpdate around them WindowServer times out part-way
    // through (51 timeouts in 150 resizes, measured, against 2 with it) and
    // can show the reshaped window before the ring is laid out in it.
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
        layout(ring);
        SLSWindowThaw(drawCid, ring->wid);
    } else if (resize) {
        layout(ring);
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
        Ring made;
        memset(&made, 0, sizeof(made));
        if (!makeWindow(&made)) return NULL;
        ring = &rings[ringCount++];
        *ring = made;
    }
    ring->target = target;
    ring->hidden = ring->fills = ring->shown = ring->previewing = ring->resizing = false;
    ring->drawn = false;
    ring->from = ring->to = target == active ? 1 : 0;
    ring->duration = 0;
    beginChanges();
    CGColorRef color = colorAt(ring->to);
    [ring->layer removeAllAnimations];
    ring->layer.borderColor = color;
    CGColorRelease(color);
    ring->layer.mask = nil;
    ring->maskKey = 0;
    commitChanges();
    ring->radius = cornerRadius(target);
    joinTargetSpace(ring);
    if (!place(ring, true)) {
        freeRing(ring);
        return NULL;
    }
    return ring;
}

// ---------------------------------------------------------------------------
// Masks (experimental)
// ---------------------------------------------------------------------------
//
// With experimental.borderMask, each ring's layer gets a mask: its outline
// minus the outlines of the windows stacked above its target, so a ring
// no longer shows over a float, a panel or Spotlight covering its window.
// The rings stay CoreAnimation windows; only the mask changes.
//
// Each update reads the windows on screen once, front to back (the
// snapshot), and works out every ring's mask from it: everything before a
// ring's target in the snapshot is above it. A ring under a see-through
// window shows through it, dimmed: the mask is a layer of shapes, the
// uncovered parts at full alpha and each part under see-through windows at
// the product of how much shows through each.
//
// WindowServer only reports the windows asked about (see skylight.h), so
// with masks on every window in the snapshot is asked about too, and any
// window coming or going is a cue to update. Off, none of this runs: no
// snapshot, no notifications beyond the managed windows'.

static struct {
    bool on;
    bool showDrags;     // drags = "show": no masks while a drag is under way
    bool suspended;     // showDrags, and a drag is under way
} masks;

typedef struct {
    uint32_t wid;
    CGRect bounds;
    int32_t level;
    CGFloat alpha;
} Seen;

#define MAX_SEEN 256
static Seen seen[MAX_SEEN]; // front to back
static int seenCount = 0;
static bool snapshotTruncated = false;
static bool snapshotTaken = false; // `seen` is this update's

// Rules' `opacity` for windows that have one (Util.rulesFor), from set().
#define MAX_OPACITIES MAX_RINGS
static struct { uint32_t wid; CGFloat opacity; } opacities[MAX_OPACITIES];
static int opacityCount = 0;

// Corner radii of windows without rings, asked once each.
#define MAX_RADII 256
static struct { uint32_t wid; CGFloat radius; } radii[MAX_RADII];
static int radiusCount = 0;

static CGFloat radiusOf(uint32_t wid) {
    Ring *ring = ringFor(wid);
    if (ring) return ring->radius;
    for (int i = 0; i < radiusCount; i++) {
        if (radii[i].wid == wid) return radii[i].radius;
    }
    if (radiusCount == MAX_RADII) radiusCount = 0;
    radii[radiusCount].wid = wid;
    radii[radiusCount].radius = cornerRadius(wid);
    return radii[radiusCount++].radius;
}

static bool isRingWindow(uint32_t wid) {
    for (int i = 0; i < ringCount; i++) {
        if (rings[i].wid == wid) return true;
    }
    return false;
}

static int number(CFDictionaryRef info, CFStringRef key, CFNumberType type, void *out) {
    CFNumberRef n = CFDictionaryGetValue(info, key);
    return n && CFNumberGetValue(n, type, out);
}

// The windows on screen, front to back, leaving out what covers nothing:
// the rings, Hammerspoon's own overlays (highlights, the HUD), invisible
// windows, the cursor's, and the windows the Dock and Notification Centre
// keep over whole displays (as hover.c).
static void takeSnapshot(void) {
    snapshotTaken = true;
    snapshotTruncated = false;
    seenCount = 0;
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return;
    CGDirectDisplayID displays[16];
    uint32_t displayCount = 0;
    if (CGGetActiveDisplayList(16, displays, &displayCount) != kCGErrorSuccess) displayCount = 0;
    pid_t self = getpid();
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
        int32_t pid = 0, level = 0, wid = 0;
        double alpha = 1;
        CGRect bounds;
        CFDictionaryRef b = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!number(info, kCGWindowNumber, kCFNumberSInt32Type, &wid) || !b
            || !CGRectMakeWithDictionaryRepresentation(b, &bounds)) {
            continue;
        }
        number(info, kCGWindowOwnerPID, kCFNumberSInt32Type, &pid);
        number(info, kCGWindowLayer, kCFNumberSInt32Type, &level);
        number(info, kCGWindowAlpha, kCFNumberDoubleType, &alpha);
        if (alpha <= 0 || level >= kCGScreenSaverWindowLevel) continue;
        if (pid == self && (level > 0 || isRingWindow((uint32_t)wid))) continue;
        bool coversDisplay = false;
        for (uint32_t d = 0; d < displayCount && level > 0 && !coversDisplay; d++) {
            coversDisplay = CGRectContainsRect(bounds, CGDisplayBounds(displays[d]));
        }
        if (coversDisplay) continue;
        if (seenCount == MAX_SEEN) {
            snapshotTruncated = true;
            break;
        }
        seen[seenCount++] = (Seen){ (uint32_t)wid, bounds, level, alpha };
    }
    CFRelease(list);
}

// The window's level from this update's snapshot, saving a call per ring.
static bool seenLevel(uint32_t wid, int64_t *level) {
    if (!snapshotTaken) return false;
    for (int i = 0; i < seenCount; i++) {
        if (seen[i].wid == wid) {
            *level = seen[i].level;
            return true;
        }
    }
    return false;
}

// How much of a ring shows under the window: 0 if it's opaque. A rule's
// `opacity` wins over what the window reports.
static CGFloat showsThrough(const Seen *window) {
    for (int i = 0; i < opacityCount; i++) {
        if (opacities[i].wid == window->wid) return fmin(fmax(1 - opacities[i].opacity, 0), 1);
    }
    // Content that's see-through with the window's alpha at 1 (a terminal
    // background) can't be told from outside the app: SLSGetWindowOpacity
    // only answers for our own windows (#1). It counts as opaque.
    return window->alpha < 1 ? 1 - window->alpha : 0;
}

// A window above a ring's target, in the ring layer's coordinates.
typedef struct {
    CGRect rect;
    CGFloat radius;
    CGFloat shows; // how much of the ring shows under it
} Cover;

#define MAX_COVERS 32

// The windows above the ring's target that overlap the ring.
static int coversOf(Ring *ring, Cover *covers) {
    CGFloat w = style.width;
    CGRect area = CGRectInset(ring->bounds, -w, -w);
    int target = -1;
    for (int i = 0; i < seenCount; i++) {
        if (seen[i].wid == ring->target) {
            target = i;
            break;
        }
    }
    // A target beyond the fixed snapshot limit has unknown occluders.
    // Hide its whole ring until it is in the snapshot, rather than draw
    // over windows that may cover it.
    if (target < 0 && snapshotTruncated) {
        covers[0] = (Cover){ (CGRect){ CGPointZero, area.size }, 0, 0 };
        return 1;
    }
    int count = 0;
    for (int i = 0; i < target && count < MAX_COVERS; i++) {
        CGRect rect = seen[i].bounds;
        // A window being dragged covers its drag's frame (as its ring does).
        Ring *other = ringFor(seen[i].wid);
        if (other && other->previewing) rect = other->preview;
        if (!CGRectIntersectsRect(rect, area)) continue;
        CGFloat shows = showsThrough(&seen[i]);
        if (shows >= 1) continue;
        covers[count++] = (Cover){ CGRectOffset(rect, -area.origin.x, -area.origin.y), radiusOf(seen[i].wid), shows };
    }
    return count;
}

// A key for what the mask is worked out from, to skip working out the
// same one again (most rings, most updates). Never 0.
static uint64_t maskKey(Ring *ring, const Cover *covers, int count) {
    uint64_t h = 1469598103934665603ULL;
    const unsigned char *p = (const unsigned char *)&ring->bounds.size;
    for (size_t i = 0; i < sizeof(CGSize); i++) h = (h ^ p[i]) * 1099511628211ULL;
    p = (const unsigned char *)covers;
    for (size_t i = 0; i < sizeof(Cover) * count; i++) h = (h ^ p[i]) * 1099511628211ULL;
    return h ? h : 1;
}

static void addOutline(CGMutablePathRef path, const Cover *cover) {
    CGFloat r = fmin(cover->radius, fmin(cover->rect.size.width, cover->rect.size.height) / 2);
    CGPathAddRoundedRect(path, NULL, cover->rect, r, r);
}

static bool pathEmpty(CGPathRef path) {
    return !path || CGRectIsEmpty(CGPathGetPathBoundingBox(path));
}

// A part of the ring's layer, and how much of the ring shows there.
typedef struct {
    CGPathRef path;
    CGFloat shows;
} Piece;

#define MAX_PIECES 16

// The parts of `size` left uncovered or under see-through windows only
// (the caller releases them). Outlines are filled non-zero, so where
// windows overlap they still cover once: even-odd would show the ring
// again.
static int pieces(CGSize size, const Cover *covers, int count, Piece *out) API_AVAILABLE(macos(13.0)) {
    CGMutablePathRef opaque = CGPathCreateMutable();
    bool anyOpaque = false;
    for (int i = 0; i < count; i++) {
        if (covers[i].shows > 0) continue;
        addOutline(opaque, &covers[i]);
        anyOpaque = true;
    }
    CGPathRef whole = CGPathCreateWithRect((CGRect){ CGPointZero, size }, NULL);
    int n = 0;
    out[n++] = (Piece){ anyOpaque ? CGPathCreateCopyBySubtractingPath(whole, opaque, false) : CGPathRetain(whole), 1 };
    CGPathRelease(whole);
    CGPathRelease(opaque);
    // Each see-through window splits the parts it overlaps, so where
    // several overlap their shares multiply.
    for (int i = 0; i < count; i++) {
        if (covers[i].shows <= 0) continue;
        CGMutablePathRef outline = CGPathCreateMutable();
        addOutline(outline, &covers[i]);
        for (int j = 0, before = n; j < before && n < MAX_PIECES; j++) {
            if (pathEmpty(out[j].path)) continue;
            CGPathRef under = CGPathCreateCopyByIntersectingPath(out[j].path, outline, false);
            if (pathEmpty(under)) {
                CGPathRelease(under);
                continue;
            }
            CGPathRef rest = CGPathCreateCopyBySubtractingPath(out[j].path, outline, false);
            CGPathRelease(out[j].path);
            out[j].path = rest;
            out[n++] = (Piece){ under, out[j].shows * covers[i].shows };
        }
        CGPathRelease(outline);
    }
    return n;
}

// Gives the ring the mask for this update's snapshot (inside a transaction).
static void maskRing(Ring *ring) {
    Cover covers[MAX_COVERS];
    int count = ring->shown && !masks.suspended ? coversOf(ring, covers) : 0;
    uint64_t key = count ? maskKey(ring, covers, count) : 0;
    if (key == ring->maskKey) return;
    ring->maskKey = key;
    if (!count) {
        ring->layer.mask = nil;
        return;
    }
    if (@available(macOS 13.0, *)) {
        Piece parts[MAX_PIECES];
        CGSize size = ring->layer.bounds.size;
        int n = pieces(size, covers, count, parts);
        if (!ring->mask) ring->mask = [[CALayer alloc] init];
        ring->mask.frame = (CGRect){ CGPointZero, size };
        NSArray *old = ring->mask.sublayers;
        NSMutableArray *shapes = [NSMutableArray arrayWithCapacity:n];
        for (int i = 0; i < n; i++) {
            if (!pathEmpty(parts[i].path) && parts[i].shows > 0) {
                CAShapeLayer *shape = shapes.count < old.count ? old[shapes.count] : [CAShapeLayer layer];
                shape.frame = ring->mask.bounds;
                shape.path = parts[i].path;
                shape.fillColor = CGColorGetConstantColor(kCGColorBlack);
                shape.opacity = (float)parts[i].shows;
                [shapes addObject:shape];
            }
            CGPathRelease(parts[i].path);
        }
        // None at all: the ring is covered whole.
        ring->mask.sublayers = shapes;
        ring->layer.mask = ring->mask;
    }
}

static bool pathOperations(void) {
    if (@available(macOS 13.0, *)) return true;
    return false;
}

static bool dragUnderWay(void) {
    for (int i = 0; i < ringCount; i++) {
        if (rings[i].target && rings[i].previewing) return true;
    }
    return false;
}

// Every ring's mask, in one transaction.
static void maskAll(void) {
    beginChanges();
    for (int i = 0; i < ringCount; i++) {
        if (rings[i].target) maskRing(&rings[i]);
    }
    commitChanges();
}

static void dropMasks(void) {
    beginChanges();
    for (int i = 0; i < ringCount; i++) {
        rings[i].layer.mask = nil;
        rings[i].maskKey = 0;
    }
    commitChanges();
}

// The windows asked about: the managed ones from Lua (main thread), and
// with masks on, the rest of those on screen, from the snapshot (`extra`,
// under watchLock). `watchAsk` asks again on the main thread when `extra`
// changes; it exists only while masks are on.
#define MAX_WATCHED 512
static uint32_t managed[MAX_WATCHED];
static int managedCount = 0;
static os_unfair_lock watchLock = OS_UNFAIR_LOCK_INIT;
static uint32_t extra[MAX_SEEN];
static int extraCount = 0;
static dispatch_source_t watchAsk = NULL;
static uint32_t asked[MAX_SEEN]; // the queue's last `extra`, sorted
static int askedCount = 0;

static void requestWatch(void) {
    uint32_t wids[MAX_WATCHED + MAX_SEEN];
    int count = managedCount;
    memcpy(wids, managed, sizeof(uint32_t) * count);
    if (watchAsk) {
        os_unfair_lock_lock(&watchLock);
        for (int i = 0; i < extraCount; i++) {
            bool listed = false;
            for (int j = 0; j < managedCount && !listed; j++) listed = managed[j] == extra[i];
            if (!listed) wids[count++] = extra[i];
        }
        os_unfair_lock_unlock(&watchLock);
    }
    SLSRequestNotificationsForWindows(mainCid, wids, count);
}

static void onWatchAsk(void *unused) {
    (void)unused;
    requestWatch();
}

// Main thread, once masks are off on the queue (which then leaves it be).
// Cancelled on the main queue, its handler can't run after.
static void stopWatchAsk(void) {
    if (!watchAsk) return;
    dispatch_source_cancel(watchAsk);
    dispatch_release(watchAsk);
    watchAsk = NULL;
}

static int compareWids(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

// After a snapshot: asks about windows that came on screen.
static void watchSeen(void) {
    uint32_t wids[MAX_SEEN];
    for (int i = 0; i < seenCount; i++) wids[i] = seen[i].wid;
    qsort(wids, seenCount, sizeof(uint32_t), compareWids);
    if (seenCount == askedCount && memcmp(wids, asked, sizeof(uint32_t) * seenCount) == 0) return;
    memcpy(asked, wids, sizeof(uint32_t) * seenCount);
    askedCount = seenCount;
    os_unfair_lock_lock(&watchLock);
    memcpy(extra, wids, sizeof(uint32_t) * seenCount);
    extraCount = seenCount;
    os_unfair_lock_unlock(&watchLock);
    if (watchAsk) dispatch_source_merge_data(watchAsk, 1);
}

// Around each update on the queue: the snapshot before its changes, and
// every ring's mask for where things ended up after. Nothing with masks off.
static void beginMasking(void) {
    if (!masks.on) return;
    masks.suspended = masks.showDrags && dragUnderWay();
    takeSnapshot();
}

static void finishMasking(void) {
    if (!masks.on) return;
    if (!snapshotTaken) takeSnapshot();
    masks.suspended = masks.showDrags && dragUnderWay();
    maskAll();
    watchSeen();
    snapshotTaken = false;
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
    beginMasking();
    for (int i = 0; i < ringCount; i++) {
        Ring *ring = &rings[i];
        if (!ring->target || !ring->resizing) continue;
        ring->resizing = false;
        place(ring, true);
    }
    finishMasking();
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
// Mission Control and Exposé
// ---------------------------------------------------------------------------

// Rings drawn by CoreAnimation show above everything, so they'd hang over
// Mission Control's and Exposé's thumbnails. Neither says when it's up (the
// Dock's accessibility notifications for it no longer come on macOS 27,
// where the WindowManager process draws it), but it's the only thing that
// puts WindowManager windows above level 14. Windows coming and
// going are the cue to look (one WindowServer query, ~0.2ms): every 0.1s
// for half a second after, since its windows are made before they're
// shown, and while it's up, since they're put away rather than closed.

static dispatch_source_t overviewCheck = NULL;
static bool overviewCheckRunning = false;
static atomic_bool overviewCheckQueued = false;
static int overviewFollowUps = 0; // checks left after the last cue

static bool overviewShowing(void) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return false;
    bool found = false;
    for (CFIndex i = 0; i < CFArrayGetCount(list) && !found; i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
        CFStringRef owner = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (!owner || CFStringCompare(owner, CFSTR("WindowManager"), 0) != kCFCompareEqualTo) continue;
        int32_t layer = 0;
        double alpha = 1;
        CFNumberRef n = CFDictionaryGetValue(info, kCGWindowLayer);
        if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &layer);
        n = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (n) CFNumberGetValue(n, kCFNumberDoubleType, &alpha);
        // 19 for Exposé and Mission Control, 17 for Mission Control's
        // thumbnails; its 14 backdrop lingers a second or two after it.
        found = layer > 14 && alpha > 0;
    }
    CFRelease(list);
    return found;
}

static void checkOverview(void *unused) {
    (void)unused;
    if (atomic_exchange(&overviewCheckQueued, false)) overviewFollowUps = 5;
    else if (overviewFollowUps > 0) overviewFollowUps--;
    bool showing = overviewShowing();
    bool keepLooking = showing || overviewFollowUps > 0;
    if (keepLooking && !overviewCheckRunning) {
        if (!overviewCheck) {
            overviewCheck = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
            dispatch_source_set_timer(overviewCheck, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                NSEC_PER_SEC / 10, NSEC_PER_SEC / 100);
            dispatch_source_set_event_handler_f(overviewCheck, checkOverview);
        }
        dispatch_resume(overviewCheck);
        overviewCheckRunning = true;
    } else if (!keepLooking && overviewCheckRunning) {
        dispatch_suspend(overviewCheck);
        overviewCheckRunning = false;
    }
    if (showing == overview) return;
    overview = showing;
    beginMasking();
    // Back from it, each ring goes where its window is now.
    if (!showing) {
        for (int i = 0; i < ringCount; i++) {
            if (rings[i].target) place(&rings[i], false);
        }
    }
    restackAll();
    finishMasking();
}

static void noteCovering(void);

// A window was created or destroyed anywhere (main thread).
static void onWindowCreatedOrDestroyed(uint32_t event, void *data, size_t length, int cid) {
    (void)event;
    (void)data;
    (void)length;
    (void)cid;
    if (queue && !atomic_exchange(&overviewCheckQueued, true)) dispatch_async_f(queue, NULL, checkOverview);
    // It may cover a ring, or uncover one (watchAsk exists only with masks on).
    if (watchAsk) noteCovering();
}

// ---------------------------------------------------------------------------
// Blending between the colours
// ---------------------------------------------------------------------------

// Fades are stepped at this rate rather than drawn at the display's: each
// frame is a composite of the screen for WindowServer, and a smooth fade at
// 120Hz cost it about twice the CPU (measured).
#define FADE_RATE 60

// Fades the ring from how it looks now to `to` over `duration` seconds.
static void blend(Ring *ring, float to, double duration) {
    if (!ring) return;
    double t = now();
    float from = mixAt(ring, t);
    if (from == to && ring->to == to) return;
    ring->from = from;
    ring->to = to;
    ring->start = t;
    ring->duration = duration;
    beginChanges();
    [ring->layer removeAllAnimations];
    CGColorRef end = colorAt(to);
    ring->layer.borderColor = end;
    int steps = (int)ceil(duration * FADE_RATE);
    if (steps > 1) {
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:steps];
        for (int i = 1; i <= steps; i++) {
            CGColorRef c = i == steps ? CGColorRetain(end) : colorAt(from + (to - from) * (float)i / steps);
            [values addObject:(id)c];
            CGColorRelease(c);
        }
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:borderColorKey];
        fade.values = values;
        fade.calculationMode = kCAAnimationDiscrete;
        fade.duration = duration;
        [ring->layer addAnimation:fade forKey:fadeKey];
    }
    CGColorRelease(end);
    commitChanges();
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

    // Whatever changed, any ring's mask may have: one snapshot for the
    // burst. Moves of windows without rings count only for this.
    beginMasking();
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
    finishMasking();
}

// A window came or went: an update for the masks alone.
static void noteCovering(void) {
    os_unfair_lock_lock(&notedLock);
    bool enqueue = !noted.queued && queue;
    noted.queued = true;
    os_unfair_lock_unlock(&notedLock);
    if (enqueue) dispatch_async_f(queue, NULL, catchUp);
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

// Only what was registered may be removed: SkyLight aborts otherwise.
static const uint32_t connectionEvents[] = { SL_EVENT_WINDOW_CREATE, SL_EVENT_WINDOW_DESTROY };
#define CONNECTION_EVENT_COUNT (sizeof(connectionEvents) / sizeof(connectionEvents[0]))
static bool connectionRegistered[CONNECTION_EVENT_COUNT];

static void registerEvents(bool on) {
    for (size_t i = 0; i < EVENT_COUNT; i++) {
        if (on) SLSRegisterNotifyProc((void *)onWindowEvent, events[i], NULL);
        else SLSRemoveNotifyProc((void *)onWindowEvent, events[i], NULL);
    }
    for (size_t i = 0; i < CONNECTION_EVENT_COUNT; i++) {
        if (on) {
            connectionRegistered[i] = SLSRegisterConnectionNotifyProc(mainCid, (void *)onWindowCreatedOrDestroyed,
                connectionEvents[i], NULL) == kCGErrorSuccess;
        } else if (connectionRegistered[i]) {
            SLSRemoveConnectionNotifyProc(mainCid, (void *)onWindowCreatedOrDestroyed, connectionEvents[i], NULL);
            connectionRegistered[i] = false;
        }
    }
}


// ---------------------------------------------------------------------------
// Lua API
// ---------------------------------------------------------------------------

// The focused window as last told by Lua, for active() (main thread).
static uint32_t activeAsked = 0;

// set({wid, ...}, {[wid] = opacity} or nil): ring exactly these windows.
// The second lists the windows with an `opacity` rule, for the masks.
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
    bool rules = lua_istable(L, 2);
    __typeof__(opacities[0]) *given = NULL;
    int givenCount = 0;
    if (rules) {
        given = calloc(MAX_OPACITIES, sizeof(given[0]));
        lua_pushnil(L);
        while (lua_next(L, 2)) {
            if (givenCount < MAX_OPACITIES && lua_isinteger(L, -2) && lua_isnumber(L, -1)) {
                given[givenCount].wid = (uint32_t)lua_tointeger(L, -2);
                given[givenCount].opacity = lua_tonumber(L, -1);
                givenCount++;
            }
            lua_pop(L, 1);
        }
    }
    dispatch_async(queue, ^{
        if (rules) {
            memcpy(opacities, given, sizeof(given[0]) * givenCount);
            opacityCount = givenCount;
            free(given);
        }
        beginMasking();
        bool keep[MAX_RINGS] = { false };
        for (int i = 0; i < count; i++) {
            Ring *ring = ringFor(wids[i]);
            if (!ring) ring = newRing(wids[i]);
            if (ring) keep[ring - rings] = true;
        }
        for (int i = 0; i < ringCount; i++) {
            if (rings[i].target && !keep[i]) freeRing(&rings[i]);
        }
        finishMasking();
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
// any of them may put it between a ring and its window. With masks on, the
// rest of the windows on screen are asked about too.
static int l_watch(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    managedCount = luaWindowIds(L, 1, managed, MAX_WATCHED);
    requestWatch();
    return 0;
}

// mask{ drags = "mask" | "show" } or mask(false):
// turns the masks (experimental.borderMask) on or off. Returns whether
// they're on: they need macOS 13's path operations.
static int l_mask(lua_State *L) {
    bool on = lua_toboolean(L, 1);
    bool showDrags = false;
    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "drags");
        showDrags = strcmp(luaL_optstring(L, -1, "mask"), "show") == 0;
        lua_pop(L, 1);
    }
    on = on && pathOperations();
    if (on && !watchAsk) {
        watchAsk = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler_f(watchAsk, onWatchAsk);
        dispatch_resume(watchAsk);
    }
    dispatch_sync(queue, ^{
        masks.on = on;
        masks.showDrags = showDrags;
        askedCount = 0;
        if (on) finishMasking();
        else dropMasks();
    });
    // Off: back to asking about the managed windows only. The queue no
    // longer touches watchAsk.
    if (!on) {
        stopWatchAsk();
        os_unfair_lock_lock(&watchLock);
        extraCount = 0;
        os_unfair_lock_unlock(&watchLock);
        requestWatch();
    }
    lua_pushboolean(L, on);
    return 1;
}

// remask(): works every ring's mask out afresh from a new snapshot, as
// after a burst of changes, and waits for it (tests/performance.lua times
// it).
static int l_remask(lua_State *L) {
    (void)L;
    dispatch_sync(queue, ^{
        if (!masks.on) return;
        for (int i = 0; i < ringCount; i++) rings[i].maskKey = UINT64_MAX;
        finishMasking();
    });
    return 0;
}

// overview(): whether Mission Control or Exposé is taken to be up (the
// rings hidden), and whether WindowServer reports windows coming and going.
static int l_overview(lua_State *L) {
    __block bool up = false;
    dispatch_sync(queue, ^{ up = overview; });
    lua_pushboolean(L, up);
    lua_pushboolean(L, connectionRegistered[0] && connectionRegistered[1]);
    return 2;
}

// active(): the focused window, or nil.
static int l_active(lua_State *L) {
    if (activeAsked) lua_pushinteger(L, activeAsked);
    else lua_pushnil(L);
    return 1;
}

// The layers are taken apart in a transaction of their own, flushed,
// before anything is released: released mid-fade, outside a transaction,
// CoreAnimation kept their animations listed, and the next commit (the
// reloaded config's first rings) crashed on them (4 crash reports in a day of reloads).
static void releaseAll(void) {
    if (ringCount == 0) return;
    beginChanges();
    for (int i = 0; i < ringCount; i++) {
        [rings[i].layer removeAllAnimations];
        rings[i].layer.mask = nil;
        [rings[i].layer removeFromSuperlayer];
        rings[i].context.layer = nil;
    }
    commitChanges();
    for (int i = 0; i < ringCount; i++) {
        freeRing(&rings[i]);
        SLSReleaseWindow(drawCid, rings[i].wid);
        if ([rings[i].context respondsToSelector:@selector(invalidate)]) {
            [rings[i].context performSelector:@selector(invalidate)];
        }
        [rings[i].mask release];
        [rings[i].layer release];
        [rings[i].root release];
        [rings[i].context release];
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
        if (overviewCheck) {
            if (!overviewCheckRunning) dispatch_resume(overviewCheck);
            dispatch_source_cancel(overviewCheck);
            dispatch_release(overviewCheck);
            overviewCheck = NULL;
            overviewCheckRunning = false;
        }
        overview = false;
        masks.on = false;
        if (releaseCheck) {
            if (!releaseCheckRunning) dispatch_resume(releaseCheck); // can't cancel a suspended source
            dispatch_source_cancel(releaseCheck);
            dispatch_release(releaseCheck);
            releaseCheck = NULL;
            releaseCheckRunning = false;
        }
        releaseAll();
        if (drain) {
            dispatch_source_cancel(drain);
            dispatch_release(drain);
            drain = NULL;
        }
    });
    stopWatchAsk(); // after masks.on went false on the queue
    dispatch_release(queue);
    queue = NULL;
    SLSReleaseConnection(drawCid);
    return 0;
}

int luaopen_hyprspoon_native_border(lua_State *L) {
    const char *missing = loadSymbols();
    if (missing) return luaL_error(L, "hyprspoon.native.border: SkyLight has no %s", missing);

    if (!borderColorKey) {
        borderColorKey = [[NSString alloc] initWithUTF8String:"borderColor"];
        fadeKey = [[NSString alloc] initWithUTF8String:"fade"];
    }
    mainCid = SLSMainConnectionID();
    if (SLSNewConnection(0, &drawCid) != kCGErrorSuccess) return luaL_error(L, "hyprspoon.native.border: no WindowServer connection");
    // Each block drains its own autorelease pool (CoreAnimation's objects).
    queue = dispatch_queue_create("hyprspoon.border",
        dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
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
    memset(&masks, 0, sizeof(masks));
    snapshotTruncated = false;
    snapshotTaken = false;
    seenCount = opacityCount = radiusCount = managedCount = extraCount = askedCount = 0;
    registerEvents(true);

    static const luaL_Reg funcs[] = {
        { "set", l_set },
        { "focus", l_focus },
        { "active", l_active },
        { "overview", l_overview },
        { "watch", l_watch },
        { "previewer", l_previewer },
        { "mask", l_mask },
        { "remask", l_remask },
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
