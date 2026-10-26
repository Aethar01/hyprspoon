-- ~/.config/hammerspoon/wm/init.lua
--
-- Hyprland-inspired window manager for Hammerspoon:
--   * toggleable BSP tiling (per workspace), with drag-and-drop and
--     split resizing by mouse, keyboard, or native window edges
--   * modifier + drag anywhere on a window to move/resize it
--   * focus follows mouse, with cursor warping on keyboard focus changes
--   * directional focus/swap/resize and numbered workspaces of our own,
--     switched by hotkey or trackpad swipe
--
-- Usage (init.lua):
--
--   local wm = require("wm")
--   wm.setup({ ...options, see `S.defaults` in wm/state.lua... })
--   hs.hotkey.bind({"alt"}, "b", wm.toggleTiling)
--   hs.hotkey.bind({"alt"}, "h", function() wm.focus("left") end)
--
-- Nothing happens on require; wm.setup() starts the event taps and watchers.
-- Keybindings are left to the caller; mouse bindings are configured here
-- because they're eventtaps rather than hotkeys.
--
-- Modules (all under wm/):
--   state     configuration defaults and state shared between the modules
--   util      logging, window classification, focus records, pointer warping
--   tree      BSP tree structure, persistence and per-workspace keys
--   float     automatic and manual floating windows, kept above the tiles
--   focus     internal focus tracking and the window snapshot for hit testing
--   discover  finding the manageable windows on each screen
--   layout    laying the trees out onto windows, and scheduling retiles
--   resize    resizing tiles by keyboard, mouse or native window edges
--   drop      dragging a tile onto another to move it in the layout
--   mouse     modifier + drag anywhere on a window
--   ffm       focus follows mouse
--   spaces    numbered workspaces, parking the windows of hidden ones
--   swipe     trackpad swipes between workspaces
--   bar       workspace numbers in the menu bar, and the row they're drawn as
--   hud       workspace pop-up and corner badge on the displays
--   border    rings around the windows, like Hyprland's borders
--   overview  every workspace at a glance, in place of Mission Control
--   actions   the hotkey actions
--   init      (this file) the public API, setup and teardown
--
-- Native modules (wm/native/*.c, built with `make -C wm/native`), each
-- optional: without one, the Lua path it replaces carries on.
--   border    the rings, drawn and moved by WindowServer
--   events    window moves and resizes as WindowServer reports them
--   hover     the window under the pointer, from a native event tap
--   frames    accessibility frame changes, animations and modifier-drags on
--             a background queue per app
--
-- Modules require each other freely (cycles are harmless: each registers
-- itself in package.loaded before requiring anything) and call each other
-- only at runtime, never while loading.

local Actions = require("wm.actions")
local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")
local Float = require("wm.float")
local Focus = require("wm.focus")
local Discover = require("wm.discover")
local Layout = require("wm.layout")
local Resize = require("wm.resize")
local Mouse = require("wm.mouse")
local Ffm = require("wm.ffm")
local Spaces = require("wm.spaces")
local Swipe = require("wm.swipe")
local Bar = require("wm.bar")
local Hud = require("wm.hud")
local Border = require("wm.border")
local Overview = require("wm.overview")

-- The public API.
local M = {
    balance = Actions.balance,
    closeWindow = Actions.closeWindow,
    focus = Actions.focus,
    focusFloat = Actions.focusFloat,
    mirror = Actions.mirror,
    preselect = Actions.preselect,
    rotate = Actions.rotate,
    gotoWorkspace = Spaces.gotoWorkspace,
    gotoWorkspaceRelative = Spaces.gotoWorkspaceRelative,
    gotoPreviousWorkspace = Spaces.gotoPreviousWorkspace,
    focusDisplay = Spaces.focusDisplay,
    moveToDisplay = Spaces.moveToDisplay,
    moveWorkspaceToDisplay = Spaces.moveWorkspaceToDisplay,
    moveToWorkspaceSilent = Spaces.moveToWorkspaceSilent,
    moveToScratchpad = Spaces.moveToScratchpad,
    toggleScratchpad = Spaces.toggleScratchpad,
    isTiling = Actions.isTiling,
    moveToWorkspace = Spaces.moveToWorkspace,
    resize = Actions.resize,
    swap = Actions.swap,
    toggleFloat = Actions.toggleFloat,
    toggleFullScreen = Actions.toggleFullScreen,
    toggleMaximize = Actions.toggleMaximize,
    toggleOverview = Overview.toggle,
    toggleSplit = Actions.toggleSplit,
    toggleTiling = Actions.toggleTiling,
    toggleWorkspaceTiling = Actions.toggleWorkspaceTiling,
    warpToFocusedWindow = Actions.warpToFocusedWindow,
    warpToWindow = Actions.warpToWindow,
    workspaces = Spaces.workspaces,
}

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local shutdownHooked = false

-- Stops everything setup() started (also run on reload and quit).
function M.stop()
    Discover.stop()
    if S.running.mouseTap then S.running.mouseTap:stop() end
    Mouse.stop()
    if S.running.moveTap then S.running.moveTap:stop() end
    if S.running.events then S.running.events.stop() end
    if S.running.gestureTap then S.running.gestureTap:stop() end
    if S.running.windowFilter then S.running.windowFilter:unsubscribeAll() end
    if S.running.pipFilter then S.running.pipFilter:unsubscribeAll() end
    if S.running.spaceWatcher then S.running.spaceWatcher:stop() end
    if S.running.screenWatcher then S.running.screenWatcher:stop() end
    if S.running.sessionWatcher then S.running.sessionWatcher:stop() end
    if S.running.appearanceWatcher then S.running.appearanceWatcher:stop() end
    if S.running.menuBarWatcher then S.running.menuBarWatcher:stop() end
    for _, t in ipairs(S.running.screenTimers or {}) do t:stop() end
    if S.running.ffmTimer then S.running.ffmTimer:stop() end
    Layout.stop()
    Spaces.stop()
    Float.stop()
    Resize.stop()
    Focus.stop()
    Ffm.stop()
    Swipe.stop()
    Bar.stop()
    Hud.stop()
    Overview.stop()
    Border.stop()
    Tree.stop() -- last: flushes a pending save after the layout has stopped
    S.running = {}
end

function M.setup(opts)
    M.stop()
    Util.forgetManagedWindows()
    S.cfg = Util.deepMerge(S.defaults, opts or {})

    hs.window.animationDuration = 0

    -- A hung app would otherwise block every accessibility call (and so the
    -- whole layout) for the system default of several seconds.
    hs.window.timeout(S.cfg.axTimeout)

    -- Debounced tree saves must not be lost when Hammerspoon reloads or quits,
    -- and quitting must not leave windows parked out of sight.
    if not shutdownHooked then
        shutdownHooked = true
        local previous = hs.shutdownCallback
        hs.shutdownCallback = function()
            Spaces.unparkAll()
            M.stop()
            if previous then previous() end
        end
    end

    S.running.ffmTimer = hs.timer.delayed.new(Util.FFM_HOVER_DELAY, Ffm.ffmFocusPending)

    -- Presses and releases only: drag events would run Lua, holding up the
    -- session's input, for every left-drag anywhere (selecting text, the
    -- system's own resizes). Our own drags get them from Mouse.
    S.running.mouseTap = hs.eventtap.new({
        Mouse.mouseTypes.leftMouseDown,
        Mouse.mouseTypes.leftMouseUp,
        Mouse.mouseTypes.rightMouseDown,
        Mouse.mouseTypes.rightMouseUp,
    }, Mouse.onMouseEvent):start()

    Ffm.start()
    S.running.sessionWatcher = hs.caffeinate.watcher.new(Ffm.onSessionEvent):start()

    if S.cfg.swipe then
        S.running.gestureTap = hs.eventtap.new({ hs.eventtap.event.types.gesture },
            Swipe.onGesture):start()
    end

    local filter = hs.window.filter.new()
    filter:setDefaultFilter({ allowRoles = Util.MANAGED_ROLES, visible = true })
    filter:setOverrideFilter({ rejectTitles = Util.PIP_TITLES })
    for _, app in ipairs(S.cfg.ignoreApps or {}) do
        filter:rejectApp(app)
    end
    filter:setCurrentSpace(true)
    S.running.windowFilter = filter

    -- A separate read-only filter tracks PiP bounds for hover occlusion.
    -- These windows never enter the tiling/floating/focus management filter.
    local pipFilter = hs.window.filter.new(false)
    pipFilter:setDefaultFilter({ allowTitles = Util.PIP_TITLES, visible = true, allowRoles = "*" })
    pipFilter:setCurrentSpace(true)
    pipFilter:subscribe({
        hs.window.filter.windowAllowed,
        hs.window.filter.windowRejected,
        hs.window.filter.windowMoved,
    }, Focus.invalidateWindowCache)
    S.running.pipFilter = pipFilter

    -- Track the last focused leaf so a newly-created window splits next to it.
    filter:subscribe(hs.window.filter.windowFocused, function(win)
        if win and Util.windowKind(win) == "ignored" then return end
        if win then
            local id = win:id()
            local requested = id == S.requestedFocus
            if requested then
                S.requestedFocus = nil
            elseif Focus.isEcho(id) then
                Focus.invalidateWindowCache()
                return
            end
            -- macOS's pick as the focused window closes goes to its sibling.
            local gone = not requested and Focus.goneBefore(win)
            if gone and Layout.handFocusBack(gone, win) then
                Focus.invalidateWindowCache()
                return
            end
            if Spaces.isHidden(id) then
                Spaces.focusedParked(win)
                return
            end
            local intent = S.intent
            if intent and id == intent.id then
                S.intent = nil
            elseif intent and hs.timer.secondsSinceEpoch() - intent.time < Focus.REASSERT_WINDOW then
                -- macOS moved focus right after our request: put it back.
                S.intent = nil
                local wanted = Util.winByID[intent.id]
                if wanted and wanted:id() == intent.id then
                    Util.focusWindow(wanted, true)
                    Focus.invalidateWindowCache()
                    return
                end
            end
            -- A focused float raises itself above the tiles; the others only
            -- need re-raising when a tile took focus.
            if not S.autoFloat[id] then Float.raiseFloating() end
            Focus.noteFocus(win)
        end
        Focus.invalidateWindowCache()
    end)

    filter:subscribe(hs.window.filter.windowUnfocused, Border.unfocused)

    -- A window moved or resized (each step of our own animations too).
    local function onWindowMoved(win)
        -- A parked window that its app moved back into view.
        if win and Spaces.isHidden(win:id()) then
            if hs.timer.secondsSinceEpoch() > S.settleUntil then Spaces.place(win, true) end
            return
        end
        -- Our own layout moves echo back here; only other moves (e.g. to
        -- another display) can change which screen a window is on.
        if win and hs.timer.secondsSinceEpoch() > S.settleUntil then
            S.windowInfo[win:id()] = nil
            S.applied[win:id()] = nil
        end
        Focus.invalidateWindowCache()
        Float.raiseFloating()
        Resize.onWindowMoved(win)
    end

    -- As WindowServer reports them with wm.native.events, else from the
    -- filter, which holds each move back half a second. Only our windows.
    local events = Util.native("events")
    if events then
        events.start(function(id)
            local win = Util.winByID[id]
            if not (win and win:id() == id) then
                win = nil
                for _, w in ipairs(Util.managedWindows()) do
                    if w:id() == id then win = w break end
                end
            end
            if win then onWindowMoved(win) end
        end)
        S.running.events = events
    else
        filter:subscribe(hs.window.filter.windowMoved, onWindowMoved)
    end

    -- Forget per-window state once a window is gone.
    filter:subscribe(hs.window.filter.windowDestroyed, function(win)
        Util.forgetManagedWindows()
        local id = win and win:id()
        if id then
            Discover.cancelLayoutCheck(id)
            Spaces.forget(id)
            Float.forgetFloat(id)
            Util.windowKinds[id] = nil
            Util.windowRules[id] = nil
            S.floatingFrames[id] = nil
            Util.winByID[id] = nil
            S.windowInfo[id] = nil
            S.applied[id] = nil
            -- Kept briefly: the retile that notices the close still needs it
            -- to tell whether this was the focused window.
            hs.timer.doAfter(1, function()
                for i = #Util.focusHistory, 1, -1 do
                    if Util.focusHistory[i] == id then table.remove(Util.focusHistory, i) end
                end
                Util.focusTimes[id] = nil
            end)
        end
    end)

    -- Retile when the set of manageable windows changes.
    filter:subscribe({
        hs.window.filter.windowAllowed,
        hs.window.filter.windowCreated,
        hs.window.filter.windowVisible,
        hs.window.filter.windowUnminimized,
        hs.window.filter.windowUnfullscreened,
        hs.window.filter.windowInCurrentSpace,
    }, function(win, appName, event)
        Util.dlog("event %s %s id=%s", tostring(event), tostring(appName), tostring(win and win:id()))
        Util.forgetManagedWindows()
        if win then
            S.windowInfo[win:id()] = nil
            -- Windows of a hidden app come back where they were: parked if
            -- their workspace has been left since.
            Spaces.place(win)
        end
        Discover.markDirty(win)
        Focus.invalidateWindowCache()
        -- Placed straight away so it doesn't sit where the app opened it;
        -- the follow-up events for the same window coalesce behind this.
        -- Only for windows that were just created: on a Space switch the new
        -- Space's windows arrive (windowAllowed, windowInCurrentSpace) before
        -- the filter's list has dropped the old Space's, and a pass then
        -- would lay the old windows out in the new Space's tree.
        local created = event == hs.window.filter.windowCreated
        Layout.scheduleRetile(false, win and created and not Layout.mayBeTab(win))
        Layout.scheduleRecheck()
    end)

    -- Windows going away: the remaining tiles can grow straight away.
    filter:subscribe({
        hs.window.filter.windowRejected,
        hs.window.filter.windowDestroyed,
        hs.window.filter.windowHidden,
        hs.window.filter.windowMinimized,
        hs.window.filter.windowFullscreened,
        hs.window.filter.windowNotInCurrentSpace,
    }, function(win, appName, event)
        Util.dlog("event %s %s id=%s", tostring(event), tostring(appName), tostring(win and win:id()))
        Util.forgetManagedWindows()
        S.lastGoneTime = hs.timer.secondsSinceEpoch()
        if win then
            S.windowInfo[win:id()] = nil
            -- Back from the Dock or full screen, a window joins the workspace
            -- showing then.
            if event == hs.window.filter.windowMinimized
               or event == hs.window.filter.windowFullscreened then
                Spaces.forget(win:id())
            end
            -- Not a tab swap: the new tab's focus moves the ring without a fade.
            if event ~= hs.window.filter.windowNotInCurrentSpace then Border.forget(win:id()) end
        end
        Discover.markDirty(win)
        Focus.invalidateWindowCache()
        if event == hs.window.filter.windowNotInCurrentSpace then
            -- Also how a tab swap looks, with the new tab arriving a moment
            -- later: wait for it instead of treating this as a close.
            Layout.scheduleRetile(false, false, Layout.BSP_TAB_SETTLE)
        else
            Layout.scheduleRetile(false, true)
        end
        Layout.scheduleRecheck()
    end)

    -- Any other change to the allowed set (the handlers above clear the list
    -- themselves, since this pseudo-event arrives after them).
    filter:subscribe(hs.window.filter.windowsChanged, Util.forgetManagedWindows)

    -- Workspaces don't use Spaces, but full-screen windows still get their
    -- own: the window list changes going in and out of one.
    S.running.spaceWatcher = hs.spaces.watcher.new(function()
        Util.forgetManagedWindows()
        Focus.invalidateWindowCache()
        Layout.scheduleRetile(true)
    end):start()

    -- macOS moves windows off a removed display (and back onto a returning
    -- one) a while after announcing the change, so look again once it has.
    S.running.screenWatcher = hs.screen.watcher.new(function()
        Spaces.screensChanged()
        Layout.scheduleRetile(true)
        for _, t in ipairs(S.running.screenTimers or {}) do t:stop() end
        S.running.screenTimers = {}
        for i, delay in ipairs({ 0.5, 1.5, 3 }) do
            S.running.screenTimers[i] = hs.timer.doAfter(delay, function()
                Spaces.screensChanged()
                Layout.scheduleRetile(true)
            end)
        end
    end):start()

    Bar.start()
    Hud.start()
    Spaces.start()
    Border.start()
    Util.watchWindows()
    -- No focus event is coming for the window already focused.
    local focused = Util.focusedWindow()
    if focused and filter:isWindowAllowed(focused) and Util.windowKind(focused) ~= "ignored" then
        Focus.noteFocus(focused)
    end
    Layout.scheduleRetile(true)
    return M
end

return M
