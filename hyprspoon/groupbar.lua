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
local Scroll = require("hyprspoon.scroll")

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

-- The gap in window `id`'s group bar nearest screen point `point`, as a
-- slot for Group.moveTo (k: before segment k; one past the last: after
-- it), and a thin rect marking it. nil unless `point` is over the bar, or
-- within `slack` points above or below it.
function M.slotAt(id, point, slack)
    local leaf = Tree.setOf(id)
    local bar = leaf and bars[leaf]
    local hit, cells = bar and bar.hit, bar and bar.cells
    if not hit or not cells or #cells == 0 then return nil end
    slack = slack or 0
    if point.x < hit.x or point.x >= hit.x + hit.w
       or point.y < hit.y - slack or point.y >= hit.y + hit.h + slack then
        return nil
    end
    local x, slot = point.x - hit.x, #cells + 1
    for i, cell in ipairs(cells) do
        if x < cell.x + cell.w / 2 then slot = i break end
    end
    local last = cells[#cells]
    local edge = slot <= #cells and cells[slot].x or last.x + last.w
    return slot, { x = hit.x + edge - 3, y = hit.y, w = 6, h = hit.h }
end

-- ---------------------------------------------------------------------------
-- Dragging a segment
-- ---------------------------------------------------------------------------
--
-- Along its bar, a member moves to the gap under the pointer, marked as it
-- goes. Off the bar, it drops like a modifier-drag (hyprspoon/drop.lua),
-- except that only it leaves the group: beside a tile (its own group's
-- too), or into another group. A press that hardly moves is a click, and
-- selects on mouse up as before.

local DRAG_START = 4  -- points of travel before a press is a drag
local BAR_SLACK = 12  -- points above and below its bar still count as on it

-- The press on a segment: its group (`leaf`), member `id`, `start` point,
-- and once it's a drag, `dragging`, and `tearing` while it's off the bar.
local press = nil
local dragTap = nil

local function stopDrag()
    if dragTap then dragTap:stop() dragTap = nil end
end

local function dragMoved(p, point)
    if not p.dragging then
        if math.abs(point.x - p.start.x) < DRAG_START
           and math.abs(point.y - p.start.y) < DRAG_START then return end
        p.dragging = true
    end
    local Drop = require("hyprspoon.drop")
    local slot, marker = M.slotAt(p.id, point, BAR_SLACK)
    if slot then
        if p.tearing then Drop.cancelDrag() p.tearing = false end
        -- The gaps either side of it would leave it where it is.
        local still = false
        for i, cell in ipairs((bars[p.leaf] or {}).cells or {}) do
            if cell.id == p.id then still = slot == i or slot == i + 1 end
        end
        Drop.preview(not still and marker or nil)
        return
    end
    if not p.tearing then
        local win = Util.windowFor(p.id)
        if not win then return end
        Drop.preview(nil)
        Drop.beginDrag(win, true)
        p.tearing = true
    end
    Drop.updateDrag(point)
end

local function dragEnded(p, point)
    local Drop = require("hyprspoon.drop")
    local slot = M.slotAt(p.id, point, BAR_SLACK)
    if slot then
        if p.tearing then Drop.cancelDrag() end
        Drop.preview(nil)
        Group.moveTo(p.id, slot)
    elseif p.tearing then
        local win = Util.windowFor(p.id)
        if win then Drop.finishDrag(win, point) else Drop.cancelDrag() end
    end
    -- To focus once the mouse up has landed: the window a drop focused,
    -- else the group's, as a click would.
    p.focus = (p.tearing and not slot and S.ffmFocusedID) or p.leaf.windowID
end

-- The press on the bar's canvas, and its mouse up, take focus from the
-- window, so it's given back after the mouse up, as Group.selectMember
-- does for a click. Focusing before then would be undone.
local function refocus(p)
    local Focus = package.loaded["hyprspoon.focus"]
    local win = p.focus and Util.windowFor(p.focus)
    if Focus and win then Focus.focus(win) end
end

-- Follows the pointer from a press on a segment until the button's up.
local function startDrag()
    stopDrag()
    local types = hs.eventtap.event.types
    local tap
    tap = hs.eventtap.new({ types.leftMouseDragged, types.leftMouseUp }, function(event)
        local p = press
        if not p or p.done then return false end
        local point = event:location()
        if event:getType() == types.leftMouseUp then
            -- The canvas may still get this mouse up; `done` tells it the
            -- drag has been dealt with. Its bar may be gone by then (a
            -- group emptied by the drop), so the tap stops itself.
            p.done = true
            if p.dragging then
                dragEnded(p, point)
                -- In case the canvas never gets it (its bar went with the drop).
                hs.timer.doAfter(0.2, function() if press == p then refocus(p) end end)
            end
            hs.timer.doAfter(0, function()
                tap:stop()
                if dragTap == tap then dragTap = nil end
            end)
        else
            dragMoved(p, point)
        end
        return false
    end)
    dragTap = tap:start()
end

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
           and not Scroll.isAway(id) and not Tree.behindMaximized(id) then
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
                    -- Selects on mouse up, as a button does: switching on mouse
                    -- down left the mouse up to land after the new window took
                    -- focus, and it lost it. Mouse down starts a drag.
                    bar.canvas:canvasMouseEvents(true, true, false, false)
                    -- A click mustn't make Hammerspoon the active app: focus
                    -- would leave the group and its colours fade out and in.
                    bar.canvas:clickActivating(false)
                    bar.canvas:mouseCallback(function(_, event, _, x, y)
                        if event == "mouseDown" then
                            local member = M.memberAt(bar.cells, x, y)
                            press = member and { leaf = leaf, id = member,
                                start = hs.mouse.absolutePosition() } or nil
                            if press then startDrag() else stopDrag() end
                        elseif event == "mouseUp" then
                            local p = press
                            press = nil
                            if p and p.dragging then refocus(p) return end
                            stopDrag()
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
                bar.spec = drawn
                local out = drawn.outset
                local hit = { x = rect.x - out, y = rect.y, w = rect.w + 2 * out, h = hitH }
                bar.hit = hit
                -- The canvas's frame, so the border's masks know it covers nothing.
                drawn.hit = { hit.x, hit.y, hit.w, hit.h }
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
                    -- The window handOver took the bar from, once the new
                    -- one has it (its ring and that bar are gone by now).
                    if bar.leaving and bar.leaving ~= id then release(bar.leaving, bar) end
                    bar.leaving = nil
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
                    bar.canvas:frame(hit)
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

-- A group shows `to` instead of `from` (Layout.showMember): the bar goes
-- to `to` first, with `to` shown, before the windows swap; the next update
-- redraws it fully and lets `from` go.
function M.handOver(from, to)
    if not running then return end
    for _, bar in pairs(bars) do
        if bar.id == from and bar.spec then
            local moved = {}
            for k, v in pairs(bar.spec) do moved[k] = v end
            for i, cell in ipairs(bar.cells or {}) do
                if cell.id == to then moved.shown = i end
            end
            bar.id, bar.leaving, bar.spec, bar.signature = to, from, moved, nil
            Border.bar(to, moved)
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
    stopDrag()
    if press and press.dragging then
        local Drop = package.loaded["hyprspoon.drop"]
        if Drop and Drop.cancelDrag then Drop.cancelDrag() end
    end
    press = nil
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
