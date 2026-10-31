// tests/opaque_probe.m: prints what WindowServer reports about each app
// window's opacity, to see whether its "not opaque" flag tells a see-through
// window (a terminal background at 85%) from an ordinary one (#1).
//
// Read-only by default. -s also creates, changes and closes its own test window.
//
//   clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreGraphics \
//       tests/opaque_probe.m -o /tmp/opaque_probe && /tmp/opaque_probe
//
// /tmp/opaque_probe [-a] [-s] [app]: -a includes windows on other spaces and
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
//             nothing; extra output bytes are reported
//   it-alpha  SLSWindowIteratorGetAlpha
//   tags      SLSWindowIteratorGetTags
//   attrs     SLSWindowIteratorGetAttributes

#import <AppKit/AppKit.h>
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
} Iterated;

static void readOpacity(int cid, uint32_t wid, const char *label) {
    unsigned char bytes[8];
    memset(bytes, 0xAA, sizeof bytes);
    if (!SLSGetWindowOpacity) { printf("%s opaque=- (getter missing)\n", label); return; }
    CGError err = SLSGetWindowOpacity(cid, wid, (bool *)bytes);
    if (err != kCGErrorSuccess) { printf("%s opaque=error(%d)\n", label, err); return; }
    bool extra = false;
    for (size_t i = 1; i < sizeof bytes; i++) if (bytes[i] != 0xAA) extra = true;
    printf("%s opaque=%u extra-bytes-written=%s\n", label, bytes[0], extra ? "yes" : "no");
}

static void selfTest(int cid) {
    [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 120, 80)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.opaque = NO;
    window.alphaValue = 0.85;
    [window orderFrontRegardless];
    uint32_t wid = (uint32_t)window.windowNumber;
    printf("self-test window=%u\n", wid);
    readOpacity(cid, wid, "opaque=NO alpha=0.85");
    window.opaque = YES;
    window.alphaValue = 1.0;
    readOpacity(cid, wid, "opaque=YES alpha=1.00");
    window.opaque = NO;
    window.alphaValue = 0.85;
    readOpacity(cid, wid, "opaque=NO alpha=0.85 (again)");
    [window orderOut:nil];
    [window close];
}

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
        bool all = false, self = false;
        const char *only = NULL;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-a") == 0) all = true;
            else if (strcmp(argv[i], "-s") == 0) self = true;
            else if (argv[i][0] == '-') { fprintf(stderr, "unknown option: %s\n", argv[i]); return 2; }
            else if (only) { fprintf(stderr, "unexpected argument: %s\n", argv[i]); return 2; }
            else only = argv[i];
        }
        if (self) selfTest(cid);

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
                Iterated it = { -1, 0, 0 };
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
            if (title.length > 28) {
                NSRange range = [title rangeOfComposedCharacterSequenceAtIndex:27];
                title = [title substringToIndex:range.location];
            }

            char sl[16] = "-", op[16] = "-", ia[16] = "-", tg[24] = "-", at[24] = "-";
            float alpha;
            if (SLSGetWindowAlpha && SLSGetWindowAlpha(cid, wid, &alpha) == kCGErrorSuccess)
                snprintf(sl, sizeof sl, "%.2f", alpha);
            // Start from a value the call can't write, to tell an answer
            // from none: it returns success either way.
            if (SLSGetWindowOpacity) {
                unsigned char bytes[8]; memset(bytes, 0xAA, sizeof bytes);
                if (SLSGetWindowOpacity(cid, wid, (bool *)bytes) == kCGErrorSuccess) {
                    if (bytes[0] == 0xAA) snprintf(op, sizeof op, "?");
                    else {
                        bool changed = false;
                        for (size_t i = 1; i < sizeof bytes; i++) if (bytes[i] != 0xAA) changed = true;
                        snprintf(op, sizeof op, "%u%s", bytes[0], changed ? "!" : "");
                    }
                }
            }
            NSValue *v = iterated[@(wid)];
            if (v) {
                Iterated it;
                [v getValue:&it];
                if (SLSWindowIteratorGetAlpha) snprintf(ia, sizeof ia, "%.2f", it.alpha);
                if (SLSWindowIteratorGetTags) snprintf(tg, sizeof tg, "0x%016llx", it.tags);
                if (SLSWindowIteratorGetAttributes) snprintf(at, sizeof at, "0x%016llx", it.attrs);
            }
            char cg[16] = "-";
            if (w[(id)kCGWindowAlpha]) snprintf(cg, sizeof cg, "%.2f", [w[(id)kCGWindowAlpha] floatValue]);
            const char *owner = [w[(id)kCGWindowOwnerName] UTF8String] ?: "";
            const char *titleUTF8 = title.UTF8String ?: "";
            printf("%-6u %-22.22s %-28s %8s %8s %6s %8s %18s %18s\n", wid,
                   owner, titleUTF8, cg, sl, op, ia, tg, at);
        }
    }
    return 0;
}
