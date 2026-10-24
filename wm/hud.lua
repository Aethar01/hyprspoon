-- wm/hud.lua: Workspace pop-up and corner badge on the displays.

local M = {}
package.loaded["wm.hud"] = M

local S = require("wm.state")
local Spaces = require("wm.spaces")
local Bar = require("wm.bar")

-- ---------------------------------------------------------------------------
-- Pop-up and badge
-- ---------------------------------------------------------------------------
--
-- For displays where the menu bar's numbers can't be seen. The pop-up shows
-- the row of numbers on the display that switched, like macOS's volume
-- pop-up, and fades; the badge stays in a corner of each display with its
-- workspace's number (or the whole row). Both are in a rounded panel in the
-- system appearance, with the display's own workspace in a pill, and let
-- clicks through.
--
-- `show` (S.cfg.indicators.popup/badge): "hiddenMenuBar" for displays whose
-- menu bar is hidden (auto-hide, where the usable area reaches the top of
-- the display), "always", or false.

local popups = {} -- screen UUID -> { canvas =, timer = }
local badges = {} -- screen UUID -> canvas

local function wanted(show, screen)
    if show == "always" then return true end
    if show == "hiddenMenuBar" then return screen:frame().y <= screen:fullFrame().y end
    return false
end

-- Panel colours for the current light or dark appearance.
local function palette()
    local dark = hs.host.interfaceStyle() == "Dark"
    local panel = dark and 0.12 or 0.96
    return {
        panel = { white = panel, alpha = 0.85 },
        edge = { white = dark and 1 or 0, alpha = 0.12 },
        text = { white = dark and 1 or 0 },
        pillText = { white = panel },
    }
end

-- A panel holding the row `list`, numbers `size` points high, placed by
-- `position(w, h)` returning its top-left. Hidden until shown.
local function panel(uuid, list, size, position)
    local colors = palette()
    local row = Bar.layout(list, size, math.ceil(size * 1.4))
    local inset = math.ceil(size * 0.45)
    local w, h = row.w + 2 * inset, row.h + 2 * inset
    local origin = position(w, h)
    local canvas = hs.canvas.new({ x = origin.x, y = origin.y, w = w, h = h })
    canvas:level(hs.canvas.windowLevels.status)
    canvas:clickActivating(false)
    canvas:appendElements({
        type = "rectangle", action = "strokeAndFill",
        roundedRectRadii = { xRadius = inset + row.h * 5 / 18, yRadius = inset + row.h * 5 / 18 },
        fillColor = colors.panel,
        strokeColor = colors.edge,
        strokeWidth = 1,
    })
    Bar.drawRow(canvas, row, inset, inset, colors, function(entry) return entry.display == uuid end)
    return canvas
end

local function screenFor(uuid)
    for _, screen in ipairs(hs.screen.allScreens()) do
        if screen:getUUID() == uuid then return screen end
    end
end

local function closePopup(uuid)
    local popup = popups[uuid]
    if not popup then return end
    popup.timer:stop()
    popup.canvas:delete()
    popups[uuid] = nil
end

-- A switch on display `uuid` (or focus going to it): show the row there,
-- replacing any pop-up still showing.
function M.switched(uuid)
    local cfg = S.cfg.indicators.popup
    local screen = uuid and screenFor(uuid)
    if not cfg or not screen or not wanted(cfg.show, screen) then return end
    closePopup(uuid)

    local frame = screen:frame()
    local canvas = panel(uuid, Bar.entries(), cfg.size, function(w, h)
        return { x = frame.x + (frame.w - w) / 2, y = frame.y + frame.h * 0.8 - h }
    end)
    canvas:show()
    local popup = { canvas = canvas }
    popup.timer = hs.timer.doAfter(cfg.duration, function()
        canvas:hide(0.25)
        popup.timer = hs.timer.doAfter(0.3, function()
            if popups[uuid] == popup then closePopup(uuid) end
        end)
    end)
    popups[uuid] = popup
end

local CORNERS = {
    topLeft = function(f, w, h, m) return { x = f.x + m, y = f.y + m } end,
    topRight = function(f, w, h, m) return { x = f.x + f.w - w - m, y = f.y + m } end,
    bottomLeft = function(f, w, h, m) return { x = f.x + m, y = f.y + f.h - h - m } end,
    bottomRight = function(f, w, h, m) return { x = f.x + f.w - w - m, y = f.y + f.h - h - m } end,
}

local function drawBadges()
    local cfg = S.cfg.indicators.badge
    local seen = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local uuid = screen:getUUID()
        if badges[uuid] then badges[uuid]:delete() badges[uuid] = nil end
        if cfg and wanted(cfg.show, screen) then
            seen[uuid] = true
            local list = Bar.entries()
            if not cfg.all then
                list = hs.fnutils.filter(list, function(entry) return entry.display == uuid end)
            end
            local frame = screen:frame()
            local corner = CORNERS[cfg.corner] or CORNERS.bottomRight
            badges[uuid] = panel(uuid, list, cfg.size, function(w, h)
                return corner(frame, w, h, cfg.margin)
            end)
            badges[uuid]:show()
        end
    end
    -- Displays that have gone.
    for uuid, canvas in pairs(badges) do
        if not seen[uuid] then canvas:delete() badges[uuid] = nil end
    end
end

-- Workspace changes come in bursts, so badges are redrawn once they're done.
local redraw = hs.timer.delayed.new(0.05, drawBadges)

function M.update()
    redraw:start()
end

function M.start()
    -- The panels follow the system appearance.
    S.running.appearanceWatcher = hs.distributednotifications.new(M.update,
        "AppleInterfaceThemeChangedNotification"):start()
    drawBadges()
end

-- Removes the pop-ups and badges (reload, shutdown).
function M.stop()
    redraw:stop()
    for uuid in pairs(popups) do closePopup(uuid) end
    for uuid, canvas in pairs(badges) do canvas:delete() badges[uuid] = nil end
end

return M
