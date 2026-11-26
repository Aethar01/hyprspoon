-- hyprspoon/overview.lua: Niri-style workspace overview (and classic grid), in place of Mission Control.
--
-- Default style ("niri"):
--   Zooms each display out onto a dark backdrop with its workspaces stacked
--   vertically (current workspace centred, neighbours above and below, plus an
--   optional trailing empty workspace). Scrolling workspaces show their entire
--   horizontal strip of columns extending past the workspace edges.
--
--   With hyprspoon.native.slide (and Screen Recording permission), windows and
--   wallpapers render as GPU-composited live/cached captures with CoreAnimation
--   spring zoom-in/out and smooth workspace/column scrolling. Without the
--   native module (or with overview.captures = false), a pure-Lua hs.canvas
--   fallback draws the same niri layout with app icons and titles.
--
--   Controls while open:
--     Up/Down or k/j          select previous / next workspace
--     Left/Right or h/l       select previous / next window / column
--     Home/End or g/G         first / last window on workspace
--     Tab / Shift+Tab         next / previous workspace
--     [ / ] or , / .          previous / next display
--     1-9, 0                  jump directly to workspace 1..10
--     Return / Space          confirm selection and zoom in
--     Escape / q              cancel and zoom back to original workspace
--     x / w / Backspace       close selected window
--     Hover                   highlight window under pointer
--     Click window/workspace  switch & zoom in (backdrop cancels)
--     Middle-click window     close window
--     Scroll wheel / trackpad pan workspaces vertically, columns horizontally
--     Drag window             move to another workspace or reorder scrolling columns

local M = {}
package.loaded["hyprspoon.overview"] = M

local S = require("hyprspoon.state")

-- Lazy requires so pure geometry/navigation helpers can be unit-tested in plain
-- Lua without loading the whole Spoon.
local function lazy(name)
    return setmetatable({}, { __index = function(_, k) return require("hyprspoon." .. name)[k] end })
end
local Util = lazy("util")
local Focus = lazy("focus")
local Spaces = lazy("spaces")
local Border = lazy("border")
local Anim = lazy("anim")
local Scroll = lazy("scroll")

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local DEFAULTS = {
    style = "niri",
    zoom = 0.5,
    backdrop = "wallpaper",
    backdropColor = "#262626",
    backdropBlur = 20,
    backdropDim = 0.35,
    workspaceShadow = true,
    workspaceGap = 24,
    workspaceRadius = 12,
    showLabels = true,
    emptyWorkspace = true,
    scratchpads = false,
    captures = true,
    swipe = false,
}

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function M.config()
    local raw = S.cfg and S.cfg.overview
    if type(raw) ~= "table" then raw = {} end
    local style = raw.style == "grid" and "grid" or DEFAULTS.style
    local zoom = finite(raw.zoom) and clamp(raw.zoom, 0.1, 0.95) or DEFAULTS.zoom
    local backdrop = raw.backdrop == "color" and "color" or DEFAULTS.backdrop
    local backdropBlur
    if raw.backdropBlur == false then
        backdropBlur = 0
    elseif finite(raw.backdropBlur) then
        backdropBlur = clamp(raw.backdropBlur, 0, 100)
    else
        backdropBlur = DEFAULTS.backdropBlur
    end
    local backdropDim = finite(raw.backdropDim) and clamp(raw.backdropDim, 0, 1) or DEFAULTS.backdropDim
    local gap = finite(raw.workspaceGap) and math.max(0, raw.workspaceGap) or DEFAULTS.workspaceGap
    local radius = finite(raw.workspaceRadius) and math.max(0, raw.workspaceRadius) or DEFAULTS.workspaceRadius
    local swipe = finite(raw.swipe) and math.floor(raw.swipe) >= 3 and math.floor(raw.swipe) or false
    local scratchpads = false
    if raw.scratchpads == "shelf" or raw.scratchpads == true then
        scratchpads = "shelf"
    elseif raw.scratchpads == "stack" then
        scratchpads = "stack"
    end
    return {
        style = style,
        zoom = zoom,
        backdrop = backdrop,
        backdropColor = raw.backdropColor ~= nil and raw.backdropColor or DEFAULTS.backdropColor,
        backdropBlur = backdropBlur,
        backdropDim = backdropDim,
        workspaceShadow = raw.workspaceShadow ~= false,
        workspaceGap = gap,
        workspaceRadius = radius,
        showLabels = raw.showLabels ~= false,
        emptyWorkspace = raw.emptyWorkspace ~= false,
        scratchpads = scratchpads,
        captures = raw.captures ~= false,
        swipe = swipe,
    }
end

-- Number of fingers for the vertical overview swipe gesture, or nil when off.
function M.swipeFingers()
    local raw = S.cfg and S.cfg.overview
    local swipe = type(raw) == "table" and raw.swipe
    if finite(swipe) and math.floor(swipe) >= 3 then return math.floor(swipe) end
    return nil
end

-- ---------------------------------------------------------------------------
-- Pure niri layout, hit-testing & navigation (unit-tested in tests/overview_test.lua)
-- ---------------------------------------------------------------------------

-- Computes display-local rectangles for every workspace surface and window
-- in the niri overview on a display with `displayFrame` ({ x, y, w, h }).
-- `workspaces` is a list of { n, label, showing, empty, panX, windows = { { id, frame, floating, ... } } }.
-- `state` has { scrollY = 1-based float workspace index }.
--
-- At zoom == 1 and panX == 0 with scrollY == i, workspace i maps 1:1 onto
-- (0, 0, displayFrame.w, displayFrame.h), matching the live desktop exactly.
function M.computeLayout(displayFrame, workspaces, cfg, state)
    local fw, fh = displayFrame.w, displayFrame.h
    local fx, fy = displayFrame.x, displayFrame.y
    local zoom = cfg.zoom or DEFAULTS.zoom
    local gap = cfg.workspaceGap or DEFAULTS.workspaceGap
    local scrollY = (state and state.scrollY) or 1

    local wsW = fw * zoom
    local wsH = fh * zoom
    local wsX = (fw - wsW) / 2
    local stepY = wsH + gap

    local rows = {}
    for i, ws in ipairs(workspaces) do
        local wsCenterY = fh / 2 + (i - scrollY) * stepY
        local wsY = wsCenterY - wsH / 2
        local panX = ws.panX or 0
        local wins = {}
        for j, w in ipairs(ws.windows or {}) do
            local f = w.frame
            local rx = wsX + ((f.x - fx) - panX) * zoom
            local ry = wsY + (f.y - fy) * zoom
            local rw = math.max(8, f.w * zoom)
            local rh = math.max(8, f.h * zoom)
            wins[j] = {
                winIdx = j,
                wsIdx = i,
                id = w.id,
                win = w,
                rect = { x = rx, y = ry, w = rw, h = rh },
                floating = w.floating == true,
            }
        end
        rows[i] = {
            wsIdx = i,
            ws = ws,
            rect = { x = wsX, y = wsY, w = wsW, h = wsH },
            windows = wins,
        }
    end
    return {
        displayFrame = displayFrame,
        zoom = zoom,
        gap = gap,
        stepY = stepY,
        wsW = wsW,
        wsH = wsH,
        wsX = wsX,
        rows = rows,
    }
end

local function inRect(x, y, r)
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

-- Computes display-local geometry for the floating bottom scratchpad shelf.
-- Returns nil when `scratchpads` is empty.
function M.computeShelfLayout(displayFrame, scratchpads)
    if not displayFrame or not scratchpads or #scratchpads == 0 then return nil end
    local n = #scratchpads
    local pad, gap, bottomMargin = 12, 12, 24
    local cardW, cardH = 148, 88
    local maxDockW = math.max(120, displayFrame.w - 48)
    if n * cardW + (n - 1) * gap + pad * 2 > maxDockW then
        cardW = math.max(64, math.floor((maxDockW - pad * 2 - (n - 1) * gap) / n))
    end
    local dockW = n * cardW + (n - 1) * gap + pad * 2
    local dockH = cardH + pad * 2
    local dockX = (displayFrame.w - dockW) / 2
    local dockY = displayFrame.h - dockH - bottomMargin
    local items = {}
    for i, sp in ipairs(scratchpads) do
        items[i] = {
            idx = i,
            sp = sp,
            rect = {
                x = dockX + pad + (i - 1) * (cardW + gap),
                y = dockY + pad,
                w = cardW,
                h = cardH,
            },
        }
    end
    return {
        frame = { x = dockX, y = dockY, w = dockW, h = dockH },
        items = items,
    }
end

-- Hit-tests a display-local point (localX, localY) against a computed layout
-- and optional floating scratchpad shelf. Checks the floating shelf first,
-- then windows (reverse order so floats on top win), then workspace surfaces.
function M.hitTest(layout, localX, localY, shelfLayout)
    if shelfLayout and shelfLayout.items then
        for _, item in ipairs(shelfLayout.items) do
            if inRect(localX, localY, item.rect) then
                return { kind = "shelf", shelfIdx = item.idx, sp = item.sp, rect = item.rect }
            end
        end
        if shelfLayout.frame and inRect(localX, localY, shelfLayout.frame) then
            return { kind = "shelfDock", rect = shelfLayout.frame }
        end
    end
    if not layout or not layout.rows then return { kind = "backdrop" } end
    -- First pass: windows (last-drawn first, so floating windows beat tiles).
    for i = #layout.rows, 1, -1 do
        local row = layout.rows[i]
        for j = #row.windows, 1, -1 do
            local w = row.windows[j]
            if inRect(localX, localY, w.rect) then
                return { kind = "window", wsIdx = i, winIdx = j, ws = row.ws, win = w.win, rect = w.rect }
            end
        end
    end
    -- Second pass: workspace surfaces.
    for i = 1, #layout.rows do
        local row = layout.rows[i]
        if inRect(localX, localY, row.rect) then
            return { kind = "workspace", wsIdx = i, ws = row.ws, rect = row.rect }
        end
    end
    return { kind = "backdrop" }
end

-- Horizontal pan bounds (unscaled points) for workspace `ws` on `displayFrame`:
-- allows panning until the leftmost or rightmost window reaches the centre of
-- the display (and always includes 0).
function M.panBounds(displayFrame, ws)
    local fx, fw = displayFrame.x, displayFrame.w
    local minX, maxX = 0, 0
    for _, w in ipairs(ws.windows or {}) do
        local f = w.frame
        local left = (f.x - fx) - fw * 0.1
        local right = (f.x - fx + f.w) - fw * 0.9
        if left < minX then minX = left end
        if right > maxX then maxX = right end
    end
    return minX, maxX
end

-- Adjusts `ws.panX` so window `w` is comfortably visible within the zoomed
-- display viewport.
local function ensureWindowVisible(displayFrame, ws, w, zoom)
    if not w or not w.frame then return end
    local fx, fw = displayFrame.x, displayFrame.w
    local wsW = fw * zoom
    local wsX = (fw - wsW) / 2
    local panX = ws.panX or 0
    local left = wsX + ((w.frame.x - fx) - panX) * zoom
    local right = left + w.frame.w * zoom
    local margin = math.min(48, fw * 0.08)
    if left < margin then
        ws.panX = panX - (margin - left) / zoom
    elseif right > fw - margin then
        ws.panX = panX + (right - (fw - margin)) / zoom
    end
    local lo, hi = M.panBounds(displayFrame, ws)
    ws.panX = clamp(ws.panX or 0, lo, hi)
end

-- Windows of `ws` sorted left-to-right (then top-to-bottom) for predictable
-- keyboard navigation across columns and tiles.
local function sortedWindows(ws)
    local order = {}
    for i, w in ipairs(ws.windows or {}) do
        order[i] = { idx = i, w = w }
    end
    table.sort(order, function(a, b)
        local af, bf = a.w.frame, b.w.frame
        if math.abs(af.x - bf.x) > 8 then return af.x < bf.x end
        if math.abs(af.y - bf.y) > 8 then return af.y < bf.y end
        return a.idx < b.idx
    end)
    return order
end

-- Picks the default selected window on workspace `ws`: the focused one if any,
-- else the first window in left-to-right order (or nil if empty).
local function defaultWindowFor(ws, focusRank)
    if not ws or not ws.windows or #ws.windows == 0 then return nil end
    if focusRank then
        local best, bestR = nil, nil
        for _, w in ipairs(ws.windows) do
            local r = focusRank[w.id]
            if r and (not bestR or r < bestR) then best, bestR = w, r end
        end
        if best then return best.id end
    end
    for _, w in ipairs(ws.windows) do
        if w.focused then return w.id end
    end
    local order = sortedWindows(ws)
    return order[1] and order[1].w.id or nil
end

-- Pure keyboard navigation on `model` ({ displays = {...}, activeDisplay = 1, cfg = {...} }).
-- Returns true if the selection or viewport changed.
function M.navigate(model, action)
    if not model or not model.displays or #model.displays == 0 then return false end
    local d = model.displays[model.activeDisplay]
    if not d or #d.workspaces == 0 then return false end
    local zoom = (model.cfg and model.cfg.zoom) or DEFAULTS.zoom

    if action == "prevDisplay" or action == "nextDisplay" then
        if #model.displays < 2 then return false end
        local delta = action == "nextDisplay" and 1 or -1
        model.activeDisplay = (model.activeDisplay - 1 + delta) % #model.displays + 1
        return true
    end

    if action == "up" or action == "down" or action == "prevWorkspace" or action == "nextWorkspace" then
        local delta = (action == "down" or action == "nextWorkspace") and 1 or -1
        local nextIdx
        if action == "prevWorkspace" or action == "nextWorkspace" then
            nextIdx = (d.activeWs - 1 + delta) % #d.workspaces + 1
        else
            nextIdx = clamp(d.activeWs + delta, 1, #d.workspaces)
        end
        if nextIdx == d.activeWs and math.abs(d.scrollY - nextIdx) < 0.01 then return false end
        d.activeWs = nextIdx
        d.scrollY = nextIdx
        local ws = d.workspaces[nextIdx]
        d.selectedWin = defaultWindowFor(ws, model.focusRank)
        d.hoveredWin = nil
        d.hoveredWs = nil
        d.hoveredShelf = nil
        if d.selectedWin then
            for _, w in ipairs(ws.windows) do
                if w.id == d.selectedWin then ensureWindowVisible(d.frame, ws, w, zoom) break end
            end
        end
        return true
    end

    if action == "left" or action == "right" or action == "first" or action == "last" then
        local ws = d.workspaces[d.activeWs]
        if not ws or #ws.windows == 0 then return false end
        local order = sortedWindows(ws)
        local pos = 1
        for i, item in ipairs(order) do
            if item.w.id == d.selectedWin then pos = i break end
        end
        local nextPos
        if action == "first" then nextPos = 1
        elseif action == "last" then nextPos = #order
        elseif action == "left" then nextPos = math.max(1, pos - 1)
        else nextPos = math.min(#order, pos + 1) end
        local target = order[nextPos].w
        local changed = (d.selectedWin ~= target.id) or (d.hoveredWin ~= nil)
        d.selectedWin = target.id
        d.hoveredWin = nil
        d.hoveredWs = nil
        d.hoveredShelf = nil
        local beforePan = ws.panX or 0
        ensureWindowVisible(d.frame, ws, target, zoom)
        return changed or math.abs((ws.panX or 0) - beforePan) > 0.5
    end

    return false
end

-- Settles a vertical trackpad scroll on `scrollY` (1-based) with `velocity`
-- (workspaces/sec) onto an integer workspace index in 1..count.
function M.settleScrollY(scrollY, velocity, count)
    if count <= 1 then return 1 end
    local projected = scrollY + (velocity or 0) * 0.14
    return clamp(math.floor(projected + 0.5), 1, count)
end

-- ---------------------------------------------------------------------------
-- Shared colour & icon helpers
-- ---------------------------------------------------------------------------

local icons = {} -- bundle id -> hs.image or false

local function colorTable(c)
    return type(c) == "string" and { hex = c } or c
end

local function colorRGBA(c, fallback)
    if hs and hs.drawing and hs.drawing.color and hs.drawing.color.asRGB then
        local rgb = c and hs.drawing.color.asRGB(colorTable(c))
        if rgb then return { rgb.red, rgb.green, rgb.blue, rgb.alpha or 1 } end
    end
    return fallback or { 0.15, 0.15, 0.15, 1 }
end

local function iconFor(win)
    if not (hs and hs.image and hs.image.imageFromAppBundle) then return nil end
    local app = win and win:application()
    local bundle = app and app:bundleID()
    if not bundle then return nil end
    if icons[bundle] == nil then icons[bundle] = hs.image.imageFromAppBundle(bundle) or false end
    return icons[bundle] or nil
end

local function appNameFor(win)
    local app = win and win:application()
    return (app and app:name()) or ""
end

local function titleFor(win)
    return (win and win:title()) or ""
end

local function wallpaperPathFor(screen)
    if not (screen and screen.desktopImageURL) then return nil end
    local url = screen:desktopImageURL()
    if type(url) ~= "string" then return nil end
    local path = url:match("^file://(.+)$")
    if not path then return nil end
    return (path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local wallpapersLua = {} -- path -> hs.image or false
local function wallpaperImageFor(path)
    if not path or not (hs and hs.image and hs.image.imageFromPath) then return nil end
    if wallpapersLua[path] == nil then wallpapersLua[path] = hs.image.imageFromPath(path) or false end
    return wallpapersLua[path] or nil
end

-- ---------------------------------------------------------------------------
-- Runtime state
-- ---------------------------------------------------------------------------

local canvases = {}     -- screen UUID -> hs.canvas (grid mode or niri Lua fallback)
local inputTap = nil    -- hs.eventtap (keyboard + mouse + scroll while open)
local gridTargets = {}  -- element id -> { n =, win = } (grid mode)
local model = nil       -- active niri overview model
local usingNative = false
local bordersSuspended = false
local drag = nil        -- { displayIdx, wsIdx, win, startPt, offset, active, dropDisplayIdx, dropWsIdx, dropHit }
local scrollState = nil -- continuous trackpad pan state
local wheelReady = 0

local DRAG_THRESHOLD = 6

local function suspendBorders(on)
    on = on == true
    if bordersSuspended == on then return end
    bordersSuspended = on
    Border.suspend(on)
    if not on and Border.focused and Focus.currentWindow then
        local win = Focus.currentWindow()
        if win then Border.focused(win) end
    end
end

local function nativeOverview()
    local mod = Util.native and Util.native("slide") or nil
    if mod and mod.overviewOpen and mod.overviewUpdate and mod.overviewClose and mod.overviewStop then
        return mod
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Classic "grid" style (when overview.style == "grid")
-- ---------------------------------------------------------------------------

local GRID_PAD = 48
local GRID_LABEL = 28

local function gridGeometry(count, w, h, areaW, areaH)
    local cols = math.max(1, math.ceil(math.sqrt(count)))
    local rows = math.ceil(count / cols)
    local cellW = (areaW - GRID_PAD * (cols + 1)) / cols
    local cellH = cellW * h / w
    local fitH = (areaH - GRID_PAD * (rows + 1)) / rows - GRID_LABEL
    if cellH > fitH then
        cellH = fitH
        cellW = cellH * w / h
    end
    return cols, rows, cellW, cellH
end

local function drawGrid(screen, list)
    local ff = screen:fullFrame()
    local canvas = hs.canvas.new(ff)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior({ "canJoinAllSpaces", "stationary" })
    canvas:appendElements({
        id = "background", type = "rectangle", action = "fill",
        fillColor = { white = 0, alpha = 0.72 }, trackMouseDown = true,
    })

    local cols, rows, cellW, cellH = gridGeometry(#list, ff.w, ff.h, ff.w, ff.h)
    local gridW = cols * cellW + (cols - 1) * GRID_PAD
    local gridH = rows * (cellH + GRID_LABEL) + (rows - 1) * GRID_PAD
    local x0, y0 = (ff.w - gridW) / 2, (ff.h - gridH) / 2
    local scale = cellW / ff.w
    local active = S.cfg.border and colorTable(S.cfg.border.active) or { white = 1 }

    for i, ws in ipairs(list) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local cx = x0 + col * (cellW + GRID_PAD)
        local cy = y0 + row * (cellH + GRID_LABEL + GRID_PAD) + GRID_LABEL
        local cellID = "ws" .. ws.n
        gridTargets[cellID] = { n = ws.n }
        canvas:appendElements({
            type = "text", text = Spaces.label(ws.n),
            textSize = 18, textColor = { white = 1, alpha = ws.showing and 1 or 0.6 },
            frame = { x = cx, y = cy - GRID_LABEL, w = cellW, h = GRID_LABEL },
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
            local rx = cx + (f.x - ff.x) * scale
            local ry = cy + (f.y - ff.y) * scale
            local rw = math.max(8, f.w * scale)
            local rh = math.max(8, f.h * scale)
            local x1, y1 = math.max(cx, rx), math.max(cy, ry)
            local x2, y2 = math.min(cx + cellW, rx + rw), math.min(cy + cellH, ry + rh)
            if x2 - x1 >= 4 and y2 - y1 >= 4 then
                local r = { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
                local winID = "win" .. w.id
                gridTargets[winID] = { n = ws.n, win = w.win }
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
                        type = "text", text = titleFor(w.win),
                        textSize = 11, textAlignment = "center", textLineBreak = "truncateTail",
                        textColor = { white = 1, alpha = 0.85 },
                        frame = { x = r.x + 4, y = r.y + (r.h + size) / 2 - 4, w = r.w - 8, h = 16 },
                    })
                end
            end
        end
    end
    return canvas
end

-- ---------------------------------------------------------------------------
-- Niri model builder & renderers (native CoreAnimation + Lua hs.canvas fallback)
-- ---------------------------------------------------------------------------

local function buildModel(cfg, prevModel)
    local list = Spaces.overview()
    local focusRank = {}
    for i, fid in ipairs(Util.focusHistory or {}) do
        if not focusRank[fid] then focusRank[fid] = i end
    end
    local focusedWin = Focus.currentWindow and Focus.currentWindow() or nil
    local focusedID = focusedWin and focusedWin:id() or (Util.focusHistory and Util.focusHistory[1])
    local pointerScreen = hs.mouse and hs.mouse.getCurrentScreen and hs.mouse.getCurrentScreen()
    local pointerUUID = pointerScreen and pointerScreen:getUUID()

    -- Remember previous scroll/pan per display when rebuilding in place (e.g.
    -- after dragging a window between workspaces or closing a window).
    local prevByUUID = {}
    if prevModel then
        for _, pd in ipairs(prevModel.displays) do prevByUUID[pd.uuid] = pd end
    end

    -- Collect scratchpad entries by workspace number (for "shelf" mode).
    local scratchByN = {}
    local scratchOrder = {}
    if cfg.scratchpads == "shelf" then
        for i, name in ipairs((S.cfg and S.cfg.namedWorkspaces) or {}) do
            local n = 100 + i
            scratchByN[n] = { n = n, label = tostring(name), display = nil, showing = false, windows = {} }
            scratchOrder[#scratchOrder + 1] = n
        end
        for _, ws in ipairs(list) do
            local isScratch = Spaces.isScratchpad and Spaces.isScratchpad(ws.n) or (ws.n > 100)
            if isScratch then
                if not scratchByN[ws.n] then
                    scratchByN[ws.n] = { n = ws.n, label = Spaces.label(ws.n), display = nil, showing = false, windows = {} }
                    scratchOrder[#scratchOrder + 1] = ws.n
                end
                local entry = scratchByN[ws.n]
                entry.display = ws.display
                entry.showing = ws.showing == true
                local wins = {}
                for _, w in ipairs(ws.windows) do
                    wins[#wins + 1] = {
                        id = w.id,
                        win = w.win,
                        frame = { x = w.frame.x, y = w.frame.y, w = w.frame.w, h = w.frame.h },
                        floating = (S.autoFloat and S.autoFloat[w.id]) == true,
                        focused = w.id == focusedID,
                        app = appNameFor(w.win),
                        title = titleFor(w.win),
                    }
                end
                entry.windows = wins
            end
        end
        table.sort(scratchOrder)
    end

    local displays = {}
    local activeDisplay = 1
    for _, screen in ipairs(hs.screen.allScreens()) do
        local uuid = screen:getUUID()
        local ff = screen:fullFrame()
        local mode = screen.currentMode and screen:currentMode()
        local scale = mode and mode.scale or 1

        local mine = {}
        for _, ws in ipairs(list) do
            local isScratch = Spaces.isScratchpad and Spaces.isScratchpad(ws.n) or (ws.n > 100)
            if ws.display == uuid and (cfg.scratchpads == "stack" or not isScratch) then
                local wins = {}
                for _, w in ipairs(ws.windows) do
                    wins[#wins + 1] = {
                        id = w.id,
                        win = w.win,
                        frame = { x = w.frame.x, y = w.frame.y, w = w.frame.w, h = w.frame.h },
                        floating = (S.autoFloat and S.autoFloat[w.id]) == true,
                        focused = w.id == focusedID,
                        app = appNameFor(w.win),
                        title = titleFor(w.win),
                    }
                end
                mine[#mine + 1] = {
                    n = ws.n,
                    label = Spaces.label(ws.n),
                    showing = ws.showing == true,
                    empty = #wins == 0,
                    panX = 0,
                    windows = wins,
                }
            end
        end

        if #mine > 0 then
            if cfg.emptyWorkspace and Spaces.nextEmptyWorkspace then
                local emptyN = Spaces.nextEmptyWorkspace(uuid)
                if emptyN then
                    mine[#mine + 1] = {
                        n = emptyN,
                        label = Spaces.label(emptyN),
                        showing = false,
                        empty = true,
                        isDynamicEmpty = true,
                        panX = 0,
                        windows = {},
                    }
                end
            end

            local showingIdx = 1
            for i, ws in ipairs(mine) do
                if ws.showing then showingIdx = i break end
            end

            local prev = prevByUUID[uuid]
            local activeWs = showingIdx
            local scrollY = showingIdx
            local selectedWin = nil
            if prev then
                -- Keep looking at the same workspace number if it still exists.
                local prevWs = prev.workspaces[prev.activeWs]
                local found = nil
                if prevWs then
                    for i, ws in ipairs(mine) do
                        if ws.n == prevWs.n then found = i break end
                    end
                end
                activeWs = found or clamp(prev.activeWs, 1, #mine)
                scrollY = activeWs
                -- Preserve horizontal panX per workspace number.
                local prevPan = {}
                for _, pws in ipairs(prev.workspaces) do prevPan[pws.n] = pws.panX end
                for _, ws in ipairs(mine) do
                    if prevPan[ws.n] then
                        local lo, hi = M.panBounds(ff, ws)
                        ws.panX = clamp(prevPan[ws.n], lo, hi)
                    end
                end
                -- Keep previous selected window if it's still on activeWs.
                if prev.selectedWin then
                    for _, w in ipairs(mine[activeWs].windows) do
                        if w.id == prev.selectedWin then selectedWin = prev.selectedWin break end
                    end
                end
            end
            if not selectedWin then
                selectedWin = defaultWindowFor(mine[activeWs], focusRank)
            end

            local dFrame = { x = ff.x, y = ff.y, w = ff.w, h = ff.h }
            local shelfList = {}
            for _, n in ipairs(scratchOrder) do
                local src = scratchByN[n]
                local front = nil
                if #src.windows > 0 then
                    local bestR = nil
                    for _, w in ipairs(src.windows) do
                        local r = focusRank[w.id]
                        if r and (not bestR or r < bestR) then front, bestR = w, r end
                    end
                    front = front or src.windows[1]
                end
                shelfList[#shelfList + 1] = {
                    n = src.n,
                    label = src.label,
                    showing = src.showing and src.display == uuid,
                    windows = src.windows,
                    winCount = #src.windows,
                    frontWin = front,
                    previewWid = front and front.id or 0,
                    app = front and front.app or "",
                }
            end
            local shelfLayout = M.computeShelfLayout(dFrame, shelfList)

            local di = #displays + 1
            displays[di] = {
                uuid = uuid,
                screen = screen,
                frame = dFrame,
                scale = scale,
                wallpaperPath = wallpaperPathFor(screen),
                workspaces = mine,
                scratchpads = shelfList,
                shelfLayout = shelfLayout,
                showingIdx = showingIdx,
                activeWs = activeWs,
                scrollY = scrollY,
                selectedWin = selectedWin,
                hoveredWin = nil,
                hoveredShelf = nil,
                dropWs = nil,
                dropShelf = nil,
            }
            if prevModel and prevModel.displays[prevModel.activeDisplay]
               and prevModel.displays[prevModel.activeDisplay].uuid == uuid then
                activeDisplay = di
            elseif not prevModel then
                if focusedID then
                    for _, w in ipairs(mine[showingIdx].windows) do
                        if w.id == focusedID then activeDisplay = di break end
                    end
                elseif uuid == pointerUUID then
                    activeDisplay = di
                end
            end
        end
    end

    return {
        cfg = cfg,
        displays = displays,
        activeDisplay = activeDisplay,
        focusRank = focusRank,
    }
end

local function buildNativeOpenSpec(m, animate)
    local cfg = m.cfg
    local borderCfg = S.cfg and S.cfg.border
    local activeRGBA = colorRGBA(borderCfg and borderCfg.active or "#6c99ba", { 0.424, 0.600, 0.729, 1 })
    local inactiveRGBA = colorRGBA(borderCfg and borderCfg.inactive or { hex = "#595959", alpha = 0.67 },
        { 0.349, 0.349, 0.349, 0.667 })
    local dropRGBA = colorRGBA(S.cfg and S.cfg.tiling and S.cfg.tiling.dropColor or { red = 0.35, green = 0.6, blue = 1 },
        { 0.35, 0.60, 1.0, 1.0 })
    local backdropRGBA = colorRGBA(cfg.backdropColor, { 0.149, 0.149, 0.149, 1.0 })

    local displays = {}
    for i, d in ipairs(m.displays) do
        local wsList = {}
        for wi, ws in ipairs(d.workspaces) do
            local winList = {}
            for k, w in ipairs(ws.windows) do
                winList[k] = {
                    wid = w.id,
                    frame = w.frame,
                    floating = w.floating,
                    focused = w.focused,
                    app = w.app,
                    title = w.title,
                }
            end
            wsList[wi] = {
                n = ws.n,
                label = ws.label,
                showing = ws.showing,
                empty = ws.empty,
                panX = ws.panX or 0,
                windows = winList,
            }
        end
        local shelfList = {}
        if d.shelfLayout and d.shelfLayout.items then
            for si, item in ipairs(d.shelfLayout.items) do
                local sp = item.sp
                shelfList[si] = {
                    n = sp.n,
                    label = sp.label,
                    showing = sp.showing == true,
                    winCount = sp.winCount or 0,
                    previewWid = sp.previewWid or 0,
                    app = sp.app or "",
                    rect = item.rect,
                }
            end
        end
        displays[i] = {
            uuid = d.uuid or "",
            frame = d.frame,
            scale = d.scale,
            wallpaperPath = d.wallpaperPath or "",
            scrollY = d.scrollY,
            activeWs = d.activeWs,
            selectedWin = d.selectedWin or 0,
            hoveredWin = d.hoveredWin or 0,
            dropWs = d.dropWs or 0,
            hoveredShelf = d.hoveredShelf or 0,
            dropShelf = d.dropShelf or 0,
            shelfFrame = d.shelfLayout and d.shelfLayout.frame or nil,
            shelf = shelfList,
            workspaces = wsList,
        }
    end

    return {
        zoom = cfg.zoom,
        gap = cfg.workspaceGap,
        radius = cfg.workspaceRadius,
        shadow = cfg.workspaceShadow,
        showLabels = cfg.showLabels,
        captures = cfg.captures,
        animate = animate ~= false,
        backdropWallpaper = cfg.backdrop == "wallpaper",
        backdropBlur = cfg.backdropBlur,
        backdropDim = cfg.backdropDim,
        backdrop = backdropRGBA,
        active = activeRGBA,
        inactive = inactiveRGBA,
        dropColor = dropRGBA,
        motion = Anim.get("overview"),
        displays = displays,
    }
end

local function buildNativeUpdateSpec(m, animate)
    local displays = {}
    for i, d in ipairs(m.displays) do
        local pans = {}
        for wi, ws in ipairs(d.workspaces) do pans[wi] = ws.panX or 0 end
        displays[i] = {
            scrollY = d.scrollY,
            activeWs = d.activeWs,
            selectedWin = d.selectedWin or 0,
            hoveredWin = d.hoveredWin or 0,
            dropWs = d.dropWs or 0,
            hoveredShelf = d.hoveredShelf or 0,
            dropShelf = d.dropShelf or 0,
            panX = pans,
        }
    end
    return {
        animate = animate ~= false,
        motion = Anim.get("overview"),
        displays = displays,
    }
end

-- Pure-Lua hs.canvas fallback renderer for niri mode (used when slide.so isn't
-- built or lacks overviewOpen). Draws the exact same geometry via computeLayout.
local function renderNiriCanvas(m)
    local cfg = m.cfg
    local backdropColor = colorTable(cfg.backdropColor)
    local activeColor = S.cfg.border and colorTable(S.cfg.border.active) or { hex = "#6c99ba" }
    local dropColor = (S.cfg.tiling and S.cfg.tiling.dropColor) or { red = 0.35, green = 0.6, blue = 1 }

    for di, d in ipairs(m.displays) do
        local canvas = canvases[d.uuid]
        if not canvas then
            canvas = hs.canvas.new(d.frame)
            canvas:level(hs.canvas.windowLevels.overlay)
            canvas:behavior({ "canJoinAllSpaces", "stationary" })
            canvases[d.uuid] = canvas
        end
        local layout = M.computeLayout(d.frame, d.workspaces, cfg, { scrollY = d.scrollY })
        local elems = {
            {
                type = "rectangle", action = "fill",
                fillColor = backdropColor,
                frame = { x = 0, y = 0, w = d.frame.w, h = d.frame.h },
            },
        }
        if cfg.backdrop == "wallpaper" then
            local wp = wallpaperImageFor(d.wallpaperPath)
            if wp then
                elems[#elems + 1] = {
                    type = "image", image = wp, imageScaling = "scaleToFit",
                    frame = { x = 0, y = 0, w = d.frame.w, h = d.frame.h },
                }
                if cfg.backdropDim > 0 then
                    elems[#elems + 1] = {
                        type = "rectangle", action = "fill",
                        fillColor = { white = 0, alpha = cfg.backdropDim },
                        frame = { x = 0, y = 0, w = d.frame.w, h = d.frame.h },
                    }
                end
            end
        end
        local r = cfg.workspaceRadius
        for wi, row in ipairs(layout.rows) do
            local ws = row.ws
            local wr = row.rect
            local isActive = (wi == d.activeWs)
            local isDrop = (wi == d.dropWs)
            if cfg.workspaceShadow then
                elems[#elems + 1] = {
                    type = "rectangle", action = "fill",
                    frame = { x = wr.x + 2, y = wr.y + 6, w = wr.w, h = wr.h },
                    roundedRectRadii = { xRadius = r, yRadius = r },
                    fillColor = { white = 0, alpha = 0.35 },
                }
            end
            elems[#elems + 1] = {
                type = "rectangle", action = "strokeAndFill",
                frame = wr,
                roundedRectRadii = { xRadius = r, yRadius = r },
                fillColor = ws.empty and { white = 0.11, alpha = 0.92 } or { white = 0.14, alpha = 0.96 },
                strokeColor = isDrop and dropColor or (isActive and activeColor or { white = 1, alpha = 0.16 }),
                strokeWidth = isDrop and 4 or (isActive and 2.5 or 1),
            }
            for _, w in ipairs(row.windows) do
                local rr = w.rect
                local isDragging = drag and drag.active and drag.win.id == w.id
                local isLit = (w.id == d.hoveredWin) or (isActive and w.id == d.selectedWin)
                elems[#elems + 1] = {
                    type = "rectangle", action = "strokeAndFill",
                    frame = rr,
                    roundedRectRadii = { xRadius = 8, yRadius = 8 },
                    fillColor = { white = 0.22, alpha = isDragging and 0.3 or 0.95 },
                    strokeColor = isLit and activeColor or { white = 1, alpha = isDragging and 0.15 or 0.3 },
                    strokeWidth = isLit and 3 or 1,
                }
                local size = math.min(44, rr.w * 0.45, rr.h * 0.45)
                local icon = iconFor(w.win.win)
                if icon and size >= 14 then
                    elems[#elems + 1] = {
                        type = "image", image = icon, imageScaling = "scaleProportionally",
                        frame = { x = rr.x + (rr.w - size) / 2, y = rr.y + (rr.h - size) / 2 - 8, w = size, h = size },
                    }
                end
                if rr.h > size + 28 then
                    elems[#elems + 1] = {
                        type = "text", text = w.win.title ~= "" and w.win.title or w.win.app,
                        textSize = 11, textAlignment = "center", textLineBreak = "truncateTail",
                        textColor = { white = 1, alpha = isDragging and 0.3 or 0.85 },
                        frame = { x = rr.x + 6, y = rr.y + (rr.h + size) / 2 - 4, w = math.max(1, rr.w - 12), h = 16 },
                    }
                end
            end
            if cfg.showLabels and ws.label and ws.label ~= "" then
                local pillW = math.max(26, #ws.label * 9 + 14)
                elems[#elems + 1] = {
                    type = "rectangle", action = "fill",
                    frame = { x = wr.x + 10, y = wr.y + 10, w = pillW, h = 24 },
                    roundedRectRadii = { xRadius = 8, yRadius = 8 },
                    fillColor = isDrop and dropColor or (isActive and activeColor or { white = 0.08, alpha = 0.8 }),
                }
                elems[#elems + 1] = {
                    type = "text", text = ws.label,
                    textSize = 12, textAlignment = "center",
                    textColor = { white = 1, alpha = 0.96 },
                    frame = { x = wr.x + 10, y = wr.y + 14, w = pillW, h = 18 },
                }
            end
        end

        -- Floating scratchpad shelf at the bottom of the display.
        if d.shelfLayout and d.shelfLayout.items then
            local sf = d.shelfLayout.frame
            elems[#elems + 1] = {
                type = "rectangle", action = "strokeAndFill",
                frame = sf,
                roundedRectRadii = { xRadius = 18, yRadius = 18 },
                fillColor = { white = 0.08, alpha = 0.84 },
                strokeColor = { white = 1, alpha = 0.16 },
                strokeWidth = 1,
            }
            for _, item in ipairs(d.shelfLayout.items) do
                local sp = item.sp
                local sr = item.rect
                local isDrop = (item.idx == d.dropShelf)
                local isHover = (item.idx == d.hoveredShelf)
                elems[#elems + 1] = {
                    type = "rectangle", action = "strokeAndFill",
                    frame = sr,
                    roundedRectRadii = { xRadius = 12, yRadius = 12 },
                    fillColor = sp.winCount > 0 and { white = 0.16, alpha = 0.96 } or { white = 0.11, alpha = 0.75 },
                    strokeColor = isDrop and dropColor or ((isHover or sp.showing) and activeColor or { white = 1, alpha = 0.16 }),
                    strokeWidth = isDrop and 3 or (isHover and 2.5 or (sp.showing and 2 or 1)),
                }
                local pillW = math.max(24, #sp.label * 9 + 12)
                elems[#elems + 1] = {
                    type = "rectangle", action = "fill",
                    frame = { x = sr.x + 7, y = sr.y + 7, w = pillW, h = 22 },
                    roundedRectRadii = { xRadius = 7, yRadius = 7 },
                    fillColor = isDrop and dropColor or ((isHover or sp.showing) and activeColor or { white = 0.08, alpha = 0.8 }),
                }
                elems[#elems + 1] = {
                    type = "text", text = sp.label,
                    textSize = 12, textAlignment = "center",
                    textColor = { white = 1, alpha = 0.96 },
                    frame = { x = sr.x + 7, y = sr.y + 10, w = pillW, h = 16 },
                }
                if sp.winCount > 1 then
                    local cntText = tostring(sp.winCount)
                    elems[#elems + 1] = {
                        type = "text", text = cntText,
                        textSize = 11, textAlignment = "right",
                        textColor = { white = 1, alpha = 0.85 },
                        frame = { x = sr.x + sr.w - 30, y = sr.y + 9, w = 22, h = 16 },
                    }
                end
                local icon = sp.frontWin and iconFor(sp.frontWin.win) or nil
                if icon then
                    local sz = 28
                    elems[#elems + 1] = {
                        type = "image", image = icon, imageScaling = "scaleProportionally",
                        frame = { x = sr.x + (sr.w - sz) / 2, y = sr.y + (sr.h - sz) / 2 + 2, w = sz, h = sz },
                    }
                end
                elems[#elems + 1] = {
                    type = "text",
                    text = sp.winCount > 0 and (sp.app ~= "" and sp.app or "Window") or "Empty",
                    textSize = 11, textAlignment = "center", textLineBreak = "truncateTail",
                    textColor = { white = 1, alpha = sp.winCount > 0 and 0.9 or 0.45 },
                    frame = { x = sr.x + 6, y = sr.y + sr.h - 20, w = math.max(1, sr.w - 12), h = 16 },
                }
            end
        end

        -- Drag ghost on the display holding the pointer.
        if drag and drag.active and drag.ghostDisplayIdx == di and drag.ghostRect then
            local gr = drag.ghostRect
            elems[#elems + 1] = {
                type = "rectangle", action = "strokeAndFill",
                frame = gr,
                roundedRectRadii = { xRadius = 8, yRadius = 8 },
                fillColor = { white = 0.25, alpha = 0.85 },
                strokeColor = activeColor,
                strokeWidth = 2.5,
            }
            elems[#elems + 1] = {
                type = "text", text = drag.win.app ~= "" and drag.win.app or drag.win.title,
                textSize = 12, textAlignment = "center", textLineBreak = "truncateTail",
                textColor = { white = 1, alpha = 0.95 },
                frame = { x = gr.x + 6, y = gr.y + gr.h / 2 - 8, w = math.max(1, gr.w - 12), h = 18 },
            }
        end

        canvas:replaceElements(table.unpack(elems))
        canvas:show()
    end
end

local function pushUpdate(animate)
    if not model then return end
    if usingNative then
        local mod = nativeOverview()
        if mod then mod.overviewUpdate(buildNativeUpdateSpec(model, animate)) end
    else
        renderNiriCanvas(model)
    end
end

local function rebuildInPlace()
    if not model then return end
    model = buildModel(model.cfg, model)
    if #model.displays == 0 then
        M.stop()
        return
    end
    if usingNative then
        local mod = nativeOverview()
        if mod then mod.overviewOpen(buildNativeOpenSpec(model, false)) end
    else
        renderNiriCanvas(model)
    end
end

-- ---------------------------------------------------------------------------
-- Closing & committing selection
-- ---------------------------------------------------------------------------

local function teardownImmediate()
    if inputTap then inputTap:stop() inputTap = nil end
    for _, canvas in pairs(canvases) do canvas:delete() end
    canvases, gridTargets = {}, {}
    if usingNative then
        local mod = nativeOverview()
        if mod then mod.overviewStop() end
    end
    usingNative = false
    model = nil
    drag = nil
    scrollState = nil
    S.overviewOpen = false
    suspendBorders(false)
end

-- Closes the niri overview cleanly, optionally committing `target` ({ displayIdx,
-- wsIdx, n, win }) with a smooth zoom-in animation while switching workspaces
-- and focusing underneath.
local function closeNiri(target)
    if not S.overviewOpen then return end
    if inputTap then inputTap:stop() inputTap = nil end
    drag = nil
    scrollState = nil
    local m = model
    local native = usingNative and nativeOverview() or nil

    -- Build close animation targets per display (default: zoom back into each
    -- display's originally showing workspace).
    local closeDisplays = {}
    if m then
        for i, d in ipairs(m.displays) do
            closeDisplays[i] = {
                scrollY = d.showingIdx,
                targetWs = d.showingIdx,
                panX = 0,
            }
        end
    end

    -- Apply workspace switch / focus underneath the overlay before zooming in
    -- so the real windows are already in place when the overlay disappears.
    if target and m then
        local td = target.displayIdx and m.displays[target.displayIdx]
        local targetWsIdx = target.wsIdx
        if td and not targetWsIdx and target.n then
            for i, ws in ipairs(td.workspaces) do
                if ws.n == target.n then targetWsIdx = i break end
            end
        end
        local key = target.n and ("ws" .. tostring(target.n)) or nil
        local beforeScroll = key and Scroll.viewOffset and Scroll.viewOffset(key) or 0

        local prevSuppress = S.overviewSuppressSlide
        local prevInstant = S.instantLayout
        S.overviewSuppressSlide = true
        S.instantLayout = true
        local ok, err = pcall(function()
            if target.scratchpad then
                if Spaces.toggleWorkspace then
                    Spaces.toggleWorkspace(target.scratchpad)
                elseif Spaces.gotoWorkspace then
                    Spaces.gotoWorkspace(target.scratchpad)
                end
                return
            end
            local win = target.win
            local id = win and win:id()
            if id and not Spaces.isHidden(id) then
                Focus.focus(win)
                if Scroll.reveal then Scroll.reveal(id) end
                Util.warpToWindow(win)
            elseif target.n then
                S.spaceFocusWin = id and win or nil
                Spaces.gotoWorkspace(target.n)
                if id and Scroll.reveal then Scroll.reveal(id) end
            end
        end)
        S.overviewSuppressSlide = prevSuppress
        S.instantLayout = prevInstant
        if not ok then print("hyprspoon: overview commit error: " .. tostring(err)) end

        if target.displayIdx and targetWsIdx and closeDisplays[target.displayIdx] then
            local afterScroll = key and Scroll.viewOffset and Scroll.viewOffset(key) or beforeScroll
            closeDisplays[target.displayIdx] = {
                scrollY = targetWsIdx,
                targetWs = targetWsIdx,
                panX = afterScroll - beforeScroll,
            }
        end
    end

    S.overviewOpen = false
    model = nil
    usingNative = false

    if native then
        native.overviewClose({
            motion = Anim.get("overview"),
            displays = closeDisplays,
        })
    else
        for _, canvas in pairs(canvases) do canvas:delete() end
        canvases = {}
    end
    -- Resume borders immediately: border rings sit at normal window level
    -- (behind the level-102 overview overlay) and borderMask ignores our
    -- above-normal overlay windows, so they're already in place when the
    -- zoom-in finishes with no timer race.
    suspendBorders(false)
end

-- ---------------------------------------------------------------------------
-- Hit-testing & pointer helpers
-- ---------------------------------------------------------------------------

local function displayAtPoint(pt)
    if not model then return nil end
    for i, d in ipairs(model.displays) do
        local f = d.frame
        if pt.x >= f.x and pt.x < f.x + f.w and pt.y >= f.y and pt.y < f.y + f.h then
            return i, d
        end
    end
    return nil
end

local function hitAtPoint(pt)
    local di, d = displayAtPoint(pt)
    if not di then return nil end
    local layout = M.computeLayout(d.frame, d.workspaces, model.cfg, { scrollY = d.scrollY })
    local hit = M.hitTest(layout, pt.x - d.frame.x, pt.y - d.frame.y, d.shelfLayout)
    return di, d, hit, layout
end

local function closeWindowEntry(di, wsIdx, entry)
    if not entry or not entry.win then return end
    pcall(function() entry.win:close() end)
    -- Optimistically remove from the overview model so the UI responds at once.
    local d = model and model.displays[di]
    local ws = d and d.workspaces[wsIdx]
    if not ws then return end
    for i, w in ipairs(ws.windows) do
        if w.id == entry.id then table.remove(ws.windows, i) break end
    end
    ws.empty = #ws.windows == 0
    if d.selectedWin == entry.id then d.selectedWin = defaultWindowFor(ws, model.focusRank) end
    if d.hoveredWin == entry.id then d.hoveredWin, d.hoveredWs = nil, nil end
    if usingNative then
        local mod = nativeOverview()
        if mod then mod.overviewOpen(buildNativeOpenSpec(model, false)) end
    else
        renderNiriCanvas(model)
    end
end

-- ---------------------------------------------------------------------------
-- Drag-and-drop in niri overview
-- ---------------------------------------------------------------------------

local function finishDrag(pt)
    local dr = drag
    drag = nil
    if not dr then return end
    if usingNative then
        local mod = nativeOverview()
        if mod and mod.overviewDrag then mod.overviewDrag(nil) end
    end
    if not dr.active then return end

    local di, d, hit = hitAtPoint(pt)
    local changed = false
    local srcDisplay = model.displays[dr.displayIdx]
    local srcWs = (not dr.fromShelf) and srcDisplay and srcDisplay.workspaces[dr.wsIdx] or nil
    local srcN = dr.fromShelf and dr.srcN or (srcWs and srcWs.n)
    if di and d and hit and hit.kind == "shelf" and hit.sp then
        if srcN ~= hit.sp.n and Spaces.sendWindowToWorkspace and Spaces.sendWindowToWorkspace(dr.win.win, hit.sp.n) then
            changed = true
        end
    elseif di and d and hit and (hit.kind == "window" or hit.kind == "workspace") then
        local dstWs = hit.ws
        if srcN and dstWs then
            if dstWs.n ~= srcN then
                if Spaces.sendWindowToWorkspace and Spaces.sendWindowToWorkspace(dr.win.win, dstWs.n) then
                    changed = true
                end
            elseif not dr.fromShelf and hit.kind == "window" and hit.win.id ~= dr.win.id then
                local key = "ws" .. tostring(srcN)
                local localX = pt.x - d.frame.x
                local side = localX < hit.rect.x + hit.rect.w / 2 and "left" or "right"
                if Scroll.reorderWindow and Scroll.reorderWindow(key, dr.win.id, hit.win.id, side) then
                    changed = true
                end
            end
        end
    end

    if changed then
        rebuildInPlace()
    else
        for _, disp in ipairs(model.displays) do
            disp.dropWs = nil
            disp.dropShelf = nil
        end
        pushUpdate(true)
    end
end

local function updateDrag(pt)
    if not drag or not model then return end
    if not drag.active then
        if math.abs(pt.x - drag.startPt.x) < DRAG_THRESHOLD
           and math.abs(pt.y - drag.startPt.y) < DRAG_THRESHOLD then
            return
        end
        drag.active = true
    end
    local di, d, hit = hitAtPoint(pt)
    local dropWs = (hit and (hit.kind == "window" or hit.kind == "workspace")) and hit.wsIdx or nil
    local dropShelf = (hit and hit.kind == "shelf") and hit.shelfIdx or nil
    for i, disp in ipairs(model.displays) do
        disp.dropWs = (i == di) and dropWs or nil
        disp.dropShelf = (i == di) and dropShelf or nil
    end
    if di and d then
        local gr = {
            x = (pt.x - d.frame.x) - drag.offset.x,
            y = (pt.y - d.frame.y) - drag.offset.y,
            w = drag.size.w,
            h = drag.size.h,
        }
        drag.ghostDisplayIdx = di
        drag.ghostRect = gr
        if usingNative then
            local mod = nativeOverview()
            if mod and mod.overviewDrag then
                mod.overviewDrag({
                    display = di,
                    wid = drag.win.id,
                    frame = gr,
                    dropWs = dropWs or 0,
                    dropShelf = dropShelf or 0,
                    captures = model.cfg.captures,
                    app = drag.win.app,
                    title = drag.win.title,
                })
            end
        else
            renderNiriCanvas(model)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Scroll wheel & trackpad panning inside niri overview
-- ---------------------------------------------------------------------------

local function settleContinuousScroll()
    local st = scrollState
    scrollState = nil
    if not st or not model then return end
    if st.axis == "vertical" then
        local d = model.displays[st.displayIdx]
        if not d then return end
        local v, samples = 0, st.samples
        local last = samples[#samples]
        if last then
            for i = #samples - 1, 1, -1 do
                local dt = last.t - samples[i].t
                if dt >= 0.03 or i == 1 then
                    v = dt > 0 and (last.y - samples[i].y) / dt or 0
                    break
                end
            end
        end
        local target = M.settleScrollY(d.scrollY, v, #d.workspaces)
        d.activeWs = target
        d.scrollY = target
        d.selectedWin = defaultWindowFor(d.workspaces[target], model.focusRank)
        pushUpdate(true)
    end
end

local function onScrollEvent(event)
    if not model then return true end
    local P = hs.eventtap.event.properties
    local phase = event:getProperty(P.scrollWheelEventScrollPhase) or 0
    local momentum = event:getProperty(P.scrollWheelEventMomentumPhase) or 0
    local continuous = event:getProperty(P.scrollWheelEventIsContinuous) == 1
    local dy = event:getProperty(P.scrollWheelEventPointDeltaAxis1) or 0
    local dx = event:getProperty(P.scrollWheelEventPointDeltaAxis2) or 0
    local pt = event:location()
    local di, d = displayAtPoint(pt)
    if not di then di, d = model.activeDisplay, model.displays[model.activeDisplay] end
    if not d then return true end
    model.activeDisplay = di

    if not continuous then
        local now = hs.timer.secondsSinceEpoch()
        if now < wheelReady then return true end
        local inverted = event:getProperty(137) == 1
        if math.abs(dy) >= math.abs(dx) and dy ~= 0 then
            local step = inverted and -dy or dy
            wheelReady = now + 0.09
            if M.navigate(model, step > 0 and "up" or "down") then pushUpdate(true) end
        elseif dx ~= 0 then
            local step = inverted and -dx or dx
            wheelReady = now + 0.09
            if M.navigate(model, step > 0 and "left" or "right") then pushUpdate(true) end
        end
        return true
    end

    -- Ignore momentum coasting after fingers lift: our own spring settles.
    if momentum ~= 0 then return true end

    if phase == 4 or phase == 8 then
        settleContinuousScroll()
        return true
    end

    if not scrollState then
        if phase ~= 1 and phase ~= 2 and phase ~= 128 then return true end
        scrollState = { displayIdx = di, axis = nil, sumX = 0, sumY = 0, samples = {} }
    end
    local st = scrollState
    if not st.axis then
        st.sumX = st.sumX + dx
        st.sumY = st.sumY + dy
        if math.abs(st.sumX) < 3 and math.abs(st.sumY) < 3 then return true end
        st.axis = math.abs(st.sumX) > math.abs(st.sumY) * 1.25 and "horizontal" or "vertical"
    end

    local zoom = model.cfg.zoom
    if st.axis == "vertical" then
        local stepY = d.frame.h * zoom + model.cfg.workspaceGap
        if stepY > 0 then
            d.scrollY = clamp(d.scrollY - dy / stepY, 0.7, #d.workspaces + 0.3)
            d.activeWs = clamp(math.floor(d.scrollY + 0.5), 1, #d.workspaces)
            st.samples[#st.samples + 1] = { t = hs.timer.secondsSinceEpoch(), y = d.scrollY }
            if #st.samples > 8 then table.remove(st.samples, 1) end
            pushUpdate(false)
        end
    else
        local ws = d.workspaces[d.activeWs]
        if ws then
            local lo, hi = M.panBounds(d.frame, ws)
            ws.panX = clamp((ws.panX or 0) - dx / zoom, lo, hi)
            pushUpdate(false)
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Unified input handler while niri overview is open
-- ---------------------------------------------------------------------------

local function onNiriKey(event)
    if not model then return false end
    local code = event:getKeyCode()
    local flags = event:getFlags()
    local map = hs.keycodes.map
    local keyName = map[code]

    if code == map.escape then
        closeNiri(nil)
        return true
    end

    -- Let hotkey chords with cmd/ctrl/alt pass through (e.g. Option+Tab to toggle close).
    if flags.cmd or flags.ctrl or flags.alt then return false end

    if keyName == "q" then
        closeNiri(nil)
        return true
    end

    if code == map["return"] or code == map.space or keyName == "padenter" then
        local d = model.displays[model.activeDisplay]
        local wsIdx = d and ((d.hoveredWin and d.hoveredWs) or d.activeWs)
        local ws = d and wsIdx and d.workspaces[wsIdx]
        local targetWin = nil
        local pickID = d and (d.hoveredWin or d.selectedWin)
        if ws and pickID then
            for _, w in ipairs(ws.windows) do
                if w.id == pickID then targetWin = w.win break end
            end
        end
        closeNiri(ws and { displayIdx = model.activeDisplay, wsIdx = wsIdx, n = ws.n, win = targetWin } or nil)
        return true
    end

    if code == map.tab then
        if M.navigate(model, flags.shift and "prevWorkspace" or "nextWorkspace") then pushUpdate(true) end
        return true
    end

    if keyName == "up" or keyName == "k" then
        if M.navigate(model, "up") then pushUpdate(true) end
        return true
    elseif keyName == "down" or keyName == "j" then
        if M.navigate(model, "down") then pushUpdate(true) end
        return true
    elseif keyName == "left" or keyName == "h" then
        if M.navigate(model, "left") then pushUpdate(true) end
        return true
    elseif keyName == "right" or keyName == "l" then
        if M.navigate(model, "right") then pushUpdate(true) end
        return true
    elseif keyName == "home" or (keyName == "g" and not flags.shift) then
        if M.navigate(model, "first") then pushUpdate(true) end
        return true
    elseif keyName == "end" or (keyName == "g" and flags.shift) then
        if M.navigate(model, "last") then pushUpdate(true) end
        return true
    elseif keyName == "[" or keyName == "," then
        if M.navigate(model, "prevDisplay") then pushUpdate(true) end
        return true
    elseif keyName == "]" or keyName == "." then
        if M.navigate(model, "nextDisplay") then pushUpdate(true) end
        return true
    elseif keyName == "x" or keyName == "w" or code == map.delete or code == map.forwarddelete then
        local d = model.displays[model.activeDisplay]
        local wsIdx = d and ((d.hoveredWin and d.hoveredWs) or d.activeWs)
        local ws = d and wsIdx and d.workspaces[wsIdx]
        local pickID = d and (d.hoveredWin or d.selectedWin)
        if ws and pickID then
            for _, w in ipairs(ws.windows) do
                if w.id == pickID then
                    closeWindowEntry(model.activeDisplay, wsIdx, w)
                    break
                end
            end
        end
        return true
    end

    local n = tonumber(keyName)
    if n then
        local targetN = n == 0 and 10 or n
        local targetDisplayIdx, targetWsIdx = nil, nil
        for di, d in ipairs(model.displays) do
            for wi, ws in ipairs(d.workspaces) do
                if ws.n == targetN then
                    targetDisplayIdx, targetWsIdx = di, wi
                    break
                end
            end
            if targetDisplayIdx then break end
        end
        closeNiri({ displayIdx = targetDisplayIdx, wsIdx = targetWsIdx, n = targetN })
        return true
    end

    if model.cfg.scratchpads ~= false and type(keyName) == "string" and #keyName == 1 then
        local lower = keyName:lower()
        for i, name in ipairs((S.cfg and S.cfg.namedWorkspaces) or {}) do
            if type(name) == "string" and name:lower() == lower then
                closeNiri({ scratchpad = 100 + i })
                return true
            end
        end
    end

    return true
end

local function onNiriEvent(event)
    if not S.overviewOpen or not model then return false end
    local types = hs.eventtap.event.types
    local t = event:getType()

    if t == types.keyDown then
        return onNiriKey(event)
    elseif t == types.scrollWheel then
        return onScrollEvent(event)
    elseif t == types.mouseMoved then
        local pt = event:location()
        local di, d, hit = hitAtPoint(pt)
        if di and d then
            model.activeDisplay = di
            local newHover = (hit and hit.kind == "window") and hit.win.id or nil
            local newHoverWs = (hit and hit.kind == "window") and hit.wsIdx or nil
            local newHoverShelf = (hit and hit.kind == "shelf") and hit.shelfIdx or nil
            local changed = false
            for i, disp in ipairs(model.displays) do
                local want = (i == di) and newHover or nil
                local wantWs = (i == di) and newHoverWs or nil
                local wantShelf = (i == di) and newHoverShelf or nil
                if disp.hoveredWin ~= want or disp.hoveredWs ~= wantWs or disp.hoveredShelf ~= wantShelf then
                    disp.hoveredWin = want
                    disp.hoveredWs = wantWs
                    disp.hoveredShelf = wantShelf
                    changed = true
                end
            end
            if changed then pushUpdate(false) end
        end
        return false
    elseif t == types.leftMouseDown then
        local pt = event:location()
        local di, d, hit = hitAtPoint(pt)
        if di and d and hit and hit.kind == "window" then
            drag = {
                displayIdx = di,
                wsIdx = hit.wsIdx,
                win = hit.win,
                startPt = { x = pt.x, y = pt.y },
                offset = { x = (pt.x - d.frame.x) - hit.rect.x, y = (pt.y - d.frame.y) - hit.rect.y },
                size = { w = hit.rect.w, h = hit.rect.h },
                active = false,
            }
        elseif di and d and hit and hit.kind == "shelf" and hit.sp and hit.sp.frontWin then
            drag = {
                displayIdx = di,
                fromShelf = true,
                shelfIdx = hit.shelfIdx,
                srcN = hit.sp.n,
                win = hit.sp.frontWin,
                startPt = { x = pt.x, y = pt.y },
                offset = { x = (pt.x - d.frame.x) - hit.rect.x, y = (pt.y - d.frame.y) - hit.rect.y },
                size = { w = hit.rect.w, h = hit.rect.h },
                active = false,
            }
        else
            drag = nil
        end
        return true
    elseif t == types.leftMouseDragged then
        if drag then updateDrag(event:location()) end
        return true
    elseif t == types.leftMouseUp then
        local pt = event:location()
        if drag and drag.active then
            finishDrag(pt)
            return true
        end
        drag = nil
        local di, _, hit = hitAtPoint(pt)
        if di and hit and hit.kind == "shelf" and hit.sp then
            closeNiri({ displayIdx = di, scratchpad = hit.sp.n })
        elseif di and hit and hit.kind == "shelfDock" then
            -- Clicking the dock's padding between cards keeps overview open.
        elseif di and hit and hit.kind == "window" then
            closeNiri({ displayIdx = di, wsIdx = hit.wsIdx, n = hit.ws.n, win = hit.win.win })
        elseif di and hit and hit.kind == "workspace" then
            closeNiri({ displayIdx = di, wsIdx = hit.wsIdx, n = hit.ws.n })
        else
            closeNiri(nil)
        end
        return true
    elseif t == types.otherMouseDown then
        local button = event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
        if button == 2 then -- middle click closes window
            local di, _, hit = hitAtPoint(event:location())
            if di and hit and hit.kind == "window" then
                closeWindowEntry(di, hit.wsIdx, hit.win)
            elseif di and hit and hit.kind == "shelf" and hit.sp and hit.sp.frontWin then
                pcall(function() hit.sp.frontWin.win:close() end)
                rebuildInPlace()
            end
        end
        return true
    elseif t == types.rightMouseDown or t == types.rightMouseUp then
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Classic grid mode callbacks
-- ---------------------------------------------------------------------------

local function goGrid(target)
    teardownImmediate()
    if not target then return end
    local win = target.win
    local id = win and win:id()
    if id and not Spaces.isHidden(id) then
        Focus.focus(win)
        Util.warpToWindow(win)
    else
        S.spaceFocusWin = id and win or nil
        Spaces.gotoWorkspace(target.n)
    end
end

local function onGridMouse(_, message, id)
    if message ~= "mouseDown" then return end
    goGrid(gridTargets[id])
end

local function onGridKey(event)
    local code = event:getKeyCode()
    local map = hs.keycodes.map
    if code == map.escape then
        teardownImmediate()
        return true
    end
    local flags = event:getFlags()
    if flags.cmd or flags.ctrl then return false end
    local n = tonumber(map[code])
    if n then
        goGrid({ n = n == 0 and 10 or n })
        return true
    end
    return false
end

local function openGrid()
    local cfg = M.config()
    local list = Spaces.overview()
    S.overviewOpen = true
    suspendBorders(true)
    for _, screen in ipairs(hs.screen.allScreens()) do
        local uuid = screen:getUUID()
        local mine = {}
        for _, ws in ipairs(list) do
            local isScratch = Spaces.isScratchpad and Spaces.isScratchpad(ws.n) or (ws.n > 100)
            if ws.display == uuid and (cfg.scratchpads or not isScratch) then mine[#mine + 1] = ws end
        end
        if #mine > 0 then
            local canvas = drawGrid(screen, mine)
            canvas:mouseCallback(onGridMouse)
            canvas:show()
            canvases[uuid] = canvas
        end
    end
    inputTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, onGridKey):start()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.toggle()
    if S.overviewOpen then
        if model then closeNiri(nil) else teardownImmediate() end
        return
    end
    local cfg = M.config()
    if cfg.style == "grid" then
        openGrid()
        return
    end

    model = buildModel(cfg, nil)
    if #model.displays == 0 then
        model = nil
        return
    end

    S.overviewOpen = true
    suspendBorders(true)

    local mod = nativeOverview()
    if mod and mod.overviewOpen(buildNativeOpenSpec(model, true)) then
        usingNative = true
        -- Overview's native capture also stored each showing workspace into
        -- slide.m's pictures[] cache: tell Slide so leaving via overview keeps
        -- slide-in pictures warm for later workspace switches.
        local Slide = package.loaded["hyprspoon.slide"]
        if model.cfg.captures and Slide and Slide.noteCaptured then
            for _, d in ipairs(model.displays) do
                local ws = d.workspaces[d.showingIdx]
                if ws and ws.showing and #ws.windows > 0 then
                    local ids, floats = {}, 0
                    for _, w in ipairs(ws.windows) do
                        if w.floating then floats = floats + 1 end
                        ids[#ids + 1] = w.id
                    end
                    if (floats == 0 or (#ids == 1 and floats == 1)) and #ids > 0 then
                        Slide.noteCaptured(ws.n, ids, d.screen)
                    end
                end
            end
        end
    else
        usingNative = false
        renderNiriCanvas(model)
    end

    local types = hs.eventtap.event.types
    inputTap = hs.eventtap.new({
        types.keyDown,
        types.mouseMoved,
        types.leftMouseDown,
        types.leftMouseDragged,
        types.leftMouseUp,
        types.rightMouseDown,
        types.rightMouseUp,
        types.otherMouseDown,
        types.scrollWheel,
    }, onNiriEvent):start()
end

-- Closes immediately (reload, shutdown, display change).
M.stop = teardownImmediate

return M
