-- hyprspoon/groupbar.lua: Clickable titles above a group's shown window.
--
-- Decides which groups get a bar and what it says; the bar itself is drawn
-- by the border module, in the shown window's ring (Border.bar), so its
-- shown tab fades with the ring and follows the window as the ring does.
-- Here, an invisible hs.canvas under each bar takes the clicks.
local M = {}
package.loaded["hyprspoon.groupbar"] = M

local S = require("hyprspoon.state")
local Tree = require("hyprspoon.tree")
local Util = require("hyprspoon.util")
local Spaces = require("hyprspoon.spaces")
local Group = require("hyprspoon.group")
local Border = require("hyprspoon.border")

local running = false
local bars, suspended = {}, {}

local function config()
    local group = S.cfg and S.cfg.group
    return type(group) == "table" and type(group.bar) == "table" and group.bar or nil
end

function M.height(rect, cfg)
    cfg = cfg or config()
    return cfg and math.min(math.max(0, tonumber(cfg.height) or 0), math.max(0, rect.h - 1)) or 0
end

-- Points the strip extends past each side of the window: a number, or
-- "border" for the border ring's width.
function M.outset(cfg)
    local v = cfg.outset
    if v == "border" then
        local b = S.cfg and S.cfg.border
        v = b and b.width or 0
    end
    return math.max(0, tonumber(v) or 0)
end

-- Pure geometry and labels; native tabs occupy one segment, using the shown
-- tab's title when selected. The caller supplies titles to avoid AX work here.
function M.segments(info, cfg, titles)
    local rect = info.rect
    local height = M.height(rect, cfg)
    local out = {}
    local count = #info.members
    for i, members in ipairs(info.members) do
        local id = info.selected and info.selected[i] or members[1]
        for _, member in ipairs(members) do
            if member == info.shown then id = member break end
        end
        -- Start and end `inset` points in, clear of the window's corners.
        local total = rect.w + 2 * M.outset(cfg)
        local inset = math.min(tonumber(cfg.inset) or 0, total / 4)
        local span = total - 2 * inset
        local x, right = inset + span * (i - 1) / count, inset + span * i / count
        local title = titles[id]
        out[i] = { id = id, label = title and title ~= "" and title or "Untitled",
            shown = id == info.shown, x = x, y = 0, w = right - x, h = height }
    end
    return out
end

-- Canvas callbacks give local coordinates. Half-open edges give a shared
-- boundary to the segment on its right and reject clicks outside the strip.
function M.memberAt(segments, x, y)
    for _, cell in ipairs(segments) do
        if x >= cell.x and x < cell.x + cell.w and y >= 0 and y < cell.h then return cell.id end
    end
end

-- Called before placement, so a new group is inset on its very first frame.
function M.prepare(leaf, rect)
    if running and leaf.kind == "group" then leaf.groupInset = M.height(rect) end
end

local function rgba(value)
    local c = hs.drawing.color.asRGB(type(value) == "string" and { hex = value } or value)
    return { c.red, c.green, c.blue, c.alpha or 1 }
end

-- The bar's height: tabs reach `overlap` down over the window; plain
-- segments stop clear of the ring, `offset` above it.
local function barHeight(cfg, height)
    if cfg.tabs then return height + math.max(0, tonumber(cfg.overlap) or 0) end
    local ring = S.cfg.border and tonumber(S.cfg.border.width) or 0
    return math.max(1, height - ring - (tonumber(cfg.offset) or 0))
end

-- What Border.bar draws (see native/border.m).
local function spec(cfg, cells, height)
    local titles, shown = {}, 1
    for i, cell in ipairs(cells) do
        titles[i] = cell.label
        if cell.shown then shown = i end
    end
    return {
        titles = titles, shown = shown, above = height,
        overlap = cfg.tabs and math.max(0, tonumber(cfg.overlap) or 0) or 0,
        outset = M.outset(cfg), inset = tonumber(cfg.inset) or 0, gap = tonumber(cfg.gap) or 0,
        radius = tonumber(cfg.radius) or 0, drop = tonumber(cfg.drop) or 0,
        padding = tonumber(cfg.padding) or 0, offset = tonumber(cfg.offset) or 0,
        tabs = cfg.tabs and true or false, under = cfg.under and true or false, font = cfg.font or nil, size = tonumber(cfg.size) or 12,
        text = rgba(cfg.text),
        -- The tabs' own colours; unset, the ring's (border.active/inactive).
        active = cfg.active and rgba(cfg.active) or nil,
        inactive = cfg.inactive and rgba(cfg.inactive) or nil,
    }
end

-- Takes window `id`'s bar away, unless another group's bar now has it: a
-- group moved in the tree is a new leaf, drawn before the old one goes.
local function release(id, except)
    if not id then return end
    for _, other in pairs(bars) do
        if other ~= except and other.id == id then return end
    end
    Border.bar(id, nil)
end

local function remove(leaf, bar)
    bars[leaf] = nil
    release(bar.id, bar)
    bar.canvas:delete()
end

local warned = false

function M.update(onlyLeaf)
    if not running then return end
    local cfg, seen = config(), {}
    local blocked = next(suspended) ~= nil
    local windows = onlyLeaf and { Util.windowFor(onlyLeaf.windowID) } or Util.managedWindows()
    for _, win in ipairs(windows) do
        local id = win:id()
        local leaf = Tree.setOf(id)
        local info = leaf and leaf.kind == "group" and leaf.windowID == id and Group.info(id)
        if cfg and not blocked and S.tilingEnabled and info and info.shown == id and info.key
           and info.rect and not S.untiled[info.key] and not S.autoFloat[id]
           and not S.fullscreen[id] and not S.offSpace[id] and not Spaces.isHidden(id)
           and not Tree.behindMaximized(id) then
            -- Maximized and pseudotiled content reserve space in their own
            -- frame; keep the strip attached to that same frame.
            local rect = leaf.fullRect or leaf.pseudoRect or info.rect
            local height = M.height(rect, cfg)
            if height > 0 then
                seen[leaf] = true
                local bar = bars[leaf]
                if not bar then
                    bar = { canvas = hs.canvas.new({ x = rect.x, y = rect.y, w = rect.w, h = height }) }
                    bars[leaf] = bar
                    bar.canvas:level(hs.canvas.windowLevels.normal)
                    bar.canvas:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
                    bar.canvas:canvasMouseEvents(true, false, false, false)
                    bar.canvas:mouseCallback(function(_, event, _, x, y)
                        if event == "mouseDown" then
                            local member = M.memberAt(bar.cells, x, y)
                            if member then Group.selectMember(member) end
                        end
                    end)
                end
                local titles = {}
                for i, members in ipairs(info.members) do
                    local member = info.selected and info.selected[i] or members[1]
                    for _, tab in ipairs(members) do
                        if tab == info.shown then member = tab break end
                    end
                    local w = Util.windowFor(member)
                    if w then titles[member] = w:title() end
                end
                info.rect = rect
                local barH = barHeight(cfg, height)
                bar.cells = M.segments(info, cfg, titles)
                -- Under the window, the overlap is the window's to click.
                local hitH = cfg.under and height or barH
                for _, cell in ipairs(bar.cells) do cell.h = hitH end
                local drawn = spec(cfg, bar.cells, height)
                -- Everything but the titles: a change there lays the bar out
                -- again; titles alone are only retitled.
                local signature = table.concat({ tostring(id), tostring(rect.x), tostring(rect.y),
                    tostring(rect.w), tostring(barH), tostring(hitH), tostring(#drawn.titles),
                    tostring(drawn.shown) }, "\0")
                if bar.signature == signature then
                    for i, title in ipairs(drawn.titles) do
                        if bar.titles[i] ~= title then Border.title(id, i, title) end
                    end
                    bar.titles = drawn.titles
                else
                    bar.titles = drawn.titles
                    bar.signature = signature
                    local old = bar.id
                    bar.id = id
                    if old ~= id then release(old, bar) end
                    if not Border.bar(id, drawn) and not warned then
                        warned = true
                        print("hyprspoon: group bars need the native border module (make -C hyprspoon/native)")
                    end
                    -- Clicks only: the bar shows above this canvas. Barely
                    -- there, so macOS still sends it the clicks.
                    local elements = {}
                    for _, cell in ipairs(bar.cells) do
                        elements[#elements + 1] = { type = "rectangle", action = "fill",
                            fillColor = { white = 0, alpha = 0.01 },
                            frame = { x = cell.x, y = 0, w = cell.w, h = hitH } }
                    end
                    local out = drawn.outset
                    bar.canvas:frame({ x = rect.x - out, y = rect.y, w = rect.w + 2 * out, h = hitH })
                    bar.canvas:replaceElements(table.unpack(elements))
                    bar.canvas:show()
                end
            end
        end
    end
    for leaf, bar in pairs(bars) do
        if (not onlyLeaf or leaf == onlyLeaf) and not seen[leaf] then remove(leaf, bar) end
    end
end

function M.titleChanged(win)
    if not running or not win then return end
    local id = win:id()
    local leaf = Tree.setOf(id)
    local bar = leaf and bars[leaf]
    if not bar then return end
    for i, cell in ipairs(bar.cells) do
        if cell.id == id then
            local title = win:title()
            local label = title and title ~= "" and title or "Untitled"
            -- Terminals retitle often (spinners): redraw only that title,
            -- without re-reading the group or touching its layout.
            if cell.label ~= label then
                cell.label = label
                bar.titles[i] = label
                Border.title(bar.id, i, label)
            end
            return
        end
    end
end

function M.suspend(reason, on)
    suspended[reason] = on and true or nil
    M.update()
end

function M.start()
    running = true
    M.update()
end

function M.stop()
    running = false
    for leaf, bar in pairs(bars) do remove(leaf, bar) end
    for key, tree in pairs(S.trees) do
        for _, leaf in ipairs(Tree.leaves(tree)) do
            if leaf.kind == "group" then
                local id, amount = leaf.windowID, leaf.groupInset or 0
                leaf.groupInset = nil
                S.applied[id] = nil
                local rect = leaf.fullRect or leaf.pseudoRect or leaf.rect
                local win = Util.windowFor(id)
                -- Layout.stop cancels pending retiles. Restore visible content
                -- here, including maximized/pseudotiled frames, before it runs.
                if amount > 0 and rect and win and S.tilingEnabled and not S.untiled[key]
                   and not S.autoFloat[id] and not S.fullscreen[id] and not S.offSpace[id]
                   and not Spaces.isHidden(id) then
                    leaf.windowRect = rect
                    Util.setFrame(win, rect, 0)
                end
            end
        end
    end
    for _, leaf in pairs(S.setsAway or {}) do
        if leaf.kind == "group" then leaf.groupInset = nil end
    end
    suspended = {}
end

return M
