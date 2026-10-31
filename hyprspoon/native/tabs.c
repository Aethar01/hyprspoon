// Native tabs are off screen and have no Space. Frames are deliberately not
// consulted: WindowServer leaves a background tab's old frame behind.
#include "frames.h"
#include "skylight.h"
#include <string.h>

extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);
static AXUIElementRef (*remoteElement)(CFDataRef);
static int (*mainConnection)(void);
static CFArrayRef (*windowSpaces)(int, int, CFArrayRef);

static CFTypeRef attribute(AXUIElementRef el, CFStringRef name) {
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(el, name, &value);
    return value;
}

static bool equalsAttribute(AXUIElementRef el, CFStringRef name, CFStringRef expected) {
    CFTypeRef value = attribute(el, name);
    bool equal = value && CFEqual(value, expected);
    if (value) CFRelease(value);
    return equal;
}

// Only AXWindow roots count: descendants also report their containing wid.
// The bounded scan is a repair path, never the normal detection path.
static AXUIElementRef remoteWindow(pid_t pid, uint64_t index) {
    if (!remoteElement) return NULL;
    unsigned char bytes[20] = {0};
    uint32_t magic = 0x636f636f;
    memcpy(bytes, &pid, 4);
    memcpy(bytes + 8, &magic, 4);
    memcpy(bytes + 12, &index, 8);
    CFDataRef token = CFDataCreate(NULL, bytes, sizeof(bytes));
    AXUIElementRef el = remoteElement(token);
    CFRelease(token);
    return el;
}

AXUIElementRef tabsFind(pid_t pid, uint32_t wid) {
    double end = CFAbsoluteTimeGetCurrent() + 0.25;
    for (uint64_t i = 0; i < 2000 && CFAbsoluteTimeGetCurrent() < end; i++) {
        AXUIElementRef el = remoteWindow(pid, i);
        if (!el) continue;
        AXUIElementSetMessagingTimeout(el, 0.05);
        CGWindowID id = 0;
        if (_AXUIElementGetWindow(el, &id) == kAXErrorSuccess && id == wid
            && equalsAttribute(el, kAXRoleAttribute, kAXWindowRole)) return el;
        CFRelease(el);
    }
    return NULL;
}

static void pushString(lua_State *L, CFTypeRef value) {
    char text[4096];
    if (value && CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8)) lua_pushstring(L, text);
    else lua_pushliteral(L, "");
}

static int l_tabWindows(lua_State *L) {
    pid_t pid = (pid_t)luaL_checkinteger(L, 1);
    lua_newtable(L);
    double end = CFAbsoluteTimeGetCurrent() + 0.25;
    for (uint64_t i = 0; i < 2000 && CFAbsoluteTimeGetCurrent() < end; i++) {
        AXUIElementRef el = remoteWindow(pid, i);
        if (!el) continue;
        AXUIElementSetMessagingTimeout(el, 0.05);
        CGWindowID wid = 0;
        if (_AXUIElementGetWindow(el, &wid) == kAXErrorSuccess && wid
            && equalsAttribute(el, kAXRoleAttribute, kAXWindowRole)
            && equalsAttribute(el, kAXSubroleAttribute, kAXStandardWindowSubrole)) {
            CFTypeRef title = attribute(el, kAXTitleAttribute);
            pushString(L, title);
            lua_rawseti(L, -2, wid);
            if (title) CFRelease(title);
        }
        CFRelease(el);
    }
    return 1;
}

static int l_tabState(lua_State *L) {
    pid_t pid = (pid_t)luaL_checkinteger(L, 1);
    if (!windowSpaces || !mainConnection) { lua_pushnil(L); return 1; }
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    if (!list) { lua_pushnil(L); return 1; }
    lua_newtable(L);
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef row = CFArrayGetValueAtIndex(list, i);
        int owner = 0, layer = -1;
        uint32_t wid = 0;
        CFNumberRef n = CFDictionaryGetValue(row, kCGWindowOwnerPID);
        if (n) CFNumberGetValue(n, kCFNumberIntType, &owner);
        if (owner != pid) continue;
        n = CFDictionaryGetValue(row, kCGWindowLayer);
        if (n) CFNumberGetValue(n, kCFNumberIntType, &layer);
        n = CFDictionaryGetValue(row, kCGWindowNumber);
        if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &wid);
        CFBooleanRef on = CFDictionaryGetValue(row, kCGWindowIsOnscreen);
        const char *state = "other";
        if (layer == 0 && on && CFBooleanGetValue(on)) state = "shown";
        else if (layer == 0) {
            CFArrayRef ids = slWindowList(wid);
            CFArrayRef spaces = windowSpaces(mainConnection(), 7, ids);
            CFRelease(ids);
            // A window may disappear between the snapshot and this query.
            // Keep the other windows' evidence instead of discarding the pass.
            if (!spaces) continue;
            if (CFArrayGetCount(spaces) == 0) state = "tab";
            CFRelease(spaces);
        }
        lua_pushstring(L, state);
        lua_rawseti(L, -2, wid);
    }
    CFRelease(list);
    return 1;
}

// A shallow bounded walk avoids wandering through document contents.
static AXUIElementRef tabGroup(AXUIElementRef el, int depth) {
    if (equalsAttribute(el, kAXRoleAttribute, CFSTR("AXTabGroup"))) return CFRetain(el);
    if (!depth) return NULL;
    CFArrayRef children = attribute(el, kAXChildrenAttribute);
    if (!children || CFGetTypeID(children) != CFArrayGetTypeID()) {
        if (children) CFRelease(children);
        return NULL;
    }
    AXUIElementRef group = NULL;
    CFIndex count = CFArrayGetCount(children);
    for (CFIndex i = 0; i < count && i < 100 && !group; i++)
        group = tabGroup((AXUIElementRef)CFArrayGetValueAtIndex(children, i), depth - 1);
    CFRelease(children);
    return group;
}

static AXUIElementRef groupFor(pid_t pid, uint32_t wid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.1);
    CFArrayRef windows = attribute(app, kAXWindowsAttribute);
    AXUIElementRef group = NULL;
    if (windows) {
        for (CFIndex i = 0; i < CFArrayGetCount(windows) && !group; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            CGWindowID id = 0;
            if (_AXUIElementGetWindow(win, &id) == kAXErrorSuccess && id == wid) group = tabGroup(win, 4);
        }
        CFRelease(windows);
    }
    CFRelease(app);
    return group;
}

bool tabsSelect(pid_t pid, uint32_t shown, CFStringRef title, int position) {
    AXUIElementRef group = groupFor(pid, shown);
    CFArrayRef tabs = group ? attribute(group, CFSTR("AXTabs")) : NULL;
    bool ok = false;
    if (tabs) {
        CFIndex count = CFArrayGetCount(tabs), match = -1;
        int matches = 0;
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef button = (AXUIElementRef)CFArrayGetValueAtIndex(tabs, i);
            if (title && CFStringGetLength(title) && equalsAttribute(button, kAXTitleAttribute, title)) {
                match = i;
                matches++;
            }
        }
        if (matches != 1) match = position > 0 && position <= count ? position - 1 : -1;
        if (match >= 0) ok = AXUIElementPerformAction((AXUIElementRef)CFArrayGetValueAtIndex(tabs, match),
            kAXPressAction) == kAXErrorSuccess;
        CFRelease(tabs);
    }
    if (group) CFRelease(group);
    return ok;
}

static int l_tabShow(lua_State *L) {
    pid_t pid = (pid_t)luaL_checkinteger(L, 1);
    uint32_t wid = (uint32_t)luaL_checkinteger(L, 2);
    uint32_t shown = (uint32_t)luaL_checkinteger(L, 3);
    CFStringRef title = CFStringCreateWithCString(NULL, luaL_optstring(L, 4, ""), kCFStringEncodingUTF8);
    framesShowTab(pid, wid, shown, title, (int)luaL_optinteger(L, 5, 0));
    if (title) CFRelease(title);
    return 0;
}

static int l_tabButtons(lua_State *L) {
    pid_t pid = (pid_t)luaL_checkinteger(L, 1);
    uint32_t wid = (uint32_t)luaL_checkinteger(L, 2);
    int delta = (int)luaL_optinteger(L, 3, 0);
    AXUIElementRef group = groupFor(pid, wid);
    CFArrayRef tabs = group ? attribute(group, CFSTR("AXTabs")) : NULL;
    lua_newtable(L);
    if (tabs) {
        CFIndex count = CFArrayGetCount(tabs), selected = -1;
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef button = (AXUIElementRef)CFArrayGetValueAtIndex(tabs, i);
            CFTypeRef title = attribute(button, kAXTitleAttribute);
            pushString(L, title);
            lua_rawseti(L, -2, i + 1);
            if (title) CFRelease(title);
            CFTypeRef value = attribute(button, kAXValueAttribute);
            int v = 0;
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &v);
            if (value == kCFBooleanTrue || v == 1) selected = i;
            if (value) CFRelease(value);
        }
        if (delta && count && selected >= 0) {
            CFIndex next = (selected + (delta > 0 ? 1 : count - 1)) % count;
            AXUIElementPerformAction((AXUIElementRef)CFArrayGetValueAtIndex(tabs, next), kAXPressAction);
        }
        CFRelease(tabs);
    }
    if (group) CFRelease(group);
    return 1;
}

void tabsRegister(lua_State *L) {
    slOpen();
    mainConnection = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    windowSpaces = dlsym(RTLD_DEFAULT, "SLSCopySpacesForWindows");
    remoteElement = dlsym(RTLD_DEFAULT, "_AXUIElementCreateWithRemoteToken");
    lua_pushcfunction(L, l_tabShow); lua_setfield(L, -2, "tabShow");
    lua_pushcfunction(L, l_tabState); lua_setfield(L, -2, "tabState");
    lua_pushcfunction(L, l_tabWindows); lua_setfield(L, -2, "tabWindows");
    lua_pushcfunction(L, l_tabButtons); lua_setfield(L, -2, "tabButtons");
}
