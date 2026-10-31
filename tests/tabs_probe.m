// tests/tabs_probe.m: prints what WindowServer and the accessibility API
// report about each app window, to find a reliable sign of a native
// background tab (#11).
//
// Read-only: it never presses, moves or closes anything.
//
//   clang -fobjc-arc -framework AppKit -framework ApplicationServices \
//       tests/tabs_probe.m -o /tmp/tabs_probe && /tmp/tabs_probe
//
// /tmp/tabs_probe [app...]: lists every layer-0 window of the named apps
// (default Finder TextEdit Terminal Ghostty Preview Xcode), then each app's
// accessibility windows and their tab bars.
// /tmp/tabs_probe -w ms [app...]: watches the apps' windows for ms
// milliseconds, sampling WindowServer about every millisecond, and prints
// each change in on-screen state or frame with a wall-clock time. Switch a
// tab while it runs to see how quickly the new tab shows.
//
// Window titles need the Screen Recording permission for the terminal that
// runs it, and the accessibility part needs Accessibility; without them,
// titles print empty and the accessibility part is skipped.
// tests/tabs_probe.lua shows the accessibility side from inside Hammerspoon.
//
// What it showed on macOS 27 (#11), in Finder, TextEdit, Terminal, Preview
// and Ghostty (with a native title bar): a native background tab is a
// layer-0 window, alpha 1, that is off screen (no kCGWindowIsOnscreen, not in
// the on-screen list) and on no Space at all. Minimized windows and windows
// of hidden apps are off screen too but keep their Space; windows parked by
// hyprspoon stay on screen. A background tab's frame is stale (the frame it
// had when last shown), so it need not match the shown tab's. AXWindows
// lists only the shown tab, except while the set is minimized. The tab bar
// (AXTabGroup) has one AXRadioButton/AXTabButton per tab, AXValue 1 or
// true on the selected one, each taking AXPress; a plain AXButton is the
// "new tab" button. A tab switch swaps the two windows' on-screen state in
// one WindowServer update, 35-55ms after the press. Window IDs stay the
// same through switches, tear-off and merge. Per-app results are on #11.
//
// Columns of the WindowServer table:
//   onscr   kCGWindowIsOnscreen
//   listed  in the on-screen-only list (kCGWindowListOptionOnScreenOnly)
//   alpha   kCGWindowAlpha
//   spaces  SLSCopySpacesForWindows: the Spaces the window is on
//   frame   kCGWindowBounds, x,y wxh

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// SkyLight's calls are private; each is looked up so a missing one prints
// "-" instead of crashing.
static int (*SLSMainConnectionID)(void);
static CFArrayRef (*SLSCopySpacesForWindows)(int, int, CFArrayRef);
// Maps an accessibility window to its CGWindowID. Private, but stable for
// years; Hammerspoon's hs.window:id() uses it.
static AXError (*AXGetWindow)(AXUIElementRef, CGWindowID *);

static NSArray<NSString *> *defaultApps(void) {
    return @[ @"Finder", @"TextEdit", @"Terminal", @"Ghostty", @"Preview", @"Xcode" ];
}

static BOOL wanted(NSString *owner, NSArray<NSString *> *apps) {
    for (NSString *a in apps)
        if ([owner caseInsensitiveCompare:a] == NSOrderedSame) return YES;
    return NO;
}

static NSString *clip(NSString *s, NSUInteger n) {
    if (!s) return @"";
    if (s.length <= n) return s;
    NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:n - 1];
    return [[s substringToIndex:r.location] stringByAppendingString:@"…"];
}

static NSString *frameText(NSDictionary *bounds) {
    return [NSString stringWithFormat:@"%d,%d %dx%d", [bounds[@"X"] intValue], [bounds[@"Y"] intValue],
                                      [bounds[@"Width"] intValue], [bounds[@"Height"] intValue]];
}

static NSString *spacesText(int cid, uint32_t wid) {
    if (!SLSCopySpacesForWindows) return @"-";
    NSArray *spaces = CFBridgingRelease(SLSCopySpacesForWindows(cid, 0x7, (__bridge CFArrayRef) @[ @(wid) ]));
    if (!spaces.count) return @"none";
    return [spaces componentsJoinedByString:@"+"];
}

// Layer-0 windows of the wanted apps, in WindowServer's front-to-back order.
static NSArray<NSDictionary *> *appWindows(NSArray<NSString *> *apps, NSSet<NSNumber *> **listed) {
    NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    NSArray *on = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableSet *ids = [NSMutableSet set];
    for (NSDictionary *w in on) [ids addObject:w[(id)kCGWindowNumber]];
    if (listed) *listed = ids;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *w in all) {
        // Layer 0 is where app windows sit; menus, the menu bar and
        // panels sit above it.
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
        if (!wanted(w[(id)kCGWindowOwnerName], apps)) continue;
        [rows addObject:w];
    }
    return rows;
}

static void printWindowServer(int cid, NSArray<NSString *> *apps) {
    NSSet *listed;
    NSArray *rows = appWindows(apps, &listed);
    printf("WindowServer (layer 0, all windows)\n");
    printf("%-7s %-6s %-9s %5s %6s %5s %-12s %-20s %s\n", "id", "pid", "owner", "onscr", "listed", "alpha",
           "spaces", "frame", "title");
    for (NSDictionary *w in rows) {
        uint32_t wid = [w[(id)kCGWindowNumber] unsignedIntValue];
        printf("%-7u %-6d %-9.9s %5s %6s %5.2f %-12s %-20s %s\n", wid, [w[(id)kCGWindowOwnerPID] intValue],
               [w[(id)kCGWindowOwnerName] UTF8String] ?: "", [w[(id)kCGWindowIsOnscreen] boolValue] ? "yes" : "no",
               [listed containsObject:@(wid)] ? "yes" : "no", [w[(id)kCGWindowAlpha] floatValue],
               spacesText(cid, wid).UTF8String, frameText(w[(id)kCGWindowBounds]).UTF8String,
               clip(w[(id)kCGWindowName], 40).UTF8String);
    }
}

static id copyAttr(AXUIElementRef el, CFStringRef attr) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static NSString *axString(AXUIElementRef el, CFStringRef attr) {
    id v = copyAttr(el, attr);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSString *axFrame(AXUIElementRef el) {
    CGPoint p = CGPointZero;
    CGSize s = CGSizeZero;
    id pos = copyAttr(el, kAXPositionAttribute), size = copyAttr(el, kAXSizeAttribute);
    if (!pos || !size) return @"-";
    AXValueGetValue((__bridge AXValueRef)pos, kAXValueTypeCGPoint, &p);
    AXValueGetValue((__bridge AXValueRef)size, kAXValueTypeCGSize, &s);
    return [NSString stringWithFormat:@"%d,%d %dx%d", (int)p.x, (int)p.y, (int)s.width, (int)s.height];
}

// The first AXTabGroup under el, searched breadth first a few levels deep:
// apps put the tab bar in the title bar, a toolbar or a split group.
static AXUIElementRef findTabGroup(AXUIElementRef root) {
    NSMutableArray *level = [NSMutableArray arrayWithObject:(__bridge id)root];
    for (int depth = 0; depth < 5 && level.count; depth++) {
        NSMutableArray *next = [NSMutableArray array];
        for (id item in level) {
            AXUIElementRef el = (__bridge AXUIElementRef)item;
            if (depth > 0 && [axString(el, kAXRoleAttribute) isEqualToString:(id)kAXTabGroupRole]) return el;
            NSArray *children = copyAttr(el, kAXChildrenAttribute);
            if (children) [next addObjectsFromArray:children];
        }
        level = next;
    }
    return NULL;
}

static void printTabGroup(AXUIElementRef group) {
    NSArray *tabs = copyAttr(group, kAXTabsAttribute);
    NSArray *children = copyAttr(group, kAXChildrenAttribute);
    printf("    tab group: AXTabs %s, %lu children\n", tabs ? [@(tabs.count) stringValue].UTF8String : "-",
           (unsigned long)children.count);
    int i = 0;
    for (id item in children) {
        AXUIElementRef el = (__bridge AXUIElementRef)item;
        NSString *role = axString(el, kAXRoleAttribute) ?: @"?";
        NSString *subrole = axString(el, kAXSubroleAttribute) ?: @"";
        NSString *title = axString(el, kAXTitleAttribute) ?: axString(el, kAXDescriptionAttribute) ?: @"";
        id value = copyAttr(el, kAXValueAttribute);
        CFArrayRef actions = NULL;
        AXUIElementCopyActionNames(el, &actions);
        NSString *acts = actions ? [(__bridge NSArray *)actions componentsJoinedByString:@","] : @"-";
        if (actions) CFRelease(actions);
        printf("      %d %s%s%s value=%s actions=%s \"%s\"\n", ++i, role.UTF8String, subrole.length ? "/" : "",
               subrole.UTF8String, value ? [[value description] UTF8String] : "-", acts.UTF8String,
               clip(title, 40).UTF8String);
    }
}

static void printAccessibility(NSArray<NSString *> *apps) {
    if (!AXIsProcessTrusted()) {
        printf("\naccessibility: not trusted for this process; run tests/tabs_probe.lua in Hammerspoon\n");
        return;
    }
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (!app.localizedName || !wanted(app.localizedName, apps)) continue;
        AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
        NSArray *windows = copyAttr(axApp, kAXWindowsAttribute);
        printf("\n%s (pid %d): %lu AXWindows\n", app.localizedName.UTF8String, app.processIdentifier,
               (unsigned long)windows.count);
        for (id item in windows) {
            AXUIElementRef win = (__bridge AXUIElementRef)item;
            CGWindowID wid = 0;
            if (AXGetWindow) AXGetWindow(win, &wid);
            printf("  %-7u %-16s min=%s main=%s %-20s \"%s\"\n", wid,
                   (axString(win, kAXSubroleAttribute) ?: @"-").UTF8String,
                   [copyAttr(win, kAXMinimizedAttribute) boolValue] ? "yes" : "no",
                   [copyAttr(win, kAXMainAttribute) boolValue] ? "yes" : "no", axFrame(win).UTF8String,
                   clip(axString(win, kAXTitleAttribute), 40).UTF8String);
            AXUIElementRef group = findTabGroup(win);
            if (group) printTabGroup(group);
        }
        CFRelease(axApp);
    }
}

// Samples the wanted apps' windows and prints whatever changed since the
// last sample: a window appearing, going on or off screen, or moving.
static void watch(int ms, NSArray<NSString *> *apps) {
    NSMutableDictionary<NSNumber *, NSString *> *last = [NSMutableDictionary dictionary];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:ms / 1000.0];
    BOOL first = YES;
    while ([end timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            NSSet *listed;
            NSArray *rows = appWindows(apps, &listed);
            double now = [[NSDate date] timeIntervalSince1970];
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *w in rows) {
                NSNumber *wid = w[(id)kCGWindowNumber];
                [seen addObject:wid];
                NSString *state = [NSString stringWithFormat:@"%@ %@ alpha=%.2f",
                    [w[(id)kCGWindowIsOnscreen] boolValue] ? @"on " : @"off",
                    frameText(w[(id)kCGWindowBounds]), [w[(id)kCGWindowAlpha] floatValue]];
                if (![last[wid] isEqualToString:state]) {
                    printf("%.3f %s %-7u %s \"%s\"\n", now, first ? "now " : (last[wid] ? "chg " : "new "),
                           wid.unsignedIntValue, state.UTF8String, clip(w[(id)kCGWindowName], 30).UTF8String);
                    last[wid] = state;
                }
            }
            for (NSNumber *wid in last.allKeys) {
                if (![seen containsObject:wid]) {
                    printf("%.3f gone %-7u\n", now, wid.unsignedIntValue);
                    [last removeObjectForKey:wid];
                }
            }
            fflush(stdout);
            first = NO;
        }
        usleep(1000);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        SLSMainConnectionID = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        SLSCopySpacesForWindows = dlsym(RTLD_DEFAULT, "SLSCopySpacesForWindows");
        AXGetWindow = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
        int cid = SLSMainConnectionID ? SLSMainConnectionID() : 0;

        int watchMs = 0;
        NSMutableArray *apps = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) watchMs = atoi(argv[++i]);
            else if (argv[i][0] == '-') { fprintf(stderr, "unknown option: %s\n", argv[i]); return 2; }
            else [apps addObject:@(argv[i])];
        }
        if (!apps.count) [apps addObjectsFromArray:defaultApps()];

        if (watchMs > 0) { watch(watchMs, apps); return 0; }
        printWindowServer(cid, apps);
        printAccessibility(apps);
    }
    return 0;
}
