// Native tabs are off screen and have no Space. Frames are deliberately not
// consulted: WindowServer leaves a background tab's old frame behind.
#include "frames.h"
#include "skylight.h"
#include <string.h>
#include <stdlib.h>
#include "luacall.h"

extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);
static AXUIElementRef (*remoteElement)(CFDataRef);
static int (*mainConnection)(void);
static CFArrayRef (*windowSpaces)(int, int, CFArrayRef);

static CFTypeRef attribute(AXUIElementRef el, CFStringRef name) {
    AXUIElementSetMessagingTimeout(el, 0.05);
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
    for (uint64_t i = 0; i <= 0x7fff && CFAbsoluteTimeGetCurrent() < end; i++) {
        AXUIElementRef el = remoteWindow(pid, i);
        if (!el) continue;
        AXUIElementSetMessagingTimeout(el, 0.05);
        CGWindowID id = 0;
        if (_AXUIElementGetWindow(el, &id) == kAXErrorSuccess && id == wid
            && equalsAttribute(el, kAXRoleAttribute, kAXWindowRole)) {
            // Frame operations use the ordinary worker timeout, not the scan timeout.
            AXUIElementSetMessagingTimeout(el, 1.0);
            return el;
        }
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

// Results cross back through a run-loop source, never through Lua on a
// worker. Shutdown drains workers before invalidating and freeing sources.
typedef struct TabQuery {
    struct TabQuery *next;
    pid_t pid;
    CFMutableDictionaryRef wanted;
    CFMutableDictionaryRef result;
    CFRunLoopSourceRef source;
    LuaCallback callback;
} TabQuery;
static TabQuery *queries;

static void pushDictionary(lua_State *L, CFDictionaryRef dict) {
    lua_newtable(L);
    if (!dict) return;
    CFIndex count = CFDictionaryGetCount(dict);
    const void **keys = calloc((size_t)count, sizeof(void *));
    const void **values = calloc((size_t)count, sizeof(void *));
    CFDictionaryGetKeysAndValues(dict, keys, values);
    for (CFIndex i = 0; i < count; i++) {
        int64_t key = 0;
        CFNumberGetValue(keys[i], kCFNumberSInt64Type, &key);
        if (CFGetTypeID(values[i]) == CFDictionaryGetTypeID()) pushDictionary(L, values[i]);
        else pushString(L, values[i]);
        lua_rawseti(L, -2, key);
    }
    free(keys);
    free(values);
}

static CFMutableDictionaryRef dictionary(void) {
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
}

static void put(CFMutableDictionaryRef dict, int64_t id, CFTypeRef value) {
    CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
    CFDictionarySetValue(dict, key, value);
    CFRelease(key);
}

static void freeQuery(TabQuery *q) {
    CFRunLoopSourceInvalidate(q->source);
    CFRelease(q->source);
    luaCallbackClear(&q->callback);
    if (q->wanted) CFRelease(q->wanted);
    if (q->result) CFRelease(q->result);
    free(q);
}

static void queryDone(void *context) {
    TabQuery *q = context;
    TabQuery **link = &queries;
    while (*link && *link != q) link = &(*link)->next;
    if (*link) *link = q->next;
    if (luaCallbackPush(&q->callback)) {
        if (q->result) pushDictionary(q->callback.L, q->result);
        else lua_pushnil(q->callback.L);
        luaCallbackCall(&q->callback, 1);
    }
    freeQuery(q);
}

void tabsStop(void) {
    while (queries) {
        TabQuery *q = queries;
        queries = q->next;
        freeQuery(q);
    }
}

static void finishQuery(TabQuery *q) {
    CFRunLoopSourceSignal(q->source);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static TabQuery *newQuery(lua_State *L, pid_t pid, int callback) {
    luaL_checktype(L, callback, LUA_TFUNCTION);
    TabQuery *q = calloc(1, sizeof(*q));
    q->pid = pid;
    q->callback = (LuaCallback)LUA_CALLBACK_NONE;
    luaCallbackSet(&q->callback, L, callback);
    CFRunLoopSourceContext context = {0};
    context.info = q;
    context.perform = queryDone;
    q->source = CFRunLoopSourceCreate(NULL, 0, &context);
    CFRunLoopAddSource(CFRunLoopGetMain(), q->source, kCFRunLoopCommonModes);
    q->next = queries;
    queries = q;
    return q;
}

static void scanWindows(void *context) {
    TabQuery *q = context;
    q->result = dictionary();
    double end = CFAbsoluteTimeGetCurrent() + 0.25;
    CFIndex remaining = CFDictionaryGetCount(q->wanted);
    for (uint64_t i = 0; i <= 0x7fff && remaining && CFAbsoluteTimeGetCurrent() < end; i++) {
        AXUIElementRef el = remoteWindow(q->pid, i);
        if (!el) continue;
        AXUIElementSetMessagingTimeout(el, 0.01);
        CGWindowID wid = 0;
        if (_AXUIElementGetWindow(el, &wid) == kAXErrorSuccess && wid) {
            int64_t id = wid;
            CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt64Type, &id);
            if (CFDictionaryContainsKey(q->wanted, key)
                && !CFDictionaryContainsKey(q->result, key)
                && equalsAttribute(el, kAXRoleAttribute, kAXWindowRole)
                && equalsAttribute(el, kAXSubroleAttribute, kAXStandardWindowSubrole)) {
                CFTypeRef title = attribute(el, kAXTitleAttribute);
                CFDictionarySetValue(q->result, key, title ? title : CFSTR(""));
                if (title) CFRelease(title);
                remaining--;
            }
            CFRelease(key);
        }
        CFRelease(el);
    }
    finishQuery(q);
}

static int l_tabWindows(lua_State *L) {
    pid_t pid = (pid_t)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    TabQuery *q = newQuery(L, pid, 3);
    q->wanted = dictionary();
    lua_pushnil(L);
    while (lua_next(L, 2)) {
        put(q->wanted, luaL_checkinteger(L, -2), kCFBooleanTrue);
        lua_pop(L, 1);
    }
    if (!framesQueue(pid, q, scanWindows)) finishQuery(q);
    return 0;
}

// One snapshot for all apps. It runs on a worker; the main thread only
// consumes the completed dictionary. Off-screen Space lookups happen once.
static CFMutableDictionaryRef snapshot(void) {
    if (!windowSpaces || !mainConnection) return NULL;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    if (!list) return NULL;
    CFMutableDictionaryRef result = dictionary();
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef row = CFArrayGetValueAtIndex(list, i);
        int owner = 0, layer = -1;
        uint32_t wid = 0;
        CFNumberRef n = CFDictionaryGetValue(row, kCGWindowOwnerPID);
        if (n) CFNumberGetValue(n, kCFNumberIntType, &owner);
        n = CFDictionaryGetValue(row, kCGWindowLayer);
        if (n) CFNumberGetValue(n, kCFNumberIntType, &layer);
        n = CFDictionaryGetValue(row, kCGWindowNumber);
        if (n) CFNumberGetValue(n, kCFNumberSInt32Type, &wid);
        CFBooleanRef on = CFDictionaryGetValue(row, kCGWindowIsOnscreen);
        CFStringRef state = CFSTR("other");
        if (layer == 0 && on && CFBooleanGetValue(on)) state = CFSTR("shown");
        else if (layer == 0) {
            CFArrayRef ids = slWindowList(wid);
            CFArrayRef spaces = windowSpaces(mainConnection(), 7, ids);
            CFRelease(ids);
            // A destroyed or unqueryable window is uncertain, not closed.
            state = CFSTR("unknown");
            if (spaces) {
                state = CFArrayGetCount(spaces) == 0 ? CFSTR("tab") : CFSTR("other");
                CFRelease(spaces);
            }
        }
        int64_t pid = owner;
        CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt64Type, &pid);
        CFMutableDictionaryRef states = (CFMutableDictionaryRef)CFDictionaryGetValue(result, key);
        if (!states) {
            states = dictionary();
            CFDictionarySetValue(result, key, states);
            CFRelease(states);
        }
        put(states, wid, state);
        CFRelease(key);
    }
    CFRelease(list);
    return result;
}

static void readSnapshot(void *context) {
    TabQuery *q = context;
    q->result = snapshot();
    finishQuery(q);
}

static int l_tabSnapshot(lua_State *L) {
    TabQuery *q = newQuery(L, 0, 1);
    if (!framesQueue(0, q, readSnapshot)) finishQuery(q);
    return 0;
}

// Compatibility for older callers; discovery uses the shared async query.
static int l_tabState(lua_State *L) {
    int64_t pid = luaL_checkinteger(L, 1);
    CFMutableDictionaryRef all = snapshot();
    if (!all) { lua_pushnil(L); return 1; }
    CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt64Type, &pid);
    pushDictionary(L, CFDictionaryGetValue(all, key));
    CFRelease(key);
    CFRelease(all);
    return 1;
}

// Native window tab bars are direct window children. Document tab strips
// and nested NSTabViews must not trigger remote-token repair scans.
static AXUIElementRef tabGroup(AXUIElementRef win) {
    if (!equalsAttribute(win, kAXSubroleAttribute, kAXStandardWindowSubrole)) return NULL;
    CFArrayRef children = attribute(win, kAXChildrenAttribute);
    if (!children || CFGetTypeID(children) != CFArrayGetTypeID()) {
        if (children) CFRelease(children);
        return NULL;
    }
    AXUIElementRef group = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(children) && !group; i++) {
        AXUIElementRef child = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        if (!equalsAttribute(child, kAXRoleAttribute, CFSTR("AXTabGroup"))) continue;
        CFArrayRef buttons = attribute(child, CFSTR("AXTabs"));
        bool native = buttons && CFGetTypeID(buttons) == CFArrayGetTypeID() && CFArrayGetCount(buttons) > 0;
        for (CFIndex j = 0; native && j < CFArrayGetCount(buttons); j++) {
            AXUIElementRef button = (AXUIElementRef)CFArrayGetValueAtIndex(buttons, j);
            native = equalsAttribute(button, kAXSubroleAttribute, CFSTR("AXTabButton"));
        }
        if (native) group = CFRetain(child);
        if (buttons) CFRelease(buttons);
    }
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
            AXUIElementSetMessagingTimeout(win, 0.05);
            CGWindowID id = 0;
            if (_AXUIElementGetWindow(win, &id) == kAXErrorSuccess && id == wid) group = tabGroup(win);
        }
        CFRelease(windows);
    }
    CFRelease(app);
    return group;
}

bool tabsSelect(pid_t pid, uint32_t shown, CFStringRef title) {
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
        // Member order is not AX tab-bar order; duplicate titles must fail safely.
        if (matches != 1) match = -1;
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
    framesShowTab(pid, wid, shown, title);
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
    lua_pushcfunction(L, l_tabSnapshot); lua_setfield(L, -2, "tabSnapshot");
    lua_pushcfunction(L, l_tabState); lua_setfield(L, -2, "tabState");
    lua_pushcfunction(L, l_tabWindows); lua_setfield(L, -2, "tabWindows");
    lua_pushcfunction(L, l_tabButtons); lua_setfield(L, -2, "tabButtons");
}
