-- hyprspoon/group.lua: Groups share a tile; only the selected member is on screen.
local M = {}
package.loaded["hyprspoon.group"] = M

local S = require("hyprspoon.state")
local Tree = require("hyprspoon.tree")
local Util = require("hyprspoon.util")
local Spaces = require("hyprspoon.spaces")
local Layout = require("hyprspoon.layout")
local Focus = require("hyprspoon.focus")

-- Native tabs travel together when joining, leaving, or dissolving a group.
local function units(leaf)
    local out, seen = {}, {}
    for _, id in ipairs(leaf.members or { leaf.windowID }) do
        if not seen[id] then
            local list = Tree.tabsOf(leaf, id) or { id }
            local copy = {}
            for _, m in ipairs(list) do copy[#copy + 1], seen[m] = m, true end
            out[#out + 1] = copy
        end
    end
    return out
end

-- Key by the unit list so membership changes cannot reuse another unit's choice.
local lastShown = setmetatable({}, { __mode = "k" })
local function remember(leaf, id)
    local tabs = Tree.tabsOf(leaf, id)
    if tabs then lastShown[tabs] = id end
end

local function preferred(leaf, id)
    local tabs = Tree.tabsOf(leaf, id)
    if not tabs then return id end
    local onScreen = {}
    for _, win in ipairs(hs.window.list(true) or {}) do onScreen[win.kCGWindowNumber] = true end
    for _, tab in ipairs(tabs) do
        if onScreen[tab] then lastShown[tabs] = tab return tab end
    end
    local saved = lastShown[tabs]
    for _, tab in ipairs(tabs) do
        if tab == saved and Util.windowFor(tab) then return tab end
    end
    return id
end

local function sameUnit(leaf, a, b)
    for _, id in ipairs(Tree.tabsOf(leaf, a) or { a }) do
        if id == b then return true end
    end
    return false
end

local function hide(leaf, key, strays)
    -- Two tabs of the shown unit with their own windows are a tear-off.
    -- Let discovery tile the detached window during this same pass.
    for _, id in ipairs(strays or {}) do
        if sameUnit(leaf, leaf.windowID, id) then Tree.removeMember(leaf, id) end
    end
    for _, id in ipairs(leaf.members) do
        if not sameUnit(leaf, leaf.windowID, id) then
            local win = Util.windowFor(id)
            if win then Spaces.park(win, Spaces.workspaceOf(id), strays and #strays > 0) end
        end
    end
end

function M.show(leaf, key, from, to)
    remember(leaf, from)
    remember(leaf, to)
    if sameUnit(leaf, from, to) then return end
    local win = Util.windowFor(to)
    if win then Spaces.unpark(win) end
    local old = Util.windowFor(from)
    if old then Spaces.park(old, Spaces.workspaceOf(from)) end
    Focus.invalidateWindowCache()
end

function M.cycle(win, leaf, key, delta)
    local tabs = Tree.tabsOf(leaf, leaf.windowID) or { leaf.windowID }
    local same = {}
    for _, id in ipairs(tabs) do same[id] = true end
    local id = Tree.memberAfter(leaf, leaf.windowID, delta, function(m)
        return not same[m] and Util.windowFor(m) ~= nil
    end)
    if not id then return end
    id = preferred(leaf, id)
    Layout.showMember(leaf, id, key)
    Layout.tileNow(false)
    Focus.focus(Util.windowFor(id))
end

local function detach(leaf, list)
    local shown = list[1]
    for _, id in ipairs(list) do
        if id == leaf.windowID then shown = id break end
    end
    for _, id in ipairs(list) do Tree.removeMember(leaf, id) end
    local out = Tree.leaf(shown)
    if #list > 1 then out.members, out.kind = list, "native" end
    return out
end

local function insert(key, beside, leaf)
    S.trees[key] = select(1, Tree.insertBeside(S.trees[key], beside, leaf.windowID, "right"))
    local _, target = Tree.ancestors(S.trees[key], leaf.windowID)
    target.members, target.kind, target.tabs = leaf.members, leaf.kind, leaf.tabs
end

function M.moveOut(win, leaf, key)
    if not key then return end
    local list = Tree.tabsOf(leaf, win:id()) or { win:id() }
    if #list == #leaf.members then return end
    local copy = {}
    for _, id in ipairs(list) do copy[#copy + 1] = id end
    local old = leaf.windowID
    local out = detach(leaf, copy)
    -- Removing a shown member changes the tree without calling the show hook.
    M.show(leaf, key, old, leaf.windowID)
    insert(key, leaf.windowID, out)
    Spaces.unpark(win)
    S.keyIndex = {}
    Layout.tileNow(false)
    Focus.focus(win)
end

function M.toggle(win)
    if not win then return end
    local _, leaf, key = Tree.findByID(win:id())
    if not leaf then return end
    if leaf.kind ~= "group" then
        if leaf.kind == "native" then
            local tabs = {}
            for _, id in ipairs(leaf.members) do tabs[#tabs + 1] = id end
            leaf.tabs = { tabs }
        end
        leaf.members, leaf.kind = leaf.members or { leaf.windowID }, "group"
        remember(leaf, leaf.windowID)
        hide(leaf)
    else
        local lists = units(leaf)
        local shown = leaf.windowID
        leaf.members, leaf.kind, leaf.tabs, leaf.groupInset = nil, nil, nil, nil
        for _, list in ipairs(lists) do
            local holds = false
            for _, id in ipairs(list) do if id == shown then holds = true end end
            if holds then
                if #list > 1 then leaf.members, leaf.kind = list, "native" end
            else
                local out = Tree.leaf(list[1])
                if #list > 1 then out.members, out.kind = list, "native" end
                insert(key, shown, out)
                local other = Util.windowFor(out.windowID)
                if other then Spaces.unpark(other) end
            end
        end
    end
    S.keyIndex = {}
    Focus.invalidateWindowCache()
    Layout.tileNow(false)
end

function M.join(win, other)
    if not win or not other then return end
    local target, toKey = Tree.setOf(other:id())
    local _, source, key = Tree.findByID(win:id())
    if not source or not target or target.kind ~= "group" or source == target or key ~= toKey then return end
    -- Groups move one selected unit; native sets move as a unit.
    local list = Tree.tabsOf(source, win:id()) or { win:id() }
    local copy = {}
    for _, id in ipairs(list) do copy[#copy + 1] = id end
    if source.kind == "group" and #copy < #source.members then
        local old = source.windowID
        detach(source, copy)
        M.show(source, key, old, source.windowID)
    else
        S.trees[key] = Tree.removeID(S.trees[key], win:id())
        for _, id in ipairs(source.members or { win:id() }) do S.setsAway[id] = nil end
    end
    Tree.addMember(target, copy[1], "group")
    for i = 2, #copy do Tree.addTab(target, copy[i], copy[i - 1]) end
    Layout.showMember(target, win:id(), toKey)
    hide(target)
    S.keyIndex = {}
    Layout.tileNow(false)
    Focus.focus(win)
end

-- #14: one entry per logical member (native tabs together), selected id and
-- tile rect. The bar can select with selectMember and reserve space with inset.
function M.info(id)
    local leaf, key = Tree.setOf(id)
    if not leaf or leaf.kind ~= "group" then return nil end
    remember(leaf, leaf.windowID)
    local members, selected = units(leaf), {}
    for i, list in ipairs(members) do selected[i] = preferred(leaf, list[1]) end
    return { members = members, selected = selected, shown = leaf.windowID,
        rect = key and leaf.rect or nil, key = key }
end

function M.selectMember(id)
    local leaf, key = Tree.setOf(id)
    if not leaf or leaf.kind ~= "group" then return end
    Layout.showMember(leaf, id, key)
    Layout.tileNow(false)
    local win = Util.windowFor(id)
    if win then Focus.focus(win) end
end

function M.inset(id, height)
    local leaf = Tree.setOf(id)
    if not leaf or leaf.kind ~= "group" then return end
    leaf.groupInset = math.max(0, tonumber(height) or 0)
    S.applied[leaf.windowID] = nil
    Layout.scheduleRetile()
end

Tree.registerKind("group", { cycle = M.cycle, moveOut = M.moveOut, show = M.show, strays = hide })
return M
