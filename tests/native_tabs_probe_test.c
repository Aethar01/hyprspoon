// Deterministic native query tests: no app is launched or contacted.
#include <ApplicationServices/ApplicationServices.h>
#include <assert.h>
#include <string.h>
#include <dispatch/dispatch.h>
static CFDictionaryRef testApp;
static CFArrayRef testList;
static int presses, tokenCalls, completed, normalTimeouts;
static CFMutableDictionaryRef timedElements;
static AXUIElementRef remoteWin;
static AXError mockAttribute(AXUIElementRef el, CFStringRef name, CFTypeRef *out) {
    assert(CFDictionaryContainsKey(timedElements, el));
    *out = CFDictionaryGetValue((CFDictionaryRef)el, name);
    if (*out) CFRetain(*out);
    return *out ? kAXErrorSuccess : kAXErrorNoValue;
}
static AXError mockTimeout(AXUIElementRef el, float timeout) {
    assert(el && timeout > 0 && timeout <= 1);
    CFDictionarySetValue(timedElements, el, kCFBooleanTrue);
    if (timeout == 1.0) normalTimeouts++;
    return kAXErrorSuccess;
}
static AXError mockPress(AXUIElementRef el, CFStringRef action) {
    assert(CFDictionaryContainsKey(timedElements, el));
    (void)action;
    presses++;
    return kAXErrorSuccess;
}
static AXUIElementRef mockApp(pid_t pid) { (void)pid; return (AXUIElementRef)CFRetain(testApp); }
static AXError mockID(AXUIElementRef el, CGWindowID *id) {
    CFNumberRef value = CFDictionaryGetValue((CFDictionaryRef)el, CFSTR("id"));
    if (!value) return kAXErrorNoValue;
    CFNumberGetValue(value, kCFNumberSInt32Type, id);
    return kAXErrorSuccess;
}
static CFArrayRef mockList(CGWindowListOption opt, CGWindowID id) {
    (void)opt; (void)id; return CFRetain(testList);
}
static void *pendingContext;
static void (*pendingWork)(void *);
static dispatch_queue_t worker;
static double clockValue, clockStep;
static double mockClock(void) { clockValue += clockStep; return clockValue; }
static void mockDispatch(dispatch_queue_t queue, void *context, void (*work)(void *)) {
    assert(queue && !pendingWork);
    pendingContext = context; pendingWork = work;
}
#define dispatch_async_f mockDispatch
#define CFAbsoluteTimeGetCurrent mockClock
#define AXUIElementCopyAttributeValue mockAttribute
#define AXUIElementSetMessagingTimeout mockTimeout
#define AXUIElementPerformAction mockPress
#define AXUIElementCreateApplication mockApp
#define _AXUIElementGetWindow mockID
#define CGWindowListCopyWindowInfo mockList
#include "../hyprspoon/native/tabs.c"
void framesShowTab(pid_t p, uint32_t w, uint32_t s, CFStringRef t) { (void)p; (void)w; (void)s; (void)t; }
dispatch_queue_t framesWorker(pid_t p) { (void)p; return worker; }
static CFArrayRef array(const void *a, const void *b) {
    const void *values[] = { a, b };
    return CFArrayCreate(NULL, values, b ? 2 : 1, &kCFTypeArrayCallBacks);
}
static void set(CFMutableDictionaryRef dict, CFStringRef key, CFTypeRef value) {
    CFDictionarySetValue(dict, key, value);
}
static AXUIElementRef mockRemote(CFDataRef data) {
    uint64_t index = 0;
    memcpy(&index, CFDataGetBytePtr(data) + 12, 8);
    tokenCalls++;
    return index == 25000 ? (AXUIElementRef)CFRetain(remoteWin) : NULL;
}
static int connection(void) { return 1; }
static CFArrayRef spaces(int c, int mask, CFArrayRef ids) {
    (void)c; (void)mask;
    int id = 0;
    CFNumberGetValue(CFArrayGetValueAtIndex(ids, 0), kCFNumberIntType, &id);
    return id == 1 ? NULL : CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}
static void drain(void) {
    while (pendingWork) {
        void (*work)(void *) = pendingWork;
        void *context = pendingContext;
        pendingWork = NULL;
        work(context);
    }
}
static int resultCallback(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_rawgeti(L, 1, 99);
    assert(lua_isstring(L, -1));
    completed++;
    return 0;
}
static void requestScan(lua_State *L) {
    lua_settop(L, 0);
    lua_pushinteger(L, 100);
    lua_newtable(L);
    lua_pushboolean(L, true); lua_rawseti(L, 2, 99);
    lua_pushcfunction(L, resultCallback);
    assert(l_tabWindows(L) == 0);
    lua_settop(L, 0);
}
int main(void) {
    timedElements = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    worker = dispatch_queue_create("test.tabs", DISPATCH_QUEUE_SERIAL);
    CFMutableDictionaryRef button = dictionary(), button2 = dictionary();
    set(button, kAXSubroleAttribute, CFSTR("AXTabButton"));
    set(button2, kAXSubroleAttribute, CFSTR("AXTabButton"));
    set(button, kAXTitleAttribute, CFSTR("duplicate"));
    set(button2, kAXTitleAttribute, CFSTR("duplicate"));
    CFArrayRef buttons = array(button, button2);
    CFMutableDictionaryRef bar = dictionary(), win = dictionary(), app = dictionary();
    set(bar, kAXRoleAttribute, CFSTR("AXTabGroup"));
    set(bar, CFSTR("AXTabs"), buttons);
    CFArrayRef children = array(bar, NULL), windows = array(win, NULL);
    set(win, kAXChildrenAttribute, children);
    set(win, kAXSubroleAttribute, kAXStandardWindowSubrole);
    set(win, kAXRoleAttribute, kAXWindowRole);
    int id = 99;
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &id);
    set(win, CFSTR("id"), num);
    set(app, kAXWindowsAttribute, windows);
    testApp = app;
    assert(!tabsSelect(100, 99, CFSTR("duplicate")) && presses == 0);
    assert(!tabsSelect(100, 99, CFSTR("missing")) && presses == 0);
    set(button2, kAXTitleAttribute, CFSTR("unique"));
    assert(tabsSelect(100, 99, CFSTR("unique")) && presses == 1);
    // Ordinary radio buttons and nested content tab groups are rejected.
    set(button, kAXSubroleAttribute, CFSTR("AXRadioButton"));
    assert(!tabGroup((AXUIElementRef)win));
    set(button, kAXSubroleAttribute, CFSTR("AXTabButton"));
    CFMutableDictionaryRef container = dictionary();
    set(container, kAXChildrenAttribute, children);
    CFArrayRef nested = array(container, NULL);
    set(win, kAXChildrenAttribute, nested);
    assert(!tabGroup((AXUIElementRef)win));
    // IDs above 1999 are reachable and the scan exits once wanted IDs match.
    remoteElement = mockRemote;
    remoteWin = (AXUIElementRef)win;
    TabQuery query = {0};
    query.pid = 100;
    query.queue = worker;
    query.wanted = dictionary();
    put(query.wanted, 99, kCFBooleanTrue);
    CFRunLoopSourceContext context = {0};
    query.source = CFRunLoopSourceCreate(NULL, 0, &context);
    tokenCalls = 0;
    // Force a yield after a few tokens, then consume every queued chunk.
    clockStep = 0.004;
    scanWindows(&query);
    assert(pendingWork && query.cursor < 25000);
    clockStep = 0;
    while (pendingWork) {
        void (*work)(void *) = pendingWork;
        void *context = pendingContext;
        pendingWork = NULL;
        work(context);
    }
    assert(CFDictionaryGetCount(query.result) == 1 && tokenCalls == 25001);
    CFRelease(query.result); CFRelease(query.wanted); CFRelease(query.source);
    // Lua returns before any scan work, and is called only by the main
    // run-loop source after the worker has finished. Its stack stays balanced.
    lua_State *L = luaL_newstate();
    requestScan(L);
    assert(pendingWork && completed == 0);
    drain();
    assert(completed == 0);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    assert(completed == 1 && lua_gettop(L) == 0);
    // A cached window is raised without rescanning and its normal timeout
    // is restored before subsequent frame reads use that same element.
    tokenCalls = 0;
    int normalBefore = normalTimeouts;
    lua_pushinteger(L, 100); lua_pushinteger(L, 99); lua_pushinteger(L, 99);
    lua_pushliteral(L, "unique");
    assert(l_tabShow(L) == 0);
    lua_settop(L, 0);
    drain();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    assert(tokenCalls == 0 && normalTimeouts > normalBefore && lua_gettop(L) == 0);
    // Reload cancels outstanding scans and invalidates their callbacks.
    requestScan(L);
    tabsCancel(); drain(); tabsStop();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    assert(completed == 1 && !queries);
    lua_close(L);
    // One failed Space lookup preserves both the other result and uncertainty.
    CFMutableDictionaryRef row1 = dictionary(), row2 = dictionary();
    int owner = 100, layer = 0, first = 1, second = 2;
    CFNumberRef pid = CFNumberCreate(NULL, kCFNumberIntType, &owner);
    CFNumberRef level = CFNumberCreate(NULL, kCFNumberIntType, &layer);
    CFNumberRef one = CFNumberCreate(NULL, kCFNumberIntType, &first);
    CFNumberRef two = CFNumberCreate(NULL, kCFNumberIntType, &second);
    set(row1, kCGWindowOwnerPID, pid); set(row2, kCGWindowOwnerPID, pid);
    set(row1, kCGWindowLayer, level); set(row2, kCGWindowLayer, level);
    set(row1, kCGWindowNumber, one); set(row2, kCGWindowNumber, two);
    testList = array(row1, row2);
    mainConnection = connection; windowSpaces = spaces;
    CFMutableDictionaryRef result = snapshot();
    int64_t p = 100;
    CFNumberRef pkey = CFNumberCreate(NULL, kCFNumberSInt64Type, &p);
    CFDictionaryRef states = CFDictionaryGetValue(result, pkey);
    assert(CFEqual(CFDictionaryGetValue(states, one), CFSTR("unknown")));
    assert(CFEqual(CFDictionaryGetValue(states, two), CFSTR("tab")));
    CFRelease(result); CFRelease(pkey); CFRelease(testList);
    CFRelease(row1); CFRelease(row2); CFRelease(pid); CFRelease(level); CFRelease(one); CFRelease(two);
    CFRelease(button); CFRelease(button2); CFRelease(buttons); CFRelease(bar);
    CFRelease(children); CFRelease(windows); CFRelease(win); CFRelease(app); CFRelease(num);
    CFRelease(container); CFRelease(nested);
    tabsStop();
    dispatch_release(worker);
    CFRelease(timedElements);
    return 0;
}
