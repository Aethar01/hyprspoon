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

-- Fallback without the Space query: the app list suppresses absorbed
-- windows even when their stale frames differ. If the list is empty, use
-- the old frame guess and prefer a tiled window, then the oldest id.
-- `windows` holds { id, pid, tiled, inTree }; frameOf and listedIDs are
-- supplied by Discover so this module stays independent of Hammerspoon.
function M.background(windows, frameOf, listedIDs)
    local perPid = {}
    for _, win in ipairs(windows) do
        perPid[win.pid] = perPid[win.pid] or {}
        table.insert(perPid[win.pid], win)
    end

    local background = {}
    for pid, wins in pairs(perPid) do
        if #wins >= 2 then
            local groups = {}
            for _, win in ipairs(wins) do
                local gk = frameKey(frameOf(win))
                groups[gk] = groups[gk] or {}
                table.insert(groups[gk], win)
            end

            local listed = listedIDs(pid)
            -- An absorbed window keeps its stale frame after Merge All
            -- Windows. The app list takes precedence whenever it has caught up.
            if next(listed) then
                for _, win in ipairs(wins) do
                    if not listed[win.id] then background[win.id] = true end
                end
            end
            for _, group in pairs(groups) do
                if #group >= 2 then
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

-- Only standard windows, either seen before or verified through AX, may
-- enter a set. Helper windows also have no Space.
function M.detect(states, standard)
    local out = {}
    for id, state in pairs(states or {}) do
        if state == "tab" and standard[id] then out[id] = true end
    end
    return out
end

-- Assign background windows to bars with spare places. Existing membership
-- wins; a switch's tile gives the next clue, then an unambiguous title,
-- finally a single remaining bar (Merge All Windows). Ambiguity is left
-- alone rather than combining independent tab sets.
function M.assign(background, shown, ownerOf)
    local assigned, used, capacity = {}, {}, {}
    for _, w in ipairs(shown) do used[w.id], capacity[w.id] = 1, w.count or 1 end
    for id in pairs(background) do
        local owner = ownerOf(id)
        if owner and used[owner.windowID] and used[owner.windowID] < capacity[owner.windowID] then
            assigned[id] = owner.windowID
            used[owner.windowID] = used[owner.windowID] + 1
        end
    end
    local ids = {}
    for id in pairs(background) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        if not assigned[id] then
            local owner, best, score, tied = ownerOf(id), nil, -1, false
            for _, w in ipairs(shown) do
                if used[w.id] < (w.count or 1) then
                    local rank = 0
                    if owner and owner.rect and centredIn(w.frame, owner.rect) then rank = 2 end
                    for _, title in ipairs(w.titles or {}) do
                        if title ~= "" and title == background[id].title then rank = math.max(rank, 1) end
                    end
                    if rank > score then best, score, tied = w.id, rank, false
                    elseif rank == score then tied = true end
                end
            end
            if best and not tied then
                assigned[id], used[best] = best, used[best] + 1
            end
        end
    end
    return assigned
end

-- Two members listed on screen are separate native windows after tear-off.
function M.strays(members, shown, visible)
    local out = {}
    for _, id in ipairs(members) do
        if id ~= shown and visible[id] then out[#out + 1] = id end
    end
    return out
end

-- Restart matching also accepts verified background windows, which never
-- appear in the normal app window list.
function M.restorePresent(id, valid, present, background)
    return valid[id] or present[id] or background[id]
end

M.centredIn = centredIn

return M
