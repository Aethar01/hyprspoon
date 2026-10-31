-- hyprspoon/tabs.lua: Deciding which windows are native tabs, from plain data.
--
-- Pure functions over plain window tables ({ id =, pid =, ... }): no
-- Hammerspoon, no tree lookups, so the rules can be tested on their own.
-- Discover and Layout gather the facts and call these.

local M = {}
package.loaded["hyprspoon.tabs"] = M

-- Where two windows sit is compared rounded to whole pixels.
local function frameKey(f)
    return string.format("%d,%d,%d,%d",
        math.floor(f.x + 0.5), math.floor(f.y + 0.5),
        math.floor(f.w + 0.5), math.floor(f.h + 0.5))
end

-- Whether the centre of `frame` lies inside `rect`: how a window that has
-- taken over a tile is recognised.
local function centredIn(frame, rect)
    local x, y = frame.x + frame.w / 2, frame.y + frame.h / 2
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end

-- Native tabs: the filter reports every tab of a tabbed window as a window,
-- all "visible" and at the same frame, but only one is the live tab. Separate
-- windows can also open at identical frames (e.g. Ghostty), so keep every
-- window the app itself lists and only suppress unlisted duplicates. If none
-- are listed yet, prefer the one already tiled, else the oldest.
-- A window alone at its frame is always
-- live: the app's own list can lag behind events (e.g. right after the
-- selected tab closes), so it's only used to choose within a group.
--
-- `windows` is a list of { id =, pid =, tiled = (holds a tile of its own),
-- inTree = (is in a tree at all) }. `frameOf(window)` and `listedIDs(pid)`
-- (the ids the app lists, as a set) are accessibility calls, so they're only
-- made when a decision needs them. Returns the ids of the background tabs as
-- a set.
function M.background(windows, frameOf, listedIDs)
    local perPid = {}
    for _, win in ipairs(windows) do
        perPid[win.pid] = perPid[win.pid] or {}
        table.insert(perPid[win.pid], win)
    end

    local background = {}
    for pid, wins in pairs(perPid) do
        -- Tiles never share a frame, so if every window of the app already
        -- holds its own tile there are no background tabs to find (and no
        -- reason to ask the app for frames).
        local allTiled = #wins >= 2
        for _, win in ipairs(wins) do
            if not win.tiled then allTiled = false break end
        end
        if #wins >= 2 and not allTiled then
            local groups = {}
            for _, win in ipairs(wins) do
                local gk = frameKey(frameOf(win))
                groups[gk] = groups[gk] or {}
                table.insert(groups[gk], win)
            end

            local listed = nil
            for _, group in pairs(groups) do
                if #group >= 2 then
                    listed = listed or listedIDs(pid)
                    local function rank(win)
                        return (listed[win.id] and 0 or 2) + (win.inTree and 0 or 1), win.id
                    end
                    table.sort(group, function(a, b)
                        local ra, ia = rank(a)
                        local rb, ib = rank(b)
                        if ra ~= rb then return ra < rb end
                        return ia < ib
                    end)
                    for i = 2, #group do
                        local id = group[i].id
                        if not listed[id] then background[id] = true end
                    end
                end
            end
        end
    end
    return background
end

-- Switching, opening or closing a native tab swaps which window id is the
-- live one, in the same place. When a tiled window `oldPid` has vanished, the
-- window that took over its tile (`rect`) is the first of `candidates` (a
-- list of { id =, pid = }: the present windows and the background tabs) that
-- is of the same app, isn't one the tree already knew (`known`, a set of ids
-- the caller updates after each handoff) and is centred inside the tile.
-- `frameOf(candidate)` is only asked for those of the same app, and
-- `visit(candidate, frame)`, if given, is told of each one looked at.
-- Returns the successor, or nil.
function M.successor(oldPid, rect, candidates, known, frameOf, visit)
    for _, c in ipairs(candidates) do
        if not known[c.id] and c.pid == oldPid then
            local f = frameOf(c)
            if visit then visit(c, f) end
            if centredIn(f, rect) then return c end
        end
    end
end

M.centredIn = centredIn

return M
