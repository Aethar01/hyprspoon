-- ~/.config/hammerspoon/wm/init.lua
--
-- Hyprland-inspired window manager for Hammerspoon:
--   * toggleable BSP tiling (per Space + display), with drag-and-drop and
--     split resizing by mouse, keyboard, or native window edges
--   * modifier + drag anywhere on a window to move/resize it
--   * focus follows mouse, with cursor warping on keyboard focus changes
--   * directional focus/swap/resize and numbered workspaces (macOS Spaces)
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
--   tree      BSP tree structure, persistence and per-Space/display keys
--   float     automatic and manual floating windows, kept above the tiles
--   focus     internal focus tracking and the window snapshot for hit testing
--   discover  finding the manageable windows on each screen
--   layout    laying the trees out onto windows, and scheduling retiles
--   resize    resizing tiles by keyboard, mouse or native window edges
--   drop      dragging a tile onto another to move it in the layout
--   mouse     modifier + drag anywhere on a window
--   ffm       focus follows mouse
--   spaces    numbered workspaces backed by macOS Spaces
--   actions   the hotkey actions
--   init      (this file) the public API, setup and teardown
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

-- The public API.
local M = {
    closeWindow = Actions.closeWindow,
    focus = Actions.focus,
    focusFloat = Actions.focusFloat,
    gotoWorkspace = Spaces.gotoWorkspace,
    gotoWorkspaceRelative = Spaces.gotoWorkspaceRelative,
    isTiling = Actions.isTiling,
    maximize = Actions.maximize,
    moveToWorkspace = Spaces.moveToWorkspace,
    resize = Actions.resize,
    swap = Actions.swap,
    toggleFloat = Actions.toggleFloat,
    toggleFullScreen = Actions.toggleFullScreen,
    toggleSplit = Actions.toggleSplit,
    toggleTiling = Actions.toggleTiling,
    warpToFocusedWindow = Actions.warpToFocusedWindow,
    warpToWindow = Actions.warpToWindow,
}

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local shutdownHooked = false

-- Stops everything setup() started (also run on reload and quit).
function M.stop()
    Discover.stop()
    if S.running.mouseTap then S.running.mouseTap:stop() end
    if S.running.moveTap then S.running.moveTap:stop() end
    if S.running.windowFilter then S.running.windowFilter:unsubscribeAll() end
    if S.running.pipFilter then S.running.pipFilter:unsubscribeAll() end
    if S.running.spaceWatcher then S.running.spaceWatcher:stop() end
    if S.running.screenWatcher then S.running.screenWatcher:stop() end
    for _, t in ipairs(S.running.screenTimers or {}) do t:stop() end
    if S.running.ffmTimer then S.running.ffmTimer:stop() end
    Layout.stop()
    Float.stop()
    Resize.stop()
    Focus.stop()
    Ffm.stop()
    Tree.stop() -- last: flushes a pending save after the layout has stopped
    S.running = {}
end

function M.setup(opts)
    M.stop()
    Util.forgetManagedWindows()
    Tree.forgetActiveSpaces()
    S.cfg = Util.deepMerge(S.defaults, opts or {})

    hs.window.animationDuration = 0

    -- A hung app would otherwise block every accessibility call (and so the
    -- whole layout) for the system default of several seconds.
    hs.window.timeout(S.cfg.axTimeout)

    -- Debounced tree saves must not be lost when Hammerspoon reloads or quits.
    if not shutdownHooked then
        shutdownHooked = true
        local previous = hs.shutdownCallback
        hs.shutdownCallback = function()
            M.stop()
            if previous then previous() end
        end
    end

    S.running.ffmTimer = hs.timer.delayed.new(Util.FFM_HOVER_DELAY, Ffm.ffmFocusPending)

    S.running.mouseTap = hs.eventtap.new({
        Mouse.mouseTypes.leftMouseDown,
        Mouse.mouseTypes.leftMouseDragged,
        Mouse.mouseTypes.leftMouseUp,
        Mouse.mouseTypes.rightMouseDown,
        Mouse.mouseTypes.rightMouseDragged,
        Mouse.mouseTypes.rightMouseUp,
    }, Mouse.onMouseEvent):start()

    S.running.moveTap = hs.eventtap.new({ Mouse.mouseTypes.mouseMoved }, Ffm.onMouseMoved):start()

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
            if id == S.requestedFocus then S.requestedFocus = nil end
            local intent = S.intent
            if intent and id == intent.id then
                S.intent = nil
            elseif intent and hs.timer.secondsSinceEpoch() - intent.time < Focus.REASSERT_WINDOW then
                -- macOS moved focus right after our request: put it back.
                S.intent = nil
                local wanted = Util.winByID[intent.id]
                if wanted and wanted:id() == intent.id then
                    wanted:focus()
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

    filter:subscribe(hs.window.filter.windowMoved, function(win)
        -- Our own layout moves echo back here; only other moves (e.g. to
        -- another display) can change which screen a window is on.
        if win and hs.timer.secondsSinceEpoch() > S.settleUntil then
            S.windowInfo[win:id()] = nil
            S.applied[win:id()] = nil
        end
        Focus.invalidateWindowCache()
        Float.raiseFloating()
        Resize.onWindowMoved(win)
    end)

    -- Forget per-window state once a window is gone.
    filter:subscribe(hs.window.filter.windowDestroyed, function(win)
        Util.forgetManagedWindows()
        local id = win and win:id()
        if id then
            Discover.cancelLayoutCheck(id)
            Float.forgetFloat(id)
            Util.windowKinds[id] = nil
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
        if event == hs.window.filter.windowInCurrentSpace then Tree.forgetActiveSpaces() end
        if win then S.windowInfo[win:id()] = nil end
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
        if event == hs.window.filter.windowNotInCurrentSpace then Tree.forgetActiveSpaces() end
        if win then S.windowInfo[win:id()] = nil end
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

    S.running.spaceWatcher = hs.spaces.watcher.new(function()
        Tree.forgetActiveSpaces()
        Util.forgetManagedWindows()
        -- Space changes we didn't start (trackpad swipes) need the same focus
        -- fix-up as keyboard ones.
        S.spaceFocusPending = true
        Spaces.settleSpaceFocus()
        Focus.invalidateWindowCache()
        Layout.scheduleRetile(true)
    end):start()

    -- macOS moves windows off a removed display (and back onto a returning
    -- one) a while after announcing the change, so look again once it has.
    S.running.screenWatcher = hs.screen.watcher.new(function()
        Tree.forgetActiveSpaces()
        Focus.invalidateWindowCache()
        Layout.scheduleRetile(true)
        for _, t in ipairs(S.running.screenTimers or {}) do t:stop() end
        S.running.screenTimers = {}
        for i, delay in ipairs({ 0.5, 1.5, 3 }) do
            S.running.screenTimers[i] = hs.timer.doAfter(delay, function()
                Tree.forgetActiveSpaces()
                Focus.invalidateWindowCache()
                Layout.scheduleRetile(true)
            end)
        end
    end):start()

    Layout.scheduleRetile(true)
    return M
end

return M
