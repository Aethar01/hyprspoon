-- hyprspoon/restore.lua: Layouts and workspaces back after a restart.

local M = {}
package.loaded["hyprspoon.restore"] = M

local Tree = require("hyprspoon.tree")
local S = require("hyprspoon.state")
local Tabs = require("hyprspoon.tabs")

-- ---------------------------------------------------------------------------
-- Restoring after a restart
-- ---------------------------------------------------------------------------
--
-- Window ids don't survive a restart, so the trees and workspaces saved
-- in the boot before are kept aside for a while (GRACE seconds after the
-- first start, across reloads) and the windows that appear meanwhile are
-- matched to the old ones by app: the same title if one has it, else the
-- oldest unmatched window of that app (apps reopen their windows in
-- order). A matched window goes back to its old workspace, and to its old
-- place in that workspace's layout as its neighbours come back. Windows
-- nobody matches are laid out as usual.

local KEY = "hyprspoon.restore"
local GRACE = 120

-- { boot =, untilTime =, trees = { key -> tree }, windows = { "id" -> {
-- app =, title =, ws = } }, pseudoAway = { "id" -> size }, active = { uuid -> n },
-- claimed = { "old id" -> new id } }, or nil when there's nothing (left) to restore.
local saved = nil

local function persist()
    hs.settings.set(KEY, saved)
end

-- Done: everything matched, or the time's up.
local function finish()
    saved = nil
    persist()
end

do
    local boot = Tree.bootTime
    local pending = hs.settings.get(KEY)
    if type(pending) == "table" and type(pending.boot) == "number" and math.abs(pending.boot - boot) < 120
       and (pending.untilTime or 0) > os.time() then
        -- Reloaded during the grace period.
        saved = pending
        saved.claimed = saved.claimed or {}
    else
        saved = nil
        local treesBoot = hs.settings.get("hyprspoon.treesBoot")
        local ws = hs.settings.get("hyprspoon.workspaces")
        if type(treesBoot) == "number" and math.abs(treesBoot - boot) >= 120
           and type(ws) == "table" and type(ws.info) == "table" and next(ws.info) then
            saved = { boot = boot, untilTime = os.time() + GRACE, windows = {},
                trees = hs.settings.get("hyprspoon.trees") or {},
                pseudoAway = hs.settings.get("hyprspoon.pseudoAway") or {},
                active = ws.active or {}, claimed = {}, nativeFloats = {} }
            local floats = hs.settings.get("hyprspoon.floats") or {}
            for _, leaf in ipairs(hs.settings.get("hyprspoon.setsAway") or {}) do
                local entry = (floats.entries or {})[tostring(leaf.windowID)]
                if leaf.kind == "native" and entry and entry.float then
                    saved.nativeFloats[#saved.nativeFloats + 1] = leaf
                end
            end
            for id, d in pairs(ws.info) do
                if type(d) == "table" and d.app then
                    saved.windows[tostring(id)] = { app = d.app, title = d.title,
                        ws = ws.of and tonumber(ws.of[tostring(id)]) }
                end
            end
        end
        persist()
    end
end

local function live()
    if saved and os.time() > saved.untilTime then finish() end
    return saved ~= nil
end

-- Nothing more is matched (spoon.hyprspoon:rescue() forgot the workspaces).
M.forget = finish

-- The display -> workspace number each display showed before the restart.
function M.savedActive()
    return live() and saved.active or {}
end

-- A window seen for the first time: the workspace it had before the
-- restart if it's one of the old windows (nil if not, or if that had none).
-- `app` is its app's bundle id.
function M.match(win, app)
    if not live() or not app then return nil end
    local best, title = nil, nil
    for old, d in pairs(saved.windows) do
        if d.app == app and not saved.claimed[old] then
            title = title or win:title() or ""
            if d.title and d.title ~= "" and d.title == title then
                best = old
                break
            end
            if not best or tonumber(old) < tonumber(best) then best = old end
        end
    end
    if not best then return nil end
    saved.claimed[best] = win:id()
    for _, oldSet in ipairs(saved.nativeFloats or {}) do
        local members, floating = {}, false
        for _, old in ipairs(oldSet.members) do
            if tostring(old) == best then floating = true end
            local new = saved.claimed[tostring(old)]
            if new then members[#members + 1] = new end
        end
        if floating then
            S.autoFloat = S.autoFloat or {}
            S.autoFloat[win:id()] = true
            -- Real shown windows persist the manual override for reloads;
            -- background identities are plain tables without an application.
            if win.application then require("hyprspoon.float").rememberFloat(win) end
        end
        if floating and #members > 1 then
            local shown = saved.claimed[tostring(oldSet.windowID)] or members[1]
            local leaf = { windowID = shown, members = members, kind = "native", pseudo = oldSet.pseudo }
            for _, id in ipairs(members) do S.setsAway[id] = leaf end
        end
    end
    if saved.pseudoAway and saved.pseudoAway[best] then
        S.pseudoAway[win:id()] = saved.pseudoAway[best]
    end
    local all = true
    for old in pairs(saved.windows) do
        if not saved.claimed[old] then all = false break end
    end
    local ws = saved.windows[best].ws
    -- Kept until the trees have used the matches too.
    if all then saved.untilTime = math.min(saved.untilTime, os.time() + 10) end
    persist()
    return ws
end

-- The tree for workspace `key` (already pruned to the windows in `valid`):
-- when a window that's back from before the restart has just arrived, the
-- old layout with the old ids swapped for the new and the windows not back
-- yet left out, plus whatever else is tiled there now. A tile that held a
-- set holds the members that are back (on show, or hidden in the tree
-- already), showing the one it showed if that's on show.
function M.rebuild(key, tree, valid)
    if not live() or not saved.trees[key] then return tree end
    local present = Tree.collectIDs(tree)
    local arrived = false
    local function newID(old)
        local new = saved.claimed[tostring(old)]
        if new and Tabs.restorePresent(new, valid, present, S.nativeBackground or {}) then return new end
    end
    local function build(node)
        if not node then return nil end
        if node.windowID ~= nil then
            local back, map = {}, {}
            for _, old in ipairs(node.members or { node.windowID }) do
                local new = newID(old)
                if new then back[#back + 1], map[old] = new, new end
            end
            if #back == 0 then return nil end
            for _, new in ipairs(back) do
                if not present[new] then arrived = true end
            end
            local shown = newID(node.windowID)
            if not (shown and valid[shown]) then
                shown = nil
                for _, id in ipairs(back) do
                    if valid[id] then shown = id break end
                end
            end
            local leaf = Tree.leaf(shown or back[1])
            leaf.pseudo = leaf.pseudo or node.pseudo
            if node.members and (#back > 1 or node.kind == "group") then
                leaf.members, leaf.kind = back, node.kind
                for _, list in ipairs(node.tabs or {}) do
                    local tabs = {}
                    for _, old in ipairs(list) do tabs[#tabs + 1] = map[old] end
                    if #tabs > 1 then
                        leaf.tabs = leaf.tabs or {}
                        leaf.tabs[#leaf.tabs + 1] = tabs
                    end
                end
            end
            return leaf
        end
        local a, b = build(node.a), build(node.b)
        if a and b then return { split = node.split, ratio = node.ratio, a = a, b = b } end
        return a or b
    end
    local built = build(saved.trees[key])
    if not arrived or not built then return tree end
    -- The rest go in after, each tile with the windows it holds.
    local inBuilt = Tree.collectIDs(built)
    for _, old in ipairs(Tree.leaves(tree)) do
        local rest = {}
        for _, id in ipairs(old.members or { old.windowID }) do
            if not inBuilt[id] then rest[#rest + 1] = id end
        end
        if #rest > 0 then
            local shown = inBuilt[old.windowID] and rest[1] or old.windowID
            built = (Tree.insertAt(built, Tree.rightmostLeafID(built), shown))
            if old.members and (#rest > 1 or old.kind == "group") then
                local _, leaf = Tree.ancestors(built, shown)
                leaf.members, leaf.kind, leaf.pseudo = rest, old.kind, old.pseudo
                for _, list in ipairs(old.tabs or {}) do
                    local tabs = {}
                    for _, id in ipairs(list) do
                        if not inBuilt[id] then tabs[#tabs + 1] = id end
                    end
                    if #tabs > 1 then
                        leaf.tabs = leaf.tabs or {}
                        leaf.tabs[#leaf.tabs + 1] = tabs
                    end
                end
            end
        end
    end
    return built
end

return M
