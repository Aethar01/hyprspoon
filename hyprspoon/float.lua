-- hyprspoon/float.lua: Floating windows: automatic and manual floats, kept above tiles.

local M = {}
package.loaded["hyprspoon.float"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Tree = require("hyprspoon.tree")
local Spaces = require("hyprspoon.spaces")

-- Windows that can't go full screen float. Fixed-layout windows (dialogs,
-- non-resizable windows, System Settings with its fixed width) opt out of
-- it, and unlike their minimum and maximum sizes, macOS exposes it. The
-- attribute is final as soon as the window exists, so one read decides.
S.autoFloat = {}

-- Manual overrides persist across reloads. Window IDs can be reused after a
-- reboot, so entries also record the app and are discarded if the machine
-- has restarted since.
local FLOATS_KEY = "hyprspoon.floats"
local savedFloats = {}
do
    local saved = hs.settings.get(FLOATS_KEY)
    if type(saved) == "table" and type(saved.boot) == "number"
       and math.abs(saved.boot - Tree.bootTime) < 120 and type(saved.entries) == "table" then
        savedFloats = saved.entries
    end
end

local function saveFloats()
    hs.settings.set(FLOATS_KEY, { boot = Tree.bootTime, entries = savedFloats })
end

local function appName(win)
    local app = win:application()
    return app and app:name() or ""
end

local function rememberFloat(win)
    local id = win:id()
    savedFloats[tostring(id)] = { float = S.autoFloat[id] and true or false, app = appName(win) }
    saveFloats()
end

local function forgetFloat(id)
    S.autoFloat[id] = nil
    if savedFloats[tostring(id)] ~= nil then
        savedFloats[tostring(id)] = nil
        saveFloats()
    end
end

local function hasFloating()
    for _, float in pairs(S.autoFloat) do
        if float then return true end
    end
    return false
end

local function shouldFloat(win)
    local id = win:id()
    if S.autoFloat[id] ~= nil then return S.autoFloat[id] end

    local saved = savedFloats[tostring(id)]
    if saved and saved.app == appName(win) then
        S.autoFloat[id] = saved.float
        return saved.float
    end

    if Util.isPictureInPicture(win) then return false end
    -- Dialogs and panels: the app placed them, so they aren't re-centred.
    if Util.windowKind(win) == "subwindow" then
        S.autoFloat[id] = true
        return true
    end
    local rule = Util.rulesFor(win).float
    if rule ~= nil then
        S.autoFloat[id] = rule == true
    else
        local ok, canFullScreen = pcall(function()
            local ax = hs.axuielement.windowElement(win)
            return ax and ax:isAttributeSettable("AXFullScreen")
        end)
        -- Unreadable (a busy app, or no such attribute): tile, ask next pass.
        if not ok or canFullScreen == nil then return false end
        S.autoFloat[id] = not canFullScreen
    end
    if S.autoFloat[id] then
        local screen = win:screen()
        if screen then
            local sf, f = screen:frame(), win:frame()
            win:setTopLeft({ x = sf.x + (sf.w - f.w) / 2,
                y = sf.y + (sf.h - f.h) / 2 })
        end
    end
    return S.autoFloat[id]
end

-- Floating windows stay above the tiles. Hammerspoon can't set a window
-- level, so we re-raise them after layout/focus changes instead.
-- Raising a window of the active app also makes it key, so floats of the
-- focused window's own app are left where the app ordered them; otherwise
-- they would take focus straight back from their parent.
local function raiseFloatingNow()
    if not S.running.windowFilter or not hasFloating() then return end
    local focusedID = S.ffmFocusedID
    local focused = focusedID and Util.winByID[focusedID]
    local focusedPid = focused and focused:id() == focusedID and focused:pid()
    local focusedFloat = nil
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        if S.autoFloat[id] and not Spaces.isHidden(id) then
            -- The focused float goes last so it stays on top of the others.
            if id == focusedID then
                focusedFloat = win
            elseif win:pid() ~= focusedPid then
                win:raise()
            end
        end
    end
    if focusedFloat then focusedFloat:raise() end
end

-- Debounced, with a second pass: the first can run before a tile that has
-- just been focused or moved has finished coming to the front. Every focus,
-- move echo and retile lands here, so the two timers are reused.
local raiseSoon = hs.timer.delayed.new(0.03, raiseFloatingNow)
local raiseLater = hs.timer.delayed.new(0.25, raiseFloatingNow)
local function raiseFloating()
    if not hasFloating() then
        raiseSoon:stop()
        raiseLater:stop()
        return
    end
    raiseSoon:start()
    raiseLater:start()
end

-- Cancels the pending raises (reload, shutdown).
local function stop()
    raiseSoon:stop()
    raiseLater:stop()
end

M.stop = stop
M.rememberFloat = rememberFloat
M.forgetFloat = forgetFloat
M.shouldFloat = shouldFloat
M.raiseFloating = raiseFloating

return M
