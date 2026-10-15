-- wm/util.lua: Small helpers: logging, window classification, focus records, pointer warping.

local M = {}
package.loaded["wm.util"] = M

local S = require("wm.state")
local Tree = require("wm.tree")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function deepMerge(base, override)
    local out = {}
    for k, v in pairs(base) do
        if type(v) == "table" and next(v) ~= nil and v[1] == nil and type(override[k]) == "table" then
            out[k] = deepMerge(v, override[k])
        elseif override[k] ~= nil then
            out[k] = override[k]
        else
            out[k] = v
        end
    end
    for k, v in pairs(override) do
        if out[k] == nil then out[k] = v end
    end
    return out
end

S.cfg = deepMerge(S.defaults, {})

-- Our own record of focus, kept in step with the BSP tree. macOS's idea of
-- the focused window lags our actions and can be moved by the system (e.g. on
-- close), so actions read this; macOS is only asked to *do* things.
local focusHistory = {} -- most recent first
local focusTimes = {}   -- window id -> when it last gained focus
local winByID = {}      -- window id -> hs.window, for every tiled window
local pidByID = {}      -- window id -> owning process, for telling tab swaps

local function dlog(fmt, ...)
    if S.cfg.debug then
        print(string.format("[wm %.3f] " .. fmt, hs.timer.secondsSinceEpoch() % 1000, ...))
    end
end

local function idList(list, f)
    local out = {}
    for _, x in ipairs(list) do out[#out + 1] = tostring(f and f(x) or x) end
    return "[" .. table.concat(out, ",") .. "]"
end

-- macOS's view of focus (an accessibility query). Use Focus.currentWindow()
-- for actions; this is for checking what macOS actually did.
local function focusedWindow()
    return hs.window.focusedWindow()
end

-- Match the dedicated player title, not browser tabs mentioning PiP.
local PIP_TITLES = {
    "^[Pp]icture[- ][Ii]n[- ][Pp]icture$",
    "^[Pp][Ii][Pp]$",
}

local function isPictureInPicture(win)
    if not win then return false end
    local title = win:title() or ""
    for _, pattern in ipairs(PIP_TITLES) do
        if title:match(pattern) then return true end
    end
    return false
end

-- Besides standard windows, dialogs and panels (preferences, inspectors,
-- tool palettes) are managed, always as floats. Apps also keep invisible
-- helper windows with those roles (menu bar and notification overlays);
-- unlike real subwindows they have no close button. Neither changes over a
-- window's lifetime, so each window is classified once.
local MANAGED_ROLES = { "AXStandardWindow", "AXDialog", "AXFloatingWindow", "AXSystemDialog" }
local windowKinds = {} -- window id -> "standard" | "subwindow" | "ignored"

local function windowKind(win)
    local id = win:id()
    if not id then return "ignored" end
    if windowKinds[id] then return windowKinds[id] end
    local kind = "standard"
    if win:subrole() ~= "AXStandardWindow" then
        local ok, close = pcall(function()
            local ax = hs.axuielement.windowElement(win)
            return ax and ax:attributeValue("AXCloseButton")
        end)
        -- Unreadable (a busy app): leave it alone and ask again next time.
        if not ok then return "ignored" end
        kind = close and "subwindow" or "ignored"
    end
    windowKinds[id] = kind
    return kind
end

-- The filter's windows minus the helper windows above. getWindows() asks
-- macOS whether each window's app is still running and re-sorts on every
-- call, so the list is kept until the filter reports a change (callers must
-- not modify it). A window that couldn't be classified yet keeps the list
-- uncached, so it is asked about again.
local managedCache = nil

local function forgetManagedWindows()
    managedCache = nil
end

local function managedWindows()
    if managedCache then return managedCache end
    local out, complete = {}, true
    for _, win in ipairs(S.running.windowFilter and S.running.windowFilter:getWindows() or {}) do
        if windowKind(win) ~= "ignored" then out[#out + 1] = win end
        if not windowKinds[win:id()] then complete = false end
    end
    if complete and S.running.windowFilter then managedCache = out end
    return out
end

local WARP_MOUSE_EVENT = 0x425350

local function warpToWindow(win)
    if not win then return end
    -- Tiled windows warp to where their tile is, not where the app currently
    -- reports the window (which lags while it resizes).
    local f = Tree.rectFor and Tree.rectFor(win:id()) or win:frame()
    local point = {
        x = f.x + f.w / 2,
        y = f.y + f.h / 2,
    }
    hs.mouse.absolutePosition(point)
    -- Warping alone doesn't send mouse movement to apps, which can leave
    -- hover UI (e.g. Zen's expanding toolbar) stuck after a focus change.
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.mouseMoved, point)
        :setProperty(hs.eventtap.event.properties.eventSourceUserData, WARP_MOUSE_EVENT)
        :post()
end

local function warpToFocusedWindow(delay)
    if delay and delay > 0 then
        hs.timer.doAfter(delay, function()
            warpToWindow(focusedWindow())
        end)
    else
        warpToWindow(focusedWindow())
    end
end

local function pointInFrame(point, frame)
    return point.x >= frame.x and point.x < (frame.x + frame.w)
       and point.y >= frame.y and point.y < (frame.y + frame.h)
end

-- Set by the mouse tap while a modifier-drag is in progress.
S.dragState = nil

local FFM_SNAPSHOT_TTL = 1.0
local FFM_HOVER_DELAY = 0.03
S.settleUntil = 0 -- when our own layout's windowMoved echoes end; see Resize.onWindowMoved
S.lastMouseTime = 0 -- last click/drag/release, to tell user resizes from app ones

M.deepMerge = deepMerge
M.focusHistory = focusHistory
M.focusTimes = focusTimes
M.winByID = winByID
M.pidByID = pidByID
M.dlog = dlog
M.idList = idList
M.focusedWindow = focusedWindow
M.PIP_TITLES = PIP_TITLES
M.isPictureInPicture = isPictureInPicture
M.MANAGED_ROLES = MANAGED_ROLES
M.windowKinds = windowKinds
M.windowKind = windowKind
M.forgetManagedWindows = forgetManagedWindows
M.managedWindows = managedWindows
M.WARP_MOUSE_EVENT = WARP_MOUSE_EVENT
M.warpToWindow = warpToWindow
M.warpToFocusedWindow = warpToFocusedWindow
M.pointInFrame = pointInFrame
M.FFM_SNAPSHOT_TTL = FFM_SNAPSHOT_TTL
M.FFM_HOVER_DELAY = FFM_HOVER_DELAY

return M
