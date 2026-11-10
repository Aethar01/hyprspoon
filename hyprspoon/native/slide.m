// hyprspoon/native/slide.m: Workspaces sliding in and out, like Hyprland's.
//
// Loaded by hyprspoon/slide.lua as hyprspoon.native.slide (build: make -C hyprspoon/native).
//
// macOS won't let us move other apps' windows smoothly: each accessibility
// move is a round trip to the app. So the windows switch at once, as
// without this, and a picture of the switch slides over them: one window of
// our own over the display, a CoreAnimation layer tree that WindowServer
// animates by itself, ordered out once the slide has settled. It never
// takes the mouse, and keys go to the windows beneath all along.
//
// Pictures are captures, and a capture costs WindowServer about 40ms
// however many windows it takes (measured), so there are as few as
// possible: one of a workspace's windows as it's left, kept to slide in
// with when it comes back (by then its windows are parked, and a capture
// sees only what's on screen), and one of each display's wallpaper, kept
// to slide over. The windows a workspace comes back with are the ones it
// left with, so the picture is only as old as the visit away (hyprspoon/slide.lua
// drops it if they differ).
//
// SkyLight's calls are private, looked up when the module loads (see
// skylight.h); the window is made as border.m makes its rings.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "luacall.h"
#include "skylight.h"

// CoreAnimation's link to a WindowServer window (private).
@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(uint32_t)cid options:(NSDictionary *)options;
@property (retain) CALayer *layer;
@end

#define SL_FUNCS(X)                                                                    \
    X(CGError, SLSNewConnection, (int, int *))                                         \
    X(CGError, SLSReleaseConnection, (int))                                            \
    X(CGError, SLSGetEventPort, (int, mach_port_t *))                                  \
    X(CGEventRef, SLEventCreateNextEvent, (int))                                       \
    X(CGError, SLSNewWindowWithOpaqueShapeAndContext, (int, int, CFTypeRef, CFTypeRef,  \
                                                       int, uint64_t *, float, float,  \
                                                       int, uint32_t *, void *))       \
    X(CGError, SLSReleaseWindow, (int, uint32_t))                                      \
    X(CGError, SLSSetWindowTags, (int, uint32_t, uint64_t *, int))                     \
    X(CGError, SLSSetWindowShape, (int, uint32_t, float, float, CFTypeRef))            \
    X(CGError, SLSSetWindowResolution, (int, uint32_t, double))                        \
    X(CGError, SLSSetWindowOpacity, (int, uint32_t, bool))                             \
    X(CGError, SLSGetWindowBounds, (int, uint32_t, CGRect *))                          \
    X(CGError, CGSNewRegionWithRect, (CGRect *, CFTypeRef *))                          \
    X(CGError, SLSWindowSetShadowProperties, (uint32_t, CFDictionaryRef))              \
    X(CFArrayRef, SLSHWCaptureWindowList, (int, uint32_t *, int, uint32_t))            \
    X(CFTypeRef, SLSTransactionCreate, (int))                                          \
    X(CGError, SLSTransactionMoveWindowWithGroup, (CFTypeRef, uint32_t, CGPoint))      \
    X(CGError, SLSTransactionOrderWindow, (CFTypeRef, uint32_t, int, uint32_t))        \
    X(CGError, SLSTransactionSetWindowLevel, (CFTypeRef, uint32_t, int))               \
    X(CGError, SLSTransactionSetWindowTransform, (CFTypeRef, uint32_t, int, int,       \
                                                  CGAffineTransform))                  \
    X(CGError, SLSTransactionCommit, (CFTypeRef, int))

SL_FUNCS(SL_DECLARE)

// Optional: each window's corner radius (macOS 26 and later), as border.m
// reads it. Without it, the radius Lua gives.
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

// Captures at the display's nominal resolution (a quarter of the pixels on
// a Retina display): they're mostly seen moving.
#define CAPTURE_NOMINAL (1 << 9)

// Just under the menu bar's level: above every app window and the rings.
#define OVERLAY_LEVEL 23

// The wallpaper is taken again once a slide is over if it's older than
// this (seconds; 0 never): macOS can shuffle a folder of them, or change
// one through the day, and says nothing. Set by run() and begin().
static double wallpaperMaxAge = 0;

// Everything below belongs to `queue`, with its own connection (cid).
static dispatch_queue_t queue = NULL;
static int cid = 0;

// Events WindowServer sends the connection, read and dropped (see border.m).
static dispatch_source_t drain = NULL;
static mach_port_t drainPort = MACH_PORT_NULL;

// Calls finish() once a slide has settled, the slide's generation in
// `settling` (not the source's context: a handler set with
// dispatch_source_set_event_handler_f is given the context as it was when
// the handler was set). A timer rather than dispatch_after: l_gc must be
// able to cancel it, or a reload unloads the library before it fires into it.
static dispatch_source_t settled = NULL;
static unsigned settling = 0;

// Deliver visibility on the main thread, coalescing spring completion with
// any replacement slide. Lua never runs on the animation queue.
static LuaCallback onChange = LUA_CALLBACK_NONE;
static dispatch_source_t visibility = NULL;
static atomic_bool overlayShown = false;

static void notifyVisibility(void *unused) {
    (void)unused;
    if (luaCallbackPush(&onChange)) {
        lua_pushboolean(onChange.L, atomic_load(&overlayShown));
        luaCallbackCall(&onChange, 1);
    }
}

static int l_onChange(lua_State *L) {
    luaCallbackSet(&onChange, L, 1);
    return 0;
}

static void drainEvents(void *unused) {
    (void)unused;
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
    while ((event = SLEventCreateNextEvent(cid))) CFRelease(event);
}

// ---------------------------------------------------------------------------
// Pictures
// ---------------------------------------------------------------------------

typedef struct {
    int key;          // the caller's (a workspace number); 0 when free
    CGImageRef image;
    CGRect bounds;    // where it was on screen
    double taken;
} Shot;

#define MAX_PICTURES 32
static Shot pictures[MAX_PICTURES];

// Wallpapers are kept apart, by display bounds.
#define MAX_WALLPAPERS 8
static Shot wallpapers[MAX_WALLPAPERS];
static int wallpaperCount = 0;

static Shot *pictureFor(int key) {
    for (int i = 0; i < MAX_PICTURES; i++) {
        if (pictures[i].key == key && pictures[i].image) return &pictures[i];
    }
    return NULL;
}

static void dropPicture(Shot *p) {
    if (p->image) CGImageRelease(p->image);
    memset(p, 0, sizeof(*p));
}

// The union of every display's bounds: a capture is of the windows' parts
// on screen.
static CGRect displaysBounds(void) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    CGRect all = CGRectNull;
    if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess) return all;
    for (uint32_t i = 0; i < count; i++) all = CGRectUnion(all, CGDisplayBounds(displays[i]));
    return all;
}

// Puts `wids` in their on-screen order, front first: a capture stacks them
// in the order it's given, the first on top. Ones not on screen go last.
static void sortByStacking(uint32_t *wids, int count) {
    CFArrayRef list = CGWindowListCreate(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!list) return;
    CFIndex n = CFArrayGetCount(list);
    CFIndex rank[count];
    for (int i = 0; i < count; i++) {
        rank[i] = n + i;
        for (CFIndex j = 0; j < n; j++) {
            if ((uint32_t)(uintptr_t)CFArrayGetValueAtIndex(list, j) == wids[i]) {
                rank[i] = j;
                break;
            }
        }
    }
    CFRelease(list);
    for (int i = 1; i < count; i++) {
        uint32_t wid = wids[i];
        CFIndex r = rank[i];
        int j = i - 1;
        for (; j >= 0 && rank[j] > r; j--) {
            wids[j + 1] = wids[j];
            rank[j + 1] = rank[j];
        }
        wids[j + 1] = wid;
        rank[j + 1] = r;
    }
}

// One capture of `wids` together, as they're stacked on screen, and where
// it covers (retained; NULL if there's nothing to see).
static CGImageRef capture(uint32_t *wids, int count, CGRect *bounds) {
    sortByStacking(wids, count);
    CGRect screen = displaysBounds(), area = CGRectNull;
    for (int i = 0; i < count; i++) {
        CGRect b;
        if (SLSGetWindowBounds(cid, wids[i], &b) != kCGErrorSuccess) continue;
        b = CGRectIntersection(b, screen);
        if (!CGRectIsNull(b)) area = CGRectUnion(area, b);
    }
    if (CGRectIsNull(area) || CGRectIsEmpty(area)) return NULL;
    CFArrayRef list = SLSHWCaptureWindowList(cid, wids, count, CAPTURE_NOMINAL);
    if (!list) return NULL;
    CGImageRef image = NULL;
    if (CFArrayGetCount(list) > 0) image = CGImageRetain((CGImageRef)CFArrayGetValueAtIndex(list, 0));
    CFRelease(list);
    *bounds = area;
    return image;
}

// The windows drawing the desktop of the display at `bounds`: the
// wallpaper, and Finder's icons over it.
static int desktopWindows(CGRect bounds, uint32_t *out, int max) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!list) return 0;
    CGPoint middle = { CGRectGetMidX(bounds), CGRectGetMidY(bounds) };
    uint32_t wallpaper = 0, icons = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
        int32_t layer = 0;
        uint32_t wid = 0;
        CFNumberRef n = CFDictionaryGetValue(info, kCGWindowLayer);
        if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &layer);
        n = CFDictionaryGetValue(info, kCGWindowNumber);
        if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &wid);
        CGRect b = CGRectNull;
        CFDictionaryRef d = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!d || !CGRectMakeWithDictionaryRepresentation(d, &b) || !CGRectContainsPoint(b, middle)) continue;
        CFStringRef name = CFDictionaryGetValue(info, kCGWindowName);
        if (!wallpaper && name && CFStringCompare(name, CFSTR("Wallpaper"), 0) == kCFCompareEqualTo) {
            wallpaper = wid;
        } else if (!icons && layer == CGWindowLevelForKey(kCGDesktopIconWindowLevelKey)) {
            icons = wid;
        }
    }
    CFRelease(list);
    int count = 0;
    if (wallpaper && count < max) out[count++] = wallpaper;
    if (icons && count < max) out[count++] = icons;
    return count;
}

static Shot *wallpaperFor(CGRect display) {
    for (int i = 0; i < wallpaperCount; i++) {
        if (CGRectEqualToRect(wallpapers[i].bounds, display)) return &wallpapers[i];
    }
    return NULL;
}

// Takes the wallpaper of the display at `display` (its full bounds).
static Shot *takeWallpaper(CGRect display) {
    Shot *p = wallpaperFor(display);
    if (!p) {
        if (wallpaperCount == MAX_WALLPAPERS) dropPicture(&wallpapers[--wallpaperCount]);
        p = &wallpapers[wallpaperCount++];
        memset(p, 0, sizeof(*p));
    }
    uint32_t wids[2];
    int count = desktopWindows(display, wids, 2);
    CGRect bounds;
    CGImageRef image = count ? capture(wids, count, &bounds) : NULL;
    if (!image) return p->image ? p : NULL;
    if (p->image) CGImageRelease(p->image);
    p->image = image;
    p->bounds = display;
    p->taken = CFAbsoluteTimeGetCurrent();
    return p;
}

// The full bounds of the display holding `frame`.
static CGRect displayHolding(CGRect frame) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    CGPoint middle = { CGRectGetMidX(frame), CGRectGetMidY(frame) };
    if (CGGetActiveDisplayList(16, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            CGRect b = CGDisplayBounds(displays[i]);
            if (CGRectContainsPoint(b, middle)) return b;
        }
    }
    return frame;
}

// ---------------------------------------------------------------------------
// The overlay
// ---------------------------------------------------------------------------

static uint32_t wid = 0;
static CAContext *context = nil;
static CALayer *root = nil;     // the window's content, origin top-left
static CGRect placed = { { 0, 0 }, { 0, 0 } }; // where the window is
static double placedScale = 0;
static bool shown = false;
static unsigned generation = 0; // which slide the ordering-out belongs to
// Tiles in the retile on show (see Retiles below); none once it's down.
static int shownCount = 0;

static NSString *positionKey = nil, *slideKey = nil;

// How something moves (the `animations` option): on a spring (Hyprland's
// mass, stiffness and dampening), or eased over `duration` seconds,
// quad-out like the windows' own animations.
typedef struct {
    bool ease;
    double duration, mass, stiffness, damping;
} Motion;

static const Motion defaultMotion = { false, 0.2, 0.6, 800, 38 };

// An animation of `key` from `from` to `to` as `m` moves, its duration how
// long that takes. `velocity`, in distances to go per second, starts a
// spring off.
static CABasicAnimation *animate(Motion m, NSString *key, id from, id to, double velocity) {
    CABasicAnimation *a;
    if (m.ease) {
        a = [CABasicAnimation animationWithKeyPath:key];
        a.duration = m.duration;
        a.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.25f :0.46f :0.45f :0.94f];
    } else {
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:key];
        spring.mass = m.mass;
        spring.stiffness = m.stiffness;
        spring.damping = m.damping;
        spring.initialVelocity = velocity;
        spring.duration = spring.settlingDuration;
        a = spring;
    }
    a.fromValue = from;
    a.toValue = to;
    return a;
}

static void beginChanges(void) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
}

static void commitChanges(void) {
    [CATransaction commit];
    [CATransaction flush];
}

static bool makeWindow(void) {
    CGRect frame = { CGPointZero, { 1, 1 } }, none = CGRectZero;
    CFTypeRef region = NULL, opaque = NULL;
    CGSNewRegionWithRect(&frame, &region);
    CGSNewRegionWithRect(&none, &opaque);
    beginChanges();
    context = [[CAContext contextWithCGSConnection:(uint32_t)cid options:@{}] retain];
    root = [[CALayer alloc] init];
    root.geometryFlipped = YES;
    root.masksToBounds = YES;
    context.layer = root;
    commitChanges();
    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    if (region && opaque) {
        SLSNewWindowWithOpaqueShapeAndContext(cid, 3, region, opaque, 13, &tags, -9999, -9999, 64, &wid, context);
    }
    if (region) CFRelease(region);
    if (opaque) CFRelease(opaque);
    if (!wid) {
        [root release];
        [context release];
        root = nil;
        context = nil;
        return false;
    }
    SLSSetWindowTags(cid, wid, &tags, 64);
    SLSSetWindowOpacity(cid, wid, false);
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
    return true;
}

// Fits the window to `frame` (only when it changes: reshaping is costly).
static void placeWindow(CGRect frame, double scale) {
    if (scale != placedScale) {
        SLSSetWindowResolution(cid, wid, scale);
        placedScale = scale;
    }
    if (CGRectEqualToRect(frame, placed)) return;
    CGRect shape = { CGPointZero, frame.size };
    CFTypeRef region = NULL;
    CGSNewRegionWithRect(&shape, &region);
    if (region) {
        SLSSetWindowShape(cid, wid, frame.origin.x, frame.origin.y, region);
        CFRelease(region);
    }
    CFTypeRef t = SLSTransactionCreate(cid);
    if (t) {
        SLSTransactionMoveWindowWithGroup(t, wid, frame.origin);
        CGAffineTransform transform = CGAffineTransformIdentity;
        transform.tx = -frame.origin.x;
        transform.ty = -frame.origin.y;
        SLSTransactionSetWindowTransform(t, wid, 0, 0, transform);
        SLSTransactionCommit(t, 0);
        CFRelease(t);
    }
    placed = frame;
}

static void orderWindow(bool in) {
    if (in == shown) return;
    CFTypeRef t = SLSTransactionCreate(cid);
    if (!t) return;
    if (in) {
        SLSTransactionSetWindowLevel(t, wid, OVERLAY_LEVEL);
        SLSTransactionOrderWindow(t, wid, ORDER_ABOVE, 0);
    } else {
        SLSTransactionOrderWindow(t, wid, ORDER_OUT, 0);
    }
    SLSTransactionCommit(t, 0);
    CFRelease(t);
    shown = in;
    atomic_store(&overlayShown, in);
    if (visibility) dispatch_source_merge_data(visibility, 1);
}

// Takes the slide's layers down, in a transaction of their own, flushed,
// before they're released (see border.m's releaseAll).
static void clearLayers(void) {
    beginChanges();
    for (CALayer *layer in [[root.sublayers copy] autorelease]) {
        [layer removeAllAnimations];
        for (CALayer *sub in layer.sublayers) [sub removeAllAnimations];
        [layer removeFromSuperlayer];
    }
    commitChanges();
}

// A layer showing `p` where it was on screen, relative to `frame`, moved
// by `offset`.
static CALayer *pictureLayer(Shot *p, CGRect frame, CGPoint offset) {
    CALayer *layer = [CALayer layer];
    layer.contents = (id)p->image;
    layer.frame = CGRectMake(p->bounds.origin.x - frame.origin.x + offset.x,
        p->bounds.origin.y - frame.origin.y + offset.y, p->bounds.size.width, p->bounds.size.height);
    return layer;
}

typedef struct {
    CGRect frame;   // the area that slides (a display's usable area)
    double scale;   // its backing scale
    int out, into;  // pictures leaving and arriving (0 for none)
    int still;      // a picture that stays put beneath them (0 for none)
    CGPoint toward; // unit direction the arriving one comes from, e.g. (1, 0): the right
    bool backdrop;  // over the wallpaper, hiding the windows beneath
    Motion motion;
} Slide;

// The plane both pictures ride (root holds it; nil between slides), how
// far it travels, and how it moves.
static CALayer *plane = nil;
static CGPoint travel = { 0, 0 };
static Motion slideMotion = { false, 0.2, 0.6, 800, 38 };

static void finish(void *unused) {
    (void)unused;
    if (settling != generation) return;
    shownCount = 0;
    clearLayers();
    plane = nil;
    orderWindow(false);
    // A stale wallpaper is taken again now, between slides.
    if (wallpaperMaxAge <= 0) return;
    for (int i = 0; i < wallpaperCount; i++) {
        if (CFAbsoluteTimeGetCurrent() - wallpapers[i].taken > wallpaperMaxAge) takeWallpaper(wallpapers[i].bounds);
    }
}

static CGPoint planeAt(double progress) {
    return CGPointMake(-travel.x * progress, -travel.y * progress);
}

// Puts the slide's layers up with the plane `progress` of the way along
// (0: as the switch starts). False if there's nothing to show.
static bool build(Slide s, double progress) {
    if (!wid && !makeWindow()) return false;
    generation++;
    clearLayers();
    plane = nil;
    Shot *out = s.out ? pictureFor(s.out) : NULL;
    Shot *into = s.into ? pictureFor(s.into) : NULL;
    if (!out && !into) {
        orderWindow(false);
        return false;
    }
    slideMotion = s.motion;

    travel = CGPointMake(s.toward.x * s.frame.size.width, s.toward.y * s.frame.size.height);
    beginChanges();
    root.frame = (CGRect){ CGPointZero, s.frame.size };
    root.backgroundColor = NULL;
    if (s.backdrop) {
        CGRect display = displayHolding(s.frame);
        Shot *wall = wallpaperFor(display);
        if (!wall) wall = takeWallpaper(display);
        if (wall) {
            [root addSublayer:pictureLayer(wall, s.frame, CGPointZero)];
        } else {
            root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        }
    }
    Shot *still = s.still ? pictureFor(s.still) : NULL;
    if (still) [root addSublayer:pictureLayer(still, s.frame, CGPointZero)];
    // Both pictures ride one plane, which moves the width (or height) of
    // the area: the leaving one off, the arriving one into place.
    plane = [CALayer layer];
    plane.frame = root.bounds;
    plane.anchorPoint = CGPointZero;
    plane.position = planeAt(progress);
    if (out) [plane addSublayer:pictureLayer(out, s.frame, CGPointZero)];
    if (into) [plane addSublayer:pictureLayer(into, s.frame, travel)];
    [root addSublayer:plane];
    commitChanges();

    placeWindow(s.frame, s.scale);
    orderWindow(true);
    return true;
}

// Moves the plane to `to` of the way along on the spring, starting at
// `velocity` (of the way along per second, positive towards all the way),
// then takes the slide down.
static void settle(double to, double velocity) {
    if (!plane) return;
    CGPoint from = ((CALayer *)plane.presentationLayer ?: plane).position;
    CGPoint end = planeAt(to);
    double distance = hypot(end.x - from.x, end.y - from.y);
    double length = hypot(travel.x, travel.y);
    double at = length > 0 ? -(from.x * travel.x + from.y * travel.y) / (length * length) : to;
    if (to < at) velocity = -velocity; // towards `to`
    double duration = 0;
    beginChanges();
    [plane removeAllAnimations];
    plane.position = end;
    if (distance >= 1 && length > 0) {
        // The velocity in distances to go per second, as CoreAnimation
        // takes it (an eased slide starts as it would from rest).
        CABasicAnimation *a = animate(slideMotion, positionKey,
            [NSValue valueWithBytes:&from objCType:@encode(CGPoint)],
            [NSValue valueWithBytes:&end objCType:@encode(CGPoint)], velocity * length / distance);
        [plane addAnimation:a forKey:slideKey];
        duration = a.duration;
    }
    commitChanges();
    settling = generation;
    dispatch_source_set_timer(settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
}

static void run(Slide s) {
    if (build(s, 0)) settle(1, 0);
}


// ---------------------------------------------------------------------------
// Retiles (#19, experimental.captureRetile; a prototype)
// ---------------------------------------------------------------------------

// A retile glides pictures of the tiles from where they were to where they
// go, over the wallpaper, while the windows themselves move at once beneath,
// as Hyprland draws a window's last frame while its tile animates and the
// app catches up with the new size.
//
// Each tile is a box that moves and resizes on the spring, clipping its
// picture, which stays at its own size: when the box outgrows it, the
// picture's last column and row stretch out to fill (edge stretch), so the
// window isn't scaled. Once the windows beneath have their new sizes, they
// are captured again and those pictures fade in over the old ones (a
// refresh), as the app's new frame would. New windows pop in at their
// tiles, growing from `popin` of their size as they fade in.
//
// Tiles don't overlap, so one capture of them all (about 40ms, as for one
// window) is cut into a picture of each: capturing each window on its own
// costs the 40ms each, and WindowServer takes captures one at a time, from
// one connection or several (measured: 4 windows, ~45ms together, ~160ms
// apart, ~160ms in parallel on four connections). A new window isn't in the
// first: it opened over the others, mid-way through macOS's own opening
// animation (drawn black in their pictures). It has a capture of its own
// straight after, once the overlay is up.

#define MAX_TILES 64

// When the windows are first captured again, and again after that for those
// not at their new size yet, up to MAX_REFRESHES times.
#define REFRESH_AFTER 0.08
#define REFRESH_AGAIN 0.05
#define MAX_REFRESHES 4

typedef struct {
    uint32_t wid;
    CGRect from, to; // on screen
    bool appear;     // new to the layout: pops in at `to`
    bool ring;       // drawn with its border ring (the real one is beneath)
    CGFloat color[4], width, radius;
} Tile;

static NSString *boundsKey = nil, *opacityKey = nil, *scaleKey = nil;

// The retile on show (while retileGeneration is the overlay's generation):
// its tiles, the box each is drawn in, and whether that shows a picture of
// the window at its new size yet.
static Tile shownTiles[MAX_TILES];
static CALayer *boxes[MAX_TILES];
static CALayer *rings[MAX_TILES]; // nil for a tile without one
static bool live[MAX_TILES];
static unsigned retileGeneration = 0;
static CGRect retileFrame;
static Motion retileMove, retileFade;
static double popScale = 0.8, retileHold = 0.05;
static double retileEnds = 0; // when it's taken down (CFAbsoluteTime)
static int refreshes = 0;
static dispatch_source_t refresher = NULL;

// Takes the retile down no sooner than `seconds` from now.
static void endNoSooner(double seconds) {
    double at = CFAbsoluteTimeGetCurrent() + seconds;
    if (at <= retileEnds) return;
    retileEnds = at;
    settling = generation;
    dispatch_source_set_timer(settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
}

// Moves `layer` (anchored at its top-left) from `from` to `to` as `m`
// moves; how long that takes.
static double glide(CALayer *layer, CGRect from, CGRect to, Motion m) {
    layer.anchorPoint = CGPointZero;
    layer.position = to.origin;
    layer.bounds = (CGRect){ CGPointZero, to.size };
    if (m.ease && m.duration <= 0) return 0;
    CABasicAnimation *move = animate(m, positionKey, [NSValue valueWithBytes:&from.origin objCType:@encode(CGPoint)],
        [NSValue valueWithBytes:&to.origin objCType:@encode(CGPoint)], 0);
    CGRect fromBounds = { CGPointZero, from.size }, toBounds = { CGPointZero, to.size };
    CABasicAnimation *size = animate(m, boundsKey, [NSValue valueWithBytes:&fromBounds objCType:@encode(CGRect)],
        [NSValue valueWithBytes:&toBounds objCType:@encode(CGRect)], 0);
    [layer addAnimation:move forKey:positionKey];
    [layer addAnimation:size forKey:boundsKey];
    return move.duration;
}

// Fades `layer` in as `m` moves; how long that takes.
static double fadeIn(CALayer *layer, Motion m) {
    layer.opacity = 1;
    if (m.ease && m.duration <= 0) return 0;
    CABasicAnimation *fade = animate(m, opacityKey, @0.0, @1.0, 0);
    [layer addAnimation:fade forKey:opacityKey];
    return fade.duration;
}

// A picture of the part `src` (on screen) of `image`, which covers `area`,
// at the top-left of its box, at its own size: its last column and row
// stretch out past its right and bottom edges, for the box to clip.
static CALayer *edgeStretched(CGImageRef image, CGRect area, CGRect src) {
    double sx = CGImageGetWidth(image) / area.size.width, sy = CGImageGetHeight(image) / area.size.height;
    CGRect px = CGRectIntegral(CGRectMake((src.origin.x - area.origin.x) * sx, (src.origin.y - area.origin.y) * sy,
        src.size.width * sx, src.size.height * sy));
    CGImageRef crop = CGImageCreateWithImageInRect(image, px);
    if (!crop) return nil;
    CGFloat w = CGImageGetWidth(crop), h = CGImageGetHeight(crop);
    CGFloat pw = src.size.width, ph = src.size.height, far = 1e4;
    CALayer *pic = [CALayer layer];
    pic.anchorPoint = CGPointZero;
    pic.frame = CGRectMake(0, 0, pw, ph);
    pic.contents = (id)crop;
    // The right column, the bottom row and the corner pixel, stretched.
    CGRect strips[3] = { { { w - 1, 0 }, { 1, h } }, { { 0, h - 1 }, { w, 1 } }, { { w - 1, h - 1 }, { 1, 1 } } };
    CGRect places[3] = { { { pw, 0 }, { far, ph } }, { { 0, ph }, { pw, far } }, { { pw, ph }, { far, far } } };
    for (int i = 0; i < 3; i++) {
        CGImageRef strip = CGImageCreateWithImageInRect(crop, strips[i]);
        if (!strip) continue;
        CALayer *edge = [CALayer layer];
        edge.frame = places[i];
        edge.contents = (id)strip;
        [pic addSublayer:edge];
        CGImageRelease(strip);
    }
    CGImageRelease(crop);
    return pic;
}

// Window `wid`'s corner radius as WindowServer has it, else `fallback`.
static CGFloat cornerRadius(uint32_t wid, CGFloat fallback) {
    CGFloat radius = 0;
    if (SLSWindowQueryWindows && SLSWindowQueryResultCopyWindows && SLSWindowIteratorAdvance
        && SLSWindowIteratorGetCornerRadii) {
        CFArrayRef list = slWindowList(wid);
        CFTypeRef query = SLSWindowQueryWindows(cid, list, 0);
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
    return radius > 0 ? radius : fallback;
}

// `r` grown by `by` on every side.
static CGRect outset(CGRect r, CGFloat by) {
    return CGRectInset(r, -by, -by);
}

// Tile `t`'s ring, as border.m draws it: `width` wide just outside the
// window, its inside following the window's corners.
static CALayer *ringLayer(const Tile *t) {
    CALayer *ring = [CALayer layer];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGColorRef color = CGColorCreate(space, t->color);
    CGColorSpaceRelease(space);
    ring.borderColor = color;
    CGColorRelease(color);
    ring.borderWidth = t->width;
    ring.cornerRadius = t->radius + t->width;
    return ring;
}

static bool near2(CGFloat a, CGFloat b) {
    return fabs(a - b) <= 2;
}

// Whether a window at `b` is where its tile `to` puts it, at its size.
static bool arrived(CGRect b, CGRect to) {
    return near2(b.origin.x, to.origin.x) && near2(b.origin.y, to.origin.y)
        && near2(b.size.width, to.size.width) && near2(b.size.height, to.size.height);
}

// Puts a picture of tile `i`, from `image` (covering `area`), in its box:
// a new tile with nothing shown yet pops in with it; otherwise it fades in
// over what's there. How long that takes.
static double showPicture(int i, CGImageRef image, CGRect area, CGRect b) {
    CALayer *box = boxes[i];
    CALayer *pic = edgeStretched(image, area, b);
    if (!pic) return 0;
    double took = 0;
    if (box.sublayers.count == 0) {
        [box addSublayer:pic];
        // The box and its ring pop in together.
        CALayer *parts[2] = { box, rings[i] };
        for (int k = 0; k < 2 && parts[k]; k++) {
            took = fmax(took, fadeIn(parts[k], retileFade));
            if (popScale < 1 && !(retileMove.ease && retileMove.duration <= 0)) {
                CABasicAnimation *grow = animate(retileMove, scaleKey, @(popScale), @1.0, 0);
                [parts[k] addAnimation:grow forKey:scaleKey];
                took = fmax(took, grow.duration);
            }
        }
    } else {
        [box addSublayer:pic];
        took = fadeIn(pic, retileFade);
    }
    return took;
}

// Captures the tiles chosen by `want` (not yet live, or new and not yet
// shown) as they are now, and shows each that has a picture. Their
// pictures count as live once the window is at its new place and size.
static void recapture(bool newOnly) {
    if (retileGeneration != generation || shownCount == 0) return;
    uint32_t wids[MAX_TILES];
    int which[MAX_TILES], n = 0;
    for (int i = 0; i < shownCount; i++) {
        if (live[i]) continue;
        if (newOnly && (!shownTiles[i].appear || boxes[i].sublayers.count)) continue;
        which[n] = i;
        wids[n++] = shownTiles[i].wid;
    }
    if (n == 0) return;
    CGRect bounds[MAX_TILES];
    for (int k = 0; k < n; k++) {
        if (SLSGetWindowBounds(cid, wids[k], &bounds[k]) != kCGErrorSuccess) bounds[k] = CGRectNull;
    }
    uint32_t sorted[MAX_TILES];
    memcpy(sorted, wids, sizeof(uint32_t) * n);
    CGRect area;
    CGImageRef image = capture(sorted, n, &area);
    if (!image) return;
    double took = 0;
    beginChanges();
    for (int k = 0; k < n; k++) {
        int i = which[k];
        CGRect b = CGRectIntersection(bounds[k], area);
        if (CGRectIsNull(b) || CGRectIsEmpty(b)) continue;
        bool there = arrived(bounds[k], shownTiles[i].to);
        // A refresh only shows windows that have their new size; a new
        // window pops in with whatever it has.
        if (!newOnly && !there && boxes[i].sublayers.count) continue;
        took = fmax(took, showPicture(i, image, area, b));
        live[i] = there;
    }
    commitChanges();
    CGImageRelease(image);
    endNoSooner(took + retileHold);
}

static void popInNew(void *context) {
    if ((unsigned)(uintptr_t)context != generation) return;
    recapture(true);
}

static void refresh(void *unused) {
    (void)unused;
    if (retileGeneration != generation) return;
    recapture(false);
    bool waiting = false;
    for (int i = 0; i < shownCount; i++) waiting |= !live[i];
    if (waiting && ++refreshes < MAX_REFRESHES) {
        dispatch_source_set_timer(refresher, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(REFRESH_AGAIN * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, 0);
        endNoSooner(REFRESH_AGAIN + 0.05 + retileHold);
    }
}

// Puts the tiles' pictures up where they are and glides them to where
// they go as `move` moves, then takes them down `hold` seconds after the
// last has settled (the apps redrawing at their new sizes). New tiles pop
// in from `pop` of their size, fading in as `fade` moves. False if there
// was nothing to take.
static bool retile(CGRect frame, double scale, Tile *tiles, int count, Motion move, Motion fade, double hold,
                   double pop) {
    if (count <= 0 || count > MAX_TILES || (!wid && !makeWindow())) return false;
    uint32_t wids[MAX_TILES];
    int captured = 0;
    for (int i = 0; i < count; i++) {
        if (!tiles[i].appear) wids[captured++] = tiles[i].wid;
    }
    CGRect area = CGRectNull;
    CGImageRef image = captured ? capture(wids, captured, &area) : NULL;
    if (captured && !image) return false;
    generation++;
    clearLayers();
    plane = nil;
    retileGeneration = generation;
    retileFrame = frame;
    retileMove = move;
    retileFade = fade;
    retileHold = hold;
    popScale = pop;
    retileEnds = 0;
    refreshes = 0;
    shownCount = count;
    memcpy(shownTiles, tiles, sizeof(Tile) * count);

    double took = 0;
    beginChanges();
    root.frame = (CGRect){ CGPointZero, frame.size };
    root.backgroundColor = NULL;
    CGRect display = displayHolding(frame);
    Shot *wall = wallpaperFor(display);
    if (!wall) wall = takeWallpaper(display);
    if (wall) {
        [root addSublayer:pictureLayer(wall, frame, CGPointZero)];
    } else {
        root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    }
    for (int i = 0; i < count; i++) {
        Tile *t = &shownTiles[i];
        t->radius = cornerRadius(t->wid, t->radius);
        CALayer *box = [CALayer layer];
        box.masksToBounds = YES;
        // The window's own corners: the picture's stretched edges are square.
        box.cornerRadius = t->radius;
        boxes[i] = box;
        CALayer *ring = t->ring && t->width > 0 ? ringLayer(t) : nil;
        rings[i] = ring;
        live[i] = false;
        CGRect to = CGRectOffset(t->to, -frame.origin.x, -frame.origin.y);
        CGFloat w = ring ? t->width : 0;
        if (t->appear) {
            // Empty and unseen until its own capture (popInNew).
            CGPoint middle = CGPointMake(CGRectGetMidX(to), CGRectGetMidY(to));
            box.anchorPoint = CGPointMake(0.5, 0.5);
            box.bounds = (CGRect){ CGPointZero, to.size };
            box.position = middle;
            box.opacity = 0;
            ring.anchorPoint = CGPointMake(0.5, 0.5);
            ring.bounds = (CGRect){ CGPointZero, outset(to, w).size };
            ring.position = middle;
            ring.opacity = 0;
        } else {
            CGRect src = image ? CGRectIntersection(t->from, area) : CGRectNull;
            CALayer *pic = CGRectIsNull(src) || CGRectIsEmpty(src) ? nil : edgeStretched(image, area, src);
            if (pic) [box addSublayer:pic];
            CGRect from = pic ? CGRectOffset(src, -frame.origin.x, -frame.origin.y) : to;
            took = fmax(took, glide(box, from, to, move));
            if (ring) glide(ring, outset(from, w), outset(to, w), move);
        }
        [root addSublayer:box];
        if (ring) [root addSublayer:ring];
    }
    commitChanges();
    if (image) CGImageRelease(image);

    placeWindow(frame, scale);
    orderWindow(true);
    endNoSooner(fmax(took, REFRESH_AFTER + 0.1) + hold);
    dispatch_async_f(queue, (void *)(uintptr_t)generation, popInNew);
    dispatch_source_set_timer(refresher, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(REFRESH_AFTER * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
    return true;
}

// ---------------------------------------------------------------------------
// Lua API
// ---------------------------------------------------------------------------

static CGRect readRect(lua_State *L, int index) {
    CGRect r = CGRectZero;
    if (lua_type(L, index) != LUA_TTABLE) return r;
    index = lua_absindex(L, index);
    lua_getfield(L, index, "x");
    lua_getfield(L, index, "y");
    lua_getfield(L, index, "w");
    lua_getfield(L, index, "h");
    r = CGRectMake(lua_tonumber(L, -4), lua_tonumber(L, -3), lua_tonumber(L, -2), lua_tonumber(L, -1));
    lua_pop(L, 4);
    return r;
}

static double numberField(lua_State *L, int index, const char *key, double fallback) {
    lua_getfield(L, index, key);
    double v = luaL_optnumber(L, -1, fallback);
    lua_pop(L, 1);
    return v;
}

// capture(key, {wid, ...}): one picture of the windows, kept under `key`
// (replacing the last). Waits for it (about 40ms): the caller is about to
// move them. True if there was anything to take.
static int l_capture(lua_State *L) {
    int key = (int)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    uint32_t list[128];
    int count = luaWindowIds(L, 2, list, 128);
    uint32_t *wids = list; // blocks can't take arrays
    __block bool took = false;
    dispatch_sync(queue, ^{
        Shot *p = pictureFor(key);
        if (p) dropPicture(p);
        if (count == 0) return;
        CGRect bounds;
        CGImageRef image = capture(wids, count, &bounds);
        if (!image) return;
        for (int i = 0; i < MAX_PICTURES; i++) {
            if (!pictures[i].image) {
                pictures[i] = (Shot){ key, image, bounds, CFAbsoluteTimeGetCurrent() };
                took = true;
                return;
            }
        }
        CGImageRelease(image);
    });
    lua_pushboolean(L, took);
    return 1;
}

// forget(key): drops the picture kept under `key`; forget(): every picture,
// wallpapers too (the displays changed).
static int l_forget(lua_State *L) {
    bool all = lua_isnoneornil(L, 1);
    int key = all ? 0 : (int)luaL_checkinteger(L, 1);
    dispatch_async(queue, ^{
        for (int i = 0; i < MAX_PICTURES; i++) {
            if (pictures[i].image && (all || pictures[i].key == key)) dropPicture(&pictures[i]);
        }
        if (all) {
            for (int i = 0; i < wallpaperCount; i++) dropPicture(&wallpapers[i]);
            wallpaperCount = 0;
        }
    });
    return 0;
}

// wallpaper({x, y, w, h}): takes the wallpaper of the display with those
// full bounds ahead of its first slide, without waiting.
static int l_wallpaper(lua_State *L) {
    CGRect display = readRect(L, 1);
    dispatch_async(queue, ^{
        if (!wallpaperFor(display)) takeWallpaper(display);
    });
    return 0;
}

// The motion in the table at `index` (curve = "spring" or "ease",
// duration =, mass =, stiffness =, damping =), `fallback` for what it leaves out.
static Motion readMotion(lua_State *L, int index, Motion fallback) {
    Motion m = fallback;
    if (lua_type(L, index) != LUA_TTABLE) return m;
    index = lua_absindex(L, index);
    lua_getfield(L, index, "curve");
    if (lua_type(L, -1) == LUA_TSTRING) m.ease = strcmp(lua_tostring(L, -1), "ease") == 0;
    lua_pop(L, 1);
    m.duration = numberField(L, index, "duration", m.duration);
    m.mass = numberField(L, index, "mass", m.mass);
    m.stiffness = numberField(L, index, "stiffness", m.stiffness);
    m.damping = numberField(L, index, "damping", m.damping);
    return m;
}

// A slide as run() and begin() take it.
static Slide readSlide(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    Slide s;
    lua_getfield(L, 1, "frame");
    s.frame = readRect(L, -1);
    lua_pop(L, 1);
    s.scale = numberField(L, 1, "scale", 1);
    s.out = (int)numberField(L, 1, "out", 0);
    s.into = (int)numberField(L, 1, "into", 0);
    s.still = (int)numberField(L, 1, "still", 0);
    s.toward = CGPointMake(numberField(L, 1, "dx", 0), numberField(L, 1, "dy", 0));
    lua_getfield(L, 1, "backdrop");
    s.backdrop = lua_toboolean(L, -1);
    lua_pop(L, 1);
    s.motion = readMotion(L, 1, defaultMotion);
    wallpaperMaxAge = numberField(L, 1, "wallpaperAge", 0);
    return s;
}

// run{ frame = {x, y, w, h}, scale =, out = key, into = key, still = key,
// dx =, dy =, backdrop =, curve =, duration =, mass =, stiffness =,
// damping =, wallpaperAge = }:
// slides `out` away and `into` in from the side (dx, dy) over `frame`,
// above `still`, then gets out of the way. The window is up before this
// returns, so the windows beneath can move.
static int l_run(lua_State *L) {
    Slide s = readSlide(L);
    if (CGRectIsEmpty(s.frame)) return 0;
    dispatch_sync(queue, ^{ run(s); });
    return 0;
}

// begin{ as run }: puts the slide up without moving it, for track() to
// move (a swipe). True if there's anything to show.
static int l_begin(lua_State *L) {
    Slide s = readSlide(L);
    __block bool up = false;
    if (!CGRectIsEmpty(s.frame)) dispatch_sync(queue, ^{ up = build(s, 0); });
    lua_pushboolean(L, up);
    return 1;
}

// track(progress): the slide begun is `progress` of the way along (0 to 1),
// at once. Only the latest of a burst is drawn.
static _Atomic double tracked = 0;
static atomic_bool trackQueued = false;

static void trackNow(void *unused) {
    (void)unused;
    atomic_store(&trackQueued, false);
    if (!plane) return;
    beginChanges();
    plane.position = planeAt(atomic_load(&tracked));
    commitChanges();
}

static int l_track(lua_State *L) {
    atomic_store(&tracked, luaL_checknumber(L, 1));
    if (!atomic_exchange(&trackQueued, true)) dispatch_async_f(queue, NULL, trackNow);
    return 0;
}

// finish(to, velocity): the slide begun springs on to `to` (1 all the way,
// 0 back), starting at `velocity` (of the way along per second), and goes.
static int l_finish(lua_State *L) {
    double to = luaL_checknumber(L, 1), velocity = luaL_optnumber(L, 2, 0);
    dispatch_async(queue, ^{ settle(to, velocity); });
    return 0;
}

// retile{ frame = {x, y, w, h}, scale =, move = motion, fade = motion,
// hold =, popin = (0.8: new tiles grow from that share of their size; 1
// only fades them in), wallpaperAge =, (a motion as run() takes it: curve =, duration =,
// mass =, stiffness =, damping =)
// tiles = { { wid =, from = {x, y, w, h}, to = {...}, appear =, ring = { color =
// {r, g, b, a}, width =, radius = } }, ... } }:
// glides the tiles' pictures from `from` to `to` (and fades those that
// `appear` in at `to`) over `frame`, then gets out of the
// way. Waits for the capture (about 40ms) and puts the overlay up before
// returning, so the windows beneath can move. True if it's up.
static int l_retile(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "frame");
    CGRect frame = readRect(L, -1);
    lua_pop(L, 1);
    double scale = numberField(L, 1, "scale", 1);
    lua_getfield(L, 1, "move");
    Motion move = readMotion(L, -1, defaultMotion);
    lua_getfield(L, 1, "fade");
    Motion fade = readMotion(L, -1, move);
    lua_pop(L, 2);
    double hold = numberField(L, 1, "hold", 0.05);
    double pop = numberField(L, 1, "popin", 0.8);
    wallpaperMaxAge = numberField(L, 1, "wallpaperAge", 0);
    static Tile tiles[MAX_TILES];
    int count = 0;
    lua_getfield(L, 1, "tiles");
    if (lua_type(L, -1) == LUA_TTABLE) {
        lua_Integer n = luaL_len(L, -1);
        for (lua_Integer i = 1; i <= n && count < MAX_TILES; i++) {
            lua_rawgeti(L, -1, i);
            uint32_t w = (uint32_t)numberField(L, -1, "wid", 0);
            lua_getfield(L, -1, "appear");
            bool popIn = lua_toboolean(L, -1);
            lua_pop(L, 1);
            lua_getfield(L, -1, "from");
            CGRect from = readRect(L, -1);
            lua_getfield(L, -2, "to");
            CGRect to = readRect(L, -1);
            lua_pop(L, 2);
            Tile t = { w, from, to, popIn, false, { 0, 0, 0, 0 }, 0, 0 };
            lua_getfield(L, -1, "ring");
            if (lua_type(L, -1) == LUA_TTABLE) {
                t.ring = true;
                t.width = numberField(L, -1, "width", 0);
                t.radius = numberField(L, -1, "radius", 0);
                lua_getfield(L, -1, "color");
                for (int c = 0; c < 4; c++) {
                    lua_rawgeti(L, -1, c + 1);
                    t.color[c] = luaL_optnumber(L, -1, c == 3 ? 1 : 0);
                    lua_pop(L, 1);
                }
                lua_pop(L, 1);
            }
            lua_pop(L, 2); // the ring and the tile
            if (w && !CGRectIsEmpty(from) && !CGRectIsEmpty(to)) tiles[count++] = t;
        }
    }
    lua_pop(L, 1);
    __block bool up = false;
    Tile *list = tiles;
    if (!CGRectIsEmpty(frame) && count > 0) dispatch_sync(queue, ^{ up = retile(frame, scale, list, count, move, fade, hold, pop); });
    lua_pushboolean(L, up);
    return 1;
}

static void releaseAll(void) {
    generation++;
    plane = nil;
    if (wid) {
        clearLayers();
        orderWindow(false);
        beginChanges();
        context.layer = nil;
        commitChanges();
        SLSReleaseWindow(cid, wid);
        if ([context respondsToSelector:@selector(invalidate)]) [context performSelector:@selector(invalidate)];
        [root release];
        [context release];
        root = nil;
        context = nil;
        wid = 0;
        placed = CGRectZero;
        placedScale = 0;
    }
    for (int i = 0; i < MAX_PICTURES; i++) dropPicture(&pictures[i]);
    for (int i = 0; i < wallpaperCount; i++) dropPicture(&wallpapers[i]);
    wallpaperCount = 0;
}

// Collected with the Lua state (reload, quit), before Lua unloads the
// library: the queue is drained, and a pending finish cancelled.
static int l_gc(lua_State *L) {
    (void)L;
    luaCallbackClear(&onChange);
    dispatch_sync(queue, ^{
        dispatch_source_cancel(settled);
        dispatch_release(settled);
        settled = NULL;
        dispatch_source_cancel(refresher);
        dispatch_release(refresher);
        refresher = NULL;
        releaseAll();
        if (drain) {
            dispatch_source_cancel(drain);
            dispatch_release(drain);
            drain = NULL;
        }
    });
    dispatch_source_cancel(visibility);
    dispatch_release(visibility);
    visibility = NULL;
    dispatch_release(queue);
    queue = NULL;
    SLSReleaseConnection(cid);
    return 0;
}

int luaopen_hyprspoon_native_slide(lua_State *L) {
    const char *missing = loadSymbols();
    if (missing) return luaL_error(L, "hyprspoon.native.slide: SkyLight has no %s", missing);
    if (!positionKey) {
        positionKey = [[NSString alloc] initWithUTF8String:"position"];
        slideKey = [[NSString alloc] initWithUTF8String:"slide"];
        boundsKey = [[NSString alloc] initWithUTF8String:"bounds"];
        opacityKey = [[NSString alloc] initWithUTF8String:"opacity"];
        scaleKey = [[NSString alloc] initWithUTF8String:"transform.scale"];
    }
    if (SLSNewConnection(0, &cid) != kCGErrorSuccess) return luaL_error(L, "hyprspoon.native.slide: no WindowServer connection");
    queue = dispatch_queue_create("hyprspoon.slide",
        dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    drainPort = MACH_PORT_NULL;
    if (SLSGetEventPort(cid, &drainPort) == kCGErrorSuccess && drainPort != MACH_PORT_NULL) {
        drain = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, drainPort, 0, queue);
        dispatch_source_set_event_handler_f(drain, drainEvents);
        dispatch_resume(drain);
        dispatch_async_f(queue, NULL, drainEvents);
    }
    visibility = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler_f(visibility, notifyVisibility);
    dispatch_resume(visibility);
    atomic_store(&overlayShown, false);
    settled = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(settled, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler_f(settled, finish);
    dispatch_resume(settled);
    refresher = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(refresher, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler_f(refresher, refresh);
    dispatch_resume(refresher);
    shownCount = 0;
    retileGeneration = 0;
    memset(pictures, 0, sizeof(pictures));
    wallpaperCount = 0;
    wid = 0;
    shown = false;
    placed = CGRectZero;
    placedScale = 0;

    static const luaL_Reg funcs[] = {
        { "onChange", l_onChange },
        { "capture", l_capture },
        { "forget", l_forget },
        { "wallpaper", l_wallpaper },
        { "run", l_run },
        { "begin", l_begin },
        { "track", l_track },
        { "finish", l_finish },
        { "retile", l_retile },
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
