-- hyprspoon/restore.lua: Layouts and workspaces back after a restart.

local M = {}
package.loaded["hyprspoon.restore"] = M

local Tree = require("hyprspoon.tree")

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
-- app =, title =, ws = } }, active = { uuid -> n }, claimed = { "old id"
-- -> new id } }, or nil when there's nothing (left) to restore.
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
            saved = { boot = boot, untilTime = os.time() + GRACE, trees = {}, windows = {},
                active = ws.active or {}, home = ws.home or {}, claimed = {} }
            for key, tree in pairs(hs.settings.get("hyprspoon.trees") or {}) do
                if type(key) == "string" and key:match("^ws%d+$") then saved.trees[key] = tree end
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

-- The display -> workspace number each display showed before the restart.
function M.savedActive()
    return live() and saved.active or {}
end

-- The display workspace `n` lived on before the restart, if known.
function M.savedHome(n)
    return live() and saved.home and saved.home[tostring(n)] or nil
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
-- yet left out, plus whatever else is tiled there now.
function M.rebuild(key, tree, valid)
    if not live() or not saved.trees[key] then return tree end
    local present = Tree.collectIDs(tree)
    local arrived = false
    local function build(node)
        if not node then return nil end
        if node.windowID ~= nil then
            local new = saved.claimed[tostring(node.windowID)]
            if not new or not valid[new] then return nil end
            if not present[new] then arrived = true end
            return Tree.leaf(new)
        end
        local a, b = build(node.a), build(node.b)
        if a and b then return { split = node.split, ratio = node.ratio, a = a, b = b } end
        return a or b
    end
    local built = build(saved.trees[key])
    if not arrived or not built then return tree end
    local inBuilt = Tree.collectIDs(built)
    for id in pairs(present) do
        if not inBuilt[id] then built = (Tree.insertAt(built, Tree.rightmostLeafID(built), id)) end
    end
    return built
end

return M
