// hyprspoon/native/overview.m: GPU-composited niri-style workspace overview.
//
// Compiled into hyprspoon/native/slide.so alongside slide.m so it shares
// wallpapers, workspace captures, per-window thumbnails, corner radii and
// CoreAnimation springs without duplicating WindowServer captures.
//
// Each display gets one SkyLight overlay window at OVERVIEW_LEVEL (102, matching
// hs.canvas.windowLevels.overlay) containing:
//   root
//     ├── backdropLayer   solid backdrop fading 0 -> 1 on open, 1 -> 0 on close
//     ├── stackLayer      scales 1.0 <-> zoom around the display centre
//     │     └── rowsLayer moves vertically as scrollY changes (workspace strip)
//     │           └── rowLayer[i]  (masksToBounds = NO: scrolling columns overflow)
//     │                 ├── shadowLayer     rounded workspace drop shadow
//     │                 ├── wallpaperClip   clipped wallpaper or dark surface
//     │                 ├── stripLayer      moves horizontally by -panX[i]
//     │                 │     └── window containers (capture or frosted card + ring)
//     │                 ├── wsBorderLayer   workspace outline / drop highlight
//     │                 └── labelLayer      workspace pill badge (optional)
//     └── dragLayer       floating window ghost following the pointer on drag
//
// All CALayer and SkyLight work runs on slideQueue() (serial dispatch queue).
// No ARC: every Cocoa / CoreGraphics / CoreText object is released explicitly.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "slide_internal.h"

#define OVERVIEW_LEVEL 102
#define MAX_OVERVIEW_DISPLAYS 8
#define MAX_OVERVIEW_WS 32
#define MAX_OVERVIEW_WINS 64
#define MAX_FLOAT_CAPTURES 8

typedef struct {
    uint32_t wid;
    CGRect frame; // global screen coordinates
    bool floating;
    bool focused;
    char app[64];
    char title[128];
} OvWinSpec;

typedef struct {
    int n;
    bool showing;
    bool empty;
    double panX;
    char label[48];
    int winCount;
    OvWinSpec wins[MAX_OVERVIEW_WINS];
} OvWsSpec;

typedef struct {
    CGRect frame; // display fullFrame
    double scale;
    char wallpaperPath[512];
    double scrollY; // 0-based workspace index
    int activeWs;   // 0-based selected workspace index
    uint32_t selectedWin;
    uint32_t hoveredWin;
    int dropWs;     // 0-based drop target workspace index, or -1
    int wsCount;
    OvWsSpec ws[MAX_OVERVIEW_WS];
} OvDisplaySpec;

typedef struct {
    double zoom;
    double gap;
    double radius;
    bool shadow;
    bool showLabels;
    bool captures;
    bool animate;
    bool backdropWallpaper;
    double backdropBlur;
    double backdropDim;
    CGFloat backdrop[4];
    CGFloat active[4];
    CGFloat inactive[4];
    CGFloat dropColor[4];
    Motion motion;
    int displayCount;
    OvDisplaySpec displays[MAX_OVERVIEW_DISPLAYS];
} OvOpenSpec;

// Live CoreAnimation layer state for one window inside one workspace row.
typedef struct {
    uint32_t wid;
    CALayer *container;
    CALayer *ring;
    CGRect localFrame; // relative to display origin, unscaled
    CGFloat radius;
    bool floating;
    char app[64];
    char title[128];
} OvWinView;

// Live CoreAnimation layer state for one workspace row.
typedef struct {
    int n;
    double panX;
    CALayer *rowLayer;
    CALayer *shadowLayer;
    CALayer *wallpaperClip;
    CALayer *wsBorderLayer;
    CALayer *stripLayer;
    CALayer *labelLayer;
    CALayer *labelBg;
    int winCount;
    OvWinView wins[MAX_OVERVIEW_WINS];
} OvWsView;

// Live CoreAnimation layer state for one display's overview window.
typedef struct {
    uint32_t wid;
    CAContext *context;
    CALayer *root;
    bool shown;
    CGRect placed;
    double placedScale;

    CGRect frame;
    double scale;
    double rowStep;
    double scrollY;
    int activeWs;
    uint32_t selectedWin;
    uint32_t hoveredWin;
    int dropWs;

    CALayer *backdropLayer;
    CALayer *stackLayer;
    CALayer *rowsLayer;
    CALayer *dragLayer;
    uint32_t dragWid;

    int wsCount;
    OvWsView ws[MAX_OVERVIEW_WS];
} OvDisplayView;

// Everything below belongs to slideQueue().
static OvDisplayView ovDisplays[MAX_OVERVIEW_DISPLAYS];
static int ovDisplayCount = 0;
static bool ovOpen = false;
static double ovZoom = 0.5;
static double ovGap = 24;
static double ovRadius = 12;
static bool ovShadow = true;
static bool ovShowLabels = true;
static CGFloat ovActiveColor[4] = { 0.42, 0.60, 0.73, 1.0 };
static CGFloat ovInactiveColor[4] = { 0.35, 0.35, 0.35, 0.67 };
static CGFloat ovDropColor[4] = { 0.35, 0.60, 1.0, 1.0 };
static Motion ovMotion = { false, 0.25, 0.6, 800, 38 };
static unsigned ovGeneration = 0;
static dispatch_source_t ovCloseTimer = NULL;
static unsigned ovClosingGen = 0;

static NSString *kScaleKey = nil;
static NSString *kPosKey = nil;
static NSString *kPosXKey = nil;
static NSString *kPosYKey = nil;
static NSString *kOpacityKey = nil;
static NSString *kCornerKey = nil;
static NSString *kShadowOpKey = nil;
static CTFontRef labelFont = NULL;
static CTFontRef appFont = NULL;
static CTFontRef titleFont = NULL;

// Cached file-loaded wallpapers (fallback when live wallpaper capture is unavailable)
// and GPU-blurred backdrop images (one per display slot, recomputed only if the
// source wallpaper or blur radius changes).
static CIContext *blurCIContext = NULL;

typedef struct {
    char path[512];
    CGImageRef image;
} FileWallEntry;

typedef struct {
    CGImageRef srcPtr;
    double srcTaken;
    double radius;
    CGImageRef blurred;
} BlurCacheEntry;

static FileWallEntry fileWallCache[MAX_OVERVIEW_DISPLAYS];
static BlurCacheEntry blurCache[MAX_OVERVIEW_DISPLAYS];

static void clearWallpaperCaches(void) {
    for (int i = 0; i < MAX_OVERVIEW_DISPLAYS; i++) {
        if (fileWallCache[i].image) {
            CGImageRelease(fileWallCache[i].image);
            fileWallCache[i].image = NULL;
        }
        fileWallCache[i].path[0] = '\0';
        if (blurCache[i].blurred) {
            CGImageRelease(blurCache[i].blurred);
            blurCache[i].blurred = NULL;
        }
        memset(&blurCache[i], 0, sizeof(blurCache[i]));
    }
    if (blurCIContext) {
        [blurCIContext release];
        blurCIContext = nil;
    }
}

static CGImageRef loadWallpaperFile(int slot, const char *path) {
    if (!path || !path[0] || slot < 0 || slot >= MAX_OVERVIEW_DISPLAYS) return NULL;
    if (fileWallCache[slot].image && strcmp(fileWallCache[slot].path, path) == 0) {
        return fileWallCache[slot].image;
    }
    if (fileWallCache[slot].image) {
        CGImageRelease(fileWallCache[slot].image);
        fileWallCache[slot].image = NULL;
    }
    fileWallCache[slot].path[0] = '\0';

    NSString *nsPath = [NSString stringWithUTF8String:path];
    if (!nsPath) return NULL;
    NSURL *url = [NSURL fileURLWithPath:nsPath];
    CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;

    strncpy(fileWallCache[slot].path, path, sizeof(fileWallCache[slot].path) - 1);
    fileWallCache[slot].path[sizeof(fileWallCache[slot].path) - 1] = '\0';
    fileWallCache[slot].image = img;
    return img;
}

// Produces (or returns cached) a GPU-blurred CGImageRef of `src` at half-res
// with edge clamping so borders never feather to transparent.
static CGImageRef blurredWallpaperFor(int slot, CGImageRef src, double srcTaken, double radius) {
    if (!src || radius <= 0.5 || slot < 0 || slot >= MAX_OVERVIEW_DISPLAYS) return NULL;
    BlurCacheEntry *c = &blurCache[slot];
    if (c->blurred && c->srcPtr == src && fabs(c->srcTaken - srcTaken) < 1e-6 && fabs(c->radius - radius) < 0.25) {
        return c->blurred;
    }
    if (c->blurred) {
        CGImageRelease(c->blurred);
        c->blurred = NULL;
    }
    size_t sw = CGImageGetWidth(src), sh = CGImageGetHeight(src);
    if (sw < 4 || sh < 4) return NULL;

    CGFloat down = (sw > 1200 || sh > 800) ? 0.5 : 1.0;
    CIImage *input = [CIImage imageWithCGImage:src];
    if (!input) return NULL;
    if (down < 1.0) {
        input = [input imageByApplyingTransform:CGAffineTransformMakeScale(down, down)];
    }
    CGRect extent = input.extent;
    CIImage *clamped = [input imageByClampingToExtent];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:clamped forKey:kCIInputImageKey];
    [blur setValue:@(radius * down) forKey:kCIInputRadiusKey];
    CIImage *output = [blur.outputImage imageByCroppingToRect:extent];
    if (!output) return NULL;

    if (!blurCIContext) {
        blurCIContext = [[CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }] retain];
    }
    CGImageRef rendered = [blurCIContext createCGImage:output fromRect:extent];
    if (!rendered) return NULL;

    c->srcPtr = src;
    c->srcTaken = srcTaken;
    c->radius = radius;
    c->blurred = rendered;
    return rendered;
}

static CGColorRef makeColor(const CGFloat rgba[4]) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGColorRef c = CGColorCreate(cs, rgba);
    CGColorSpaceRelease(cs);
    return c;
}

static CGColorRef makeRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    CGFloat vals[4] = { r, g, b, a };
    return makeColor(vals);
}

static void ensureKeysAndFonts(void) {
    if (!kScaleKey) {
        kScaleKey = [[NSString alloc] initWithUTF8String:"transform.scale"];
        kPosKey = [[NSString alloc] initWithUTF8String:"position"];
        kPosXKey = [[NSString alloc] initWithUTF8String:"position.x"];
        kPosYKey = [[NSString alloc] initWithUTF8String:"position.y"];
        kOpacityKey = [[NSString alloc] initWithUTF8String:"opacity"];
        kCornerKey = [[NSString alloc] initWithUTF8String:"cornerRadius"];
        kShadowOpKey = [[NSString alloc] initWithUTF8String:"shadowOpacity"];
    }
    if (!labelFont) {
        labelFont = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 13.0, NULL);
        if (!labelFont) labelFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 13.0, NULL);
    }
    if (!appFont) {
        appFont = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 18.0, NULL);
        if (!appFont) appFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 18.0, NULL);
    }
    if (!titleFont) {
        titleFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 13.0, NULL);
    }
}

static void removeSublayersRecursive(CALayer *parent) {
    if (!parent) return;
    NSArray *subs = [[parent.sublayers copy] autorelease];
    for (CALayer *sub in subs) {
        [sub removeAllAnimations];
        removeSublayersRecursive(sub);
        [sub removeFromSuperlayer];
    }
}

static void clearDisplayLayers(OvDisplayView *d) {
    if (d->root) {
        slideBeginChanges();
        [d->root removeAllAnimations];
        removeSublayersRecursive(d->root);
        slideCommitChanges();
    }
    d->backdropLayer = nil;
    d->stackLayer = nil;
    d->rowsLayer = nil;
    d->dragLayer = nil;
    d->dragWid = 0;
    d->wsCount = 0;
    memset(d->ws, 0, sizeof(d->ws));
}

static void ovCloseFinished(void *unused) {
    (void)unused;
    if (ovClosingGen != ovGeneration) return;
    ovOpen = false;
    for (int i = 0; i < MAX_OVERVIEW_DISPLAYS; i++) {
        clearDisplayLayers(&ovDisplays[i]);
        slideOrderOverlay(ovDisplays[i].wid, &ovDisplays[i].shown, false, OVERVIEW_LEVEL);
    }
    ovDisplayCount = 0;
}

static void stopOverviewOnQueue(void) {
    ovGeneration++;
    ovClosingGen = 0;
    ovOpen = false;
    if (ovCloseTimer) {
        dispatch_source_set_timer(ovCloseTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    }
    for (int i = 0; i < MAX_OVERVIEW_DISPLAYS; i++) {
        clearDisplayLayers(&ovDisplays[i]);
        slideOrderOverlay(ovDisplays[i].wid, &ovDisplays[i].shown, false, OVERVIEW_LEVEL);
    }
    ovDisplayCount = 0;
}

// Captures currently visible windows on each display so the active workspace
// (and our persistent thumbnail cache) has crisp real-time frames.
static void captureVisibleWindows(const OvOpenSpec *spec) {
    if (!spec->captures || !slideCanCapture()) return;
    for (int di = 0; di < spec->displayCount; di++) {
        const OvDisplaySpec *ds = &spec->displays[di];
        uint32_t tileWids[MAX_OVERVIEW_WINS];
        int tileCount = 0;
        uint32_t floatWids[MAX_FLOAT_CAPTURES];
        int floatCount = 0;
        for (int wi = 0; wi < ds->wsCount; wi++) {
            const OvWsSpec *ws = &ds->ws[wi];
            if (!ws->showing) continue;
            for (int k = 0; k < ws->winCount; k++) {
                const OvWinSpec *w = &ws->wins[k];
                CGRect b;
                if (!slideWindowBounds(w->wid, &b)) continue;
                CGRect inter = CGRectIntersection(b, ds->frame);
                if (CGRectIsNull(inter) || inter.size.width < 8 || inter.size.height < 8) continue;
                if (w->floating) {
                    if (floatCount < MAX_FLOAT_CAPTURES) floatWids[floatCount++] = w->wid;
                } else {
                    if (tileCount < MAX_OVERVIEW_WINS) tileWids[tileCount++] = w->wid;
                }
            }
        }
        if (tileCount > 0) {
            CGRect area = CGRectNull;
            CGImageRef img = slideCaptureWindows(tileWids, tileCount, &area, false);
            if (img) {
                uint32_t capWids[MAX_SHOT_WINS];
                CGRect capRects[MAX_SHOT_WINS];
                int capCount = 0;
                for (int k = 0; k < tileCount; k++) {
                    CGRect b;
                    if (slideWindowBounds(tileWids[k], &b)) {
                        CGRect inter = CGRectIntersection(b, area);
                        if (!CGRectIsNull(inter) && inter.size.width >= 4 && inter.size.height >= 4) {
                            slideThumbStore(tileWids[k], img, area, inter);
                            if (capCount < MAX_SHOT_WINS) {
                                capWids[capCount] = tileWids[k];
                                capRects[capCount] = inter;
                                capCount++;
                            }
                        }
                    }
                }
                // Keep slide.m's workspace picture warm when leaving via overview.
                if (floatCount == 0 && capCount > 0) {
                    for (int wi = 0; wi < ds->wsCount; wi++) {
                        if (ds->ws[wi].showing && ds->ws[wi].n != 0) {
                            slidePictureStore(ds->ws[wi].n, img, area, capWids, capRects, capCount);
                            break;
                        }
                    }
                }
                CGImageRelease(img);
            }
        }
        for (int k = 0; k < floatCount; k++) {
            uint32_t one[1] = { floatWids[k] };
            CGRect area = CGRectNull;
            CGImageRef img = slideCaptureWindows(one, 1, &area, false);
            if (img) {
                slideThumbStore(floatWids[k], img, area, area);
                if (tileCount == 0 && floatCount == 1) {
                    for (int wi = 0; wi < ds->wsCount; wi++) {
                        if (ds->ws[wi].showing && ds->ws[wi].n != 0) {
                            slidePictureStore(ds->ws[wi].n, img, area, one, &area, 1);
                            break;
                        }
                    }
                }
                CGImageRelease(img);
            }
        }
    }
}

// Builds a window content layer: real thumbnail from the cache if present,
// otherwise a dark rounded card with app name and window title.
static CALayer *makeWindowContentLayer(uint32_t targetWid, CGRect sizeRect, CGFloat radius,
                                       const char *app, const char *title, double scale, double zoom,
                                       bool useCaptures) {
    CALayer *content = [CALayer layer];
    content.frame = (CGRect){ CGPointZero, sizeRect.size };
    content.masksToBounds = YES;
    content.cornerRadius = radius;
    content.cornerCurve = kCACornerCurveContinuous;

    Thumb *thumb = useCaptures ? slideThumbLookup(targetWid) : NULL;
    if (thumb && thumb->image && thumb->area.size.width > 0 && thumb->area.size.height > 0) {
        content.contents = (id)thumb->image;
        CGFloat rx = (thumb->src.origin.x - thumb->area.origin.x) / thumb->area.size.width;
        CGFloat ry = (thumb->src.origin.y - thumb->area.origin.y) / thumb->area.size.height;
        CGFloat rw = thumb->src.size.width / thumb->area.size.width;
        CGFloat rh = thumb->src.size.height / thumb->area.size.height;
        rx = fmax(0.0, fmin(1.0, rx));
        ry = fmax(0.0, fmin(1.0, ry));
        rw = fmax(0.0, fmin(1.0 - rx, rw));
        rh = fmax(0.0, fmin(1.0 - ry, rh));
        content.contentsRect = CGRectMake(rx, ry, rw, rh);
        content.contentsGravity = kCAGravityResize;
        CGColorRef bg = makeRGBA(0.12, 0.13, 0.15, 1.0);
        content.backgroundColor = bg;
        CGColorRelease(bg);
        return content;
    }

    // Fallback card when no capture is cached or captures are disabled.
    CGColorRef cardBg = makeRGBA(0.17, 0.18, 0.21, 0.96);
    CGColorRef cardStroke = makeRGBA(1.0, 1.0, 1.0, 0.18);
    content.backgroundColor = cardBg;
    content.borderColor = cardStroke;
    content.borderWidth = fmax(1.0, 1.5 / zoom);
    CGColorRelease(cardBg);
    CGColorRelease(cardStroke);

    CGFloat w = sizeRect.size.width, h = sizeRect.size.height;
    CGFloat pad = fmin(24.0 / zoom, w * 0.08);
    CGFloat invZoom = 1.0 / fmax(0.15, zoom);
    CGFloat appPt = fmin(28.0 * invZoom, fmax(14.0, h * 0.09));
    CGFloat titlePt = fmin(16.0 * invZoom, fmax(11.0, h * 0.055));

    NSString *appStr = app && app[0] ? [NSString stringWithUTF8String:app] : @"Window";
    NSString *titleStr = title && title[0] ? [NSString stringWithUTF8String:title] : @"";

    if (h > appPt * 1.4 && w > pad * 2 + 20) {
        CATextLayer *appLabel = [CATextLayer layer];
        appLabel.string = appStr;
        if (appFont) appLabel.font = appFont;
        appLabel.fontSize = appPt;
        appLabel.alignmentMode = kCAAlignmentCenter;
        appLabel.truncationMode = kCATruncationEnd;
        appLabel.contentsScale = scale * fmax(1.0, zoom);
        CGColorRef white = makeRGBA(1.0, 1.0, 1.0, 0.95);
        appLabel.foregroundColor = white;
        CGColorRelease(white);
        CGFloat lineH = appPt * 1.3;
        CGFloat y = titleStr.length > 0 ? (h - lineH - titlePt * 1.5) / 2.0 : (h - lineH) / 2.0;
        appLabel.frame = CGRectMake(pad, fmax(4.0, y), w - 2 * pad, lineH);
        [content addSublayer:appLabel];

        if (titleStr.length > 0 && h > (appPt + titlePt) * 2.2) {
            CATextLayer *tLabel = [CATextLayer layer];
            tLabel.string = titleStr;
            if (titleFont) tLabel.font = titleFont;
            tLabel.fontSize = titlePt;
            tLabel.alignmentMode = kCAAlignmentCenter;
            tLabel.truncationMode = kCATruncationEnd;
            tLabel.contentsScale = scale * fmax(1.0, zoom);
            CGColorRef muted = makeRGBA(1.0, 1.0, 1.0, 0.62);
            tLabel.foregroundColor = muted;
            CGColorRelease(muted);
            tLabel.frame = CGRectMake(pad, fmax(4.0, y + lineH + 4.0), w - 2 * pad, titlePt * 1.35);
            [content addSublayer:tLabel];
        }
    }
    return content;
}

static void updateWsStyles(OvDisplayView *d, double zoom) {
    CGColorRef activeCol = makeColor(ovActiveColor);
    CGColorRef dropCol = makeColor(ovDropColor);
    CGColorRef subtleCol = makeRGBA(1.0, 1.0, 1.0, 0.16);
    CGColorRef pillBg = makeRGBA(0.08, 0.09, 0.11, 0.78);
    CGColorRef activePill = makeRGBA(ovActiveColor[0], ovActiveColor[1], ovActiveColor[2], 0.92);
    CGColorRef dropPill = makeRGBA(ovDropColor[0], ovDropColor[1], ovDropColor[2], 0.92);

    for (int wi = 0; wi < d->wsCount; wi++) {
        OvWsView *ws = &d->ws[wi];
        bool isDrop = (wi == d->dropWs);
        bool isActive = (wi == d->activeWs);
        if (ws->wsBorderLayer) {
            ws->wsBorderLayer.borderColor = isDrop ? dropCol : (isActive ? activeCol : subtleCol);
            ws->wsBorderLayer.borderWidth = (isDrop ? 4.0 : (isActive ? 2.5 : 1.0)) / zoom;
        }
        if (ws->labelBg) {
            ws->labelBg.backgroundColor = isDrop ? dropPill : (isActive ? activePill : pillBg);
        }
        for (int k = 0; k < ws->winCount; k++) {
            OvWinView *wv = &ws->wins[k];
            bool lit = (wv->wid == d->hoveredWin) || (isActive && wv->wid == d->selectedWin);
            if (wv->ring) {
                wv->ring.opacity = lit ? 1.0f : 0.0f;
            }
            if (wv->container) {
                wv->container.opacity = (d->dragWid && wv->wid == d->dragWid) ? 0.30f : 1.0f;
            }
        }
    }

    CGColorRelease(activeCol);
    CGColorRelease(dropCol);
    CGColorRelease(subtleCol);
    CGColorRelease(pillBg);
    CGColorRelease(activePill);
    CGColorRelease(dropPill);
}

static void buildDisplay(int idx, const OvOpenSpec *spec) {
    const OvDisplaySpec *ds = &spec->displays[idx];
    OvDisplayView *d = &ovDisplays[idx];
    if (!d->wid) {
        d->wid = slideCreateOverlay(&d->context, &d->root);
        if (!d->wid) return;
    }
    clearDisplayLayers(d);

    double fw = ds->frame.size.width;
    double fh = ds->frame.size.height;
    double zoom = spec->zoom;
    double rowStep = fh + spec->gap / zoom;
    double wsRadius = spec->radius / zoom;

    d->frame = ds->frame;
    d->scale = ds->scale;
    d->rowStep = rowStep;
    d->scrollY = ds->scrollY;
    d->activeWs = ds->activeWs;
    d->selectedWin = ds->selectedWin;
    d->hoveredWin = ds->hoveredWin;
    d->dropWs = ds->dropWs;
    d->wsCount = ds->wsCount;

    Shot *wall = (spec->captures && slideCanCapture()) ? slideWallpaper(ds->frame) : NULL;
    CGImageRef wallImg = wall ? wall->image : loadWallpaperFile(idx, ds->wallpaperPath);
    double wallTaken = wall ? wall->taken : 1.0;
    bool wallFromShot = (wall != NULL && wall->image != NULL);

    slideBeginChanges();
    d->root.frame = CGRectMake(0, 0, fw, fh);
    d->root.backgroundColor = NULL;

    // 1. Backdrop layer behind everything (macOS wallpaper with optional blur
    //    and dimming scrim, or solid backdropColor).
    CALayer *backdrop = [CALayer layer];
    backdrop.frame = CGRectMake(0, 0, fw, fh);
    backdrop.masksToBounds = YES;
    CGColorRef bgColor = makeColor(spec->backdrop);
    backdrop.backgroundColor = bgColor;
    CGColorRelease(bgColor);
    if (spec->backdropWallpaper && wallImg) {
        CGImageRef bgImg = (spec->backdropBlur > 0.5)
            ? blurredWallpaperFor(idx, wallImg, wallTaken, spec->backdropBlur)
            : NULL;
        CALayer *wpBg = [CALayer layer];
        wpBg.frame = wallFromShot
            ? CGRectMake(wall->bounds.origin.x - ds->frame.origin.x,
                         wall->bounds.origin.y - ds->frame.origin.y,
                         wall->bounds.size.width, wall->bounds.size.height)
            : CGRectMake(0, 0, fw, fh);
        wpBg.contents = (id)(bgImg ? bgImg : wallImg);
        wpBg.contentsGravity = wallFromShot ? kCAGravityResize : kCAGravityResizeAspectFill;
        [backdrop addSublayer:wpBg];
        if (spec->backdropDim > 0.001) {
            CALayer *scrim = [CALayer layer];
            scrim.frame = CGRectMake(0, 0, fw, fh);
            CGColorRef scrimCol = makeRGBA(0.0, 0.0, 0.0, spec->backdropDim);
            scrim.backgroundColor = scrimCol;
            CGColorRelease(scrimCol);
            [backdrop addSublayer:scrim];
        }
    }
    backdrop.opacity = 1.0f;
    [d->root addSublayer:backdrop];
    d->backdropLayer = backdrop;

    // 2. Stack layer: scales 1.0 -> zoom about the display centre.
    CALayer *stack = [CALayer layer];
    stack.bounds = CGRectMake(0, 0, fw, fh);
    stack.position = CGPointMake(fw / 2.0, fh / 2.0);
    stack.masksToBounds = NO;
    stack.transform = CATransform3DMakeScale(zoom, zoom, 1.0);
    [d->root addSublayer:stack];
    d->stackLayer = stack;

    // 3. Vertically stacked workspace rows.
    CALayer *rows = [CALayer layer];
    rows.anchorPoint = CGPointZero;
    rows.bounds = CGRectMake(0, 0, fw, fh);
    rows.position = CGPointMake(0, -ds->scrollY * rowStep);
    rows.masksToBounds = NO;
    [stack addSublayer:rows];
    d->rowsLayer = rows;

    CGColorRef activeCol = makeColor(spec->active);
    CGColorRef surfaceFill = makeRGBA(0.13, 0.14, 0.16, 0.96);
    CGColorRef emptyTint = makeRGBA(0.08, 0.09, 0.11, 0.35);
    CGColorRef blackCol = CGColorGetConstantColor(kCGColorBlack);

    for (int wi = 0; wi < ds->wsCount; wi++) {
        const OvWsSpec *ws = &ds->ws[wi];
        OvWsView *wv = &d->ws[wi];
        wv->n = ws->n;
        wv->panX = ws->panX;
        wv->winCount = ws->winCount;

        CALayer *row = [CALayer layer];
        row.anchorPoint = CGPointZero;
        row.frame = CGRectMake(0, wi * rowStep, fw, fh);
        row.masksToBounds = NO;
        [rows addSublayer:row];
        wv->rowLayer = row;

        // Workspace shadow behind the surface.
        CALayer *shadowL = [CALayer layer];
        shadowL.frame = CGRectMake(0, 0, fw, fh);
        shadowL.backgroundColor = surfaceFill;
        shadowL.cornerRadius = wsRadius;
        shadowL.cornerCurve = kCACornerCurveContinuous;
        if (spec->shadow) {
            shadowL.shadowColor = blackCol;
            shadowL.shadowOpacity = 0.55f;
            shadowL.shadowRadius = 22.0 / zoom;
            shadowL.shadowOffset = CGSizeMake(0, 8.0 / zoom);
            CGPathRef sp = CGPathCreateWithRoundedRect(CGRectMake(0, 0, fw, fh), wsRadius, wsRadius, NULL);
            shadowL.shadowPath = sp;
            CGPathRelease(sp);
        }
        [row addSublayer:shadowL];
        wv->shadowLayer = shadowL;

        // Clipped wallpaper surface (always crisp, unblurred).
        CALayer *wallClip = [CALayer layer];
        wallClip.frame = CGRectMake(0, 0, fw, fh);
        wallClip.masksToBounds = YES;
        wallClip.cornerRadius = wsRadius;
        wallClip.cornerCurve = kCACornerCurveContinuous;
        wallClip.backgroundColor = surfaceFill;
        if (wallImg) {
            CALayer *wp = [CALayer layer];
            wp.frame = wallFromShot
                ? CGRectMake(wall->bounds.origin.x - ds->frame.origin.x,
                             wall->bounds.origin.y - ds->frame.origin.y,
                             wall->bounds.size.width, wall->bounds.size.height)
                : CGRectMake(0, 0, fw, fh);
            wp.contents = (id)wallImg;
            wp.contentsGravity = wallFromShot ? kCAGravityResize : kCAGravityResizeAspectFill;
            [wallClip addSublayer:wp];
            if (ws->empty) {
                CALayer *dim = [CALayer layer];
                dim.frame = CGRectMake(0, 0, fw, fh);
                dim.backgroundColor = emptyTint;
                [wallClip addSublayer:dim];
            }
        }
        [row addSublayer:wallClip];
        wv->wallpaperClip = wallClip;

        // Workspace border (behind scrolling windows that cross the edge,
        // or above wallpaper so the monitor frame stays clear).
        CALayer *wsBorder = [CALayer layer];
        wsBorder.frame = CGRectMake(0, 0, fw, fh);
        wsBorder.cornerRadius = wsRadius;
        wsBorder.cornerCurve = kCACornerCurveContinuous;
        [row addSublayer:wsBorder];
        wv->wsBorderLayer = wsBorder;

        // Horizontal window strip (unclipped: scrolling columns extend past workspace edges).
        CALayer *strip = [CALayer layer];
        strip.anchorPoint = CGPointZero;
        strip.bounds = CGRectMake(0, 0, fw, fh);
        strip.position = CGPointMake(-ws->panX, 0);
        strip.masksToBounds = NO;
        [row addSublayer:strip];
        wv->stripLayer = strip;

        CGFloat ringWidth = 3.0 / zoom;
        for (int k = 0; k < ws->winCount; k++) {
            const OvWinSpec *w = &ws->wins[k];
            OvWinView *winView = &wv->wins[k];
            winView->wid = w->wid;
            winView->floating = w->floating;
            strncpy(winView->app, w->app, sizeof(winView->app) - 1);
            strncpy(winView->title, w->title, sizeof(winView->title) - 1);

            CGRect local = CGRectMake(w->frame.origin.x - ds->frame.origin.x,
                                      w->frame.origin.y - ds->frame.origin.y,
                                      w->frame.size.width, w->frame.size.height);
            winView->localFrame = local;
            CGFloat winRad = slideCornerRadius(w->wid, 12.0);
            winView->radius = winRad;

            CALayer *container = [CALayer layer];
            container.frame = local;
            container.masksToBounds = NO;
            if (w->floating) {
                container.shadowColor = blackCol;
                container.shadowOpacity = 0.45f;
                container.shadowRadius = 14.0 / zoom;
                container.shadowOffset = CGSizeMake(0, 6.0 / zoom);
            }
            CALayer *content = makeWindowContentLayer(w->wid, local, winRad, w->app, w->title,
                                                      ds->scale, zoom, spec->captures);
            [container addSublayer:content];

            CALayer *ring = [CALayer layer];
            ring.frame = CGRectInset(CGRectMake(0, 0, local.size.width, local.size.height), -ringWidth, -ringWidth);
            ring.cornerRadius = winRad + ringWidth;
            ring.cornerCurve = kCACornerCurveContinuous;
            ring.borderColor = activeCol;
            ring.borderWidth = ringWidth;
            ring.opacity = 0.0f;
            [container addSublayer:ring];

            [strip addSublayer:container];
            winView->container = container;
            winView->ring = ring;
        }

        // Workspace label pill in top-left corner of the workspace surface.
        if (spec->showLabels && ws->label[0]) {
            CGFloat inv = 1.0 / zoom;
            CGFloat pillH = 26.0 * inv;
            CGFloat fontSize = 13.0 * inv;
            NSString *lbl = [NSString stringWithUTF8String:ws->label];
            CGFloat estW = fmax(pillH, (CGFloat)lbl.length * fontSize * 0.65 + 16.0 * inv);
            CALayer *pill = [CALayer layer];
            pill.frame = CGRectMake(12.0 * inv, 12.0 * inv, estW, pillH);
            pill.cornerRadius = pillH * 0.35;
            pill.cornerCurve = kCACornerCurveContinuous;
            CGColorRef pBorder = makeRGBA(1.0, 1.0, 1.0, 0.22);
            pill.borderColor = pBorder;
            pill.borderWidth = 1.0 * inv;
            CGColorRelease(pBorder);

            CATextLayer *text = [CATextLayer layer];
            text.string = lbl;
            if (labelFont) text.font = labelFont;
            text.fontSize = fontSize;
            text.alignmentMode = kCAAlignmentCenter;
            text.truncationMode = kCATruncationEnd;
            text.contentsScale = ds->scale * fmax(1.0, zoom);
            CGColorRef white = makeRGBA(1.0, 1.0, 1.0, 0.96);
            text.foregroundColor = white;
            CGColorRelease(white);
            CGFloat th = fontSize * 1.25;
            text.frame = CGRectMake(4.0 * inv, (pillH - th) / 2.0, estW - 8.0 * inv, th);
            [pill addSublayer:text];

            [row addSublayer:pill];
            wv->labelLayer = pill;
            wv->labelBg = pill;
        }
    }

    // 4. Drag ghost layer (hidden until drag starts).
    CALayer *drag = [CALayer layer];
    drag.hidden = YES;
    drag.opacity = 0.85f;
    drag.shadowColor = blackCol;
    drag.shadowOpacity = 0.5f;
    drag.shadowRadius = 18.0;
    drag.shadowOffset = CGSizeMake(0, 8.0);
    [d->root addSublayer:drag];
    d->dragLayer = drag;

    updateWsStyles(d, zoom);

    // Zoom-out entrance animation from 1.0 -> zoom.
    if (spec->animate && !(spec->motion.ease && spec->motion.duration <= 0)) {
        [backdrop addAnimation:slideAnimate(spec->motion, kOpacityKey, @0.0, @1.0, 0) forKey:kOpacityKey];
        [stack addAnimation:slideAnimate(spec->motion, kScaleKey, @1.0, @(zoom), 0) forKey:kScaleKey];
        for (int wi = 0; wi < ds->wsCount; wi++) {
            OvWsView *wv = &d->ws[wi];
            if (wv->labelLayer) {
                [wv->labelLayer addAnimation:slideAnimate(spec->motion, kOpacityKey, @0.0, @1.0, 0) forKey:kOpacityKey];
            }
            if (wi == ds->activeWs) {
                if (wv->wallpaperClip) {
                    [wv->wallpaperClip addAnimation:slideAnimate(spec->motion, kCornerKey, @0.0, @(wsRadius), 0) forKey:kCornerKey];
                }
                if (wv->shadowLayer) {
                    [wv->shadowLayer addAnimation:slideAnimate(spec->motion, kCornerKey, @0.0, @(wsRadius), 0) forKey:kCornerKey];
                    if (spec->shadow) {
                        [wv->shadowLayer addAnimation:slideAnimate(spec->motion, kShadowOpKey, @0.0, @0.55, 0) forKey:kShadowOpKey];
                    }
                }
            }
        }
    }

    CGColorRelease(activeCol);
    CGColorRelease(surfaceFill);
    CGColorRelease(emptyTint);
    slideCommitChanges();

    slidePlaceOverlay(d->wid, &d->placed, &d->placedScale, ds->frame, ds->scale);
    slideOrderOverlay(d->wid, &d->shown, true, OVERVIEW_LEVEL);
}

// ---------------------------------------------------------------------------
// Lua reading helpers
// ---------------------------------------------------------------------------

static void readColorField(lua_State *L, int index, const char *key, CGFloat out[4], const CGFloat fallback[4]) {
    memcpy(out, fallback, sizeof(CGFloat) * 4);
    lua_getfield(L, index, key);
    if (lua_type(L, -1) == LUA_TTABLE) {
        for (int i = 0; i < 4; i++) {
            lua_rawgeti(L, -1, i + 1);
            double v = luaL_optnumber(L, -1, fallback[i]);
            out[i] = isfinite(v) ? fmin(1.0, fmax(0.0, v)) : fallback[i];
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}

static void readStringField(lua_State *L, int index, const char *key, char *buf, size_t size) {
    buf[0] = '\0';
    lua_getfield(L, index, key);
    if (lua_type(L, -1) == LUA_TSTRING) {
        const char *s = lua_tostring(L, -1);
        if (s) {
            strncpy(buf, s, size - 1);
            buf[size - 1] = '\0';
        }
    }
    lua_pop(L, 1);
}

static bool readBoolField(lua_State *L, int index, const char *key, bool fallback) {
    lua_getfield(L, index, key);
    bool v = lua_isnil(L, -1) ? fallback : (lua_toboolean(L, -1) != 0);
    lua_pop(L, 1);
    return v;
}

// overviewOpen(spec): opens (or rebuilds in-place when animate=false) the niri
// overview on every listed display.
int l_overviewOpen(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    OvOpenSpec *spec = calloc(1, sizeof(OvOpenSpec));
    if (!spec) {
        lua_pushboolean(L, 0);
        return 1;
    }

    double zoom = slideNumberField(L, 1, "zoom", 0.5);
    spec->zoom = isfinite(zoom) ? fmin(0.95, fmax(0.1, zoom)) : 0.5;
    double gap = slideNumberField(L, 1, "gap", 24.0);
    spec->gap = isfinite(gap) ? fmax(0.0, gap) : 24.0;
    double radius = slideNumberField(L, 1, "radius", 12.0);
    spec->radius = isfinite(radius) ? fmax(0.0, radius) : 12.0;
    spec->shadow = readBoolField(L, 1, "shadow", true);
    spec->showLabels = readBoolField(L, 1, "showLabels", true);
    spec->captures = readBoolField(L, 1, "captures", true);
    spec->animate = readBoolField(L, 1, "animate", true);
    spec->backdropWallpaper = readBoolField(L, 1, "backdropWallpaper", true);
    double bBlur = slideNumberField(L, 1, "backdropBlur", 20.0);
    spec->backdropBlur = isfinite(bBlur) ? fmin(100.0, fmax(0.0, bBlur)) : 20.0;
    double bDim = slideNumberField(L, 1, "backdropDim", 0.35);
    spec->backdropDim = isfinite(bDim) ? fmin(1.0, fmax(0.0, bDim)) : 0.35;

    const CGFloat defBg[4] = { 0.149, 0.149, 0.149, 1.0 };
    const CGFloat defActive[4] = { 0.424, 0.600, 0.729, 1.0 };
    const CGFloat defInactive[4] = { 0.349, 0.349, 0.349, 0.667 };
    const CGFloat defDrop[4] = { 0.35, 0.60, 1.0, 1.0 };
    readColorField(L, 1, "backdrop", spec->backdrop, defBg);
    readColorField(L, 1, "active", spec->active, defActive);
    readColorField(L, 1, "inactive", spec->inactive, defInactive);
    readColorField(L, 1, "dropColor", spec->dropColor, defDrop);

    lua_getfield(L, 1, "motion");
    spec->motion = slideReadMotion(L, -1, slideDefaultMotion());
    lua_pop(L, 1);

    lua_getfield(L, 1, "displays");
    if (lua_type(L, -1) == LUA_TTABLE) {
        lua_Integer dn = luaL_len(L, -1);
        for (lua_Integer di = 1; di <= dn && spec->displayCount < MAX_OVERVIEW_DISPLAYS; di++) {
            lua_rawgeti(L, -1, di);
            if (lua_type(L, -1) != LUA_TTABLE) { lua_pop(L, 1); continue; }
            OvDisplaySpec *ds = &spec->displays[spec->displayCount];
            lua_getfield(L, -1, "frame");
            ds->frame = slideReadRect(L, -1);
            lua_pop(L, 1);
            if (!slideValidRect(ds->frame)) { lua_pop(L, 1); continue; }
            double sc = slideNumberField(L, -1, "scale", 1.0);
            ds->scale = (isfinite(sc) && sc > 0) ? sc : 1.0;
            readStringField(L, -1, "wallpaperPath", ds->wallpaperPath, sizeof(ds->wallpaperPath));
            ds->scrollY = slideNumberField(L, -1, "scrollY", 1.0) - 1.0; // Lua 1-based -> C 0-based
            ds->activeWs = (int)slideNumberField(L, -1, "activeWs", 1.0) - 1;
            ds->selectedWin = (uint32_t)slideNumberField(L, -1, "selectedWin", 0);
            ds->hoveredWin = (uint32_t)slideNumberField(L, -1, "hoveredWin", 0);
            int drop = (int)slideNumberField(L, -1, "dropWs", 0);
            ds->dropWs = drop > 0 ? drop - 1 : -1;

            lua_getfield(L, -1, "workspaces");
            if (lua_type(L, -1) == LUA_TTABLE) {
                lua_Integer wn = luaL_len(L, -1);
                for (lua_Integer wi = 1; wi <= wn && ds->wsCount < MAX_OVERVIEW_WS; wi++) {
                    lua_rawgeti(L, -1, wi);
                    if (lua_type(L, -1) != LUA_TTABLE) { lua_pop(L, 1); continue; }
                    OvWsSpec *ws = &ds->ws[ds->wsCount++];
                    ws->n = (int)slideNumberField(L, -1, "n", 0);
                    ws->showing = readBoolField(L, -1, "showing", false);
                    ws->empty = readBoolField(L, -1, "empty", false);
                    ws->panX = slideNumberField(L, -1, "panX", 0.0);
                    readStringField(L, -1, "label", ws->label, sizeof(ws->label));

                    lua_getfield(L, -1, "windows");
                    if (lua_type(L, -1) == LUA_TTABLE) {
                        lua_Integer kn = luaL_len(L, -1);
                        for (lua_Integer k = 1; k <= kn && ws->winCount < MAX_OVERVIEW_WINS; k++) {
                            lua_rawgeti(L, -1, k);
                            if (lua_type(L, -1) != LUA_TTABLE) { lua_pop(L, 1); continue; }
                            OvWinSpec *w = &ws->wins[ws->winCount];
                            w->wid = (uint32_t)slideNumberField(L, -1, "wid", 0);
                            lua_getfield(L, -1, "frame");
                            w->frame = slideReadRect(L, -1);
                            lua_pop(L, 1);
                            w->floating = readBoolField(L, -1, "floating", false);
                            w->focused = readBoolField(L, -1, "focused", false);
                            readStringField(L, -1, "app", w->app, sizeof(w->app));
                            readStringField(L, -1, "title", w->title, sizeof(w->title));
                            if (w->wid && slideValidRect(w->frame)) ws->winCount++;
                            lua_pop(L, 1);
                        }
                    }
                    lua_pop(L, 1); // windows
                    lua_pop(L, 1); // ws
                }
            }
            lua_pop(L, 1); // workspaces
            if (ds->wsCount > 0) spec->displayCount++;
            lua_pop(L, 1); // display
        }
    }
    lua_pop(L, 1); // displays

    if (spec->displayCount == 0) {
        free(spec);
        lua_pushboolean(L, 0);
        return 1;
    }

    __block bool ok = false;
    dispatch_sync(slideQueue(), ^{
        ensureKeysAndFonts();
        ovGeneration++;
        ovClosingGen = 0;
        if (ovCloseTimer) {
            dispatch_source_set_timer(ovCloseTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        }
        ovZoom = spec->zoom;
        ovGap = spec->gap;
        ovRadius = spec->radius;
        ovShadow = spec->shadow;
        ovShowLabels = spec->showLabels;
        memcpy(ovActiveColor, spec->active, sizeof(ovActiveColor));
        memcpy(ovInactiveColor, spec->inactive, sizeof(ovInactiveColor));
        memcpy(ovDropColor, spec->dropColor, sizeof(ovDropColor));
        ovMotion = spec->motion;

        captureVisibleWindows(spec);

        for (int i = spec->displayCount; i < MAX_OVERVIEW_DISPLAYS; i++) {
            clearDisplayLayers(&ovDisplays[i]);
            slideOrderOverlay(ovDisplays[i].wid, &ovDisplays[i].shown, false, OVERVIEW_LEVEL);
        }
        ovDisplayCount = spec->displayCount;
        for (int i = 0; i < spec->displayCount; i++) {
            buildDisplay(i, spec);
            if (ovDisplays[i].shown) ok = true;
        }
        ovOpen = ok;
    });

    free(spec);
    lua_pushboolean(L, ok);
    return 1;
}

// overviewUpdate(state): updates scrollY, per-workspace panX, activeWs,
// selectedWin, hoveredWin, dropWs on each display (animated or immediate).
typedef struct {
    bool hasScrollY;
    double scrollY;
    int activeWs;
    uint32_t selectedWin;
    uint32_t hoveredWin;
    int dropWs;
    int panCount;
    double panX[MAX_OVERVIEW_WS];
} OvDisplayUpdate;

typedef struct {
    bool animate;
    Motion motion;
    int displayCount;
    OvDisplayUpdate displays[MAX_OVERVIEW_DISPLAYS];
} OvUpdateSpec;

int l_overviewUpdate(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    OvUpdateSpec *u = calloc(1, sizeof(OvUpdateSpec));
    if (!u) return 0;
    u->animate = readBoolField(L, 1, "animate", true);
    lua_getfield(L, 1, "motion");
    bool hasMotion = lua_type(L, -1) == LUA_TTABLE;
    if (hasMotion) u->motion = slideReadMotion(L, -1, slideDefaultMotion());
    lua_pop(L, 1);

    lua_getfield(L, 1, "displays");
    if (lua_type(L, -1) == LUA_TTABLE) {
        lua_Integer dn = luaL_len(L, -1);
        for (lua_Integer di = 1; di <= dn && u->displayCount < MAX_OVERVIEW_DISPLAYS; di++) {
            lua_rawgeti(L, -1, di);
            if (lua_type(L, -1) != LUA_TTABLE) { lua_pop(L, 1); continue; }
            OvDisplayUpdate *du = &u->displays[u->displayCount++];
            lua_getfield(L, -1, "scrollY");
            if (lua_isnumber(L, -1)) {
                du->hasScrollY = true;
                du->scrollY = lua_tonumber(L, -1) - 1.0;
            }
            lua_pop(L, 1);
            du->activeWs = (int)slideNumberField(L, -1, "activeWs", 1.0) - 1;
            du->selectedWin = (uint32_t)slideNumberField(L, -1, "selectedWin", 0);
            du->hoveredWin = (uint32_t)slideNumberField(L, -1, "hoveredWin", 0);
            int drop = (int)slideNumberField(L, -1, "dropWs", 0);
            du->dropWs = drop > 0 ? drop - 1 : -1;

            lua_getfield(L, -1, "panX");
            if (lua_type(L, -1) == LUA_TTABLE) {
                lua_Integer pn = luaL_len(L, -1);
                for (lua_Integer p = 1; p <= pn && du->panCount < MAX_OVERVIEW_WS; p++) {
                    lua_rawgeti(L, -1, p);
                    double v = luaL_optnumber(L, -1, 0.0);
                    du->panX[du->panCount++] = isfinite(v) ? v : 0.0;
                    lua_pop(L, 1);
                }
            }
            lua_pop(L, 1);
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    dispatch_async(slideQueue(), ^{
        if (ovOpen) {
            Motion m = hasMotion ? u->motion : ovMotion;
            bool anim = u->animate && !(m.ease && m.duration <= 0);
            slideBeginChanges();
            for (int i = 0; i < u->displayCount && i < ovDisplayCount; i++) {
                OvDisplayView *d = &ovDisplays[i];
                const OvDisplayUpdate *du = &u->displays[i];
                if (du->hasScrollY && d->rowsLayer) {
                    CGFloat fromY = ((CALayer *)d->rowsLayer.presentationLayer ?: d->rowsLayer).position.y;
                    CGFloat toY = -du->scrollY * d->rowStep;
                    d->scrollY = du->scrollY;
                    [d->rowsLayer removeAnimationForKey:kPosYKey];
                    d->rowsLayer.position = CGPointMake(0, toY);
                    if (anim && fabs(toY - fromY) >= 0.5) {
                        [d->rowsLayer addAnimation:slideAnimate(m, kPosYKey, @(fromY), @(toY), 0) forKey:kPosYKey];
                    }
                }
                for (int wi = 0; wi < du->panCount && wi < d->wsCount; wi++) {
                    OvWsView *wv = &d->ws[wi];
                    if (!wv->stripLayer) continue;
                    CGFloat fromX = ((CALayer *)wv->stripLayer.presentationLayer ?: wv->stripLayer).position.x;
                    CGFloat toX = -du->panX[wi];
                    wv->panX = du->panX[wi];
                    [wv->stripLayer removeAnimationForKey:kPosXKey];
                    wv->stripLayer.position = CGPointMake(toX, 0);
                    if (anim && fabs(toX - fromX) >= 0.5) {
                        [wv->stripLayer addAnimation:slideAnimate(m, kPosXKey, @(fromX), @(toX), 0) forKey:kPosXKey];
                    }
                }
                d->activeWs = du->activeWs;
                d->selectedWin = du->selectedWin;
                d->hoveredWin = du->hoveredWin;
                d->dropWs = du->dropWs;
                updateWsStyles(d, ovZoom);
            }
            slideCommitChanges();
        }
        free(u);
    });
    return 0;
}

// overviewDrag(specOrNil): shows/moves the floating drag ghost on the display
// holding the pointer, or hides it when spec is nil/false.
int l_overviewDrag(lua_State *L) {
    if (lua_isnoneornil(L, 1) || (lua_isboolean(L, 1) && !lua_toboolean(L, 1))) {
        dispatch_async(slideQueue(), ^{
            if (!ovOpen) return;
            slideBeginChanges();
            for (int i = 0; i < ovDisplayCount; i++) {
                OvDisplayView *d = &ovDisplays[i];
                d->dragWid = 0;
                d->dropWs = -1;
                if (d->dragLayer) {
                    d->dragLayer.hidden = YES;
                    removeSublayersRecursive(d->dragLayer);
                }
                updateWsStyles(d, ovZoom);
            }
            slideCommitChanges();
        });
        return 0;
    }

    luaL_checktype(L, 1, LUA_TTABLE);
    int displayIdx = (int)slideNumberField(L, 1, "display", 1.0) - 1;
    uint32_t targetWid = (uint32_t)slideNumberField(L, 1, "wid", 0);
    lua_getfield(L, 1, "frame");
    CGRect frame = slideReadRect(L, -1); // display-local rect
    lua_pop(L, 1);
    int dropWs = (int)slideNumberField(L, 1, "dropWs", 0) - 1;
    bool useCaptures = readBoolField(L, 1, "captures", true);
    char app[64], title[128];
    readStringField(L, 1, "app", app, sizeof(app));
    readStringField(L, 1, "title", title, sizeof(title));
    NSString *appNs = [[NSString alloc] initWithUTF8String:app];
    NSString *titleNs = [[NSString alloc] initWithUTF8String:title];

    dispatch_async(slideQueue(), ^{
        if (ovOpen && slideValidRect(frame)) {
            slideBeginChanges();
            for (int i = 0; i < ovDisplayCount; i++) {
                OvDisplayView *d = &ovDisplays[i];
                bool here = (i == displayIdx);
                d->dragWid = targetWid;
                d->dropWs = here ? dropWs : -1;
                if (d->dragLayer) {
                    if (!here) {
                        d->dragLayer.hidden = YES;
                    } else {
                        bool rebuild = d->dragLayer.hidden || d->dragLayer.sublayers.count == 0
                            || fabs(d->dragLayer.bounds.size.width - frame.size.width) > 1.0
                            || fabs(d->dragLayer.bounds.size.height - frame.size.height) > 1.0;
                        d->dragLayer.frame = frame;
                        d->dragLayer.hidden = NO;
                        if (rebuild) {
                            removeSublayersRecursive(d->dragLayer);
                            CGFloat r = slideCornerRadius(targetWid, 10.0) * ovZoom;
                            CALayer *card = makeWindowContentLayer(targetWid, frame, r,
                                [appNs UTF8String], [titleNs UTF8String], d->scale, 1.0, useCaptures);
                            CGColorRef activeCol = makeColor(ovActiveColor);
                            card.borderColor = activeCol;
                            card.borderWidth = 2.0;
                            CGColorRelease(activeCol);
                            [d->dragLayer addSublayer:card];
                        }
                    }
                }
                updateWsStyles(d, ovZoom);
            }
            slideCommitChanges();
        }
        [appNs release];
        [titleNs release];
    });
    return 0;
}

// overviewClose(spec): animates zoom back to 1.0 on each display's target
// workspace & horizontal panX, fades backdrop/labels out, then orders out.
// Returns the animation duration in seconds.
typedef struct {
    bool hasScrollY;
    double scrollY;
    int targetWs;
    bool hasPanX;
    double panX;
} OvCloseTarget;

typedef struct {
    Motion motion;
    int targetCount;
    OvCloseTarget targets[MAX_OVERVIEW_DISPLAYS];
} OvCloseSpec;

int l_overviewClose(lua_State *L) {
    OvCloseSpec *spec = calloc(1, sizeof(OvCloseSpec));
    if (!spec) {
        lua_pushnumber(L, 0);
        return 1;
    }
    bool hasMotion = false;
    if (lua_type(L, 1) == LUA_TTABLE) {
        lua_getfield(L, 1, "motion");
        if (lua_type(L, -1) == LUA_TTABLE) {
            hasMotion = true;
            spec->motion = slideReadMotion(L, -1, slideDefaultMotion());
        }
        lua_pop(L, 1);

        lua_getfield(L, 1, "displays");
        if (lua_type(L, -1) == LUA_TTABLE) {
            lua_Integer dn = luaL_len(L, -1);
            for (lua_Integer di = 1; di <= dn && spec->targetCount < MAX_OVERVIEW_DISPLAYS; di++) {
                lua_rawgeti(L, -1, di);
                if (lua_type(L, -1) != LUA_TTABLE) { lua_pop(L, 1); continue; }
                OvCloseTarget *t = &spec->targets[spec->targetCount++];
                lua_getfield(L, -1, "scrollY");
                if (lua_isnumber(L, -1)) {
                    t->hasScrollY = true;
                    t->scrollY = lua_tonumber(L, -1) - 1.0;
                }
                lua_pop(L, 1);
                t->targetWs = (int)slideNumberField(L, -1, "targetWs", 0) - 1;
                lua_getfield(L, -1, "panX");
                if (lua_isnumber(L, -1)) {
                    t->hasPanX = true;
                    t->panX = lua_tonumber(L, -1);
                }
                lua_pop(L, 1);
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
    }

    __block double duration = 0;
    dispatch_sync(slideQueue(), ^{
        if (!ovOpen) return;
        Motion m = hasMotion ? spec->motion : ovMotion;
        bool anim = !(m.ease && m.duration <= 0);
        ovGeneration++;
        unsigned gen = ovGeneration;

        if (!anim) {
            stopOverviewOnQueue();
            return;
        }

        double maxDur = 0;
        slideBeginChanges();
        for (int i = 0; i < ovDisplayCount; i++) {
            OvDisplayView *d = &ovDisplays[i];
            if (!d->stackLayer) continue;
            if (d->dragLayer) d->dragLayer.hidden = YES;

            int targetWs = d->activeWs;
            double targetScrollY = d->scrollY;
            bool hasPan = false;
            double targetPanX = 0;
            if (i < spec->targetCount) {
                if (spec->targets[i].hasScrollY) targetScrollY = spec->targets[i].scrollY;
                if (spec->targets[i].targetWs >= 0) targetWs = spec->targets[i].targetWs;
                if (spec->targets[i].hasPanX) {
                    hasPan = true;
                    targetPanX = spec->targets[i].panX;
                }
            }

            // Zoom stackLayer smoothly back to 1.0.
            CALayer *presStack = (CALayer *)d->stackLayer.presentationLayer ?: d->stackLayer;
            NSNumber *fromScale = [presStack valueForKeyPath:@"transform.scale"] ?: @(ovZoom);
            [d->stackLayer removeAnimationForKey:kScaleKey];
            d->stackLayer.transform = CATransform3DIdentity;
            CABasicAnimation *zoomAnim = slideAnimate(m, kScaleKey, fromScale, @1.0, 0);
            [d->stackLayer addAnimation:zoomAnim forKey:kScaleKey];
            maxDur = fmax(maxDur, zoomAnim.duration);

            // Pan rowsLayer to centre on the target workspace.
            if (d->rowsLayer) {
                CGFloat fromY = ((CALayer *)d->rowsLayer.presentationLayer ?: d->rowsLayer).position.y;
                CGFloat toY = -targetScrollY * d->rowStep;
                [d->rowsLayer removeAnimationForKey:kPosYKey];
                d->rowsLayer.position = CGPointMake(0, toY);
                if (fabs(toY - fromY) >= 0.5) {
                    CABasicAnimation *pa = slideAnimate(m, kPosYKey, @(fromY), @(toY), 0);
                    [d->rowsLayer addAnimation:pa forKey:kPosYKey];
                    maxDur = fmax(maxDur, pa.duration);
                }
            }

            // Fade backdrop out.
            if (d->backdropLayer) {
                CGFloat fromOp = ((CALayer *)d->backdropLayer.presentationLayer ?: d->backdropLayer).opacity;
                [d->backdropLayer removeAnimationForKey:kOpacityKey];
                d->backdropLayer.opacity = 0.0f;
                [d->backdropLayer addAnimation:slideAnimate(m, kOpacityKey, @(fromOp), @0.0, 0) forKey:kOpacityKey];
            }

            // Un-round target workspace corners & fade shadows, borders, labels, rings.
            for (int wi = 0; wi < d->wsCount; wi++) {
                OvWsView *wv = &d->ws[wi];
                if (wv->labelLayer) {
                    wv->labelLayer.opacity = 0.0f;
                    [wv->labelLayer addAnimation:slideAnimate(m, kOpacityKey, @1.0, @0.0, 0) forKey:kOpacityKey];
                }
                if (wv->wsBorderLayer) {
                    wv->wsBorderLayer.opacity = 0.0f;
                    [wv->wsBorderLayer addAnimation:slideAnimate(m, kOpacityKey, @1.0, @0.0, 0) forKey:kOpacityKey];
                }
                for (int k = 0; k < wv->winCount; k++) {
                    if (wv->wins[k].ring) {
                        wv->wins[k].ring.opacity = 0.0f;
                    }
                }
                if (wi == targetWs) {
                    if (wv->wallpaperClip) {
                        CGFloat fromR = wv->wallpaperClip.cornerRadius;
                        wv->wallpaperClip.cornerRadius = 0;
                        [wv->wallpaperClip addAnimation:slideAnimate(m, kCornerKey, @(fromR), @0.0, 0) forKey:kCornerKey];
                    }
                    if (wv->shadowLayer) {
                        CGFloat fromR = wv->shadowLayer.cornerRadius;
                        wv->shadowLayer.cornerRadius = 0;
                        wv->shadowLayer.shadowOpacity = 0;
                        [wv->shadowLayer addAnimation:slideAnimate(m, kCornerKey, @(fromR), @0.0, 0) forKey:kCornerKey];
                        if (ovShadow) {
                            [wv->shadowLayer addAnimation:slideAnimate(m, kShadowOpKey, @0.55, @0.0, 0) forKey:kShadowOpKey];
                        }
                    }
                    if (hasPan && wv->stripLayer) {
                        CGFloat fromX = ((CALayer *)wv->stripLayer.presentationLayer ?: wv->stripLayer).position.x;
                        CGFloat toX = -targetPanX;
                        [wv->stripLayer removeAnimationForKey:kPosXKey];
                        wv->stripLayer.position = CGPointMake(toX, 0);
                        if (fabs(toX - fromX) >= 0.5) {
                            CABasicAnimation *xa = slideAnimate(m, kPosXKey, @(fromX), @(toX), 0);
                            [wv->stripLayer addAnimation:xa forKey:kPosXKey];
                            maxDur = fmax(maxDur, xa.duration);
                        }
                    }
                }
            }
        }
        slideCommitChanges();

        ovClosingGen = gen;
        duration = maxDur;
        if (ovCloseTimer) {
            dispatch_source_set_timer(ovCloseTimer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmax(0.01, maxDur) * NSEC_PER_SEC)),
                DISPATCH_TIME_FOREVER, 0);
        }
    });

    free(spec);
    lua_pushnumber(L, duration);
    return 1;
}

// overviewStop(): tears down overview overlays immediately without animation.
int l_overviewStop(lua_State *L) {
    (void)L;
    dispatch_sync(slideQueue(), ^{
        stopOverviewOnQueue();
    });
    return 0;
}

// ---------------------------------------------------------------------------
// Lifecycle (called from slide.m)
// ---------------------------------------------------------------------------

void overviewInit(void) {
    memset(ovDisplays, 0, sizeof(ovDisplays));
    ovDisplayCount = 0;
    ovOpen = false;
    ovGeneration = 0;
    ovClosingGen = 0;
    ovCloseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, slideQueue());
    dispatch_source_set_timer(ovCloseTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler_f(ovCloseTimer, ovCloseFinished);
    dispatch_resume(ovCloseTimer);
}

void overviewStopNow(void) {
    stopOverviewOnQueue();
}

void overviewCancelTimers(void) {
    ovGeneration++;
    ovClosingGen = 0;
    if (ovCloseTimer) {
        dispatch_source_cancel(ovCloseTimer);
        dispatch_release(ovCloseTimer);
        ovCloseTimer = NULL;
    }
}

void overviewReleaseAll(void) {
    stopOverviewOnQueue();
    clearWallpaperCaches();
    for (int i = 0; i < MAX_OVERVIEW_DISPLAYS; i++) {
        OvDisplayView *d = &ovDisplays[i];
        slideReleaseOverlay(&d->wid, &d->context, &d->root, &d->shown, &d->placed, &d->placedScale);
    }
    if (labelFont) { CFRelease(labelFont); labelFont = NULL; }
    if (appFont) { CFRelease(appFont); appFont = NULL; }
    if (titleFont) { CFRelease(titleFont); titleFont = NULL; }
}
