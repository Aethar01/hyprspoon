-- hyprspoon/util.lua: Small helpers: logging, window classification, focus records, pointer warping.

local M = {}
package.loaded["hyprspoon.util"] = M

local S = require("hyprspoon.state")
local Tree = require("hyprspoon.tree")
local Border = require("hyprspoon.border")

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
        print(string.format("[hyprspoon %.3f] " .. fmt, hs.timer.secondsSinceEpoch() % 1000, ...))
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
-- unlike real subwindows they have no close button. Some real dialogs lack
-- one too (Tailscale's prompts), but those are modal or have a default or
-- cancel button, which the helpers never do. Neither changes over a
-- window's lifetime, so each window is classified once.
local MANAGED_ROLES = { "AXStandardWindow", "AXDialog", "AXFloatingWindow", "AXSystemDialog" }
local windowKinds = {} -- window id -> "standard" | "subwindow" | "ignored"

local function windowKind(win)
    local id = win:id()
    if not id then return "ignored" end
    if windowKinds[id] then return windowKinds[id] end
    local kind = "standard"
    if win:subrole() ~= "AXStandardWindow" then
        local ok, dialog = pcall(function()
            local ax = hs.axuielement.windowElement(win)
            if not ax then return false end
            return ax:attributeValue("AXCloseButton") ~= nil
                or ax:attributeValue("AXModal") == true
                or ax:attributeValue("AXDefaultButton") ~= nil
                or ax:attributeValue("AXCancelButton") ~= nil
        end)
        -- Unreadable (a busy app): leave it alone and ask again next time.
        if not ok then return "ignored" end
        kind = dialog and "subwindow" or "ignored"
    end
    windowKinds[id] = kind
    return kind
end

-- The rules (S.cfg.rules) matching a window, merged into one table: later
-- matches override earlier ones. Worked out once per window.
local windowRules = {} -- window id -> merged rule
local MATCHERS = { app = true, title = true, role = true, subrole = true }

-- Borders can read rules before the title settles; those reads must not
-- populate the cache that placement and workspace assignment share.
local function rulesFor(win, uncached)
    local id = win:id()
    if id and windowRules[id] then return windowRules[id] end
    local out = {}
    local rules = S.cfg.rules or {}
    if #rules > 0 then
        local app = win:application()
        local name = app and app:name() or ""
        local title, role, subrole = nil, nil, nil
        for _, rule in ipairs(rules) do
            local match = rule.app == nil or rule.app == name
            if match and rule.role then
                role = role or win:role() or ""
                match = role == rule.role
            end
            if match and rule.subrole then
                subrole = subrole or win:subrole() or ""
                match = subrole == rule.subrole
            end
            if match and rule.title then
                title = title or win:title() or ""
                match = title:match(rule.title) ~= nil
            end
            if match then
                for k, v in pairs(rule) do
                    if not MATCHERS[k] then out[k] = v end
                end
            end
        end
    end
    if id and not uncached then windowRules[id] = out end
    return out
end

-- The filter's windows minus the helper windows above. getWindows() asks
-- macOS whether each window's app is still running and re-sorts on every
-- call, so the list is kept until the filter reports a change (callers must
-- not modify it). A window that couldn't be classified yet keeps the list
-- uncached, so it is asked about again.
local managedCache = nil

-- WindowServer reports moves, resizes and restacks only of the windows a
-- connection asks about, each ask replacing the last: hyprspoon.native.events and
-- hyprspoon.native.border are both told the managed windows (the set changes in
-- bursts).
local watchTimer = nil

local function watchWindows()
    if watchTimer then watchTimer:start() end
end

local function forgetManagedWindows()
    managedCache = nil
    -- The windows with rings follow the set.
    Border.sync()
    watchWindows()
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

-- The hs.window for window `id`, if it's one we manage.
local function windowFor(id)
    local win = winByID[id]
    if win and win:id() == id then return win end
    for _, w in ipairs(managedWindows()) do
        if w:id() == id then return w end
    end
    return nil
end

-- The native modules in hyprspoon/native (built with `make -C hyprspoon/native`): nil,
-- with a note in the console, for one that isn't built or won't load. The
-- callers then carry on in Lua (and there are no borders).
local natives = {}

local function native(name)
    if natives[name] == nil then
        -- macOS refuses a downloaded module still marked as quarantined, but
        -- only after holding Hammerspoon up for seconds while it checks, so
        -- don't try.
        local path = package.searchpath("hyprspoon.native." .. name, package.cpath)
        if path and hs.fs.xattr.get(path, "com.apple.quarantine") then
            print("hyprspoon: hyprspoon.native." .. name .. " not loaded: macOS has it quarantined. Run: "
                .. "xattr -dr com.apple.quarantine " .. path:match("^(.*/)hyprspoon/native/"))
            natives[name] = false
            return nil
        end
        local ok, mod = pcall(require, "hyprspoon.native." .. name)
        if not ok then
            print("hyprspoon: hyprspoon.native." .. name .. " not loaded (build with: make -C hyprspoon/native): " .. tostring(mod))
        end
        natives[name] = ok and mod or false
    end
    return natives[name] or nil
end

-- Gives `win` the frame `rect`, eased over `duration` seconds: on the app's
-- own queue with hyprspoon.native.frames (returning at once, and a slow app holds
-- up nobody else), else through hs.window.
local function setFrame(win, rect, duration)
    local frames = native("frames")
    local id = win:id()
    if frames and id then
        frames.set(pidByID[id] or win:pid(), id, rect.x, rect.y, rect.w, rect.h, duration or 0)
    else
        win:setFrame(rect, duration or 0)
    end
end

watchTimer = hs.timer.delayed.new(0.01, function()
    local ids = {}
    for _, win in ipairs(managedWindows()) do ids[#ids + 1] = win:id() end
    if S.running.events then S.running.events.watch(ids) end
    Border.watch(ids)
end)

-- Focuses `win`: through WindowServer with hyprspoon.native.frames, which doesn't
-- wait for the app (hs.window:focus() goes through accessibility, and a
-- busy app holds up the main thread for as long as it takes to answer).
-- `raise` false leaves it where it is in its app's stacking: raising is an
-- accessibility call, only needed when one of its app's windows covers it
-- (bringing the app to the front puts it above other apps' windows).
local function focusWindow(win, raise)
    local frames = native("frames")
    local id = win:id()
    if frames and id and frames.focus(pidByID[id] or win:pid(), id, raise ~= false) then return end
    win:focus()
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
M.native = native
M.setFrame = setFrame
M.focusWindow = focusWindow
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
M.windowRules = windowRules
M.rulesFor = rulesFor
M.forgetManagedWindows = forgetManagedWindows
M.watchWindows = watchWindows
M.managedWindows = managedWindows
M.windowFor = windowFor
M.WARP_MOUSE_EVENT = WARP_MOUSE_EVENT
M.warpToWindow = warpToWindow
M.warpToFocusedWindow = warpToFocusedWindow
M.pointInFrame = pointInFrame
M.FFM_SNAPSHOT_TTL = FFM_SNAPSHOT_TTL
M.FFM_HOVER_DELAY = FFM_HOVER_DELAY

return M
