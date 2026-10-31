// tests/opaque_probe.m: prints what WindowServer reports about each app
// window's opacity, to see whether its "not opaque" flag tells a see-through
// window (a terminal background at 85%) from an ordinary one (#1).
//
// Read-only: it lists windows and queries them, and changes nothing.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//       tests/opaque_probe.m -o /tmp/opaque_probe && /tmp/opaque_probe
//
// /tmp/opaque_probe [-a] [app]: -a includes windows on other spaces and
// minimized ones; an app name shows only its windows, e.g. Ghostty.
// Window titles need the Screen Recording permission for the terminal that
// runs it; without it they print empty.
//
// What it showed on macOS 27 (#1): SLSGetWindowOpacity answers only for the
// caller's own windows. For another app's window it returns success and
// leaves its result untouched, so the opaque column prints "?". Neither the
// iterator's tags nor its attributes change when a window's opaque flag
// does, and CGWindowListCopyWindowInfo has no key for it. From outside the
// app, only alpha is readable.
//
// Columns:
//   cg-alpha  kCGWindowAlpha from CGWindowListCopyWindowInfo
//   sl-alpha  SLSGetWindowAlpha, the window's alpha as WindowServer has it
//   opaque    SLSGetWindowOpacity: the window's opaque flag, as an app sets it
//             through NSWindow.opaque: 1 opaque, 0 not, ? if the call wrote
//             nothing
//   it-alpha  SLSWindowIteratorGetAlpha
//   tags      SLSWindowIteratorGetTags
//   attrs     SLSWindowIteratorGetAttributes

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// SkyLight's calls are private; each is looked up so a missing one prints
// "-" instead of crashing.
static int (*SLSMainConnectionID)(void);
static CGError (*SLSGetWindowOpacity)(int, uint32_t, bool *);
static CGError (*SLSGetWindowAlpha)(int, uint32_t, float *);
static CFTypeRef (*SLSWindowQueryWindows)(int, CFArrayRef, uint32_t);
static CFTypeRef (*SLSWindowQueryResultCopyWindows)(CFTypeRef);
static bool (*SLSWindowIteratorAdvance)(CFTypeRef);
static uint32_t (*SLSWindowIteratorGetWindowID)(CFTypeRef);
static float (*SLSWindowIteratorGetAlpha)(CFTypeRef);
static uint64_t (*SLSWindowIteratorGetTags)(CFTypeRef);
static uint64_t (*SLSWindowIteratorGetAttributes)(CFTypeRef);

typedef struct {
    float alpha;
    uint64_t tags, attrs;
    bool found;
} Iterated;

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
#define LOAD(name) name = dlsym(RTLD_DEFAULT, #name)
        LOAD(SLSMainConnectionID);
        LOAD(SLSGetWindowOpacity);
        LOAD(SLSGetWindowAlpha);
        LOAD(SLSWindowQueryWindows);
        LOAD(SLSWindowQueryResultCopyWindows);
        LOAD(SLSWindowIteratorAdvance);
        LOAD(SLSWindowIteratorGetWindowID);
        LOAD(SLSWindowIteratorGetAlpha);
        LOAD(SLSWindowIteratorGetTags);
        LOAD(SLSWindowIteratorGetAttributes);
        if (!SLSMainConnectionID) {
            fprintf(stderr, "SkyLight not found\n");
            return 1;
        }
        int cid = SLSMainConnectionID();
        bool all = argc > 1 && strcmp(argv[1], "-a") == 0;
        const char *only = argc > 1 + all ? argv[1 + all] : NULL;

        CGWindowListOption options = all ? kCGWindowListOptionAll
                                         : kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements;
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(options, kCGNullWindowID));
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *w in windows) {
            // Layer 0 is where app windows sit; menus, the menu bar and
            // panels sit above it.
            if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
            if (only && ![w[(id)kCGWindowOwnerName] isEqualToString:@(only)]) continue;
            [rows addObject:w];
        }

        // The iterator reports windows in its own order, so key it by id.
        NSMutableDictionary<NSNumber *, NSValue *> *iterated = [NSMutableDictionary dictionary];
        if (SLSWindowQueryWindows && SLSWindowQueryResultCopyWindows && SLSWindowIteratorAdvance
            && SLSWindowIteratorGetWindowID) {
            NSMutableArray *ids = [NSMutableArray array];
            for (NSDictionary *w in rows) [ids addObject:w[(id)kCGWindowNumber]];
            CFTypeRef query = SLSWindowQueryWindows(cid, (__bridge CFArrayRef)ids, 0);
            CFTypeRef iterator = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
            while (iterator && SLSWindowIteratorAdvance(iterator)) {
                Iterated it = { -1, 0, 0, true };
                if (SLSWindowIteratorGetAlpha) it.alpha = SLSWindowIteratorGetAlpha(iterator);
                if (SLSWindowIteratorGetTags) it.tags = SLSWindowIteratorGetTags(iterator);
                if (SLSWindowIteratorGetAttributes) it.attrs = SLSWindowIteratorGetAttributes(iterator);
                iterated[@(SLSWindowIteratorGetWindowID(iterator))] = [NSValue valueWithBytes:&it
                                                                                     objCType:@encode(Iterated)];
            }
            if (iterator) CFRelease(iterator);
            if (query) CFRelease(query);
        }

        printf("%-6s %-22s %-28s %8s %8s %6s %8s %18s %18s\n", "id", "owner", "title", "cg-alpha",
               "sl-alpha", "opaque", "it-alpha", "tags", "attrs");
        for (NSDictionary *w in rows) {
            uint32_t wid = [w[(id)kCGWindowNumber] unsignedIntValue];
            NSString *title = w[(id)kCGWindowName] ?: @"";
            if (title.length > 28) title = [title substringToIndex:28];

            char sl[16] = "-", op[16] = "-", ia[16] = "-", tg[24] = "-", at[24] = "-";
            float alpha;
            if (SLSGetWindowAlpha && SLSGetWindowAlpha(cid, wid, &alpha) == kCGErrorSuccess)
                snprintf(sl, sizeof sl, "%.2f", alpha);
            // Start from a value the call can't write, to tell an answer
            // from none: it returns success either way.
            union { bool b; uint8_t raw; } opaque = { .raw = 0xAA };
            if (SLSGetWindowOpacity && SLSGetWindowOpacity(cid, wid, &opaque.b) == kCGErrorSuccess) {
                if (opaque.raw == 0xAA) snprintf(op, sizeof op, "?");
                else snprintf(op, sizeof op, "%u", opaque.raw);
            }
            NSValue *v = iterated[@(wid)];
            if (v) {
                Iterated it;
                [v getValue:&it];
                snprintf(ia, sizeof ia, "%.2f", it.alpha);
                snprintf(tg, sizeof tg, "0x%016llx", it.tags);
                snprintf(at, sizeof at, "0x%016llx", it.attrs);
            }
            printf("%-6u %-22.22s %-28s %8.2f %8s %6s %8s %18s %18s\n", wid,
                   [w[(id)kCGWindowOwnerName] UTF8String], title.UTF8String,
                   [w[(id)kCGWindowAlpha] floatValue], sl, op, ia, tg, at);
        }
    }
    return 0;
}
