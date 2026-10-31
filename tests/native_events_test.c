// WindowServer event routing, without a connection or any real windows.
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include "../hyprspoon/native/events.c"

int main(void) {
    uint32_t wid = 123;
    onWindowEvent(SL_EVENT_WINDOW_MOVE, &wid, sizeof(wid), NULL);
    assert(pendingCount == 1 && pending[0] == wid && !visibility[0]);
    // An order-out coalescing with a move must still request discovery.
    onWindowEvent(SL_EVENT_WINDOW_REORDER, &wid, sizeof(wid), NULL);
    assert(pendingCount == 1 && visibility[0]);
    pendingCount = 0;
    onWindowEvent(SL_EVENT_WINDOW_HIDE, &wid, sizeof(wid), NULL);
    assert(pendingCount == 1 && visibility[0]);
    pendingCount = 0;
    onWindowEvent(SL_EVENT_WINDOW_UNHIDE, &wid, sizeof(wid), NULL);
    assert(pendingCount == 1 && visibility[0]);
    filtering = true;
    watchedCount = 0;
    pendingCount = 0;
    onWindowEvent(SL_EVENT_WINDOW_HIDE, &wid, sizeof(wid), NULL);
    assert(pendingCount == 0);
    bool hide = false, unhide = false, reorder = false;
    for (size_t i = 0; i < EVENT_COUNT; i++) {
        hide |= events[i] == SL_EVENT_WINDOW_HIDE;
        unhide |= events[i] == SL_EVENT_WINDOW_UNHIDE;
        reorder |= events[i] == SL_EVENT_WINDOW_REORDER;
    }
    assert(hide && unhide && reorder);
    return 0;
}
