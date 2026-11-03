-- hyprspoon/scroll.lua: EXPERIMENTAL, the throwaway prototype for issue #18
-- (phase 0): tiles laid out as columns side by side on a strip wider than
-- the display, scrolled so the focused one is fully on show, like niri.
-- It's here to find out whether scrolling can be smooth with 6+ columns
-- before the layout interface (#15) is built for it; see
-- tests/scroll_bench.lua for the measurement.
--
-- Turned on per workspace with experimental.scrolling (hyprspoon/state.lua).
-- The BSP tree still decides which windows there are and their order: its
-- tiles from first to last are the columns from left to right, so a new
-- window opens beside the focused one, and swapping tiles moves columns.
-- One window (or group) per column.
--
-- macOS won't leave a window wholly off its display, so a column scrolled
-- out of sight is parked in the display's corner like a hidden workspace's
-- windows (Spaces.parkPoint). It slides to the display's edge first and
-- comes back in from it, so the scroll looks like one; parked, it's moved
-- at its column's size, so scrolling only ever moves windows (one
-- accessibility call each step) and never resizes them. A column partly in
-- view hangs over the edge, unless another display is there.
--
-- Windows scrolled out of sight ("away") are not hidden in the Spaces
-- sense: they're still discovered, on their workspace's display, so they
-- stay in the layout. Rings, group bars and focus follows mouse leave them
-- out (see M.isAway), and focusing one (directionally, Cmd-Tab, the Dock)
-- scrolls it into view.

local M = {}
package.loaded["hyprspoon.scroll"] = M

local S = require("hyprspoon.state")

-- Required on first use: the modules that ask M.isAway are loaded (alone,
-- in the unit tests) without the layout around them.
local function lazy(name)
    return setmetatable({}, { __index = function(_, k) return require("hyprspoon." .. name)[k] end })
end
local Util = lazy("util")
local Tree = lazy("tree")
local Spaces = lazy("spaces")
local Layout = lazy("layout")
local Border = lazy("border")
local Discover = lazy("discover")

local DEFAULTS = {
    workspaces = true, -- true for all, or a list such as { 3, "A" }
    width = 0.5,       -- a column's share of the tiling area's width
    duration = 0.2,    -- seconds a scroll takes; 0 snaps
    center = false,    -- keep the focused column centred, not just in view
}

-- The share of the width columns cycle through (M.cycleWidth).
M.WIDTHS = { 1 / 3, 1 / 2, 2 / 3, 1 }

-- Tree key -> { x = scroll offset in points, focus = window id, and from
-- the last layout: leaves, starts, widths, total, viewW }.
local views = {}
-- Window id -> { key =, side = "left" | "right", parked = true once in the
-- corner, timer = the park after its slide out }.
local away = {}

local function cfg()
    local c = S.cfg and S.cfg.experimental and S.cfg.experimental.scrolling
    if not c then return nil end
    return c == true and {} or c
end

local function opt(name)
    local c = cfg()
    local v = c and c[name]
    if v == nil then return DEFAULTS[name] end
    return v
end

-- Whether workspace `key` ("ws<n>") is laid out in columns. Never for
-- scratchpads, which are laid out smaller over the workspace beneath.
function M.enabled(key)
    local c = cfg()
    if not c or not key or Spaces.layoutScale(key) then return false end
    local list = opt("workspaces")
    if list == true then return true end
    local n = tonumber(key:match("^ws(%-?%d+)$"))
    if not n then return false end
    local label = Spaces.label(n)
    for _, w in ipairs(list) do
        if tostring(w) == label or w == n then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The geometry (no Hammerspoon calls; see tests/scroll_test.lua)
-- ---------------------------------------------------------------------------

-- Each column's start along the strip, and the strip's length.
function M.strip(widths, gap)
    local starts, x = {}, 0
    for i, w in ipairs(widths) do
        starts[i] = x
        x = x + w + (i < #widths and gap or 0)
    end
    return starts, x
end

-- The scroll offset that shows column `index` in full, moving as little as
-- possible from `x` (or centring it, with `center`). Never past either end
-- of the strip, and 0 when the whole strip fits.
function M.viewport(starts, widths, total, viewW, x, index, center)
    if total <= viewW then return 0 end
    if index and starts[index] then
        local s, w = starts[index], widths[index]
        if center then
            x = s + w / 2 - viewW / 2
        elseif w >= viewW or s < x then
            x = s
        elseif s + w > x + viewW then
            x = s + w - viewW
        end
    end
    return math.max(0, math.min(x, total - viewW))
end

local function overlaps(a, b)
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y
end

local function overlapsAny(rect, frames)
    for _, f in ipairs(frames) do
        if overlaps(rect, f) then return true end
    end
    return false
end

-- Where a column's rect goes on display frame `sf`, with `others` the other
-- displays' frames: "show" (wholly on it), "hang" (partly, over an edge with
-- no display beyond), or the side it's away on, "left" or "right".
function M.classify(rect, sf, others)
    local right = rect.x + rect.w
    if rect.x >= sf.x - 1 and right <= sf.x + sf.w + 1 then return "show" end
    if right > sf.x and rect.x < sf.x + sf.w and not overlapsAny(rect, others) then
        return "hang"
    end
    return rect.x + rect.w / 2 < sf.x + sf.w / 2 and "left" or "right"
end

-- The frame just over the display's `side` edge, a point of it still on
-- show (macOS's limit), at the column's size and height.
function M.edgeRect(rect, side, sf)
    local x = side == "left" and sf.x - rect.w + 1 or sf.x + sf.w - 1
    return { x = x, y = rect.y, w = rect.w, h = rect.h }
end

-- ---------------------------------------------------------------------------
-- Laying out
-- ---------------------------------------------------------------------------

local function settle(extra)
    S.settleUntil = math.max(S.settleUntil,
        hs.timer.secondsSinceEpoch() + Layout.BSP_SETTLE + (extra or 0))
end

local function cancelPark(a)
    if a and a.timer then
        a.timer:stop()
        a.timer = nil
    end
end

local function park(win, a, id)
    if away[id] ~= a or win:id() ~= id then return end
    a.timer = nil
    local uuid = Spaces.uuidForKey(a.key)
    if not uuid then return end
    local p = Spaces.parkPoint(uuid, a.size)
    if not p then return end
    a.parked = true
    settle()
    Util.setFrame(win, { x = p.x, y = p.y, w = a.size.w, h = a.size.h }, 0)
end

-- Column `rect` of window `id` scrolled out of sight on `side`.
local function sendAway(id, win, key, rect, side, sf, others, duration)
    local a = away[id]
    if a then
        a.side, a.size = side, { w = rect.w, h = rect.h }
        -- Parked or on its way; else it had no window to move last time.
        if a.parked or a.timer or not win then return end
        return park(win, a, id)
    end
    a = { key = key, side = side, size = { w = rect.w, h = rect.h } }
    away[id] = a
    Discover.cancelLayoutCheck(id)
    S.applied[id] = nil
    Border.forget(id)
    if not win then return end
    local edge = M.edgeRect(rect, side, sf)
    if duration > 0 and not overlapsAny(edge, others) then
        settle(duration)
        Util.setFrame(win, edge, duration)
        a.timer = hs.timer.doAfter(duration + 0.05, function() park(win, a, id) end)
    else
        park(win, a, id)
    end
end

local function focusIndex(leaves, view)
    local function find(id)
        if not id then return nil end
        local leaf = Tree.setOf(id)
        for i, l in ipairs(leaves) do
            if l.windowID == id or (leaf and l == leaf) then return i end
        end
    end
    local i = find(view.focus)
    if i then return i end
    for _, id in ipairs(Util.focusHistory) do
        i = find(id)
        if i then
            view.focus = id
            return i
        end
    end
end

-- Lays tree `key` out in columns within `area` on `screen`, in place of
-- Layout.applyTree. `byID` and `full` are as applyTree's.
function M.arrange(key, tree, area, screen, byID, full)
    local leaves = Tree.leaves(tree)
    local view = views[key] or { x = 0 }
    views[key] = view

    local base = opt("width")
    local widths = {}
    for i, leaf in ipairs(leaves) do
        widths[i] = math.max(1, math.floor(area.w * (leaf.columnWidth or base)))
    end
    local starts, total = M.strip(widths, S.cfg.tiling.innerGap)
    view.x = M.viewport(starts, widths, total, area.w, view.x, focusIndex(leaves, view), opt("center"))
    view.leaves, view.starts, view.widths, view.total, view.viewW = leaves, starts, widths, total, area.w

    local sf = screen:fullFrame()
    local others = {}
    for _, s in ipairs(hs.screen.allScreens()) do
        if s:getUUID() ~= screen:getUUID() then others[#others + 1] = s:fullFrame() end
    end
    local duration = (S.instantLayout or S.dragState) and 0 or opt("duration")
    -- Every step of a scroll fires windowMoved too.
    settle(duration)

    local seen, came = {}, false
    for i, leaf in ipairs(leaves) do
        local id = leaf.windowID
        seen[id] = true
        local rect = hs.geometry.rect(area.x + starts[i] - view.x, area.y, widths[i], area.h)
        local where = M.classify(rect, sf, others)
        if where == "show" or where == "hang" then
            local a = away[id]
            local opts = { duration = duration }
            if a then
                cancelPark(a)
                away[id] = nil
                came = true
                local edge = M.edgeRect(rect, a.side, sf)
                if duration > 0 and not overlapsAny(edge, others) then opts.dx = edge.x - rect.x end
            end
            Layout.applyTree(leaf, rect, byID, full, opts)
        else
            -- Kept for directional focus and swaps, which go by tile rects.
            leaf.rect, leaf.windowRect, leaf.fullRect, leaf.pseudoRect = rect, rect, nil, nil
            sendAway(id, byID[id], key, rect, where, sf, others, duration)
        end
    end
    for id, a in pairs(away) do
        if a.key == key and not seen[id] then
            cancelPark(a)
            away[id] = nil
        end
    end
    if came then Border.sync() end
end

-- What changes the layout besides the windows and the area, for
-- tileNow's unchanged-screen shortcut.
function M.signature(key)
    local view = views[key]
    return view and string.format("|scroll %.0f", view.x) or ""
end

-- ---------------------------------------------------------------------------
-- Following focus
-- ---------------------------------------------------------------------------

-- Focus went to `id`: scroll its column into view.
function M.reveal(id)
    if not cfg() or not S.tilingEnabled or not id then return end
    local _, leaf, key = Tree.findByID(id)
    if not key or not M.enabled(key) then return end
    local view = views[key]
    if not view or not view.leaves then return end
    view.focus = id
    local index
    for i, l in ipairs(view.leaves) do
        if l == leaf then index = i end
    end
    if index then
        local x = M.viewport(view.starts, view.widths, view.total, view.viewW, view.x, index, opt("center"))
        if math.abs(x - view.x) < 1 and not away[id] then return end
    end
    if S.applyingLayout then
        Layout.scheduleRetile(true, true)
    else
        Layout.tileNow(false, Tree.keyUUID(key))
    end
end

-- Whether window `id` is scrolled out of sight (or on its way out).
function M.isAway(id)
    return away[id] ~= nil
end

-- The display a window scrolled out of sight belongs on, whatever its
-- frame says.
function M.awayUUID(id)
    local a = away[id]
    return a and Spaces.uuidForKey(a.key)
end

-- Cycles the focused column through M.WIDTHS.
function M.cycleWidth(win)
    if not win then return end
    local _, leaf, key = Tree.findByID(win:id())
    if not leaf or not M.enabled(key) then return end
    local current = leaf.columnWidth or opt("width")
    local nextWidth = M.WIDTHS[1]
    for _, w in ipairs(M.WIDTHS) do
        if w > current + 0.01 then nextWidth = w break end
    end
    leaf.columnWidth = nextWidth
    Layout.tileNow(false, Tree.keyUUID(key))
end

-- Puts every window scrolled out of sight back on its display, at its
-- column's size, centred (scrolling turned off, quitting).
function M.bringBack(onlyKey)
    for id, a in pairs(away) do
        if not onlyKey or a.key == onlyKey then
            cancelPark(a)
            away[id] = nil
            local win = Util.winByID[id]
            local uuid = Spaces.uuidForKey(a.key)
            local screen = uuid and hs.screen.find(uuid)
            if win and win:id() == id and screen and not Spaces.isHidden(id) then
                local f = screen:frame()
                local w, h = math.min(a.size.w, f.w), math.min(a.size.h, f.h)
                Util.setFrame(win, { x = f.x + (f.w - w) / 2, y = f.y + (f.h - h) / 2, w = w, h = h }, 0)
            end
        end
    end
    if not onlyKey then views = {} else views[onlyKey] = nil end
end

-- Cancels pending parks (reload, shutdown). Windows away stay where they
-- are; the layout after a reload carries on from there.
function M.stop()
    for _, a in pairs(away) do cancelPark(a) end
end

return M
