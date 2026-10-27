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

static const char *loadSymbols(void) {
    slOpen();
    SL_FUNCS(SL_LOAD)
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

static NSString *positionKey = nil, *slideKey = nil;

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
    double mass, stiffness, damping;
} Slide;

// The plane both pictures ride (root holds it; nil between slides), how
// far it travels, and the spring that moves it.
static CALayer *plane = nil;
static CGPoint travel = { 0, 0 };
static double springMass = 1, springStiffness = 800, springDamping = 50;

static void finish(void *unused) {
    (void)unused;
    if (settling != generation) return;
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
    springMass = s.mass;
    springStiffness = s.stiffness;
    springDamping = s.damping;

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
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:positionKey];
        spring.mass = springMass;
        spring.stiffness = springStiffness;
        spring.damping = springDamping;
        // In distances to go per second, as CoreAnimation takes it.
        spring.initialVelocity = velocity * length / distance;
        spring.fromValue = [NSValue valueWithBytes:&from objCType:@encode(CGPoint)];
        spring.toValue = [NSValue valueWithBytes:&end objCType:@encode(CGPoint)];
        spring.duration = spring.settlingDuration;
        [plane addAnimation:spring forKey:slideKey];
        duration = spring.duration;
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
    s.mass = numberField(L, 1, "mass", 1);
    s.stiffness = numberField(L, 1, "stiffness", 800);
    s.damping = numberField(L, 1, "damping", 50);
    wallpaperMaxAge = numberField(L, 1, "wallpaperAge", 0);
    return s;
}

// run{ frame = {x, y, w, h}, scale =, out = key, into = key, still = key,
// dx =, dy =, backdrop =, mass =, stiffness =, damping =, wallpaperAge = }:
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
    dispatch_sync(queue, ^{
        dispatch_source_cancel(settled);
        dispatch_release(settled);
        settled = NULL;
        releaseAll();
        if (drain) {
            dispatch_source_cancel(drain);
            dispatch_release(drain);
            drain = NULL;
        }
    });
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
    settled = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(settled, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler_f(settled, finish);
    dispatch_resume(settled);
    memset(pictures, 0, sizeof(pictures));
    wallpaperCount = 0;
    wid = 0;
    shown = false;
    placed = CGRectZero;
    placedScale = 0;

    static const luaL_Reg funcs[] = {
        { "capture", l_capture },
        { "forget", l_forget },
        { "wallpaper", l_wallpaper },
        { "run", l_run },
        { "begin", l_begin },
        { "track", l_track },
        { "finish", l_finish },
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
