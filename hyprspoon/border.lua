-- hyprspoon/border.lua: Rings around the windows, like Hyprland's borders.
--
-- Windows on show, except native full screen (Split View too), get a ring
-- just outside them, in the gap between
-- tiles: the focused window's in the active colour, the others in the
-- (see-through) inactive one, blending between the two as focus moves.
-- They are drawn by hyprspoon.native.border (hyprspoon/native/border.m), which moves them
-- from WindowServer's own notifications, so they follow drags, resizes and
-- animated retiles as they happen. A ring shows over windows that cover its
-- own (see border.m). This module only tells it which windows are on
-- show (not parked on another workspace) and which one has focus.

local M = {}
package.loaded["hyprspoon.border"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Spaces = require("hyprspoon.spaces")
local Tree = require("hyprspoon.tree")

-- The native module, loaded and styled by M.start(); false if unavailable.
local native = false
local suspended = false -- no rings at all (the overview is open)

local function onShow()
    local ids = {}
    if suspended then return ids end
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        -- Native full screen, Split View too (border.m also hides those
        -- rings, for windows whose events haven't come yet).
        if id and not S.fullscreen[id] and not Spaces.isHidden(id) and not Tree.behindMaximized(id)
           and not Tree.filling(id) then
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- Window set changes come in bursts.
local syncTimer = hs.timer.delayed.new(0.01, function()
    if native then native.set(onShow()) end
end)

-- Windows came, went, were parked or brought back.
function M.sync()
    if native then syncTimer:start() end
end

-- The windows WindowServer should tell us about (see Util.watchWindows).
function M.watch(ids)
    if native then native.watch(ids) end
end

-- Takes every ring away, or brings them back.
function M.suspend(on)
    suspended = on
    if native then native.set(onShow()) end
end

-- No window has focus: every ring goes inactive.
function M.hide()
    if native then native.focus(nil, S.cfg.border.fade) end
end

-- For hyprspoon.native.frames' drags: shows each frame in the window's ring as the
-- pointer moves, without waiting for the app to take it (nil without rings).
function M.previewer()
    return native and native.previewer() or nil
end

-- Window `id` went away, was parked or went full screen.
function M.forget(id)
    if native and native.active() == id then M.hide() end
    M.sync()
end

-- Focus went to `win`, or we asked for it.
function M.focused(win)
    if not native then return end
    local id = win and win:id()
    if not id or Spaces.isHidden(id) then
        M.hide()
        return
    end
    native.focus(id, S.cfg.border.fade)
end

-- Focus leaving for something we don't manage (an ignored app, a helper
-- window, the desktop) brings us no focus event: check just after the
-- focused window loses focus.
local unfocusCheck = hs.timer.delayed.new(0.05, function()
    local id = native and native.active()
    if not id then return end
    local win = Util.focusedWindow()
    if not win or win:id() ~= id then M.hide() end
end)

function M.unfocused(win)
    if native and win and win:id() == native.active() then unfocusCheck:start() end
end

local function rgba(color)
    local rgb = hs.drawing.color.asRGB(type(color) == "string" and { hex = color } or color)
    return { rgb.red, rgb.green, rgb.blue, rgb.alpha or 1 }
end

-- Loads the native module with the configured style and rings the windows.
function M.start()
    local cfg = S.cfg.border
    if not cfg then return end
    native = Util.native("border") or false
    if not native then return end
    -- Drawn at the finest resolution of any display.
    local resolution = 1
    for _, screen in ipairs(hs.screen.allScreens()) do
        local mode = screen:currentMode()
        if mode and mode.scale and mode.scale > resolution then resolution = mode.scale end
    end
    native.style({
        active = rgba(cfg.active),
        inactive = cfg.inactive and rgba(cfg.inactive) or { 0, 0, 0, 0 },
        width = cfg.width,
        radius = cfg.radius,
        resolution = resolution,
    })
    native.set(onShow())
end

-- Removes the rings (reload, shutdown).
function M.stop()
    suspended = false
    syncTimer:stop()
    unfocusCheck:stop()
    if native then native.stop() end
end

return M
