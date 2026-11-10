-- hyprspoon/border.lua: Rings around the windows, like Hyprland's borders.
--
-- Windows on show, except native full screen (Split View too), get a ring
-- just outside them, in the gap between
-- tiles: the focused window's in the active colour, the others in the
-- (see-through) inactive one, blending between the two as focus moves.
-- They are drawn by hyprspoon.native.border (hyprspoon/native/border.m), which moves them
-- from WindowServer's own notifications, so they follow drags, resizes and
-- animated retiles as they happen. A ring shows over windows that cover its
-- own (see border.m), unless experimental.borderMask masks those parts out.
-- This module only tells it which windows are on show (not parked on
-- another workspace), which one has focus, and for the masks, which have
-- an `opacity` rule.

local M = {}
package.loaded["hyprspoon.border"] = M

local S = require("hyprspoon.state")
local Util = require("hyprspoon.util")
local Spaces = require("hyprspoon.spaces")
local Tree = require("hyprspoon.tree")
local Scroll = require("hyprspoon.scroll")

-- The native module, loaded and styled by M.start(); false if unavailable.
local native = false
local suspended = false -- no rings at all (the overview is open)
local masking = false -- experimental.borderMask is on
local barred = {} -- windows with a group bar (M.bar), drawn here too

-- With `border = false` the rings are still made, unseen, for group bars.
local function style()
    return S.cfg.border or S.defaults.border
end

local function fade()
    return S.cfg.border and S.cfg.border.fade or 0
end

-- The group bar's shown tab: group.bar.fade, else the ring's fade.
local function barFade()
    local group = S.cfg.group
    local bar = type(group) == "table" and type(group.bar) == "table" and group.bar or nil
    local v = bar and tonumber(bar.fade)
    return v and math.max(0, v) or fade()
end

-- The windows to ring, and with masks on, the managed windows' `opacity`
-- rules (a see-through window shows the ring under it, dimmed).
local function onShow()
    local ids, opacity = {}, masking and {} or nil
    if suspended then return ids, opacity end
    for _, win in ipairs(Util.managedWindows()) do
        local id = win:id()
        if opacity and id then opacity[id] = tonumber(Util.rulesFor(win).opacity) end
        -- Native full screen, Split View too (border.m also hides those
        -- rings, for windows whose events haven't come yet), and windows
        -- with a `noborder` rule.
        if id and not S.fullscreen[id] and not Spaces.isHidden(id) and not Scroll.isAway(id)
           and not Tree.behindMaximized(id)
           and not Tree.filling(id)
           and (barred[id] or (S.cfg.border and not Util.rulesFor(win, true).noborder)) then
            ids[#ids + 1] = id
        end
    end
    return ids, opacity
end

-- Window set changes come in bursts.
local syncTimer = hs.timer.delayed.new(0.01, function()
    if native then native.set(onShow()) end
end)

-- Windows came, went, were parked or brought back.
function M.sync()
    if native then syncTimer:start() end
end

-- The same, straight away (a group showing another member).
function M.syncNow()
    syncTimer:stop()
    if native then native.set(onShow()) end
end

-- The windows WindowServer should tell us about (see Util.watchWindows).
function M.watch(ids)
    if native then native.watch(ids) end
end

-- Takes every ring away, or brings them back.
function M.suspend(on)
    suspended = on
    require("hyprspoon.groupbar").suspend("overview", on)
    if native then native.set(onShow()) end
end

-- No window has focus: every ring goes inactive.
function M.hide()
    if native then native.focus(nil, fade(), barFade()) end
end

-- Draws the group bar `spec` above window `id` in its ring's window (nil
-- removes it), so the shown tab fades with the ring; see native/border.m
-- for `spec`. False without the native module.
function M.bar(id, spec)
    if not native then return false end
    local had = barred[id]
    barred[id] = spec and true or nil
    native.bar(id, spec)
    if not S.cfg.border and had ~= barred[id] then M.sync() end
    return true
end

-- Retitles tab `n` of window `id`'s bar; nothing else is redrawn.
function M.title(id, n, text)
    if native and barred[id] then native.title(id, n, text) end
end

-- For hyprspoon.native.frames' drags: shows each frame in the window's ring as the
-- pointer moves, without waiting for the app to take it (nil without rings).
function M.previewer()
    return native and native.previewer() or nil
end

-- The tile showing window `from` shows `to` instead (a set switched, or its
-- shown window closed): the active ring goes straight over, without a fade.
function M.handOver(from, to)
    if native and from and native.active() == from then native.focus(to, 0) end
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
    if not id or Spaces.isHidden(id) or Scroll.isAway(id) then
        M.hide()
        return
    end
    native.focus(id, fade(), barFade())
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

-- experimental.borderMask as hyprspoon.native.border takes it; nil when off.
local function maskOptions()
    local opt = S.cfg.experimental and S.cfg.experimental.borderMask
    if opt == true then opt = {} end
    if type(opt) ~= "table" then return nil end
    return { drags = opt.drags == "show" and "show" or "mask" }
end

local function rgba(color)
    local rgb = hs.drawing.color.asRGB(type(color) == "string" and { hex = color } or color)
    return { rgb.red, rgb.green, rgb.blue, rgb.alpha or 1 }
end

-- The ring window `win` has now, for pictures of it that hide the real one
-- (experimental.captureRetile, hyprspoon/slide.lua): { color = {r, g, b, a},
-- width =, radius = } (radius the configured one: the native side reads the
-- window's own where macOS reports it), or nil for none. With `coming`, the
-- one it will have as it scrolls back into view.
function M.ringFor(win, coming)
    if not native or suspended or not S.cfg.border then return nil end
    local id = win and win:id()
    if not id or S.fullscreen[id] or Spaces.isHidden(id) or (Scroll.isAway(id) and not coming)
       or Tree.behindMaximized(id) or Tree.filling(id) or Util.rulesFor(win, true).noborder then
        return nil
    end
    local cfg = style()
    local active = native.active and native.active() == id
    local color = active and cfg.active or cfg.inactive
    if not color then return nil end
    return { color = rgba(color), width = cfg.width or 0, radius = cfg.radius or 0 }
end

-- Loads the native module with the configured style and rings the windows.
function M.start()
    local group = S.cfg.group
    local bars = type(group) == "table" and type(group.bar) == "table"
    if not S.cfg.border and not bars then return end
    local cfg = style()
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
        width = S.cfg.border and cfg.width or 0,
        radius = cfg.radius,
        resolution = resolution,
    })
    local mask = maskOptions()
    if mask then
        masking = native.mask(mask)
        if S.running.events then S.running.events.filter(masking) end
        if not masking then print("hyprspoon: experimental.borderMask needs macOS 13 or later") end
    end
    native.set(onShow())
end

-- Removes the rings (reload, shutdown).
function M.stop()
    suspended = false
    syncTimer:stop()
    unfocusCheck:stop()
    if native and masking then
        native.mask(false)
        if S.running.events then S.running.events.filter(false) end
    end
    masking = false
    barred = {}
    if native then native.stop() end
end

return M
