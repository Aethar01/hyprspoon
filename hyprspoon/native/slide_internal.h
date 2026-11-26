// hyprspoon/native/slide_internal.h: Internal interface shared between slide.m and overview.m.

#ifndef HYPRSPOON_SLIDE_INTERNAL_H
#define HYPRSPOON_SLIDE_INTERNAL_H

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>

#include "lauxlib.h"
#include "lua.h"

@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(uint32_t)cid options:(NSDictionary *)options;
@property (retain) CALayer *layer;
@end

#define MAX_SHOT_WINS 32
#define MONITOR_ID_MAX 64

typedef struct {
    int key;
    char monitor[MONITOR_ID_MAX];
    CGImageRef image;
    CGRect bounds;
    CGRect lastDisplay; // last active full display bounds (for wallpaper refresh)
    bool relative;      // bounds (and winRects) are relative to display's fullFrame.origin
    bool fallback;      // file-loaded wallpaper fallback (aspect-fill; upgrade on live capture)
    bool black;         // live wallpaper capture was solid black (eligible for settle retry)
    double taken;
    int winCount;
    uint32_t wids[MAX_SHOT_WINS];
    CGRect winRects[MAX_SHOT_WINS];
} Shot;

typedef struct {
    bool ease;
    double duration, mass, stiffness, damping;
} Motion;

typedef struct {
    uint32_t wid;
    char monitor[MONITOR_ID_MAX];
    CGImageRef image; // retained; often shared across tiles from one capture
    CGRect area;      // capture bounds (matches `src` coordinate space)
    CGRect src;       // window bounds at capture time
    double taken;
} Thumb;

// Shared queue and state accessors (owned by slide.m).
dispatch_queue_t slideQueue(void);
bool slideIsStopping(void);
bool slideCanCapture(void);
bool slideValidRect(CGRect r);
Motion slideDefaultMotion(void);

// CoreAnimation helpers (called on slideQueue()).
void slideBeginChanges(void);
void slideCommitChanges(void);
CABasicAnimation *slideAnimate(Motion m, NSString *key, id from, id to, double velocity);

// SkyLight overlay window helpers (called on slideQueue()).
uint32_t slideCreateOverlay(CAContext **contextOut, CALayer **layerOut);
void slidePlaceOverlay(uint32_t targetWid, CGRect *placed, double *placedScale, CGRect frame, double scale);
void slideOrderOverlay(uint32_t targetWid, bool *shown, bool in, int level);
void slideReleaseOverlay(uint32_t *targetWid, CAContext **ctx, CALayer **layer,
                         bool *shown, CGRect *placed, double *placedScale);

// Capture and window query helpers (called on slideQueue()).
bool slideWindowBounds(uint32_t target, CGRect *bounds);
CGImageRef slideCaptureWindows(uint32_t *wids, int count, CGRect *bounds, bool stacked);
Shot *slideWallpaper(const char *monitor, CGRect display);
CGFloat slideCornerRadius(uint32_t target, CGFloat fallback);

// Thumbnail cache (called on slideQueue()).
void slideThumbStore(const char *monitor, uint32_t target, CGImageRef image, CGRect area, CGRect src);
Thumb *slideThumbLookup(const char *monitor, uint32_t target);
void slideThumbForget(uint32_t target);
void slideThumbForgetMonitor(const char *monitor);
void slideThumbClear(void);
void slidePictureStore(const char *monitor, int key, CGImageRef image, CGRect bounds, CGRect display,
                       const uint32_t *wids, const CGRect *winRects, int winCount);

// Lua argument readers.
CGRect slideReadRect(lua_State *L, int index);
double slideNumberField(lua_State *L, int index, const char *key, double fallback);
Motion slideReadMotion(lua_State *L, int index, Motion fallback);

// Overview lifecycle hooks (implemented in overview.m, called from slide.m).
void overviewInit(void);
void overviewStopNow(void);
void overviewCancelTimers(void);
void overviewReleaseAll(void);

// Overview Lua entry points (implemented in overview.m, registered by slide.m).
int l_overviewOpen(lua_State *L);
int l_overviewUpdate(lua_State *L);
int l_overviewDrag(lua_State *L);
int l_overviewClose(lua_State *L);
int l_overviewStop(lua_State *L);

#endif
