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
#import <ImageIO/ImageIO.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lift.h"
#include "luacall.h"
#include "skylight.h"
#include "slide_internal.h"

#define SL_FUNCS(X)                                                                    \
    X(CGError, SLSNewConnection, (int, int *))                                         \
    X(int, SLSMainConnectionID, (void))                                                \
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
// one through the day, and says nothing. Set by run(), begin(), retile().
static _Atomic double wallpaperMaxAge = 0;

static bool validRect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y)
        && isfinite(r.size.width) && isfinite(r.size.height)
        && r.size.width > 0 && r.size.height > 0;
}

static void cancelDrain(dispatch_source_t *source) {
    if (!*source) return;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_source_set_cancel_handler(*source, ^{ dispatch_semaphore_signal(done); });
    dispatch_source_cancel(*source);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_release(done);
    dispatch_release(*source);
    *source = NULL;
}

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

static void drainConnection(int connection, mach_port_t port) {
    struct {
        mach_msg_header_t header;
        char body[4096];
    } message;
    for (;;) {
        mach_msg_return_t r = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(message),
            port, 0, MACH_PORT_NULL);
        if (r == MACH_MSG_SUCCESS) mach_msg_destroy(&message.header);
        else if (r != MACH_RCV_TOO_LARGE) break;
    }
    CGEventRef event;
    while ((event = SLEventCreateNextEvent(connection))) CFRelease(event);
}

static void drainEvents(void *unused) {
    (void)unused;
    drainConnection(cid, drainPort);
}

// ---------------------------------------------------------------------------
// Pictures
// ---------------------------------------------------------------------------

// Shot is defined in slide_internal.h.

static void copyMonitor(char dst[MONITOR_ID_MAX], const char *src) {
    if (!src || !src[0]) {
        dst[0] = '\0';
        return;
    }
    strncpy(dst, src, MONITOR_ID_MAX - 1);
    dst[MONITOR_ID_MAX - 1] = '\0';
}

static bool sameMonitor(const char *a, const char *b) {
    const char *sa = a ? a : "";
    const char *sb = b ? b : "";
    return strcmp(sa, sb) == 0;
}

#define MAX_PICTURES 64
static Shot pictures[MAX_PICTURES];

// Per-window thumbnail cache for overview (kept per monitor across opens and
// display switches so each display keeps its own thumbnails without extra
// captures). Hidden workspaces also reuse `pictures[]` directly.
#define MAX_THUMBS 96
static Thumb thumbs[MAX_THUMBS];

void slideThumbStore(const char *monitor, uint32_t target, CGImageRef image, CGRect area, CGRect src) {
    if (!target || !image || !validRect(area) || !validRect(src)) return;
    int slot = -1, oldest = 0;
    for (int i = 0; i < MAX_THUMBS; i++) {
        if (thumbs[i].wid == target && sameMonitor(thumbs[i].monitor, monitor)) { slot = i; break; }
        if (!thumbs[i].image && slot < 0) slot = i;
        if (thumbs[i].image && thumbs[i].taken < thumbs[oldest].taken) oldest = i;
    }
    if (slot < 0) slot = oldest;
    CGImageRetain(image);
    if (thumbs[slot].image) CGImageRelease(thumbs[slot].image);
    memset(&thumbs[slot], 0, sizeof(thumbs[slot]));
    thumbs[slot].wid = target;
    copyMonitor(thumbs[slot].monitor, monitor);
    thumbs[slot].image = image;
    thumbs[slot].area = area;
    thumbs[slot].src = src;
    thumbs[slot].taken = CFAbsoluteTimeGetCurrent();
}

Thumb *slideThumbLookup(const char *monitor, uint32_t target) {
    // 1. Exact monitor match in thumbs[].
    for (int i = 0; i < MAX_THUMBS; i++) {
        if (thumbs[i].wid == target && thumbs[i].image && sameMonitor(thumbs[i].monitor, monitor)) return &thumbs[i];
    }
    // 2. Exact monitor match in workspace pictures[].
    static Thumb fromShot;
    for (int i = 0; i < MAX_PICTURES; i++) {
        Shot *p = &pictures[i];
        if (!p->image || p->winCount <= 0 || !sameMonitor(p->monitor, monitor)) continue;
        for (int k = 0; k < p->winCount; k++) {
            if (p->wids[k] == target) {
                memset(&fromShot, 0, sizeof(fromShot));
                fromShot.wid = target;
                copyMonitor(fromShot.monitor, p->monitor);
                fromShot.image = p->image;
                fromShot.area = p->bounds;
                fromShot.src = p->winRects[k];
                fromShot.taken = p->taken;
                return &fromShot;
            }
        }
    }
    // 3. Overview fallback: any monitor's cached thumbnail for this window.
    if (monitor && monitor[0]) {
        Thumb *best = NULL;
        for (int i = 0; i < MAX_THUMBS; i++) {
            if (thumbs[i].wid == target && thumbs[i].image
                && (!best || thumbs[i].taken > best->taken)) {
                best = &thumbs[i];
            }
        }
        if (best) return best;
        for (int i = 0; i < MAX_PICTURES; i++) {
            Shot *p = &pictures[i];
            if (!p->image || p->winCount <= 0) continue;
            for (int k = 0; k < p->winCount; k++) {
                if (p->wids[k] == target) {
                    memset(&fromShot, 0, sizeof(fromShot));
                    fromShot.wid = target;
                    copyMonitor(fromShot.monitor, p->monitor);
                    fromShot.image = p->image;
                    fromShot.area = p->bounds;
                    fromShot.src = p->winRects[k];
                    fromShot.taken = p->taken;
                    return &fromShot;
                }
            }
        }
    }
    return NULL;
}

void slideThumbForget(uint32_t target) {
    for (int i = 0; i < MAX_THUMBS; i++) {
        if (thumbs[i].wid == target) {
            if (thumbs[i].image) CGImageRelease(thumbs[i].image);
            memset(&thumbs[i], 0, sizeof(thumbs[i]));
        }
    }
}

void slideThumbForgetMonitor(const char *monitor) {
    if (!monitor || !monitor[0]) return;
    for (int i = 0; i < MAX_THUMBS; i++) {
        if (thumbs[i].image && sameMonitor(thumbs[i].monitor, monitor)) {
            CGImageRelease(thumbs[i].image);
            memset(&thumbs[i], 0, sizeof(thumbs[i]));
        }
    }
}

void slideThumbClear(void) {
    for (int i = 0; i < MAX_THUMBS; i++) {
        if (thumbs[i].image) CGImageRelease(thumbs[i].image);
        memset(&thumbs[i], 0, sizeof(thumbs[i]));
    }
}

// Wallpapers are kept apart, per monitor UUID (and size) so plugging/unplugging
// displays preserves each monitor's wallpaper across origin shifts.
#define MAX_WALLPAPERS 16
static Shot wallpapers[MAX_WALLPAPERS];
static int wallpaperCount = 0;

static Shot *pictureFor(const char *monitor, int key) {
    for (int i = 0; i < MAX_PICTURES; i++) {
        if (pictures[i].key == key && pictures[i].image && sameMonitor(pictures[i].monitor, monitor)) {
            return &pictures[i];
        }
    }
    return NULL;
}

static void dropPicture(Shot *p) {
    if (p->image) CGImageRelease(p->image);
    memset(p, 0, sizeof(*p));
}

// Takes ownership of `image` (caller transfers +1 ref). Replaces any existing
// picture for `(monitor, key)`, else uses a free slot or evicts the oldest.
static void storePictureOwned(const char *monitor, int key, CGImageRef image, CGRect bounds, CGRect display,
                              const uint32_t *wids, const CGRect *winRects, int winCount) {
    if (!key || !image || !validRect(bounds)) {
        if (image) CGImageRelease(image);
        return;
    }
    int slot = -1, oldest = 0;
    for (int i = 0; i < MAX_PICTURES; i++) {
        if (pictures[i].image && pictures[i].key == key && sameMonitor(pictures[i].monitor, monitor)) {
            slot = i;
            break;
        }
        if (!pictures[i].image && slot < 0) slot = i;
        if (pictures[i].image && pictures[i].taken < pictures[oldest].taken) oldest = i;
    }
    if (slot < 0) slot = oldest;
    dropPicture(&pictures[slot]);

    bool rel = validRect(display);
    pictures[slot].key = key;
    copyMonitor(pictures[slot].monitor, monitor);
    pictures[slot].image = image;
    pictures[slot].relative = rel;
    pictures[slot].bounds = rel ? CGRectOffset(bounds, -display.origin.x, -display.origin.y) : bounds;
    pictures[slot].taken = CFAbsoluteTimeGetCurrent();
    int n = winCount > MAX_SHOT_WINS ? MAX_SHOT_WINS : winCount;
    pictures[slot].winCount = n;
    for (int k = 0; k < n; k++) {
        pictures[slot].wids[k] = wids[k];
        pictures[slot].winRects[k] = rel ? CGRectOffset(winRects[k], -display.origin.x, -display.origin.y) : winRects[k];
    }
}

void slidePictureStore(const char *monitor, int key, CGImageRef image, CGRect bounds, CGRect display,
                       const uint32_t *wids, const CGRect *winRects, int winCount) {
    if (!key || !image || !validRect(bounds)) return;
    storePictureOwned(monitor, key, CGImageRetain(image), bounds, display, wids, winRects, winCount);
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

static bool isActiveDisplayBounds(CGRect display) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess) return false;
    for (uint32_t i = 0; i < count; i++) {
        if (CGRectEqualToRect(CGDisplayBounds(displays[i]), display)) return true;
    }
    return false;
}

// Keeps only the `wids` currently on screen, in their stacking order (front
// first: a capture stacks them in the order it's given, the first on top).
// Off-screen windows (another Space, native full screen, minimized, hidden)
// would otherwise expand the capture bounds and draw stale or solid-black
// backing behind the visible windows.
static int onScreenByStacking(uint32_t *wids, int count) {
    CFArrayRef list = CGWindowListCreate(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!list) return count;
    CFIndex n = CFArrayGetCount(list);
    CFIndex rank[count];
    int kept = 0;
    for (int i = 0; i < count; i++) {
        CFIndex r = -1;
        for (CFIndex j = 0; j < n; j++) {
            if ((uint32_t)(uintptr_t)CFArrayGetValueAtIndex(list, j) == wids[i]) {
                r = j;
                break;
            }
        }
        if (r >= 0) {
            wids[kept] = wids[i];
            rank[kept] = r;
            kept++;
        }
    }
    CFRelease(list);
    for (int i = 1; i < kept; i++) {
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
    return kept;
}

// One capture of `wids` together on `connection`, and where it covers
// (retained; NULL if there's nothing to see). With `stacked`, keep only
// on-screen windows and put them in their stacking order first; windows
// that don't overlap (tiles) needn't be. When `validRect(clip)` is true,
// excludes windows that aren't meaningfully on that display (>= 8x8pt) so
// windows parked or migrating on another display never widen the capture.
static CGImageRef captureOnClipped(int connection, uint32_t *wids, int count, CGRect clip,
                                   CGRect *bounds, bool stacked,
                                   int *outCount, uint32_t *outWids, CGRect *outRects, int maxOut) {
    if (stacked) {
        count = onScreenByStacking(wids, count);
        if (count == 0) return NULL;
    }
    bool hasClip = validRect(clip);
    CGRect screen = displaysBounds(), area = CGRectNull;
    uint32_t keptWids[128];
    int keptCount = 0;
    int recorded = 0;
    for (int i = 0; i < count && keptCount < 128; i++) {
        CGRect raw;
        if (SLSGetWindowBounds(connection, wids[i], &raw) != kCGErrorSuccess) continue;
        if (hasClip) {
            CGRect onDisplay = CGRectIntersection(raw, clip);
            if (CGRectIsNull(onDisplay) || onDisplay.size.width < 8 || onDisplay.size.height < 8) continue;
        }
        CGRect b = CGRectIntersection(raw, screen);
        if (!CGRectIsNull(b) && !CGRectIsEmpty(b)) {
            keptWids[keptCount++] = wids[i];
            area = CGRectUnion(area, b);
            if (outWids && outRects && recorded < maxOut) {
                outWids[recorded] = wids[i];
                outRects[recorded] = b;
                recorded++;
            }
        }
    }
    if (keptCount == 0 || CGRectIsNull(area) || CGRectIsEmpty(area)) return NULL;
    CFArrayRef list = SLSHWCaptureWindowList(connection, keptWids, keptCount, CAPTURE_NOMINAL);
    if (!list) return NULL;
    CGImageRef image = NULL;
    if (CFArrayGetCount(list) > 0) image = CGImageRetain((CGImageRef)CFArrayGetValueAtIndex(list, 0));
    CFRelease(list);
    *bounds = area;
    if (outCount) *outCount = recorded;
    return image;
}

static CGImageRef captureOn(int connection, uint32_t *wids, int count, CGRect *bounds, bool stacked) {
    return captureOnClipped(connection, wids, count, CGRectZero, bounds, stacked, NULL, NULL, NULL, 0);
}

// A capture of `wids` as they're stacked on screen, on the slide's connection.
static CGImageRef capture(uint32_t *wids, int count, CGRect *bounds) {
    return captureOn(cid, wids, count, bounds, true);
}

// The windows drawing the desktop of the display at `bounds`: the
// wallpaper, and Finder's icons over it (only when matching this display).
static int desktopWindows(CGRect bounds, uint32_t *out, int max) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!list) return 0;
    CGPoint middle = { CGRectGetMidX(bounds), CGRectGetMidY(bounds) };
    int32_t desktopLevel = CGWindowLevelForKey(kCGDesktopWindowLevelKey);
    int32_t iconLevel = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey);
    uint32_t wallpaper = 0, fallbackWallpaper = 0, icons = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
        int32_t layer = 0;
        uint32_t wid = 0;
        CFNumberRef n = CFDictionaryGetValue(info, kCGWindowLayer);
        if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &layer);
        if (layer > iconLevel) continue;
        n = CFDictionaryGetValue(info, kCGWindowNumber);
        if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &wid);
        if (!wid) continue;
        CGRect b = CGRectNull;
        CFDictionaryRef d = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!d || !CGRectMakeWithDictionaryRepresentation(d, &b) || !CGRectContainsPoint(b, middle)) continue;
        CFStringRef name = CFDictionaryGetValue(info, kCGWindowName);
        CFStringRef owner = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (layer <= desktopLevel) {
            if (!wallpaper && name && CFStringCompare(name, CFSTR("Wallpaper"), 0) == kCFCompareEqualTo) {
                wallpaper = wid;
            } else if (!fallbackWallpaper && name && CFStringHasPrefix(name, CFSTR("Desktop Picture"))) {
                fallbackWallpaper = wid;
            } else if (!fallbackWallpaper && owner && CFStringCompare(owner, CFSTR("Wallpaper"), 0) == kCFCompareEqualTo) {
                fallbackWallpaper = wid;
            }
        } else if (!icons && layer == iconLevel
                   && fabs(b.origin.x - bounds.origin.x) <= 2 && fabs(b.origin.y - bounds.origin.y) <= 2
                   && fabs(b.size.width - bounds.size.width) <= 2 && fabs(b.size.height - bounds.size.height) <= 2) {
            icons = wid;
        }
    }
    CFRelease(list);
    if (!wallpaper) wallpaper = fallbackWallpaper;
    if (!wallpaper) return 0; // never capture transparent Finder icons without a wallpaper
    int count = 0;
    if (count < max) out[count++] = wallpaper;
    if (icons && count < max) out[count++] = icons;
    return count;
}

// Downsamples `image` to 8x8 RGBA8 (~5us) to detect a completely transparent
// or solid-black capture (which macOS can emit briefly during display wake /
// reconfiguration).
static void inspectWallpaperImage(CGImageRef image, bool *allTransparent, bool *allBlack) {
    *allTransparent = true;
    *allBlack = true;
    if (!image) return;
    uint8_t pixels[8 * 8 * 4];
    memset(pixels, 0, sizeof(pixels));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, 8, 8, 8, 8 * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        *allTransparent = false;
        *allBlack = false;
        return;
    }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 8, 8), image);
    CGContextRelease(ctx);
    for (int i = 0; i < 64; i++) {
        uint8_t r = pixels[i * 4 + 0];
        uint8_t g = pixels[i * 4 + 1];
        uint8_t b = pixels[i * 4 + 2];
        uint8_t a = pixels[i * 4 + 3];
        if (a > 0) *allTransparent = false;
        if (r > 3 || g > 3 || b > 3) *allBlack = false;
    }
}

static CGImageRef loadWallpaperImageFile(const char *path) {
    if (!path || !path[0]) return NULL;
    NSString *nsPath = [NSString stringWithUTF8String:path];
    if (!nsPath) return NULL;
    NSURL *url = [NSURL fileURLWithPath:nsPath];
    CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;
}

static bool sameSize2(CGSize a, CGSize b) {
    return fabs(a.width - b.width) <= 2 && fabs(a.height - b.height) <= 2;
}

static Shot *wallpaperFor(const char *monitor, CGRect display) {
    bool hasMon = monitor && monitor[0];
    for (int i = 0; i < wallpaperCount; i++) {
        if (!wallpapers[i].image) continue;
        if (hasMon) {
            if (sameMonitor(wallpapers[i].monitor, monitor) && sameSize2(wallpapers[i].bounds.size, display.size)) {
                wallpapers[i].lastDisplay = display;
                return &wallpapers[i];
            }
        } else if (!wallpapers[i].relative && CGRectEqualToRect(wallpapers[i].bounds, display)) {
            wallpapers[i].lastDisplay = display;
            return &wallpapers[i];
        } else if (wallpapers[i].relative && CGRectEqualToRect(wallpapers[i].lastDisplay, display)) {
            return &wallpapers[i];
        }
    }
    return NULL;
}

static Shot *allocWallpaperSlot(const char *monitor, CGRect display) {
    Shot *p = wallpaperFor(monitor, display);
    if (p) return p;
    for (int i = 0; i < wallpaperCount; i++) {
        if (!wallpapers[i].image) {
            memset(&wallpapers[i], 0, sizeof(wallpapers[i]));
            return &wallpapers[i];
        }
    }
    if (wallpaperCount < MAX_WALLPAPERS) {
        p = &wallpapers[wallpaperCount++];
        memset(p, 0, sizeof(*p));
        return p;
    }
    int oldest = 0;
    for (int i = 1; i < wallpaperCount; i++) {
        if (wallpapers[i].taken < wallpapers[oldest].taken) oldest = i;
    }
    dropPicture(&wallpapers[oldest]);
    return &wallpapers[oldest];
}

// Takes the wallpaper of the display `monitor` at `display` (its full bounds),
// falling back to `fallbackPath` (desktopImageURL) if live capture fails or
// returns a transient black/transparent frame during display reconfiguration.
// Never overwrites an existing non-black wallpaper with a failed/blank/black capture.
static Shot *takeWallpaper(const char *monitor, CGRect display, const char *fallbackPath) {
    if (!validRect(display)) return NULL;
    Shot *existing = wallpaperFor(monitor, display);
    uint32_t wids[2];
    int count = desktopWindows(display, wids, 2);
    CGRect bounds = display;
    CGImageRef image = count ? capture(wids, count, &bounds) : NULL;
    bool transparent = false, black = false;
    if (image) {
        inspectWallpaperImage(image, &transparent, &black);
        if (transparent) {
            CGImageRelease(image);
            image = NULL;
        }
    }
    bool isFallback = false;
    if (!image || black) {
        // Keep an already-valid non-black wallpaper (live or file) over a
        // transient failed/black capture during display wake or switch.
        if (existing && existing->image && !existing->black) {
            if (image) CGImageRelease(image);
            existing->lastDisplay = display;
            return existing;
        }
        CGImageRef fileImg = loadWallpaperImageFile(fallbackPath);
        if (fileImg) {
            if (image) CGImageRelease(image);
            image = fileImg;
            bounds = display;
            black = false;
            isFallback = true;
        } else if (!image) {
            return (existing && existing->image) ? existing : NULL;
        }
    }
    Shot *p = allocWallpaperSlot(monitor, display);
    if (p->image) CGImageRelease(p->image);
    p->image = image;
    copyMonitor(p->monitor, monitor);
    p->relative = true;
    p->bounds = (CGRect){ CGPointZero, display.size };
    p->lastDisplay = display;
    p->fallback = isFallback;
    p->black = black;
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

// Motion is defined in slide_internal.h.

static const Motion defaultMotion = { false, 0.2, 0.6, 800, 38 };

// The retile on show (see Retiles below) while the overlay's generation is
// retileGeneration: how its tiles move, and how new ones and its handover
// fade, and how it refreshes its pictures mid-glide (retileRefresh).
static unsigned retileGeneration = 0;
static Motion retileMove, retileFade;
enum { REFRESH_OFF, REFRESH_ONCE, REFRESH_LIVE };
static int retileRefresh = REFRESH_OFF;
static double glideEnds = 0; // when its last glide settles (CFAbsoluteTime)
static bool fadingOut = false; // the overlay fading to the windows beneath
static NSString *boundsKey = nil, *sizeKey = nil, *opacityKey = nil, *scaleKey = nil;

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

// A window of our own on `connection`, off screen until placed, showing
// `*layerOut` (origin top-left) through `*contextOut`; 0 if it can't be made.
static uint32_t newOverlay(int connection, CAContext **contextOut, CALayer **layerOut) {
    CGRect frame = { CGPointZero, { 1, 1 } }, none = CGRectZero;
    CFTypeRef region = NULL, opaque = NULL;
    CGSNewRegionWithRect(&frame, &region);
    CGSNewRegionWithRect(&none, &opaque);
    beginChanges();
    CAContext *context = [[CAContext contextWithCGSConnection:(uint32_t)connection options:@{}] retain];
    CALayer *root = [[CALayer alloc] init];
    root.geometryFlipped = YES;
    root.masksToBounds = YES;
    context.layer = root;
    commitChanges();
    uint64_t tags = (1ULL << 1) | (1ULL << 9);
    uint32_t wid = 0;
    if (region && opaque) {
        SLSNewWindowWithOpaqueShapeAndContext(connection, 3, region, opaque, 13, &tags, -9999, -9999, 64, &wid, context);
    }
    if (region) CFRelease(region);
    if (opaque) CFRelease(opaque);
    if (!wid) {
        beginChanges();
        context.layer = nil;
        commitChanges();
        if ([context respondsToSelector:@selector(invalidate)]) [context performSelector:@selector(invalidate)];
        [root release];
        [context release];
        return 0;
    }
    SLSSetWindowTags(connection, wid, &tags, 64);
    SLSSetWindowOpacity(connection, wid, false);
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
    *contextOut = context;
    *layerOut = root;
    return wid;
}

static bool makeWindow(void) {
    wid = newOverlay(cid, &context, &root);
    return wid != 0;
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
// by `offset`. Display-relative shots are anchored to `display.origin`.
static CALayer *pictureLayer(Shot *p, CGRect frame, CGRect display, CGPoint offset) {
    CALayer *layer = [CALayer layer];
    layer.contents = (id)p->image;
    CGFloat x = p->relative ? (display.origin.x + p->bounds.origin.x - frame.origin.x + offset.x)
                            : (p->bounds.origin.x - frame.origin.x + offset.x);
    CGFloat y = p->relative ? (display.origin.y + p->bounds.origin.y - frame.origin.y + offset.y)
                            : (p->bounds.origin.y - frame.origin.y + offset.y);
    layer.frame = CGRectMake(x, y, p->bounds.size.width, p->bounds.size.height);
    if (p->fallback) {
        layer.contentsGravity = kCAGravityResizeAspectFill;
        layer.masksToBounds = YES;
    }
    return layer;
}

typedef struct {
    char monitor[MONITOR_ID_MAX];
    CGRect frame;     // the area that slides (a display's usable area)
    CGRect fullFrame; // the display's full bounds (optional; falls back to displayHolding)
    double scale;     // its backing scale
    int out, into;    // pictures leaving and arriving (0 for none)
    int still;        // a picture that stays put beneath them (0 for none)
    CGPoint toward;   // unit direction the arriving one comes from, e.g. (1, 0): the right
    bool backdrop;    // over the wallpaper, hiding the windows beneath
    char wallpaperPath[512]; // optional file fallback when live wallpaper capture isn't ready
    Motion motion;
} Slide;

// The plane both pictures ride (root holds it; nil between slides), how
// far it travels, and how it moves.
static CALayer *plane = nil;
static CGPoint travel = { 0, 0 };
static Motion slideMotion = { false, 0.2, 0.6, 800, 38 };

static void dropBeneath(void);
static void keepGone(void);

static void finish(void *unused) {
    (void)unused;
    if (settling != generation) return;
    // A retile hands over by fading to the windows beneath, in place by
    // now: the stretched pictures turn into the real windows in one change.
    if (shownCount > 0 && retileGeneration == generation && !fadingOut
        && !(retileFade.ease && retileFade.duration <= 0)) {
        fadingOut = true;
        beginChanges();
        CABasicAnimation *fade = animate(retileFade, opacityKey, @1.0, @0.0, 0);
        root.opacity = 0;
        [root addAnimation:fade forKey:opacityKey];
        commitChanges();
        dispatch_source_set_timer(settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fade.duration * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, 0);
        return;
    }
    fadingOut = false;
    keepGone();
    shownCount = 0;
    clearLayers();
    plane = nil;
    orderWindow(false);
    dropBeneath();
    beginChanges();
    [root removeAnimationForKey:opacityKey];
    root.opacity = 1;
    commitChanges();
    // A stale wallpaper is taken again now, between slides (active displays only).
    double maxAge = atomic_load(&wallpaperMaxAge);
    if (maxAge <= 0) return;
    for (int i = 0; i < wallpaperCount; i++) {
        if (wallpapers[i].image && CFAbsoluteTimeGetCurrent() - wallpapers[i].taken > maxAge
            && validRect(wallpapers[i].lastDisplay) && isActiveDisplayBounds(wallpapers[i].lastDisplay)) {
            takeWallpaper(wallpapers[i].monitor, wallpapers[i].lastDisplay, NULL);
        }
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
    Shot *out = s.out ? pictureFor(s.monitor, s.out) : NULL;
    Shot *into = s.into ? pictureFor(s.monitor, s.into) : NULL;
    if (!out && !into) {
        orderWindow(false);
        return false;
    }
    slideMotion = s.motion;
    CGRect display = validRect(s.fullFrame) ? s.fullFrame : displayHolding(s.frame);

    travel = CGPointMake(s.toward.x * s.frame.size.width, s.toward.y * s.frame.size.height);
    beginChanges();
    // Not faded, as a retile handing over leaves it.
    fadingOut = false;
    [root removeAnimationForKey:opacityKey];
    root.opacity = 1;
    root.frame = (CGRect){ CGPointZero, s.frame.size };
    root.backgroundColor = NULL;
    if (s.backdrop) {
        Shot *wall = wallpaperFor(s.monitor, display);
        if (!wall) wall = takeWallpaper(s.monitor, display, s.wallpaperPath);
        if (wall) {
            [root addSublayer:pictureLayer(wall, s.frame, display, CGPointZero)];
        } else {
            root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        }
    }
    Shot *still = s.still ? pictureFor(s.monitor, s.still) : NULL;
    if (still) [root addSublayer:pictureLayer(still, s.frame, display, CGPointZero)];
    // Both pictures ride one plane, which moves the width (or height) of
    // the area: the leaving one off, the arriving one into place.
    plane = [CALayer layer];
    plane.frame = root.bounds;
    plane.anchorPoint = CGPointZero;
    plane.position = planeAt(progress);
    if (out) [plane addSublayer:pictureLayer(out, s.frame, display, CGPointZero)];
    if (into) [plane addSublayer:pictureLayer(into, s.frame, display, travel)];
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
// window is mirrored in a band at its edges and stretched past that (see
// edgeExtended), so it isn't scaled. Once it has settled, the overlay fades to the
// windows beneath, in place by then. With `refresh`, windows that have their
// new size are captured again mid-glide and fade in over the old pictures,
// as Hyprland shows an app's new frame; off by default, since macOS doesn't
// say when an app has finished drawing at its new size, and a picture taken
// mid-redraw shows as an extra jump. New windows pop in at their tiles,
// growing from `popin` of their size as they fade in.
//
// Tiles don't overlap, so one capture of them all (about 40ms, as for one
// window) is cut into a picture of each: capturing each window on its own
// costs the 40ms each, and WindowServer takes captures one at a time, from
// one connection or several (measured: 4 windows, ~45ms together, ~160ms
// apart, ~160ms in parallel on four connections). A new window isn't in the
// first: it opened over the others, mid-way through macOS's own opening
// animation (drawn black in their pictures). It has a capture of its own
// straight after, once the overlay is up.
//
// Scrolling columns (hyprspoon/scroll.lua) go out of sight and come back:
// a tile whose window is parked out of sight (`away`) has no picture to
// take. The picture of a tile that glided off the display is kept a while
// (MAX_KEPT, KEPT_MAX_AGE) for when it comes back, and glides in with
// that; without one it pops in at its tile once its window is there.

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
    bool away;       // its window is out of sight: no picture to take
    bool ring;       // drawn with its border ring (the real one is beneath)
    CGFloat color[4], width, radius;
} Tile;


// The retile on show (while retileGeneration is the overlay's generation):
// its tiles, the box each is drawn in, and whether that shows a picture of
// the window at its new size yet.
static Tile shownTiles[MAX_TILES];
static CALayer *boxes[MAX_TILES];
static CALayer *rings[MAX_TILES]; // nil for a tile without one
static bool live[MAX_TILES];
static char retileMonitor[MONITOR_ID_MAX] = "";
static CGRect retileFrame;
static double popScale = 0.8, retileHold = 0.05;
static double retileEnds = 0; // when it's taken down (CFAbsoluteTime)
static int refreshes = 0;
static dispatch_source_t refresher = NULL;
static dispatch_source_t popInTimer = NULL;
static unsigned popGeneration = 0;

// Takes the retile down no sooner than `seconds` from now.
static void endNoSooner(double seconds) {
    if (fadingOut) return;
    double at = CFAbsoluteTimeGetCurrent() + seconds;
    if (at <= retileEnds) return;
    retileEnds = at;
    settling = generation;
    dispatch_source_set_timer(settled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmax(0, seconds) * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
}

// Where `layer`'s anchor point is when its frame is `r`.
static CGPoint anchorAt(CALayer *layer, CGRect r) {
    return CGPointMake(r.origin.x + r.size.width * layer.anchorPoint.x,
        r.origin.y + r.size.height * layer.anchorPoint.y);
}

// Moves `layer` from `from` to `to` as `m` moves; how long that takes.
//
// Additively: the layer is put at `to` and drawn offset by `from - to`, an
// offset that goes to nothing. A retile carried on (`from` the frame the
// last one was taking it to) adds its own offset over the one still
// running, so the tile turns towards its new place without stopping: its
// speed carries on, as Hyprland's windows do when their target changes.
static double glide(CALayer *layer, CGRect from, CGRect to, Motion m) {
    CGPoint p0 = anchorAt(layer, from), p1 = anchorAt(layer, to);
    layer.position = p1;
    layer.bounds = (CGRect){ CGPointZero, to.size };
    if (m.ease && m.duration <= 0) return 0;
    if (CGPointEqualToPoint(p0, p1) && CGSizeEqualToSize(from.size, to.size)) return 0;
    CGPoint offset = CGPointMake(p0.x - p1.x, p0.y - p1.y), none = CGPointZero;
    // The size alone: an offset with a negative width (a tile growing) as
    // a whole bounds rect is standardized by CoreAnimation into a shifted
    // origin, which slid the picture over by the width it was to grow.
    CGSize grow = { from.size.width - to.size.width, from.size.height - to.size.height }, still = CGSizeZero;
    CABasicAnimation *move = animate(m, positionKey, [NSValue valueWithBytes:&offset objCType:@encode(CGPoint)],
        [NSValue valueWithBytes:&none objCType:@encode(CGPoint)], 0);
    CABasicAnimation *size = animate(m, sizeKey, [NSValue valueWithBytes:&grow objCType:@encode(CGSize)],
        [NSValue valueWithBytes:&still objCType:@encode(CGSize)], 0);
    move.additive = YES;
    size.additive = YES;
    // Unnamed, so each adds to those still running instead of replacing them.
    [layer addAnimation:move forKey:nil];
    [layer addAnimation:size forKey:nil];
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

// The parts of a picture all show the one capture: each layer has the whole
// image as its contents and shows its part through contentsRect, so
// CoreAnimation uploads the capture once. (A cropped copy per layer, about
// 30 a picture, was uploaded on its own each time, and cost Hammerspoon
// most of its CPU time in a retile with live refresh.)
typedef struct {
    CGImageRef image;
    CGFloat iw, ih; // its size in pixels
    CGFloat ox, oy; // where the window starts in it, in pixels
    CGFloat w, h;   // the window's size in it, in pixels
} Source;

// A layer showing pixels `px` (relative to the window in `s`) over `frame`
// (in its parent), with `transform`; `sharp` for a strip stretched out, so
// it isn't blended with the pixels beside it.
static CALayer *partLayer(const Source *s, CGRect px, CGRect frame, CATransform3D transform, bool sharp) {
    CALayer *layer = [CALayer layer];
    layer.bounds = (CGRect){ CGPointZero, frame.size };
    layer.position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    layer.transform = transform;
    layer.contents = (id)s->image;
    layer.contentsRect = CGRectMake((s->ox + px.origin.x) / s->iw, (s->oy + px.origin.y) / s->ih,
        px.size.width / s->iw, px.size.height / s->ih);
    if (sharp) {
        layer.magnificationFilter = kCAFilterNearest;
        layer.minificationFilter = kCAFilterNearest;
    }
    return layer;
}

// The window in `s` (`pw` x `ph` points, `ix` x `iy` pixels clear of its
// rounded corners at each edge) as a layer over `frame` with `transform`,
// its see-through corners filled from the window just beside them: patches
// beneath it, so a corner shows the window's own edge, not what's behind.
static CALayer *squared(const Source *s, CGFloat ix, CGFloat iy, CGFloat pw, CGFloat ph, CGRect frame,
                        CATransform3D transform) {
    CGFloat w = s->w, h = s->h;
    CGFloat cw = ix * pw / w, ch = iy * ph / h; // a corner, in points
    CALayer *layer = [CALayer layer];
    layer.bounds = (CGRect){ CGPointZero, frame.size };
    layer.position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    layer.transform = transform;
    // Each corner from the pixels across from it, towards the middle.
    CGRect from[4] = { { { ix, 0 }, { ix, iy } }, { { w - 2 * ix, 0 }, { ix, iy } },
        { { ix, h - iy }, { ix, iy } }, { { w - 2 * ix, h - iy }, { ix, iy } } };
    CGRect to[4] = { { { 0, 0 }, { cw, ch } }, { { pw - cw, 0 }, { cw, ch } },
        { { 0, ph - ch }, { cw, ch } }, { { pw - cw, ph - ch }, { cw, ch } } };
    for (int i = 0; i < 4; i++) [layer addSublayer:partLayer(s, from[i], to[i], CATransform3DIdentity, false)];
    [layer addSublayer:partLayer(s, CGRectMake(0, 0, w, h), CGRectMake(0, 0, pw, ph), CATransform3DIdentity, false)];
    return layer;
}

// Points of a growing tile's window mirrored past its edges before the
// rest is stretched (captureRetile.mirror).
static double mirrorBand = 32;

// Adds to `parent`, clipped to `clip`, the window squared off (see squared)
// over `frame` (relative to `clip`) with `transform`.
static void clippedMirror(CALayer *parent, const Source *s, CGFloat ix, CGFloat iy, CGFloat pw, CGFloat ph,
                          CGRect clip, CGRect frame, CATransform3D transform) {
    if (clip.size.width <= 0 || clip.size.height <= 0) return;
    CALayer *window = [CALayer layer];
    window.anchorPoint = CGPointZero;
    window.frame = clip;
    window.masksToBounds = YES;
    [window addSublayer:squared(s, ix, iy, pw, ph, frame, transform)];
    [parent addSublayer:window];
}

// A picture of the part `src` (on screen) of `image`, which covers `area`,
// at the top-left of its box, at its own size, the window's corners
// `radius` round and filled in (see squared). Past its right and bottom
// edges, for the box to clip as the tile grows: a band `band` points wide
// of the window mirrored at that edge, so a scroll bar or border there
// carries on, and past the band its far edge stretched.
static CALayer *edgeExtended(CGImageRef image, CGRect area, CGRect src, CGFloat radius, double band) {
    double sx = CGImageGetWidth(image) / area.size.width, sy = CGImageGetHeight(image) / area.size.height;
    CGRect px = CGRectIntegral(CGRectMake((src.origin.x - area.origin.x) * sx, (src.origin.y - area.origin.y) * sy,
        src.size.width * sx, src.size.height * sy));
    Source s = { image, CGImageGetWidth(image), CGImageGetHeight(image), px.origin.x, px.origin.y,
        px.size.width, px.size.height };
    if (s.w < 3 || s.h < 3) return nil;
    CGFloat w = s.w, h = s.h;
    CGFloat pw = src.size.width, ph = src.size.height, far = 1e4;
    // Columns and rows clear of the rounded corners.
    CGFloat rad = fmax(0, radius);
    CGFloat ix = fmin(ceil(rad * sx) + 1, floor(w / 3)), iy = fmin(ceil(rad * sy) + 1, floor(h / 3));
    // The bands: clear of the corners where there's a band at all, and no
    // more than half the window.
    CGFloat bx = band > 0 ? fmin(fmax(band, ix / sx + 1), pw / 2) : 0;
    CGFloat by = band > 0 ? fmin(fmax(band, iy / sy + 1), ph / 2) : 0;
    // The columns (rows) the stretch is taken from: the bands' far edges,
    // or without bands the window's own, inside its corners.
    CGFloat cx = bx > 0 ? floor(w - bx * sx) : w - 1 - ix, cy = by > 0 ? floor(h - by * sy) : h - 1 - iy;
    CALayer *pic = [CALayer layer];
    pic.anchorPoint = CGPointZero;
    pic.frame = CGRectMake(0, 0, pw, ph);
    CATransform3D none = CATransform3DIdentity;
    [pic addSublayer:partLayer(&s, CGRectMake(cx, 0, 1, h), CGRectMake(pw + bx, 0, far, ph), none, true)];
    [pic addSublayer:partLayer(&s, CGRectMake(0, cy, w, 1), CGRectMake(0, ph + by, pw, far), none, true)];
    [pic addSublayer:partLayer(&s, CGRectMake(cx, cy, 1, 1), CGRectMake(pw + bx, ph, far, far), none, true)];
    [pic addSublayer:partLayer(&s, CGRectMake(cx, cy, 1, 1), CGRectMake(pw, ph + by, bx, far), none, true)];
    // The mirrored bands: right, below, and both at the corner. Flipped
    // about its middle, a copy at the band's origin has the window's edge
    // against the seam; the band shows the part of it nearest.
    CGRect mirrored = CGRectMake(0, 0, pw, ph);
    clippedMirror(pic, &s, ix, iy, pw, ph, CGRectMake(pw, 0, bx, ph), mirrored, CATransform3DMakeScale(-1, 1, 1));
    clippedMirror(pic, &s, ix, iy, pw, ph, CGRectMake(0, ph, pw, by), mirrored, CATransform3DMakeScale(1, -1, 1));
    clippedMirror(pic, &s, ix, iy, pw, ph, CGRectMake(pw, ph, bx, by), mirrored, CATransform3DMakeScale(-1, -1, 1));
    // The window itself.
    [pic addSublayer:squared(&s, ix, iy, pw, ph, CGRectMake(0, 0, pw, ph), none)];
    return pic;
}

// Corner radii looked up lately, by window: a window's doesn't change, and
// asking WindowServer for each tile's on every retile held its overlay up.
#define MAX_RADII 64
#define RADIUS_MAX_AGE 10.0
static struct {
    uint32_t wid;
    CGFloat radius;
    double at;
} radii[MAX_RADII];
static int nextRadius = 0;

static CGFloat lookUpRadius(uint32_t wid, CGFloat fallback);

// Window `wid`'s corner radius as WindowServer has it, else `fallback`.
static CGFloat cornerRadius(uint32_t wid, CGFloat fallback) {
    double now = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < MAX_RADII; i++) {
        if (radii[i].wid == wid && now - radii[i].at < RADIUS_MAX_AGE) return radii[i].radius > 0 ? radii[i].radius : fallback;
    }
    CGFloat radius = lookUpRadius(wid, 0);
    radii[nextRadius].wid = wid;
    radii[nextRadius].radius = radius;
    radii[nextRadius].at = now;
    nextRadius = (nextRadius + 1) % MAX_RADII;
    return radius > 0 ? radius : fallback;
}

static CGFloat lookUpRadius(uint32_t wid, CGFloat fallback) {
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

// The tile showing window `target`, or -1.
static int tileOf(uint32_t target) {
    for (int i = 0; i < shownCount; i++) {
        if (shownTiles[i].wid == target) return i;
    }
    return -1;
}

// Gives ring `ring` tile `t`'s colour and width.
static void styleRing(CALayer *ring, const Tile *t) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGColorRef color = CGColorCreate(space, t->color);
    CGColorSpaceRelease(space);
    ring.borderColor = color;
    CGColorRelease(color);
    ring.borderWidth = t->width;
    ring.cornerRadius = t->radius + t->width;
}

// Whether `r` shows less than a sliver of `frame` (a parked window, a tile
// gone off the display).
static bool offFrame(CGRect r, CGRect frame) {
    CGRect i = CGRectIntersection(r, frame);
    return CGRectIsNull(i) || i.size.width < 8 || i.size.height < 8;
}

// Pictures of tiles that glided off the display, per monitor and window, for
// when they come back (see above). Each holds the capture it was cut from.
#define MAX_KEPT 64
#define KEPT_MAX_AGE 600.0
static struct {
    uint32_t wid;
    char monitor[MONITOR_ID_MAX];
    CALayer *pic;
    double at;
} kept[MAX_KEPT];

static void dropKept(int i) {
    [kept[i].pic release];
    kept[i].pic = nil;
    kept[i].wid = 0;
    kept[i].monitor[0] = '\0';
}

static void dropAllKept(void) {
    for (int i = 0; i < MAX_KEPT; i++) dropKept(i);
}

static void dropKeptForMonitor(const char *monitor) {
    if (!monitor || !monitor[0]) return;
    for (int i = 0; i < MAX_KEPT; i++) {
        if (kept[i].pic && sameMonitor(kept[i].monitor, monitor)) dropKept(i);
    }
}

// Keeps `pic` for window `w` on `monitor`, in place of one it had, else of the oldest.
static void keepPicture(const char *monitor, uint32_t w, CALayer *pic) {
    int slot = -1, oldest = 0;
    for (int i = 0; i < MAX_KEPT && slot < 0; i++) {
        if (kept[i].pic && kept[i].wid == w && sameMonitor(kept[i].monitor, monitor)) slot = i;
    }
    for (int i = 0; i < MAX_KEPT && slot < 0; i++) {
        if (!kept[i].pic) slot = i;
        else if (kept[i].at < kept[oldest].at) oldest = i;
    }
    if (slot < 0) slot = oldest;
    [pic retain];
    dropKept(slot);
    kept[slot].wid = w;
    copyMonitor(kept[slot].monitor, monitor);
    kept[slot].pic = pic;
    kept[slot].at = CFAbsoluteTimeGetCurrent();
}

// Window `w`'s kept picture on `monitor`, retained, no longer kept; nil if none or stale.
static CALayer *takeKept(const char *monitor, uint32_t w) {
    for (int i = 0; i < MAX_KEPT; i++) {
        if (!kept[i].pic || kept[i].wid != w || !sameMonitor(kept[i].monitor, monitor)) continue;
        CALayer *pic = CFAbsoluteTimeGetCurrent() - kept[i].at < KEPT_MAX_AGE ? [kept[i].pic retain] : nil;
        dropKept(i);
        return pic;
    }
    return nil;
}

// Keeps the pictures of the tiles of the retile on show that went off the
// display, as it's taken down.
static void keepGone(void) {
    if (retileGeneration != generation) return;
    for (int i = 0; i < shownCount; i++) {
        CALayer *pic = boxes[i].sublayers.lastObject;
        if (pic && offFrame(shownTiles[i].to, retileFrame)) keepPicture(retileMonitor, shownTiles[i].wid, pic);
    }
}

// Puts a picture of tile `i`, from `image` (covering `area`), in its box:
// a new tile with nothing shown yet pops in with it; otherwise it fades in
// over what's there (the one beneath kept for that, older ones dropped).
// How long that takes.
static double showPicture(int i, CGImageRef image, CGRect area, CGRect b) {
    CALayer *box = boxes[i];
    CALayer *pic = edgeExtended(image, area, b, shownTiles[i].radius, mirrorBand);
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
        NSArray *old = [[box.sublayers copy] autorelease];
        for (NSUInteger k = 0; k + 1 < old.count; k++) {
            [(CALayer *)old[k] removeAllAnimations];
            [(CALayer *)old[k] removeFromSuperlayer];
        }
        [box addSublayer:pic];
        took = fadeIn(pic, retileFade);
    }
    return took;
}

// Captures for refreshes and new windows run on a queue and connection of
// their own: WindowServer takes about 40ms over each, and a retile asked for
// meanwhile must not wait behind it. The pictures come back to `queue`. One
// at a time; a refresh that finds one running comes again.
static dispatch_queue_t captureQueue = NULL;
static int captureCid = 0;
static dispatch_source_t captureDrain = NULL;
static mach_port_t captureDrainPort = MACH_PORT_NULL;
static bool capturing = false; // belongs to `queue`
static atomic_bool stopping = false;

static void drainCaptureEvents(void *unused) {
    (void)unused;
    drainConnection(captureCid, captureDrainPort);
}

typedef struct {
    int count;
    uint32_t wids[MAX_TILES];
    CGRect bounds[MAX_TILES]; // where each was as the capture was asked for
    bool newOnly;
    bool every; // live: every tile, each new picture in place of the last
    unsigned generation;
} Wanted;

// Shows the pictures of `w` (in `image`, covering `area`): each of a window
// at its new place and size counts as live; a new tile shows whatever its
// window has. Tiles are found by window: a retarget may have reordered them.
static void showCaptured(const Wanted *w, CGImageRef image, CGRect area) {
    double took = 0;
    beginChanges();
    for (int k = 0; k < w->count; k++) {
        int i = tileOf(w->wids[k]);
        if (i < 0 || (live[i] && !w->every)) continue;
        CGRect b = CGRectIntersection(w->bounds[k], area);
        if (CGRectIsNull(b) || CGRectIsEmpty(b)) continue;
        bool pictured = boxes[i].sublayers.count > 0;
        if (w->every && pictured) {
            // Live: the window's latest frame in place of the last, as an
            // app's new frame shows, whatever size it has got to.
            CALayer *pic = edgeExtended(image, area, b, shownTiles[i].radius, mirrorBand);
            if (!pic) continue;
            for (CALayer *old in [[boxes[i].sublayers copy] autorelease]) {
                [old removeAllAnimations];
                [old removeFromSuperlayer];
            }
            [boxes[i] addSublayer:pic];
            continue;
        }
        bool there = arrived(w->bounds[k], shownTiles[i].to);
        if (pictured && (w->newOnly || !there)) continue;
        took = fmax(took, showPicture(i, image, area, b));
        live[i] = there;
    }
    commitChanges();
    endNoSooner(took + retileHold);
}

// Captures the tiles not live yet (with `newOnly`, the new ones with nothing
// shown) as they are now, off the queue, and shows them when it's back.
// Windows out of sight (parked, not back yet) are left for later. True if
// a tile with nothing shown is still waiting for its window.
static bool recapture(bool newOnly, bool every) {
    if (atomic_load(&stopping) || fadingOut || retileGeneration != generation || shownCount == 0) return false;
    bool waiting = false;
    if (capturing) {
        // Its turn comes after: say whether there's a new tile to wait for.
        for (int i = 0; i < shownCount && newOnly; i++) {
            waiting |= shownTiles[i].appear && boxes[i].sublayers.count == 0;
        }
        return waiting;
    }
    Wanted *w = calloc(1, sizeof(Wanted));
    if (!w) return false;
    w->newOnly = newOnly;
    w->every = every;
    w->generation = generation;
    for (int i = 0; i < shownCount; i++) {
        if (live[i] && !every) continue;
        bool empty = boxes[i].sublayers.count == 0;
        if (newOnly && (!shownTiles[i].appear || !empty)) continue;
        if (SLSGetWindowBounds(cid, shownTiles[i].wid, &w->bounds[w->count]) != kCGErrorSuccess) continue;
        if (offFrame(w->bounds[w->count], retileFrame)) {
            waiting |= empty && !offFrame(shownTiles[i].to, retileFrame);
            continue;
        }
        w->wids[w->count++] = shownTiles[i].wid;
    }
    if (w->count == 0) {
        free(w);
        return waiting;
    }
    capturing = true;
    dispatch_async(captureQueue, ^{
        uint32_t wids[MAX_TILES];
        memcpy(wids, w->wids, sizeof(uint32_t) * w->count);
        CGRect area = CGRectNull;
        CGImageRef image = atomic_load(&stopping) ? NULL : captureOn(captureCid, wids, w->count, &area, false);
        dispatch_async(queue, ^{
            capturing = false;
            if (image && !fadingOut && w->generation == generation && retileGeneration == generation && shownCount > 0) {
                showCaptured(w, image, area);
            }
            if (image) CGImageRelease(image);
            free(w);
        });
    });
    return waiting;
}

// New tiles, and those back in view without a picture, pop in once their
// windows are there to capture (Lua moves them once the overlay is up):
// looked for again this often, up to POP_IN_TRIES times, the overlay kept
// up meanwhile.
#define POP_IN_AGAIN 0.02
#define POP_IN_TRIES 15
static int popTries = 0;

static void popInNew(void *unused) {
    (void)unused;
    if (atomic_load(&stopping) || fadingOut || popGeneration != generation) return;
    if (recapture(true, false) && ++popTries < POP_IN_TRIES) {
        endNoSooner(POP_IN_AGAIN + 0.1 + retileHold);
        dispatch_source_set_timer(popInTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(POP_IN_AGAIN * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, 0);
    }
}

// Live, the tiles are captured back to back while they glide: the capture
// queue takes one at a time, so this looks again this often for the next.
#define LIVE_START 0.04
#define LIVE_POLL 0.01

static void refresh(void *unused) {
    (void)unused;
    if (atomic_load(&stopping) || fadingOut || retileGeneration != generation || shownCount == 0 || retileRefresh == REFRESH_OFF) return;
    if (retileRefresh == REFRESH_LIVE) {
        if (CFAbsoluteTimeGetCurrent() >= glideEnds) return;
        recapture(false, true);
        dispatch_source_set_timer(refresher, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LIVE_POLL * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, 0);
        return;
    }
    recapture(false, false);
    bool waiting = false;
    for (int i = 0; i < shownCount; i++) waiting |= !live[i];
    if (waiting && ++refreshes < MAX_REFRESHES) {
        dispatch_source_set_timer(refresher, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(REFRESH_AGAIN * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, 0);
        endNoSooner(REFRESH_AGAIN + 0.1 + retileHold);
    }
}

// The windows a scratchpad covers, captured as the backdrop of its
// retiles: kept for BENEATH_MAX_AGE seconds while the same windows are
// beneath, so a burst of keys takes it once.
#define BENEATH_MAX_AGE 1.0
static Shot beneath;
static uint32_t beneathIds[MAX_TILES];
static int beneathCount = 0;

static int compareIds(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

// Lets the picture of the windows beneath go (the overlay is down: it's
// soon out of date, and as big as the display).
static void dropBeneath(void) {
    dropPicture(&beneath);
    beneathCount = 0;
}

// A picture of windows `ids` (stacked as on screen), current or taken
// again. NULL if there's nothing to see.
static Shot *beneathPicture(const uint32_t *ids, int count) {
    uint32_t sorted[MAX_TILES];
    if (count > MAX_TILES) count = MAX_TILES;
    memcpy(sorted, ids, sizeof(uint32_t) * count);
    qsort(sorted, count, sizeof(uint32_t), compareIds);
    bool same = beneath.image && count == beneathCount && memcmp(sorted, beneathIds, sizeof(uint32_t) * count) == 0
        && CFAbsoluteTimeGetCurrent() - beneath.taken < BENEATH_MAX_AGE;
    if (same) return &beneath;
    dropPicture(&beneath);
    uint32_t stacked[MAX_TILES];
    memcpy(stacked, ids, sizeof(uint32_t) * count);
    CGRect bounds;
    CGImageRef image = captureOn(cid, stacked, count, &bounds, true);
    if (!image) return NULL;
    beneath = (Shot){ .key = -1, .image = image, .bounds = bounds, .taken = CFAbsoluteTimeGetCurrent() };
    memcpy(beneathIds, sorted, sizeof(uint32_t) * count);
    beneathCount = count;
    return &beneath;
}

// A box (and ring) for new tile `t`, placed at `to`, unseen until its
// picture pops in.
static void placeHidden(CALayer *box, CALayer *ring, CGRect to, CGFloat w) {
    CGPoint middle = CGPointMake(CGRectGetMidX(to), CGRectGetMidY(to));
    box.anchorPoint = CGPointMake(0.5, 0.5);
    box.bounds = (CGRect){ CGPointZero, to.size };
    box.position = middle;
    box.opacity = 0;
    ring.anchorPoint = CGPointMake(0.5, 0.5);
    ring.bounds = (CGRect){ CGPointZero, outset(to, w).size };
    ring.position = middle;
    ring.opacity = 0;
}

// Where `layer` is drawn now, mid-animation or not.
static CGRect drawnFrame(CALayer *layer) {
    return ((CALayer *)layer.presentationLayer ?: layer).frame;
}

// Puts the tiles' pictures up where they are and glides them to where
// they go as `move` moves, then takes them down `hold` seconds after the
// last has settled (the apps redrawing at their new sizes). New tiles pop
// in from `pop` of their size, fading in as `fade` moves.
//
// While a retile on the same display is still on show, this one carries
// it on: each tile it has glides on from where it's drawn now to its new
// place, with the picture it has (no capture), so keys pressed in quick
// succession merge into one motion. Only windows it hasn't got are
// captured. False if there was nothing to show.
static bool retile(const char *monitor, CGRect frame, CGRect fullFrame, const char *wallpaperPath,
                   double scale, Tile *tiles, int count, Motion move, Motion fade, double hold,
                   double pop, int refresh, const uint32_t *under, int underCount) {
    if (count <= 0 || count > MAX_TILES || (!wid && !makeWindow())) return false;
    bool carry = shown && retileGeneration == generation && shownCount > 0
        && CGRectEqualToRect(frame, retileFrame) && sameMonitor(monitor, retileMonitor);
    int was[MAX_TILES];
    uint32_t wids[MAX_TILES];
    int captured = 0;
    for (int i = 0; i < count; i++) {
        was[i] = carry ? tileOf(tiles[i].wid) : -1;
        if (was[i] < 0 && !tiles[i].appear && !tiles[i].away) wids[captured++] = tiles[i].wid;
    }
    CGRect area = CGRectNull;
    CGImageRef image = captured ? captureOn(cid, wids, captured, &area, false) : NULL;
    if (captured && !image && !carry) return false;
    Shot *covered = !carry && underCount > 0 ? beneathPicture(under, underCount) : NULL;

    if (!carry) {
        keepGone();
        generation++;
        clearLayers();
        plane = nil;
        retileEnds = 0;
        glideEnds = 0;
    }
    retileGeneration = generation;
    copyMonitor(retileMonitor, monitor);
    retileFrame = frame;
    retileMove = move;
    retileFade = fade;
    retileHold = hold;
    retileRefresh = refresh;
    popScale = pop;
    refreshes = 0;
    popTries = 0;

    double took = 0;
    CALayer *nextBoxes[MAX_TILES], *nextRings[MAX_TILES];
    bool used[MAX_TILES] = { false };
    bool nextLive[MAX_TILES] = { false };
    CGRect display = validRect(fullFrame) ? fullFrame : displayHolding(frame);
    beginChanges();
    // Back from fading out, if it was handing over.
    fadingOut = false;
    [root removeAnimationForKey:opacityKey];
    root.opacity = 1;
    if (!carry) {
        root.frame = (CGRect){ CGPointZero, frame.size };
        root.backgroundColor = NULL;
        Shot *wall = wallpaperFor(monitor, display);
        if (!wall) wall = takeWallpaper(monitor, display, wallpaperPath);
        if (wall) {
            [root addSublayer:pictureLayer(wall, frame, display, CGPointZero)];
        } else {
            root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        }
        // Over a scratchpad, the workspace it covers, as it shows around it.
        if (covered) [root addSublayer:pictureLayer(covered, frame, display, CGPointZero)];
    }
    for (int i = 0; i < count; i++) {
        Tile *t = &tiles[i];
        CGRect to = CGRectOffset(t->to, -frame.origin.x, -frame.origin.y);
        int j = was[i];
        CALayer *box, *ring;
        if (j >= 0) {
            used[j] = true;
            t->radius = shownTiles[j].radius;
            // Its fresh picture still holds where its tile stays put.
            nextLive[i] = live[j] && CGRectEqualToRect(shownTiles[j].to, t->to);
            box = boxes[j];
            ring = rings[j];
            // Where the last retile was taking them: the glides still
            // running carry on beneath the new ones.
            CGRect was = box.frame;
            CGRect ringWas = ring ? ring.frame : CGRectNull;
            if (ring && !(t->ring && t->width > 0)) {
                [ring removeAllAnimations];
                [ring removeFromSuperlayer];
                ring = nil;
            } else if (!ring && t->ring && t->width > 0) {
                // A ring it didn't have: from where the box is drawn now.
                ring = ringLayer(t);
                ring.anchorPoint = box.anchorPoint;
                ringWas = outset(drawnFrame(box), t->width);
                [root addSublayer:ring];
            }
            if (ring) styleRing(ring, t);
            CGFloat w = ring ? t->width : 0;
            if (box.sublayers.count == 0) {
                // Still waiting for its picture: it pops in at the new place.
                t->appear = true;
                [box removeAllAnimations];
                [ring removeAllAnimations];
                placeHidden(box, ring, to, w);
            } else {
                t->appear = false;
                took = fmax(took, glide(box, was, to, move));
                if (ring) glide(ring, ringWas, outset(to, w), move);
            }
        } else {
            t->radius = cornerRadius(t->wid, t->radius);
            box = [CALayer layer];
            box.masksToBounds = YES;
            // The window's own corners: the picture's stretched edges are square.
            box.cornerRadius = t->radius;
            ring = t->ring && t->width > 0 ? ringLayer(t) : nil;
            CGFloat w = ring ? t->width : 0;
            CALayer *back = t->away && !t->appear ? takeKept(monitor, t->wid) : nil;
            if (back) {
                // Back in view: in with the picture it went with.
                [box addSublayer:back];
                [back release];
                CGRect from = CGRectOffset(t->from, -frame.origin.x, -frame.origin.y);
                box.anchorPoint = CGPointZero;
                ring.anchorPoint = CGPointZero;
                took = fmax(took, glide(box, from, to, move));
                if (ring) glide(ring, outset(from, w), outset(to, w), move);
            } else if (t->appear || t->away) {
                t->appear = true;
                // Empty and unseen until its own capture (popInNew).
                placeHidden(box, ring, to, w);
            } else {
                CGRect src = image ? CGRectIntersection(t->from, area) : CGRectNull;
                CALayer *pic = CGRectIsNull(src) || CGRectIsEmpty(src) ? nil : edgeExtended(image, area, src, t->radius, mirrorBand);
                if (pic) [box addSublayer:pic];
                CGRect from = pic ? CGRectOffset(src, -frame.origin.x, -frame.origin.y) : to;
                box.anchorPoint = CGPointZero;
                ring.anchorPoint = CGPointZero;
                took = fmax(took, glide(box, from, to, move));
                if (ring) glide(ring, outset(from, w), outset(to, w), move);
            }
            [root addSublayer:box];
            if (ring) [root addSublayer:ring];
        }
        nextBoxes[i] = box;
        nextRings[i] = ring;
    }
    // Tiles gone from the display since (closed, moved away).
    for (int j = 0; j < shownCount && carry; j++) {
        if (used[j]) continue;
        [boxes[j] removeAllAnimations];
        [boxes[j] removeFromSuperlayer];
        [rings[j] removeAllAnimations];
        [rings[j] removeFromSuperlayer];
    }
    commitChanges();
    if (image) CGImageRelease(image);

    shownCount = count;
    memcpy(shownTiles, tiles, sizeof(Tile) * count);
    for (int i = 0; i < count; i++) {
        boxes[i] = nextBoxes[i];
        rings[i] = nextRings[i];
        live[i] = nextLive[i];
    }

    placeWindow(frame, scale);
    orderWindow(true);
    glideEnds = fmax(glideEnds, CFAbsoluteTimeGetCurrent() + took);
    endNoSooner((refresh == REFRESH_ONCE ? fmax(took, REFRESH_AFTER + 0.1) : took) + hold);
    popGeneration = generation;
    dispatch_source_set_timer(popInTimer, DISPATCH_TIME_NOW, DISPATCH_TIME_FOREVER, 0);
    if (refresh != REFRESH_OFF) {
        double after = refresh == REFRESH_LIVE ? LIVE_START : REFRESH_AFTER;
        dispatch_source_set_timer(refresher, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER, 0);
    }
    return true;
}

// Retiles are asked for from the main thread and answered there, once
// their overlay is up (or isn't): Lua moves the windows then, and isn't
// held up meanwhile by the capture.
static LuaCallback onReady = LUA_CALLBACK_NONE;
static dispatch_source_t readySource = NULL;
#define MAX_READY 64
static struct {
    int token;
    bool up;
} ready[MAX_READY];
static int readyCount = 0;
static os_unfair_lock readyLock = OS_UNFAIR_LOCK_INIT;

static void postReady(int token, bool up) {
    os_unfair_lock_lock(&readyLock);
    if (readyCount < MAX_READY) {
        ready[readyCount].token = token;
        ready[readyCount++].up = up;
    }
    os_unfair_lock_unlock(&readyLock);
    if (readySource) dispatch_source_merge_data(readySource, 1);
}

static void deliverReady(void *unused) {
    (void)unused;
    os_unfair_lock_lock(&readyLock);
    int count = readyCount;
    int tokens[MAX_READY];
    bool ups[MAX_READY];
    for (int i = 0; i < count; i++) {
        tokens[i] = ready[i].token;
        ups[i] = ready[i].up;
    }
    readyCount = 0;
    os_unfair_lock_unlock(&readyLock);
    for (int i = 0; i < count; i++) {
        if (!luaCallbackPush(&onReady)) break;
        lua_pushinteger(onReady.L, tokens[i]);
        lua_pushboolean(onReady.L, ups[i]);
        luaCallbackCall(&onReady, 2);
    }
}

// ---------------------------------------------------------------------------
// Drags (#26, mouse.dragEffect; a prototype)
// ---------------------------------------------------------------------------
//
// With mouse.dragEffect, a window being moved shrinks a little and goes
// see-through, as Hyprland's does. macOS ignores the alpha set on another
// app's window (SLSSetWindowAlpha succeeds and the window stays opaque), so
// what's dragged is a picture of it: one capture as the drag begins, in a
// window of our own the size of the real one, the picture shrunk and faded
// inside it. drag.c moves our window instead of the real one, which waits
// parked out of sight (see lift.h). Its contents are as they were when the
// drag began. Once the button's up the real window goes where the drag
// left it (and on to wherever the drop puts it), and the picture fades
// over it.
//
// Its own queue, connection and window: a drop sets off a retile, whose
// overlay must neither take the picture down nor be held up by it, and a
// 40ms capture for a retile mustn't hold up the drag's frames.

static dispatch_queue_t liftQueue = NULL;
static int liftCid = 0;
static dispatch_source_t liftDrain = NULL;
static mach_port_t liftDrainPort = MACH_PORT_NULL;

// Everything below belongs to liftQueue.
static uint32_t liftWid = 0;
static CAContext *liftContext = nil;
static CALayer *liftRoot = nil; // the window's content, origin top-left
static CALayer *liftBox = nil;  // the picture, shrunk and faded (in liftRoot)
static CGRect liftPlaced = { { 0, 0 }, { 0, 0 } };
static double liftPlacedScale = 0;
static bool liftDrawn = false; // ordered in
static unsigned liftShown = 0; // the drag whose picture is up; 0 for none
static unsigned liftGoing = 0; // the drag whose picture is fading out
static double liftScale = 0.95, liftOpacity = 0.8, liftDuration = 0.15, liftResolution = 1;

// Takes the picture down once it has faded: a timer, for l_gc to cancel.
static dispatch_source_t liftGone = NULL;

// The drag a picture is wanted for (0 once it has landed), and the frame
// it last gave. Any thread.
static _Atomic unsigned liftWanted = 0;
static os_unfair_lock liftLock = OS_UNFAIR_LOCK_INIT;
static CGRect liftFrame;
static unsigned liftFrameSerial = 0;
static atomic_bool liftMoveQueued = false;

static void drainLiftEvents(void *unused) {
    (void)unused;
    drainConnection(liftCid, liftDrainPort);
}

// Puts our window at `frame`, as placeWindow puts the overlay; a new shape
// only when the size changes.
static void placeLift(CGRect frame) {
    if (liftResolution != liftPlacedScale) {
        SLSSetWindowResolution(liftCid, liftWid, liftResolution);
        liftPlacedScale = liftResolution;
    }
    if (CGRectEqualToRect(frame, liftPlaced)) return;
    if (!CGSizeEqualToSize(frame.size, liftPlaced.size)) {
        CGRect shape = { CGPointZero, frame.size };
        CFTypeRef region = NULL;
        CGSNewRegionWithRect(&shape, &region);
        if (region) {
            SLSSetWindowShape(liftCid, liftWid, frame.origin.x, frame.origin.y, region);
            CFRelease(region);
        }
    }
    CFTypeRef t = SLSTransactionCreate(liftCid);
    if (t) {
        SLSTransactionMoveWindowWithGroup(t, liftWid, frame.origin);
        CGAffineTransform transform = CGAffineTransformIdentity;
        transform.tx = -frame.origin.x;
        transform.ty = -frame.origin.y;
        SLSTransactionSetWindowTransform(t, liftWid, 0, 0, transform);
        SLSTransactionCommit(t, 0);
        CFRelease(t);
    }
    liftPlaced = frame;
}

// At the overlay's level: above the windows and their rings, under the
// drop preview (an hs.canvas at the overlay level).
static void orderLift(bool in) {
    if (in == liftDrawn) return;
    CFTypeRef t = SLSTransactionCreate(liftCid);
    if (!t) return;
    if (in) {
        SLSTransactionSetWindowLevel(t, liftWid, OVERLAY_LEVEL);
        SLSTransactionOrderWindow(t, liftWid, ORDER_ABOVE, 0);
    } else {
        SLSTransactionOrderWindow(t, liftWid, ORDER_OUT, 0);
    }
    SLSTransactionCommit(t, 0);
    CFRelease(t);
    liftDrawn = in;
}

static void clearLift(void) {
    beginChanges();
    for (CALayer *layer in [[liftRoot.sublayers copy] autorelease]) {
        [layer removeAllAnimations];
        [layer removeFromSuperlayer];
    }
    commitChanges();
    liftBox = nil;
    liftShown = 0;
    liftGoing = 0;
    orderLift(false);
}

static Motion liftMotion(void) {
    return (Motion){ true, liftDuration, 0, 0, 0 };
}

// The frame drag `serial` last gave, else `fallback`.
static CGRect liftFrameOf(unsigned serial, CGRect fallback) {
    os_unfair_lock_lock(&liftLock);
    CGRect at = liftFrameSerial == serial ? liftFrame : fallback;
    os_unfair_lock_unlock(&liftLock);
    return at;
}

// Captures window `target` for drag `serial` (begun with it at `frame`),
// puts the picture up over it where the drag has it now, and offers it to
// `claim`: taken, it shrinks and fades to the drag's look.
static void liftUp(unsigned serial, uint32_t target, CGRect frame, LiftClaim claim) {
    if (atomic_load(&liftWanted) != serial) return;
    CGRect b;
    if (SLSGetWindowBounds(liftCid, target, &b) != kCGErrorSuccess || b.size.width < 1 || b.size.height < 1) return;
    uint32_t wids[1] = { target };
    CGRect area = CGRectNull;
    CGImageRef image = captureOn(liftCid, wids, 1, &area, false);
    if (!image) return;
    if (atomic_load(&liftWanted) != serial || (!liftWid && !(liftWid = newOverlay(liftCid, &liftContext, &liftRoot)))) {
        CGImageRelease(image);
        return;
    }
    // A capture covers the window's part on screen (`area`); a picture
    // the window's own shape is all of it.
    CGRect part = CGRectOffset(area, -b.origin.x, -b.origin.y);
    CGFloat iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
    if (ih > 0 && fabs(iw / ih - b.size.width / b.size.height) < 0.01) part = (CGRect){ CGPointZero, b.size };
    CGRect at = liftFrameOf(serial, frame);
    CGFloat kx = at.size.width / b.size.width, ky = at.size.height / b.size.height;

    liftGoing = 0;
    beginChanges();
    for (CALayer *layer in [[liftRoot.sublayers copy] autorelease]) {
        [layer removeAllAnimations];
        [layer removeFromSuperlayer];
    }
    liftRoot.frame = (CGRect){ CGPointZero, at.size };
    CALayer *box = [CALayer layer];
    box.frame = liftRoot.bounds; // shrinks about its middle
    CALayer *picture = [CALayer layer];
    picture.frame = CGRectMake(part.origin.x * kx, part.origin.y * ky, part.size.width * kx, part.size.height * ky);
    picture.contents = (id)image;
    [box addSublayer:picture];
    [liftRoot addSublayer:box];
    commitChanges();
    CGImageRelease(image);
    placeLift(at);
    orderLift(true);

    // Up over the window, as it is: now the drag can park it.
    if (!claim(serial)) {
        clearLift();
        return;
    }
    liftShown = serial;
    liftBox = box;
    beginChanges();
    box.transform = CATransform3DMakeScale(liftScale, liftScale, 1);
    box.opacity = liftOpacity;
    if (liftDuration > 0) {
        [box addAnimation:animate(liftMotion(), scaleKey, @1.0, @(liftScale), 0) forKey:scaleKey];
        [box addAnimation:animate(liftMotion(), opacityKey, @1.0, @(liftOpacity), 0) forKey:opacityKey];
    }
    commitChanges();
    // Where the drag has got to meanwhile.
    placeLift(liftFrameOf(serial, at));
}

static void liftMoveNow(void *unused) {
    (void)unused;
    atomic_store(&liftMoveQueued, false);
    os_unfair_lock_lock(&liftLock);
    CGRect at = liftFrame;
    unsigned serial = liftFrameSerial;
    os_unfair_lock_unlock(&liftLock);
    if (liftShown && serial == liftShown) placeLift(at);
}

// Lifter.begin (lift.h). Main thread.
static void liftBegin(unsigned serial, uint32_t target, CGRect frame, LiftClaim claim) {
    if (!liftQueue || !serial || !claim) return;
    atomic_store(&liftWanted, serial);
    dispatch_async(liftQueue, ^{ liftUp(serial, target, frame, claim); });
}

// Lifter.move (lift.h): only the latest of a burst is drawn. Any thread.
static void liftMove(unsigned serial, CGRect frame) {
    if (!validRect(frame)) return;
    os_unfair_lock_lock(&liftLock);
    dispatch_queue_t q = liftQueue;
    if (q) {
        liftFrame = frame;
        liftFrameSerial = serial;
        if (!atomic_exchange(&liftMoveQueued, true)) dispatch_async_f(q, NULL, liftMoveNow);
    }
    os_unfair_lock_unlock(&liftLock);
}

static const Lifter lifter = { liftBegin, liftMove };

// The drag has landed, its window where it goes: the picture grows back
// to its size as it fades over it, then goes.
static void liftDown(void) {
    if (!liftShown) return;
    liftGoing = liftShown;
    liftShown = 0;
    CALayer *box = liftBox;
    double took = 0;
    if (box) {
        CALayer *drawn = (CALayer *)box.presentationLayer ?: box;
        NSNumber *scale = [drawn valueForKeyPath:@"transform.scale"] ?: @(liftScale);
        NSNumber *opacity = @(drawn.opacity);
        beginChanges();
        [box removeAllAnimations];
        box.transform = CATransform3DIdentity;
        box.opacity = 0;
        if (liftDuration > 0) {
            CABasicAnimation *grow = animate(liftMotion(), scaleKey, scale, @1.0, 0);
            CABasicAnimation *fade = animate(liftMotion(), opacityKey, opacity, @0.0, 0);
            [box addAnimation:grow forKey:scaleKey];
            [box addAnimation:fade forKey:opacityKey];
            took = fade.duration;
        }
        commitChanges();
    }
    dispatch_source_set_timer(liftGone, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(took * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
}

// A drop that changes nothing: the picture goes back to `to`, the frame
// its window had as the drag began (parked till then: dragUnpark), growing
// back to its size and opaque on the way, as `m` moves: once there it looks
// just as the window will, so the window comes back under it unseen (still
// see-through, the desktop behind it would vanish at once). Our window
// covers both frames meanwhile, the picture moving inside it.
static void liftHome(CGRect to, Motion m) {
    if (!liftShown || !liftBox) return;
    CALayer *box = liftBox;
    CALayer *drawn = (CALayer *)box.presentationLayer ?: box;
    NSNumber *scale = [drawn valueForKeyPath:@"transform.scale"] ?: @(liftScale);
    NSNumber *opacity = @(drawn.opacity);
    CGRect from = liftPlaced;
    CGRect area = CGRectIntegral(CGRectUnion(from, to));
    CGPoint a = CGPointMake(CGRectGetMidX(from) - area.origin.x, CGRectGetMidY(from) - area.origin.y);
    CGPoint b = CGPointMake(CGRectGetMidX(to) - area.origin.x, CGRectGetMidY(to) - area.origin.y);
    beginChanges();
    [box removeAllAnimations];
    liftRoot.frame = (CGRect){ CGPointZero, area.size };
    box.position = a;
    commitChanges();
    placeLift(area);
    beginChanges();
    box.position = b;
    box.transform = CATransform3DIdentity;
    box.opacity = 1;
    if (m.duration > 0 || !m.ease) {
        // Eased, not on the spring: an overshoot past opaque means nothing.
        Motion clear = { true, liftDuration > 0 ? fmax(liftDuration, m.ease ? m.duration * 0.8 : 0.15) : 0, 0, 0, 0 };
        if (clear.duration > 0) [box addAnimation:animate(clear, opacityKey, opacity, @1.0, 0) forKey:opacityKey];
        [box addAnimation:animate(m, positionKey, [NSValue valueWithBytes:&a objCType:@encode(CGPoint)],
            [NSValue valueWithBytes:&b objCType:@encode(CGPoint)], 0) forKey:positionKey];
        [box addAnimation:animate(m, scaleKey, scale, @1.0, 0) forKey:scaleKey];
    }
    commitChanges();
}

static void liftGoneNow(void *unused) {
    (void)unused;
    // Not if another drag's picture has come up meanwhile.
    if (!liftGoing || liftShown) return;
    liftGoing = 0;
    clearLift();
}

static void releaseLift(void) {
    liftShown = liftGoing = 0;
    if (!liftWid) return;
    clearLift();
    beginChanges();
    liftContext.layer = nil;
    commitChanges();
    SLSReleaseWindow(liftCid, liftWid);
    if ([liftContext respondsToSelector:@selector(invalidate)]) [liftContext performSelector:@selector(invalidate)];
    [liftRoot release];
    [liftContext release];
    liftRoot = nil;
    liftContext = nil;
    liftWid = 0;
    liftPlaced = CGRectZero;
    liftPlacedScale = 0;
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

static void readStringField(lua_State *L, int index, const char *key, char *dst, size_t size) {
    dst[0] = '\0';
    lua_getfield(L, index, key);
    if (lua_type(L, -1) == LUA_TSTRING) {
        const char *s = lua_tostring(L, -1);
        if (s) {
            strncpy(dst, s, size - 1);
            dst[size - 1] = '\0';
        }
    }
    lua_pop(L, 1);
}

// capture(key, {wid, ...} [, monitor [, fullFrame]]): one picture of the
// windows on `monitor`, kept under `(monitor, key)` (replacing the last).
// Waits for it (about 40ms): the caller is about to move them. True if there
// was anything to take.
static int l_capture(lua_State *L) {
    int key = (int)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    char monBuf[MONITOR_ID_MAX];
    copyMonitor(monBuf, luaL_optstring(L, 3, ""));
    CGRect display = lua_type(L, 4) == LUA_TTABLE ? readRect(L, 4) : CGRectZero;
    uint32_t list[128];
    int count = luaWindowIds(L, 2, list, 128);
    uint32_t *wids = list; // blocks can't take arrays
    const char *monPtr = monBuf;
    __block bool took = false;
    dispatch_sync(queue, ^{
        Shot *p = pictureFor(monPtr, key);
        if (p) dropPicture(p);
        if (count == 0) return;
        CGRect bounds;
        uint32_t winIds[MAX_SHOT_WINS];
        CGRect winRects[MAX_SHOT_WINS];
        int winCount = 0;
        CGImageRef image = captureOnClipped(cid, wids, count, display, &bounds, true,
            &winCount, winIds, winRects, MAX_SHOT_WINS);
        if (!image) return;
        CGRect anchor = validRect(display) ? display : CGRectZero;
        storePictureOwned(monPtr, key, image, bounds, anchor, winIds, winRects, winCount);
        took = true;
    });
    lua_pushboolean(L, took);
    return 1;
}

// forget(): every picture, wallpaper, thumb and scroll-away layer.
// forget(key): drops the picture kept under `key` across all monitors.
// forget(nil, monitor): drops every cached picture/wallpaper/thumb for `monitor`.
// forget(key, monitor): drops the picture kept under `(monitor, key)`.
static int l_forget(lua_State *L) {
    bool hasKey = !lua_isnoneornil(L, 1);
    int key = hasKey ? (int)luaL_checkinteger(L, 1) : 0;
    const char *monArg = luaL_optstring(L, 2, NULL);
    bool hasMon = monArg && monArg[0] != '\0';
    NSString *monCopy = hasMon ? [[NSString alloc] initWithUTF8String:monArg] : nil;
    dispatch_async(queue, ^{
        const char *mon = monCopy ? [monCopy UTF8String] : NULL;
        bool all = !hasKey && !hasMon;
        for (int i = 0; i < MAX_PICTURES; i++) {
            if (!pictures[i].image) continue;
            bool matchKey = !hasKey || pictures[i].key == key;
            bool matchMon = !hasMon || sameMonitor(pictures[i].monitor, mon);
            if (all || (matchKey && matchMon)) dropPicture(&pictures[i]);
        }
        if (all) {
            for (int i = 0; i < wallpaperCount; i++) dropPicture(&wallpapers[i]);
            wallpaperCount = 0;
            dropAllKept();
            slideThumbClear();
        } else if (!hasKey && hasMon) {
            for (int i = 0; i < wallpaperCount; i++) {
                if (wallpapers[i].image && sameMonitor(wallpapers[i].monitor, mon)) {
                    dropPicture(&wallpapers[i]);
                }
            }
            dropKeptForMonitor(mon);
            slideThumbForgetMonitor(mon);
        }
        [monCopy release];
    });
    return 0;
}

// wallpaper({x, y, w, h} [, monitor [, wallpaperPath [, force]]]): takes the
// wallpaper of the display ahead of its first slide, without waiting. With
// `force`, recaptures even if already cached (without overwriting a valid
// non-black wallpaper with a failed or black capture).
static int l_wallpaper(lua_State *L) {
    CGRect display = readRect(L, 1);
    if (!validRect(display)) return 0;
    const char *monArg = luaL_optstring(L, 2, "");
    const char *pathArg = luaL_optstring(L, 3, "");
    bool force = lua_toboolean(L, 4);
    NSString *monCopy = [[NSString alloc] initWithUTF8String:monArg ? monArg : ""];
    NSString *pathCopy = [[NSString alloc] initWithUTF8String:pathArg ? pathArg : ""];
    dispatch_async(queue, ^{
        const char *mon = [monCopy UTF8String];
        const char *path = [pathCopy UTF8String];
        Shot *wall = wallpaperFor(mon, display);
        if (force || !wall || wall->fallback || wall->black) {
            takeWallpaper(mon, display, path);
        }
        [monCopy release];
        [pathCopy release];
    });
    return 0;
}

// The motion in the table at `index` (curve = "spring" or "ease",
// duration =, mass =, stiffness =, damping =), `fallback` for what it leaves out.
static Motion readMotion(lua_State *L, int index, Motion fallback) {
    Motion m = fallback;
    if (lua_type(L, index) == LUA_TTABLE) {
        index = lua_absindex(L, index);
        lua_getfield(L, index, "curve");
        if (lua_type(L, -1) == LUA_TSTRING) m.ease = strcmp(lua_tostring(L, -1), "ease") == 0;
        lua_pop(L, 1);
        double v;
        v = numberField(L, index, "duration", m.duration);
        if (isfinite(v)) m.duration = v;
        v = numberField(L, index, "mass", m.mass);
        if (isfinite(v)) m.mass = v;
        v = numberField(L, index, "stiffness", m.stiffness);
        if (isfinite(v)) m.stiffness = v;
        v = numberField(L, index, "damping", m.damping);
        if (isfinite(v)) m.damping = v;
    }
    m.duration = fmax(0, isfinite(m.duration) ? m.duration : fallback.duration);
    m.mass = fmax(0.01, isfinite(m.mass) ? m.mass : fallback.mass);
    m.stiffness = fmax(1, isfinite(m.stiffness) ? m.stiffness : fallback.stiffness);
    m.damping = fmax(1, isfinite(m.damping) ? m.damping : fallback.damping);
    return m;
}

// A slide as run() and begin() take it.
static Slide readSlide(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    Slide s;
    memset(&s, 0, sizeof(s));
    readStringField(L, 1, "monitor", s.monitor, sizeof(s.monitor));
    lua_getfield(L, 1, "frame");
    s.frame = readRect(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, 1, "fullFrame");
    s.fullFrame = readRect(L, -1);
    lua_pop(L, 1);
    readStringField(L, 1, "wallpaperPath", s.wallpaperPath, sizeof(s.wallpaperPath));
    double sc = numberField(L, 1, "scale", 1);
    s.scale = isfinite(sc) && sc > 0 ? sc : 1;
    s.out = (int)numberField(L, 1, "out", 0);
    s.into = (int)numberField(L, 1, "into", 0);
    s.still = (int)numberField(L, 1, "still", 0);
    double dx = numberField(L, 1, "dx", 0), dy = numberField(L, 1, "dy", 0);
    s.toward = CGPointMake(isfinite(dx) ? dx : 0, isfinite(dy) ? dy : 0);
    lua_getfield(L, 1, "backdrop");
    s.backdrop = lua_toboolean(L, -1);
    lua_pop(L, 1);
    s.motion = readMotion(L, 1, defaultMotion);
    double age = numberField(L, 1, "wallpaperAge", 0);
    atomic_store(&wallpaperMaxAge, isfinite(age) && age > 0 ? age : 0);
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
    if (!validRect(s.frame)) return 0;
    dispatch_sync(queue, ^{ run(s); });
    return 0;
}

// begin{ as run }: puts the slide up without moving it, for track() to
// move (a swipe). True if there's anything to show.
static int l_begin(lua_State *L) {
    Slide s = readSlide(L);
    __block bool up = false;
    if (validRect(s.frame)) dispatch_sync(queue, ^{ up = build(s, 0); });
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
    double progress = luaL_checknumber(L, 1);
    if (!isfinite(progress)) return 0;
    atomic_store(&tracked, progress);
    if (!atomic_exchange(&trackQueued, true)) dispatch_async_f(queue, NULL, trackNow);
    return 0;
}

// finish(to, velocity): the slide begun springs on to `to` (1 all the way,
// 0 back), starting at `velocity` (of the way along per second), and goes.
static int l_finish(lua_State *L) {
    double to = luaL_checknumber(L, 1), velocity = luaL_optnumber(L, 2, 0);
    if (!isfinite(to)) to = 0;
    if (!isfinite(velocity)) velocity = 0;
    dispatch_async(queue, ^{ settle(to, velocity); });
    return 0;
}

// retile{ frame = {x, y, w, h}, scale =, move = motion, fade = motion,
//   hold =, popin =, mirror =, refresh =, wallpaperAge =, beneath =,
//   tiles = { { wid =, from = {x, y, w, h}, to = {...}, appear =,
//               ring = { color = {r, g, b, a}, width =, radius = } }, ... } }
// glides the tiles' pictures from `from` to `to` (popping those that
// `appear` in at `to`) over `frame`, then fades to the windows beneath.
//   move, fade   motions as run() takes them (curve =, duration =, mass =,
//                stiffness =, damping =)
//   hold         seconds the pictures stay once settled (0.05)
//   popin        share of their size new tiles grow from (0.8; 1 only fades)
//   mirror       points of a growing window mirrored past its edges before
//                the rest is stretched (32; 0 stretches only)
//   refresh      "live": the windows captured back to back while they
//                glide, each frame in place of the last; true: once each
//                has its new size, faded in; false: never
//   beneath      over a scratchpad, the windows it covers: the backdrop
// Returns a token at once; the capture (about 40ms) and the overlay are
// done on the queue, and onReady's fn(token, up) says when the windows
// beneath can move.
static int l_retile(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    char monBuf[MONITOR_ID_MAX];
    char wallBuf[512];
    readStringField(L, 1, "monitor", monBuf, sizeof(monBuf));
    readStringField(L, 1, "wallpaperPath", wallBuf, sizeof(wallBuf));
    lua_getfield(L, 1, "frame");
    CGRect frame = readRect(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, 1, "fullFrame");
    CGRect fullFrame = readRect(L, -1);
    lua_pop(L, 1);
    double scale = numberField(L, 1, "scale", 1);
    if (!isfinite(scale) || scale <= 0) scale = 1;
    lua_getfield(L, 1, "move");
    Motion move = readMotion(L, -1, defaultMotion);
    lua_getfield(L, 1, "fade");
    Motion fade = readMotion(L, -1, move);
    lua_pop(L, 2);
    double hold = numberField(L, 1, "hold", 0.05);
    if (!isfinite(hold) || hold < 0) hold = 0;
    double pop = numberField(L, 1, "popin", 0.8);
    if (!isfinite(pop)) pop = 0.8;
    pop = fmin(1, fmax(0.01, pop));
    double band = numberField(L, 1, "mirror", 32);
    band = isfinite(band) ? fmax(0, band) : 32;
    lua_getfield(L, 1, "refresh");
    int refresh = lua_type(L, -1) == LUA_TSTRING && strcmp(lua_tostring(L, -1), "live") == 0 ? REFRESH_LIVE
        : lua_toboolean(L, -1) ? REFRESH_ONCE : REFRESH_OFF;
    lua_pop(L, 1);
    double age = numberField(L, 1, "wallpaperAge", 0);
    atomic_store(&wallpaperMaxAge, isfinite(age) && age > 0 ? age : 0);
    static Tile tiles[MAX_TILES];
    int count = 0;
    lua_getfield(L, 1, "tiles");
    if (lua_type(L, -1) == LUA_TTABLE) {
        lua_Integer n = luaL_len(L, -1);
        for (lua_Integer i = 1; i <= n && count < MAX_TILES; i++) {
            lua_rawgeti(L, -1, i);
            if (lua_type(L, -1) != LUA_TTABLE) {
                lua_pop(L, 1);
                continue;
            }
            uint32_t w = (uint32_t)numberField(L, -1, "wid", 0);
            lua_getfield(L, -1, "appear");
            bool popIn = lua_toboolean(L, -1);
            lua_getfield(L, -2, "away");
            bool gone = lua_toboolean(L, -1);
            lua_pop(L, 2);
            lua_getfield(L, -1, "from");
            CGRect from = readRect(L, -1);
            lua_getfield(L, -2, "to");
            CGRect to = readRect(L, -1);
            lua_pop(L, 2);
            Tile t = { w, from, to, popIn, gone, false, { 0, 0, 0, 0 }, 0, 0 };
            lua_getfield(L, -1, "ring");
            if (lua_type(L, -1) == LUA_TTABLE) {
                t.ring = true;
                double rw = numberField(L, -1, "width", 0);
                double rr = numberField(L, -1, "radius", 0);
                t.width = isfinite(rw) ? fmax(0, rw) : 0;
                t.radius = isfinite(rr) ? fmax(0, rr) : 0;
                if (lua_getfield(L, -1, "color") == LUA_TTABLE) {
                    for (int c = 0; c < 4; c++) {
                        lua_rawgeti(L, -1, c + 1);
                        double cv = luaL_optnumber(L, -1, c == 3 ? 1 : 0);
                        t.color[c] = isfinite(cv) ? cv : (c == 3 ? 1 : 0);
                        lua_pop(L, 1);
                    }
                }
                lua_pop(L, 1);
            }
            lua_pop(L, 2); // the ring and the tile
            if (w && validRect(from) && validRect(to)) tiles[count++] = t;
        }
    }
    lua_pop(L, 1);
    if (!validRect(frame) || count == 0) return 0;
    uint32_t underList[MAX_TILES];
    int underCount = 0;
    lua_getfield(L, 1, "beneath");
    if (lua_type(L, -1) == LUA_TTABLE) underCount = luaWindowIds(L, -1, underList, MAX_TILES);
    lua_pop(L, 1);
    Tile *list = malloc(sizeof(Tile) * count + sizeof(uint32_t) * MAX_TILES);
    if (!list) return 0;
    memcpy(list, tiles, sizeof(Tile) * count);
    uint32_t *under = (uint32_t *)(list + count);
    memcpy(under, underList, sizeof(uint32_t) * underCount);
    static int lastToken = 0;
    int token = ++lastToken;
    NSString *monCopy = [[NSString alloc] initWithUTF8String:monBuf];
    NSString *wallCopy = [[NSString alloc] initWithUTF8String:wallBuf];
    dispatch_async(queue, ^{
        mirrorBand = band;
        bool up = retile([monCopy UTF8String], frame, fullFrame, [wallCopy UTF8String],
            scale, list, count, move, fade, hold, pop, refresh, under, underCount);
        [monCopy release];
        [wallCopy release];
        free(list);
        postReady(token, up);
    });
    lua_pushinteger(L, token);
    return 1;
}

// bounds({wid, ...}): {[wid] = {x =, y =, w =, h =}} as WindowServer has
// the windows now, for those it knows. No accessibility calls: the main
// thread doesn't wait on any app for them.
static int l_bounds(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    uint32_t wids[MAX_TILES * 4];
    int count = luaWindowIds(L, 1, wids, MAX_TILES * 4);
    int connection = SLSMainConnectionID();
    lua_createtable(L, 0, count);
    for (int i = 0; i < count; i++) {
        CGRect b;
        if (SLSGetWindowBounds(connection, wids[i], &b) != kCGErrorSuccess) continue;
        lua_createtable(L, 0, 4);
        lua_pushnumber(L, b.origin.x);
        lua_setfield(L, -2, "x");
        lua_pushnumber(L, b.origin.y);
        lua_setfield(L, -2, "y");
        lua_pushnumber(L, b.size.width);
        lua_setfield(L, -2, "w");
        lua_pushnumber(L, b.size.height);
        lua_setfield(L, -2, "h");
        lua_rawseti(L, -2, wids[i]);
    }
    return 1;
}

// lifter{ scale =, opacity =, duration =, resolution = }: the Lifter
// (lift.h) frames.dragBegin takes, its pictures shrunk to `scale` and
// faded to `opacity` over `duration` seconds (back again as they land),
// drawn at `resolution`. Nil without Screen Recording permission: a
// capture would show nothing of the window.
static int l_lifter(lua_State *L) {
    bool allowed = false;
    if (@available(macOS 10.15, *)) allowed = CGPreflightScreenCaptureAccess();
    if (!allowed || !liftQueue) {
        lua_pushnil(L);
        return 1;
    }
    double scale = 0.95, opacity = 0.8, duration = 0.15, resolution = 1;
    if (lua_type(L, 1) == LUA_TTABLE) {
        scale = numberField(L, 1, "scale", scale);
        opacity = numberField(L, 1, "opacity", opacity);
        duration = numberField(L, 1, "duration", duration);
        resolution = numberField(L, 1, "resolution", resolution);
    }
    scale = fmin(1, fmax(0.1, scale));
    opacity = fmin(1, fmax(0.05, opacity));
    duration = fmax(0, duration);
    resolution = fmax(1, resolution);
    // Before the drag's begin, on the same queue.
    dispatch_async(liftQueue, ^{
        liftScale = scale;
        liftOpacity = opacity;
        liftDuration = duration;
        liftResolution = resolution;
    });
    lua_pushlightuserdata(L, (void *)&lifter);
    return 1;
}

// land(): the drag with a picture has ended and its window is in place:
// the picture fades over it, or isn't put up if it isn't yet.
static int l_land(lua_State *L) {
    (void)L;
    atomic_store(&liftWanted, 0);
    if (liftQueue) dispatch_async(liftQueue, ^{ liftDown(); });
    return 0;
}

// home(frame, motion): the drop changed nothing, so the picture glides back
// to `frame` (see liftHome), as `motion` (an `animations` entry) moves.
// Returns the seconds that takes; then dragUnpark() and land().
static int l_home(lua_State *L) {
    CGRect to = readRect(L, 1);
    if (!validRect(to)) {
        lua_pushnumber(L, 0);
        return 1;
    }
    Motion m = readMotion(L, 2, defaultMotion);
    double took = 0;
    if (m.duration > 0 || !m.ease) took = animate(m, positionKey, @0, @1, 0).duration;
    if (liftQueue) dispatch_async(liftQueue, ^{ liftHome(to, m); });
    lua_pushnumber(L, took);
    return 1;
}

// onReady(fn): fn(token, up) on the main thread once retile `token`'s
// overlay is up (`up`), or couldn't be put up.
static int l_onReady(lua_State *L) {
    luaCallbackSet(&onReady, L, 1);
    return 0;
}

// stop(): tears down any active slide, retile or drag-effect overlay and
// clears Lua callbacks without releasing connections.
static int l_stop(lua_State *L) {
    (void)L;
    luaCallbackClear(&onChange);
    luaCallbackClear(&onReady);
    atomic_store(&liftWanted, 0);
    if (queue) {
        dispatch_sync(queue, ^{
            generation++;
            fadingOut = false;
            shownCount = 0;
            plane = nil;
            dispatch_source_set_timer(settled, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_timer(refresher, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_timer(popInTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            clearLayers();
            orderWindow(false);
            dropBeneath();
            overviewStopNow();
        });
    }
    if (liftQueue) {
        dispatch_sync(liftQueue, ^{
            dispatch_source_set_timer(liftGone, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            clearLift();
        });
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Internal bridge for overview.m (slide_internal.h)
// ---------------------------------------------------------------------------

dispatch_queue_t slideQueue(void) { return queue; }
bool slideIsStopping(void) { return atomic_load(&stopping); }
bool slideValidRect(CGRect r) { return validRect(r); }
Motion slideDefaultMotion(void) { return defaultMotion; }
void slideBeginChanges(void) { beginChanges(); }
void slideCommitChanges(void) { commitChanges(); }
CABasicAnimation *slideAnimate(Motion m, NSString *key, id from, id to, double velocity) {
    return animate(m, key, from, to, velocity);
}
bool slideCanCapture(void) {
    if (@available(macOS 10.15, *)) return CGPreflightScreenCaptureAccess();
    return true;
}
uint32_t slideCreateOverlay(CAContext **contextOut, CALayer **layerOut) {
    return newOverlay(cid, contextOut, layerOut);
}
void slidePlaceOverlay(uint32_t targetWid, CGRect *placedRect, double *placedSc, CGRect frame, double scale) {
    if (!targetWid) return;
    if (scale != *placedSc) {
        SLSSetWindowResolution(cid, targetWid, scale);
        *placedSc = scale;
    }
    if (CGRectEqualToRect(frame, *placedRect)) return;
    CGRect shape = { CGPointZero, frame.size };
    CFTypeRef region = NULL;
    CGSNewRegionWithRect(&shape, &region);
    if (region) {
        SLSSetWindowShape(cid, targetWid, frame.origin.x, frame.origin.y, region);
        CFRelease(region);
    }
    CFTypeRef t = SLSTransactionCreate(cid);
    if (t) {
        SLSTransactionMoveWindowWithGroup(t, targetWid, frame.origin);
        CGAffineTransform transform = CGAffineTransformIdentity;
        transform.tx = -frame.origin.x;
        transform.ty = -frame.origin.y;
        SLSTransactionSetWindowTransform(t, targetWid, 0, 0, transform);
        SLSTransactionCommit(t, 0);
        CFRelease(t);
    }
    *placedRect = frame;
}
void slideOrderOverlay(uint32_t targetWid, bool *isShown, bool in, int level) {
    if (!targetWid || in == *isShown) return;
    CFTypeRef t = SLSTransactionCreate(cid);
    if (!t) return;
    if (in) {
        SLSTransactionSetWindowLevel(t, targetWid, level);
        SLSTransactionOrderWindow(t, targetWid, ORDER_ABOVE, 0);
    } else {
        SLSTransactionOrderWindow(t, targetWid, ORDER_OUT, 0);
    }
    SLSTransactionCommit(t, 0);
    CFRelease(t);
    *isShown = in;
}
void slideReleaseOverlay(uint32_t *targetWid, CAContext **ctx, CALayer **layer,
                         bool *isShown, CGRect *placedRect, double *placedSc) {
    if (!*targetWid) return;
    slideOrderOverlay(*targetWid, isShown, false, OVERLAY_LEVEL);
    if (*ctx) {
        beginChanges();
        (*ctx).layer = nil;
        commitChanges();
    }
    SLSReleaseWindow(cid, *targetWid);
    if (*ctx && [*ctx respondsToSelector:@selector(invalidate)]) [*ctx performSelector:@selector(invalidate)];
    [*layer release];
    [*ctx release];
    *layer = nil;
    *ctx = nil;
    *targetWid = 0;
    *placedRect = CGRectZero;
    *placedSc = 0;
}
bool slideWindowBounds(uint32_t target, CGRect *bounds) {
    return SLSGetWindowBounds(cid, target, bounds) == kCGErrorSuccess;
}
CGImageRef slideCaptureWindows(uint32_t *wids, int count, CGRect *bounds, bool stacked) {
    return captureOn(cid, wids, count, bounds, stacked);
}
Shot *slideWallpaper(const char *monitor, CGRect display) {
    CGRect full = displayHolding(display);
    Shot *wall = wallpaperFor(monitor, full);
    if (!wall) wall = takeWallpaper(monitor, full, NULL);
    return wall;
}
CGFloat slideCornerRadius(uint32_t target, CGFloat fallback) {
    return cornerRadius(target, fallback);
}
CGRect slideReadRect(lua_State *L, int index) { return readRect(L, index); }
double slideNumberField(lua_State *L, int index, const char *key, double fallback) {
    return numberField(L, index, key, fallback);
}
Motion slideReadMotion(lua_State *L, int index, Motion fallback) {
    return readMotion(L, index, fallback);
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
    dropPicture(&beneath);
    beneathCount = 0;
    dropAllKept();
    slideThumbClear();
    overviewReleaseAll();
}

// Collected with the Lua state (reload, quit), before Lua unloads the
// library: the queues are drained and timers cancelled in dependency order.
static int l_gc(lua_State *L) {
    (void)L;
    luaCallbackClear(&onChange);
    luaCallbackClear(&onReady);
    atomic_store(&stopping, true);
    // Stop timers on `queue` first so no new capture can be submitted to
    // `captureQueue`, then drain `captureQueue` (whose completion blocks go
    // to `queue`), then drain `queue` a second time and release everything.
    dispatch_sync(queue, ^{
        overviewCancelTimers();
        dispatch_source_cancel(settled);
        dispatch_release(settled);
        settled = NULL;
        dispatch_source_cancel(refresher);
        dispatch_release(refresher);
        refresher = NULL;
        dispatch_source_cancel(popInTimer);
        dispatch_release(popInTimer);
        popInTimer = NULL;
    });
    dispatch_sync(captureQueue, ^{});
    dispatch_sync(queue, ^{
        releaseAll();
    });
    cancelDrain(&drain);
    cancelDrain(&captureDrain);
    dispatch_sync(queue, ^{});
    dispatch_sync(captureQueue, ^{});

    // Clear `liftQueue` under liftLock before draining so off-main liftMove()
    // cannot dispatch into a released queue during teardown.
    atomic_store(&liftWanted, 0);
    os_unfair_lock_lock(&liftLock);
    dispatch_queue_t lq = liftQueue;
    liftQueue = NULL;
    os_unfair_lock_unlock(&liftLock);
    if (lq) {
        dispatch_sync(lq, ^{
            dispatch_source_cancel(liftGone);
            dispatch_release(liftGone);
            liftGone = NULL;
            releaseLift();
        });
        cancelDrain(&liftDrain);
        dispatch_sync(lq, ^{});
        dispatch_release(lq);
    }
    SLSReleaseConnection(liftCid);
    dispatch_source_cancel(visibility);
    dispatch_release(visibility);
    visibility = NULL;
    dispatch_source_cancel(readySource);
    dispatch_release(readySource);
    readySource = NULL;
    dispatch_release(queue);
    queue = NULL;
    dispatch_release(captureQueue);
    captureQueue = NULL;
    SLSReleaseConnection(cid);
    SLSReleaseConnection(captureCid);
    return 0;
}

int luaopen_hyprspoon_native_slide(lua_State *L) {
    const char *missing = loadSymbols();
    if (missing) return luaL_error(L, "hyprspoon.native.slide: SkyLight has no %s", missing);
    if (!positionKey) {
        positionKey = [[NSString alloc] initWithUTF8String:"position"];
        slideKey = [[NSString alloc] initWithUTF8String:"slide"];
        boundsKey = [[NSString alloc] initWithUTF8String:"bounds"];
        sizeKey = [[NSString alloc] initWithUTF8String:"bounds.size"];
        opacityKey = [[NSString alloc] initWithUTF8String:"opacity"];
        scaleKey = [[NSString alloc] initWithUTF8String:"transform.scale"];
    }
    if (SLSNewConnection(0, &cid) != kCGErrorSuccess) return luaL_error(L, "hyprspoon.native.slide: no WindowServer connection");
    if (SLSNewConnection(0, &captureCid) != kCGErrorSuccess) {
        SLSReleaseConnection(cid);
        return luaL_error(L, "hyprspoon.native.slide: no WindowServer connection");
    }
    if (SLSNewConnection(0, &liftCid) != kCGErrorSuccess) {
        SLSReleaseConnection(cid);
        SLSReleaseConnection(captureCid);
        return luaL_error(L, "hyprspoon.native.slide: no WindowServer connection");
    }
    // The QoS goes in the attributes: retargeting a queue that autoreleases
    // per work item at a global queue traps in libdispatch (macOS 27).
    liftQueue = dispatch_queue_create("hyprspoon.slide.lift", dispatch_queue_attr_make_with_qos_class(
        dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM),
        QOS_CLASS_USER_INTERACTIVE, 0));
    liftDrainPort = MACH_PORT_NULL;
    if (SLSGetEventPort(liftCid, &liftDrainPort) == kCGErrorSuccess && liftDrainPort != MACH_PORT_NULL) {
        liftDrain = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, liftDrainPort, 0, liftQueue);
        dispatch_source_set_event_handler_f(liftDrain, drainLiftEvents);
        dispatch_resume(liftDrain);
        dispatch_async_f(liftQueue, NULL, drainLiftEvents);
    }
    liftGone = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, liftQueue);
    dispatch_source_set_timer(liftGone, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler_f(liftGone, liftGoneNow);
    dispatch_resume(liftGone);
    atomic_store(&liftWanted, 0);
    liftWid = 0;
    liftDrawn = false;
    liftShown = liftGoing = 0;
    liftPlaced = CGRectZero;
    liftPlacedScale = 0;
    captureQueue = dispatch_queue_create("hyprspoon.slide.capture",
        dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    captureDrainPort = MACH_PORT_NULL;
    if (SLSGetEventPort(captureCid, &captureDrainPort) == kCGErrorSuccess && captureDrainPort != MACH_PORT_NULL) {
        captureDrain = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, captureDrainPort, 0, captureQueue);
        dispatch_source_set_event_handler_f(captureDrain, drainCaptureEvents);
        dispatch_resume(captureDrain);
        dispatch_async_f(captureQueue, NULL, drainCaptureEvents);
    }
    atomic_store(&stopping, false);
    capturing = false;
    readySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler_f(readySource, deliverReady);
    dispatch_resume(readySource);
    readyCount = 0;
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
    popInTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(popInTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler_f(popInTimer, popInNew);
    dispatch_resume(popInTimer);
    popGeneration = 0;
    shownCount = 0;
    retileGeneration = 0;
    memset(pictures, 0, sizeof(pictures));
    memset(thumbs, 0, sizeof(thumbs));
    wallpaperCount = 0;
    wid = 0;
    shown = false;
    placed = CGRectZero;
    placedScale = 0;
    overviewInit();

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
        { "onReady", l_onReady },
        { "bounds", l_bounds },
        { "lifter", l_lifter },
        { "land", l_land },
        { "home", l_home },
        { "stop", l_stop },
        { "overviewOpen", l_overviewOpen },
        { "overviewUpdate", l_overviewUpdate },
        { "overviewDrag", l_overviewDrag },
        { "overviewClose", l_overviewClose },
        { "overviewStop", l_overviewStop },
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
