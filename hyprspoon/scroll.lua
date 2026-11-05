-- hyprspoon/scroll.lua: EXPERIMENTAL, the prototype for issue #18: niri's
-- scrollable tiling. Windows go in columns side by side on a strip wider
-- than the display, scrolled so the focused column is fully on show. It's
-- here to find out whether scrolling can be smooth with 6+ columns before
-- the layout interface (#15) is built for it; see tests/scroll_bench.lua
-- for the measurement.
--
-- Turned on per workspace with experimental.scrolling (hyprspoon/state.lua).
-- The workspace's BSP tree holds the columns: vertical splits separate
-- columns, left to right, and the tiles under a horizontal split are one
-- column's windows, top to bottom (M.columns reads a tree that way, and
-- M.build writes columns back as one). As in niri:
--   * a new window opens as a column right of the focused one, at
--     `width` (default-column-width);
--   * columns keep their own widths, cycled through `presets` or resized,
--     and a column can be made full width (maximize-column);
--   * a column's windows share its height, unless resized;
--   * focus left/right goes to the next column's window focused last,
--     up/down within the column; swap moves whole columns left and right
--     (move-column-left/right) and windows up and down in their column;
--     move left/right takes a window into the column beside it, or out
--     of its column into a new one (consume-or-expel-window-left/right);
--   * the view scrolls just enough to show the focused column, or centres
--     it (`center`: "never", "always" or "on-overflow"), and is kept
--     relative to the focused column, so columns opening or closing to its
--     left don't move it;
--   * closing a window just opened from another column goes back there, as
--     it was; otherwise the column to its right takes focus (left at the end).
--
-- macOS won't leave a window wholly off its display, so a column scrolled
-- out of sight is parked in the display's corner like a hidden workspace's
-- windows (Spaces.parkPoint). It slides to the display's edge first and
-- comes back in from it, so the scroll looks like one; parked, it's moved
-- at its own size, so scrolling only ever moves windows (one accessibility
-- call each step) and never resizes them. A column partly in view hangs over
-- the edge, unless another display is there.
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
local Focus = lazy("focus")

local DEFAULTS = {
    workspaces = true,              -- true for all, or a list such as { 3, "A" }
    width = 0.5,                    -- a new column's share of the area (default-column-width)
    presets = { 1 / 3, 1 / 2, 2 / 3 }, -- what cycleColumnWidth goes through (preset-column-widths)
    fill = false,                   -- columns of `width` share the area while they fit
    duration = 0.2,                 -- seconds a scroll takes; 0 snaps
    center = "never",               -- "never", "always" (or true) or "on-overflow"
}

-- Tree key -> { x = scroll offset in points, focusID = the window focused
-- last, pointer = it, if focus follows mouse focused it, active = the window the view was kept by last time and rel, the
-- offset from its column's start, openedFrom = { id, back, rel } while a
-- window just opened beside `back` is focused; and from the last layout:
-- cols, starts, widths, viewW, areaH, known = { [window id] = true } }.
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
-- Columns in the tree (no Hammerspoon calls; see tests/scroll_test.lua)
-- ---------------------------------------------------------------------------

local function isLeaf(node)
    return node ~= nil and node.windowID ~= nil
end

local function leavesOf(node, out)
    if not node then return out end
    if isLeaf(node) then
        out[#out + 1] = node
    else
        leavesOf(node.a, out)
        leavesOf(node.b, out)
    end
    return out
end

local function hasVertical(node)
    if not node or isLeaf(node) then return false end
    return node.split == "vertical" or hasVertical(node.a) or hasVertical(node.b)
end

-- A tree's columns, left to right: lists of leaves, top to bottom, with
-- the column's `width` (its own share, or nil) and `full` (full width).
-- Vertical splits separate columns; a part of the tree with none is one
-- column.
function M.columns(tree)
    local cols = {}
    local function walk(node)
        if not node then return end
        if isLeaf(node) or not hasVertical(node) then
            local col = leavesOf(node, {})
            col.width, col.full = col[1].columnWidth, col[1].fullWidth
            cols[#cols + 1] = col
            return
        end
        walk(node.a)
        walk(node.b)
    end
    walk(tree)
    return cols
end

-- Columns as a tree: each column a chain of horizontal splits, the columns
-- a chain of vertical ones, all even (so turning scrolling off leaves
-- equal tiles). Every leaf takes its column's width.
function M.build(cols)
    local function chain(items, split, i)
        if i == #items then return items[i] end
        return { split = split, ratio = 1 / (#items - i + 1), a = items[i], b = chain(items, split, i + 1) }
    end
    local nodes = {}
    for _, col in ipairs(cols) do
        if #col > 0 then
            for _, leaf in ipairs(col) do
                leaf.columnWidth, leaf.fullWidth = col.width, col.full or nil
            end
            nodes[#nodes + 1] = chain(col, "horizontal", 1)
        end
    end
    if #nodes == 0 then return nil end
    return chain(nodes, "vertical", 1)
end

local function leafHas(leaf, id)
    if leaf.windowID == id then return true end
    for _, m in ipairs(leaf.members or {}) do
        if m == id then return true end
    end
    return false
end

-- The column and place in it of the leaf holding window `id` (or of `id`
-- itself, a leaf).
local function locate(cols, id)
    for ci, col in ipairs(cols) do
        for wi, leaf in ipairs(col) do
            if leaf == id or (type(id) ~= "table" and leafHas(leaf, id)) then return ci, wi end
        end
    end
end
M.locate = locate

-- Tree `tree` with window `newID` in a new leaf beside target's: as a
-- column right of its column (or left), or above or below it in its column
-- ("top", "bottom"). The new column has the default width.
function M.insert(tree, targetID, newID, side)
    local cols = M.columns(tree)
    local ci, wi = locate(cols, targetID)
    if not ci then return tree, false end
    local leaf = Tree.leaf(newID)
    leaf.windowHeight = nil
    if side == "top" or side == "bottom" then
        local col = cols[ci]
        table.insert(col, side == "top" and wi or wi + 1, leaf)
    else
        table.insert(cols, side == "left" and ci or ci + 1, { leaf })
    end
    return M.build(cols), true
end

-- ---------------------------------------------------------------------------
-- The geometry (no Hammerspoon calls; see tests/scroll_test.lua)
-- ---------------------------------------------------------------------------

-- A share `p` of an area `areaW` wide as a column's width, counting the
-- gaps like niri: columns of a half (a third...) fit it exactly.
function M.px(p, areaW, gap)
    return math.max(1, math.floor((areaW + gap) * p - gap + 0.5))
end

function M.share(w, areaW, gap)
    return (w + gap) / (areaW + gap)
end

-- Columns' widths in points, from their own shares (`own[i]`, nil for
-- one that has none and takes `base`). With `fill`, while there are no
-- more columns than fit at `base`, those without a share of their own
-- share what the others leave, if that's at least `least` points each.
function M.widths(own, n, base, areaW, gap, fill, least)
    local widths, autos, used = {}, {}, (n - 1) * gap
    for i = 1, n do
        widths[i] = M.px(own[i] or base, areaW, gap)
        if own[i] then used = used + widths[i] else autos[#autos + 1] = i end
    end
    local few = n <= math.floor((areaW + gap) / (M.px(base, areaW, gap) + gap) + 1e-9)
    if fill and few and #autos > 0 then
        local each = math.floor((areaW - used) / #autos)
        if each >= (least or 1) then
            for _, i in ipairs(autos) do widths[i] = each end
            -- Rounding left over goes to the last, so they fit exactly.
            local last = autos[#autos]
            widths[last] = widths[last] + (areaW - used - each * #autos)
        end
    end
    return widths
end

-- A column's windows' heights in points, from their own shares of the
-- column (`own[i]`, nil to share what's left evenly, as niri's auto
-- height), `n` of them in `areaH` with gaps. Windows with no share of
-- their own get at least `least` each; with none, the rest scale to fill.
function M.heights(own, n, areaH, gap, least)
    least = least or 1
    local avail = areaH - (n - 1) * gap
    local hs, autos, used = {}, {}, 0
    for i = 1, n do
        if own[i] then
            hs[i] = M.px(own[i], areaH, gap)
            used = used + hs[i]
        else
            autos[#autos + 1] = i
        end
    end
    local room = avail - least * #autos
    if used > 0 and (#autos == 0 or used > room) then
        local scale = math.max(0, #autos == 0 and avail or room) / used
        used = 0
        for i = 1, n do
            if hs[i] then
                hs[i] = math.max(1, math.floor(hs[i] * scale))
                used = used + hs[i]
            end
        end
    end
    if #autos > 0 then
        local each = math.max(1, math.floor((avail - used) / #autos))
        for _, i in ipairs(autos) do hs[i] = each end
        used = used + each * #autos
    end
    hs[n] = hs[n] + (avail - used)
    return hs
end

-- Each column's start along the strip, and the strip's length.
function M.strip(widths, gap)
    local starts, x = {}, 0
    for i, w in ipairs(widths) do
        starts[i] = x
        x = x + w + (i < #widths and gap or 0)
    end
    return starts, x
end

-- The scroll offset that shows column `index` from `x`, the way niri does:
-- with `center` "always" (or true) it's centred; "on-overflow" centres it
-- only when it and its neighbour towards the column focused before
-- (`prev`) don't fit the view together; otherwise ("never") the view
-- moves as little as it can to show all of it, and not at all if it's
-- already on show. A column wider than the view shows its start.
function M.viewport(starts, widths, viewW, x, index, center, prev)
    if not (index and starts[index]) then return x end
    local s, w = starts[index], widths[index]
    local mode = center == true and "always" or center or "never"
    if mode == "on-overflow" then
        mode = "never"
        if prev and prev ~= index and starts[prev] then
            local src = prev > index and index + 1 or index - 1
            local lo = math.min(s, starts[src])
            local hi = math.max(s + w, starts[src] + widths[src])
            if hi - lo > viewW then mode = "always" end
        end
    end
    if mode == "always" then return math.floor(s + w / 2 - viewW / 2 + 0.5) end
    if s >= x - 1 and s + w <= x + viewW + 1 then return x end
    if w >= viewW then return s end
    if math.abs(x - s) <= math.abs((x + viewW) - (s + w)) then return s end
    return s + w - viewW
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
-- no display beyond), or the side it's away on, "left" or "right". Only a
-- column reaching into the tiling area `area` (default `sf`) hangs: one
-- just into the outer gap would be a sliver at the edge (full-width
-- columns' neighbours are).
function M.classify(rect, sf, others, area)
    area = area or sf
    local right = rect.x + rect.w
    if rect.x >= sf.x - 1 and right <= sf.x + sf.w + 1 then return "show" end
    if right > area.x and rect.x < area.x + area.w and not overlapsAny(rect, others) then
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

-- Window `id`, at `rect` on the strip, scrolled out of sight on `side`.
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

-- The window of column `col` focused last (niri's active window in a
-- column), else its first. With `valid`, only windows in it.
local function activeIn(col, valid)
    for _, id in ipairs(Util.focusHistory) do
        for _, leaf in ipairs(col) do
            if leafHas(leaf, id) and (not valid or valid[leaf.windowID]) then return leaf end
        end
    end
    for _, leaf in ipairs(col) do
        if not valid or valid[leaf.windowID] then return leaf end
    end
end

-- The column to show and the window focused in it: a window new to the
-- layout that macOS has focused (it may be focused before it's in the tree,
-- or laid out before macOS says so), else the one focused last here.
local function focusOf(cols, view, fresh)
    if fresh then
        local win = Util.focusedWindow()
        local id = win and win:id()
        local ci = id and fresh[id] and locate(cols, id)
        if ci then return ci, id end
    end
    local ci = view.focusID and locate(cols, view.focusID)
    if ci then return ci, view.focusID end
    for _, id in ipairs(Util.focusHistory) do
        ci = locate(cols, id)
        if ci then return ci, id end
    end
end

-- Where the view goes with window `focusID` (column `ci`) focused: kept
-- where it was relative to the column it was kept by last time, or for a
-- window just opened that closed, back as it was before; then scrolled to
-- show column `ci`. Also returns what to keep the view by next time.
local function placeView(view, cols, starts, widths, viewW, ci)
    local x = view.x or 0
    local prev = view.active and locate(cols, view.active)
    local r = view.restore
    if r and r.rel and ci and locate({ cols[ci] }, r.back) then
        x = starts[ci] + r.rel
    elseif prev and view.rel then
        x = starts[prev] + view.rel
    end
    -- Focus follows mouse only scrolls as far as it must, centred or not:
    -- centring would move the window from under the pointer.
    local center = opt("center")
    if view.pointer and view.pointer == view.focusID then center = "never" end
    if ci then x = M.viewport(starts, widths, viewW, x, ci, center, prev) end
    return x, prev
end

-- Lays tree `key` out in columns within `area` on `screen`, in place of
-- Layout.applyTree. `byID` and `full` are as applyTree's.
function M.arrange(key, tree, area, screen, byID, full)
    local cols = M.columns(tree)
    local view = views[key] or { x = 0 }
    views[key] = view

    local gap = S.cfg.tiling.innerGap
    local own = {}
    for i, col in ipairs(cols) do own[i] = col.full and 1 or col.width end
    local widths = M.widths(own, #cols, opt("width"), area.w, gap, opt("fill"), S.cfg.minWidth)
    local starts = M.strip(widths, gap)

    local known, fresh = {}, nil
    for _, col in ipairs(cols) do
        for _, leaf in ipairs(col) do
            local id = leaf.windowID
            known[id] = true
            if not (view.known or {})[id] then
                fresh = fresh or {}
                fresh[id] = true
            end
        end
    end
    local ci, focusID = focusOf(cols, view, fresh)
    local x, prev = placeView(view, cols, starts, widths, area.w, ci)
    -- A window opened from the column focused before, focused in a new
    -- column: closing it goes back there (activate_prev_column_on_removal).
    if focusID and fresh and fresh[focusID] and prev and ci == prev + 1 and #cols[ci] == 1 then
        view.openedFrom = { id = focusID, back = view.active, rel = view.rel }
    elseif view.openedFrom and focusID ~= view.openedFrom.id then
        view.openedFrom = nil
    end
    local r = view.restore
    if r and (not locate(cols, r.gone) or not (ci and locate({ cols[ci] }, r.back))) then
        view.restore = nil
    end
    view.x = x
    view.focusID, view.active = focusID, focusID
    view.rel = ci and x - starts[ci] or nil
    view.cols, view.starts, view.widths, view.viewW, view.areaH = cols, starts, widths, area.w, area.h
    view.known = known

    local sf = screen:fullFrame()
    local others = {}
    for _, s in ipairs(hs.screen.allScreens()) do
        if s:getUUID() ~= screen:getUUID() then others[#others + 1] = s:fullFrame() end
    end
    local duration = (S.instantLayout or S.dragState) and 0 or opt("duration")
    -- Every step of a scroll fires windowMoved too.
    settle(duration)

    local least = S.cfg.minHeight
    local seen, came = {}, false
    for i, col in ipairs(cols) do
        local colRect = hs.geometry.rect(area.x + starts[i] - x, area.y, widths[i], area.h)
        local where = M.classify(colRect, sf, others, area)
        local heights = M.heights((function()
            local t = {}
            for j, leaf in ipairs(col) do t[j] = #col > 1 and leaf.windowHeight or nil end
            return t
        end)(), #col, area.h, gap, least)
        local y = area.y
        for j, leaf in ipairs(col) do
            local id = leaf.windowID
            seen[id] = true
            local rect = hs.geometry.rect(colRect.x, y, colRect.w, heights[j])
            y = y + heights[j] + gap
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

local function retile(key)
    if S.applyingLayout then
        Layout.scheduleRetile(true, true)
    else
        Layout.tileNow(false, Tree.keyUUID(key))
    end
end

-- ---------------------------------------------------------------------------
-- Following focus
-- ---------------------------------------------------------------------------

-- Focus went to `id`: scroll its column into view.
function M.reveal(id)
    if not cfg() or not S.tilingEnabled or not id then return end
    local _, _, key = Tree.findByID(id)
    if not key or not M.enabled(key) then return end
    local view = views[key]
    if not view or not view.cols then return end
    view.focusID = id
    local f = S.ffmFocus
    view.pointer = f and f.id == id and hs.timer.secondsSinceEpoch() - f.time < 2 and id or nil
    local ci = locate(view.cols, id)
    if ci then
        local x = placeView(view, view.cols, view.starts, view.widths, view.viewW, ci)
        if math.abs(x - view.x) < 1 and not away[id] then
            view.active, view.rel = id, x - view.starts[ci]
            if view.openedFrom and view.openedFrom.id ~= id then view.openedFrom = nil end
            return
        end
    end
    retile(key)
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

-- Window `goneID`, focused, is closing (or leaving) workspace `key`, whose
-- tree was `tree`: the window to focus instead, of those in `valid`. The
-- one it was opened from, if it was just opened in a column of its own
-- (and the view goes back as it was then); else the next window in its
-- column; else the column to its right; else the one to its left.
function M.afterClose(key, tree, goneID, valid)
    if not M.enabled(key) then return nil end
    local cols = M.columns(tree)
    local ci, wi = locate(cols, goneID)
    if not ci then return nil end
    local view = views[key] or {}
    local o = view.openedFrom
    local pick
    if o and o.id == goneID and valid[o.back] then
        pick = o.back
        view.restore = { back = o.back, rel = o.rel, gone = goneID }
    else
        local col = cols[ci]
        for _, leaf in ipairs({ col[wi + 1] or false, col[wi - 1] or false }) do
            if leaf and valid[leaf.windowID] then pick = leaf.windowID break end
        end
        for _, c in ipairs({ cols[ci + 1] or false, cols[ci - 1] or false }) do
            local leaf = not pick and c and activeIn(c, valid)
            if leaf then pick = leaf.windowID end
        end
    end
    view.openedFrom = nil
    if pick and views[key] then view.focusID = pick end
    return pick
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

-- The focused window's workspace, columns, column and place in it, and leaf,
-- if it's a tile of a workspace laid out in columns.
local function context(win)
    if not win or not cfg() or not S.tilingEnabled then return nil end
    local id = win:id()
    local _, leaf, key = Tree.findByID(id)
    if not leaf or not M.enabled(key) then return nil end
    local cols = M.columns(S.trees[key])
    local ci, wi = locate(cols, leaf)
    if not ci then return nil end
    return key, cols, ci, wi, leaf
end

-- The columns `cols` become workspace `key`'s tree.
local function commit(key, cols)
    S.trees[key] = M.build(cols)
    S.keyIndex = {}
    Tree.saveTrees()
    Layout.tileNow(false, Tree.keyUUID(key))
end

local function focusLeaf(key, leaf)
    local win = leaf and Util.winByID[leaf.windowID]
    if not win then return false end
    local view = views[key]
    if view then view.focusID = leaf.windowID end
    Layout.tileNow(false, Tree.keyUUID(key))
    Focus.focus(win)
    Util.warpToWindow(win)
    return true
end

local STEP = { left = -1, up = -1, right = 1, down = 1 }

-- focus(direction): left and right go to the column beside the focused
-- one, to its window focused last (focus-column-left/right); up and down
-- to the window above or below in the column (focus-window-up/down).
-- False when there's none that way.
function M.focus(win, direction)
    local key, cols, ci, wi = context(win)
    if not key then return false end
    local d = STEP[direction]
    if direction == "left" or direction == "right" then
        return cols[ci + d] ~= nil and focusLeaf(key, activeIn(cols[ci + d]))
    end
    return cols[ci][wi + d] ~= nil and focusLeaf(key, cols[ci][wi + d])
end

-- Moves the window up or down its column (move-window-up/down).
local function moveInColumn(win, key, cols, ci, wi, d)
    local col = cols[ci]
    if not col[wi + d] then return false end
    col[wi], col[wi + d] = col[wi + d], col[wi]
    commit(key, cols)
    Focus.focus(win)
    return true
end

-- move(direction): left and right move the focused column past the one
-- beside it (move-column-left/right), up and down the window within its
-- column (move-window-up/down). False when there's none that way.
function M.move(win, direction)
    local key, cols, ci, wi = context(win)
    if not key then return false end
    local d = STEP[direction]
    if direction == "up" or direction == "down" then return moveInColumn(win, key, cols, ci, wi, d) end
    if not cols[ci + d] then return false end
    cols[ci], cols[ci + d] = cols[ci + d], cols[ci]
    commit(key, cols)
    Focus.focus(win)
    Util.warpToWindow(win)
    return true
end

-- swap(direction): left and right swap the window with the column
-- beside it's window focused last, the columns keeping their widths
-- (swap-window-left/right); up and down are as move.
function M.swap(win, direction)
    local key, cols, ci, wi, leaf = context(win)
    if not key then return false end
    local d = STEP[direction]
    if direction == "up" or direction == "down" then return moveInColumn(win, key, cols, ci, wi, d) end
    local other = cols[ci + d]
    if not other then return false end
    local _, owi = locate({ other }, activeIn(other))
    cols[ci][wi], other[owi] = other[owi], leaf
    leaf.windowHeight, cols[ci][wi].windowHeight = nil, nil
    commit(key, cols)
    Focus.focus(win)
    Util.warpToWindow(win)
    return true
end

-- Takes the window into the column `direction` ("left" or "right"), at its
-- bottom, or when it shares its column, out into a new column of its own
-- that way, as wide as the one it left (consume-or-expel-window-left/right).
function M.consumeOrExpel(win, direction)
    local key, cols, ci, wi, leaf = context(win)
    if not key then return false end
    local col = cols[ci]
    leaf.windowHeight = nil
    if #col > 1 then
        table.remove(col, wi)
        table.insert(cols, direction == "left" and ci or ci + 1, { leaf, width = col.width, full = col.full })
    else
        local target = cols[ci + STEP[direction]]
        if not target then return false end
        target[#target + 1] = leaf
        table.remove(cols, ci)
    end
    commit(key, cols)
    Focus.focus(win)
    Util.warpToWindow(win)
    return true
end

-- The first window of the column to the right joins the focused column,
-- at its bottom (consume-window-into-column).
function M.consume(win)
    local key, cols, ci = context(win)
    local nextCol = key and cols[ci + 1]
    if not nextCol then return end
    local leaf = table.remove(nextCol, 1)
    leaf.windowHeight = nil
    table.insert(cols[ci], leaf)
    if #nextCol == 0 then table.remove(cols, ci + 1) end
    commit(key, cols)
end

-- The focused window leaves its column for a new one to its right, as
-- wide (expel-window-from-column).
function M.expel(win)
    local key, cols, ci, wi, leaf = context(win)
    if not key or #cols[ci] < 2 then return end
    table.remove(cols[ci], wi)
    leaf.windowHeight = nil
    table.insert(cols, ci + 1, { leaf, width = cols[ci].width, full = cols[ci].full })
    commit(key, cols)
    Focus.focus(win)
end

-- The first or last column takes focus (focus-column-first/last).
function M.focusEnd(win, last)
    local key, cols = context(win)
    if not key then return end
    focusLeaf(key, activeIn(cols[last and #cols or 1]))
end

-- The focused column goes first or last (move-column-to-first/last).
function M.moveToEnd(win, last)
    local key, cols, ci = context(win)
    if not key then return end
    local col = table.remove(cols, ci)
    table.insert(cols, last and #cols + 1 or 1, col)
    commit(key, cols)
    Focus.focus(win)
end

-- Centres the focused column in the view (center-column).
function M.center(win)
    local key, _, _, _, leaf = context(win)
    local view = key and views[key]
    local ci = view and view.cols and locate(view.cols, leaf)
    if not ci then return end
    view.x = math.floor(view.starts[ci] + view.widths[ci] / 2 - view.viewW / 2 + 0.5)
    view.active, view.rel = leaf.windowID, view.x - view.starts[ci]
    Layout.tileNow(false, Tree.keyUUID(key))
end

-- Sets column `col` of workspace `key` to share `p` of the area (clamped to
-- minWidth and the whole area), not full width, and lays it out again.
local function setWidth(key, col, p)
    local view = views[key]
    if not view then return end
    local gap = S.cfg.tiling.innerGap
    local least = math.min(1, M.share(S.cfg.minWidth, view.viewW, gap))
    p = math.max(least, math.min(1, p))
    for _, leaf in ipairs(col) do leaf.columnWidth, leaf.fullWidth = p, nil end
    Tree.saveTrees()
    Layout.tileNow(false, Tree.keyUUID(key))
end

-- The share of the area column `ci` of workspace `key` has now (filled,
-- full width or not), or nil before it's been laid out.
local function shareNow(key, leaf)
    local view = views[key]
    local ci = view and view.cols and locate(view.cols, leaf)
    if not ci then return nil end
    return M.share(view.widths[ci], view.viewW, S.cfg.tiling.innerGap)
end

-- The focused column's width to the next of `presets`, or with `back` the
-- one before, wrapping round (switch-preset-column-width[-back]).
function M.cycleWidth(win, back)
    local key, cols, ci, _, leaf = context(win)
    if not key then return end
    local current = shareNow(key, leaf) or cols[ci].width or opt("width")
    local presets = opt("presets")
    local pick = back and presets[#presets] or presets[1]
    if back then
        for i = #presets, 1, -1 do
            if presets[i] < current - 0.01 then pick = presets[i] break end
        end
    else
        for _, p in ipairs(presets) do
            if p > current + 0.01 then pick = p break end
        end
    end
    setWidth(key, cols[ci], pick)
end

-- The focused column fills the area, or goes back to its width
-- (maximize-column). False if the window isn't in a column.
function M.toggleFullWidth(win)
    local key, cols, ci = context(win)
    if not key then return false end
    local full = not cols[ci].full
    for _, leaf in ipairs(cols[ci]) do leaf.fullWidth = full or nil end
    Tree.saveTrees()
    Layout.tileNow(false, Tree.keyUUID(key))
    return true
end

-- The focused column takes the width the other columns wholly in view
-- leave (expand-column-to-available-width), and they stay in view.
function M.expand(win)
    local key, _, _, _, leaf = context(win)
    local view = key and views[key]
    local ci = view and view.cols and locate(view.cols, leaf)
    if not ci then return end
    local gap = S.cfg.tiling.innerGap
    local used, first = 0, ci
    for j, s in ipairs(view.starts) do
        local w = view.widths[j]
        if j ~= ci and s >= view.x - 1 and s + w <= view.x + view.viewW + 1 then
            used = used + w + gap
            if j < first then first = j end
        end
    end
    local w = view.viewW - used
    if w <= view.widths[ci] then return end
    view.active, view.rel = leaf.windowID, view.starts[first] - view.starts[ci]
    setWidth(key, view.cols[ci], M.share(w, view.viewW, gap))
end

-- Keyboard resize: column `leaf` of workspace `key` grows by `xPct` percent
-- of the area's width, and its window by `yPct` percent of the column's
-- height if it shares the column (niri's set-column-width "+10%" and
-- set-window-height "+10%"). Shrinks if negative.
function M.resize(leaf, key, xPct, yPct)
    local view = views[key]
    if not (view and view.cols) then return end
    local ci, wi = locate(view.cols, leaf)
    if not ci then return end
    local col = view.cols[ci]
    if yPct and yPct ~= 0 and #col > 1 and leaf.rect then
        local gap = S.cfg.tiling.innerGap
        local now = M.share(leaf.rect.h, view.areaH, gap)
        local least = math.min(1, M.share(S.cfg.minHeight, view.areaH, gap))
        col[wi].windowHeight = math.max(least, math.min(1, now + yPct / 100))
        if not xPct or xPct == 0 then
            Tree.saveTrees()
            Layout.tileNow(false, Tree.keyUUID(key))
        end
    end
    if xPct and xPct ~= 0 then
        setWidth(key, col, (shareNow(key, leaf) or opt("width")) + xPct / 100)
    end
end

-- A column's window was resized by its edges or a modifier-drag to `frame`:
-- its new width becomes the column's own, and its new height its own if
-- it shares the column. False if neither changed (a move, which snaps back).
function M.adopt(leaf, key, frame)
    local view = views[key]
    if not (view and view.cols) then return false end
    local ci, wi = locate(view.cols, leaf)
    if not ci then return false end
    local gap = S.cfg.tiling.innerGap
    local col = view.cols[ci]
    local wide = math.abs(frame.w - view.widths[ci]) > 4
    local tall = #col > 1 and leaf.rect and math.abs(frame.h - leaf.rect.h) > 4
    if not wide and not tall then return false end
    if tall then
        local least = math.min(1, M.share(S.cfg.minHeight, view.areaH, gap))
        col[wi].windowHeight = math.max(least, math.min(1, M.share(frame.h, view.areaH, gap)))
    end
    if wide then
        setWidth(key, col, M.share(frame.w, view.viewW, gap))
    else
        Tree.saveTrees()
        Layout.tileNow(false, Tree.keyUUID(key))
    end
    return true
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
