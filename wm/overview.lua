-- wm/overview.lua: Every workspace at a glance, in place of Mission Control.

local M = {}
package.loaded["wm.overview"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Focus = require("wm.focus")
local Spaces = require("wm.spaces")
local Border = require("wm.border")

-- ---------------------------------------------------------------------------
-- Overview
-- ---------------------------------------------------------------------------
--
-- Each display shows its workspaces side by side as miniatures of the
-- display, every window an outline with its app's icon and title, the
-- workspace showing outlined in the active ring colour. It's drawn from
-- what the layout already knows (tile rects, parked windows' frames), so
-- it needs no screen recording and opens at once.
--
-- Click a window to go to it, a workspace to switch to it, anywhere else
-- to close. 1-9 and 0 go to that workspace, Escape closes. While it's open
-- focus doesn't follow the pointer and the rings are hidden.

local canvases = {}  -- screen UUID -> canvas
local keyTap = nil
local targets = {}   -- element id -> { n =, win = }
local icons = {}     -- bundle id -> hs.image

local PAD = 48
local LABEL = 28

local function color(c)
    return type(c) == "string" and { hex = c } or c
end

local function iconFor(win)
    local app = win:application()
    local bundle = app and app:bundleID()
    if not bundle then return nil end
    if icons[bundle] == nil then icons[bundle] = hs.image.imageFromAppBundle(bundle) or false end
    return icons[bundle] or nil
end

-- Columns and cell size for `count` miniatures of a `w` x `h` display in an
-- area `areaW` x `areaH`.
local function grid(count, w, h, areaW, areaH)
    local cols = math.max(1, math.ceil(math.sqrt(count)))
    local rows = math.ceil(count / cols)
    local cellW = (areaW - PAD * (cols + 1)) / cols
    local cellH = cellW * h / w
    local fitH = (areaH - PAD * (rows + 1)) / rows - LABEL
    if cellH > fitH then
        cellH = fitH
        cellW = cellH * w / h
    end
    return cols, rows, cellW, cellH
end

local function draw(screen, list)
    local ff = screen:fullFrame()
    local canvas = hs.canvas.new(ff)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior({ "canJoinAllSpaces", "stationary" })
    canvas:appendElements({
        id = "background", type = "rectangle", action = "fill",
        fillColor = { white = 0, alpha = 0.72 }, trackMouseDown = true,
    })

    local cols, rows, cellW, cellH = grid(#list, ff.w, ff.h, ff.w, ff.h)
    local gridW = cols * cellW + (cols - 1) * PAD
    local gridH = rows * (cellH + LABEL) + (rows - 1) * PAD
    local x0, y0 = (ff.w - gridW) / 2, (ff.h - gridH) / 2
    local scale = cellW / ff.w
    local active = S.cfg.border and color(S.cfg.border.active) or { white = 1 }

    for i, ws in ipairs(list) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local cx = x0 + col * (cellW + PAD)
        local cy = y0 + row * (cellH + LABEL + PAD) + LABEL
        local cellID = "ws" .. ws.n
        targets[cellID] = { n = ws.n }
        canvas:appendElements({
            type = "text", text = tostring(ws.n),
            textSize = 18, textColor = { white = 1, alpha = ws.showing and 1 or 0.6 },
            frame = { x = cx, y = cy - LABEL, w = cellW, h = LABEL },
        }, {
            id = cellID, type = "rectangle", action = "strokeAndFill",
            frame = { x = cx, y = cy, w = cellW, h = cellH },
            roundedRectRadii = { xRadius = 10, yRadius = 10 },
            fillColor = { white = 0.15, alpha = 0.9 },
            strokeColor = ws.showing and active or { white = 1, alpha = 0.15 },
            strokeWidth = ws.showing and 3 or 1,
            trackMouseDown = true,
        })
        for _, w in ipairs(ws.windows) do
            local f = w.frame
            local r = {
                x = cx + (f.x - ff.x) * scale, y = cy + (f.y - ff.y) * scale,
                w = math.max(8, f.w * scale), h = math.max(8, f.h * scale),
            }
            local winID = "win" .. w.id
            targets[winID] = { n = ws.n, win = w.win }
            canvas:appendElements({
                id = winID, type = "rectangle", action = "strokeAndFill",
                frame = r, roundedRectRadii = { xRadius = 6, yRadius = 6 },
                fillColor = { white = 0.28, alpha = 0.95 },
                strokeColor = { white = 1, alpha = 0.35 }, strokeWidth = 1,
                trackMouseDown = true,
            })
            local size = math.min(48, r.w * 0.5, r.h * 0.5)
            local icon = iconFor(w.win)
            if icon and size >= 12 then
                canvas:appendElements({
                    type = "image", image = icon, imageScaling = "scaleProportionally",
                    frame = { x = r.x + (r.w - size) / 2, y = r.y + (r.h - size) / 2 - 8, w = size, h = size },
                })
            end
            if r.h > size + 30 then
                canvas:appendElements({
                    type = "text", text = w.win:title() or "",
                    textSize = 11, textAlignment = "center", textLineBreak = "truncateTail",
                    textColor = { white = 1, alpha = 0.85 },
                    frame = { x = r.x + 4, y = r.y + (r.h + size) / 2 - 4, w = r.w - 8, h = 16 },
                })
            end
        end
    end
    return canvas
end

local function close()
    if keyTap then keyTap:stop() keyTap = nil end
    for _, canvas in pairs(canvases) do canvas:delete() end
    canvases, targets = {}, {}
    if S.overviewOpen then
        S.overviewOpen = false
        Border.suspend(false)
    end
end

local function go(target)
    close()
    if not target then return end
    local win = target.win
    if win and not Spaces.isHidden(win:id()) then
        Focus.focus(win)
        Util.warpToWindow(win)
    else
        S.spaceFocusWin = win
        Spaces.gotoWorkspace(target.n)
    end
end

local function onMouse(_, message, id)
    if message ~= "mouseDown" then return end
    go(targets[id])
end

local escape = hs.keycodes.map.escape

local function onKey(event)
    local code = event:getKeyCode()
    if code == escape then
        close()
        return true
    end
    local flags = event:getFlags()
    if flags.cmd or flags.ctrl then return false end
    local n = tonumber(hs.keycodes.map[code])
    if n then
        go({ n = n == 0 and 10 or n })
        return true
    end
    return false
end

function M.toggle()
    if S.overviewOpen then
        close()
        return
    end
    local list = Spaces.overview()
    S.overviewOpen = true
    Border.suspend(true)
    for _, screen in ipairs(hs.screen.allScreens()) do
        local uuid = screen:getUUID()
        local mine = {}
        for _, ws in ipairs(list) do
            if ws.display == uuid then mine[#mine + 1] = ws end
        end
        if #mine > 0 then
            local canvas = draw(screen, mine)
            canvas:mouseCallback(onMouse)
            canvas:show()
            canvases[uuid] = canvas
        end
    end
    keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onKey):start()
end

-- Closes it (reload, shutdown).
M.stop = close

return M
