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

-- Manual overrides persist across reloads, as does placement history. Window
-- IDs can be reused after a reboot, so entries also record the app and are
-- discarded if the machine has restarted since.
local FLOATS_KEY = "hyprspoon.floats"
local savedFloats, placedFloats = {}, {}
do
    local saved = hs.settings.get(FLOATS_KEY)
    if type(saved) == "table" and type(saved.boot) == "number"
       and math.abs(saved.boot - Tree.bootTime) < 120 and type(saved.entries) == "table" then
        savedFloats = saved.entries
        if type(saved.placed) == "table" then placedFloats = saved.placed end
    end
end

local function saveFloats()
    hs.settings.set(FLOATS_KEY, { boot = Tree.bootTime, entries = savedFloats, placed = placedFloats })
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
    if savedFloats[tostring(id)] ~= nil or placedFloats[tostring(id)] ~= nil then
        savedFloats[tostring(id)] = nil
        placedFloats[tostring(id)] = nil
        saveFloats()
    end
end

local function hasFloating()
    for _, float in pairs(S.autoFloat) do
        if float then return true end
    end
    return false
end

-- Puts a new float where its rule says: `size` and `position` (from the
-- display's top left) are points, or fractions when 0 < v <= 1 (1 is the
-- full display). Zero and negatives are points; the frame stays on screen.
-- Without a position it's centred if the rule's `center` is true, or if
-- `centre` is and the rule doesn't say.
local function placeFloat(win, rule, centre)
    -- Classification runs again on reload, but an existing float keeps the
    -- frame the user gave it. Keep this separate from manual overrides so
    -- automatic floats still pick up changes to their classification rules.
    local id, app = tostring(win:id()), appName(win)
    if placedFloats[id] == app then return end
    if rule.center ~= nil then centre = rule.center == true end
    local size, pos = rule.size, rule.position
    if not size and not pos and not centre then return end
    local screen = win:screen()
    if not screen then return end
    local sf = screen:frame()
    local f = win:frame()
    local x, y, w, h = f.x, f.y, f.w, f.h
    local function scale(v, whole) return v > 0 and v <= 1 and v * whole or v end
    if type(size) == "table" then
        local rw, rh = size[1] or size.w, size[2] or size.h
        if type(rw) == "number" and type(rh) == "number" then
            w, h = scale(rw, sf.w), scale(rh, sf.h)
        end
    end
    w, h = math.max(1, math.min(w, sf.w)), math.max(1, math.min(h, sf.h))
    if centre then
        -- Use the requested size: an app may not have resized yet.
        x, y = sf.x + (sf.w - w) / 2, sf.y + (sf.h - h) / 2
    end
    if type(pos) == "table" then
        local px, py = pos[1] or pos.x, pos[2] or pos.y
        if type(px) == "number" and type(py) == "number" then
            x, y = sf.x + scale(px, sf.w), sf.y + scale(py, sf.h)
        end
    end
    x, y = math.max(sf.x, math.min(x, sf.x + sf.w - w)), math.max(sf.y, math.min(y, sf.y + sf.h - h))
    if w ~= f.w or h ~= f.h then win:setSize({ w = w, h = h }) end
    if x ~= f.x or y ~= f.y then
        win:setTopLeft({ x = x, y = y })
    end
    -- Only once it's placed: saving writes the settings file, and a float
    -- no rule places has nothing to keep.
    placedFloats[id] = app
    saveFloats()
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
    -- Dialogs and panels: the app placed them, so they aren't re-centred
    -- unless a rule says where they go.
    if Util.windowKind(win) == "subwindow" then
        S.autoFloat[id] = true
        placeFloat(win, Util.rulesFor(win), false)
        return true
    end
    local rule = Util.rulesFor(win)
    if rule.float ~= nil then
        S.autoFloat[id] = rule.float == true
    else
        local ok, canFullScreen = pcall(function()
            local ax = hs.axuielement.windowElement(win)
            return ax and ax:isAttributeSettable("AXFullScreen")
        end)
        -- Unreadable (a busy app, or no such attribute): tile, ask next pass.
        if not ok or canFullScreen == nil then return false end
        S.autoFloat[id] = not canFullScreen
    end
    if S.autoFloat[id] then placeFloat(win, rule, true) end
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
