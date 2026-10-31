-- hyprspoon/groupbar.lua: Clickable titles above a group's shown window.
local M = {}
package.loaded["hyprspoon.groupbar"] = M

local S = require("hyprspoon.state")
local Tree = require("hyprspoon.tree")
local Util = require("hyprspoon.util")
local Spaces = require("hyprspoon.spaces")
local Group = require("hyprspoon.group")

local running = false
local focused = nil
local bars, suspended = {}, {}

local function config()
    local group = S.cfg and S.cfg.group
    return type(group) == "table" and type(group.bar) == "table" and group.bar or nil
end

function M.height(rect, cfg)
    cfg = cfg or config()
    return cfg and math.min(math.max(0, tonumber(cfg.height) or 0), math.max(0, rect.h - 1)) or 0
end

-- Pure geometry and labels; native tabs occupy one segment, using the shown
-- tab's title when selected. The caller supplies titles to avoid AX work here.
function M.segments(info, cfg, titles, focused)
    local rect = info.rect
    local height = M.height(rect, cfg)
    local out = {}
    local count = #info.members
    for i, members in ipairs(info.members) do
        local id = info.selected and info.selected[i] or members[1]
        for _, member in ipairs(members) do
            if member == info.shown then id = member break end
        end
        local x, right = rect.w * (i - 1) / count, rect.w * i / count
        local title = titles[id]
        out[i] = { id = id, label = title and title ~= "" and title or "Untitled",
            active = id == focused, x = x, y = 0, w = right - x, h = height }
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

local function color(value)
    return type(value) == "string" and { hex = value } or value
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
                bar.cells = M.segments(info, cfg, titles, focused)
                local signature = { tostring(rect.x), tostring(rect.y), tostring(rect.w), tostring(height) }
                for _, cell in ipairs(bar.cells) do
                    signature[#signature + 1] = table.concat({ cell.id, cell.label, tostring(cell.active) }, "\0")
                end
                signature = table.concat(signature, "\0")
                -- Focus/layout notifications often repeat without a visual
                -- change; keep the existing canvas contents in that case.
                if bar.signature ~= signature then
                    bar.signature = signature
                    local border = S.cfg.border or S.defaults.border
                    local elements = {}
                    local font = cfg.font or hs.styledtext.defaultFonts.menuBar.name
                    local textH = hs.drawing.getTextDrawingSize("Ag", { font = font, size = cfg.size }).h
                    for _, cell in ipairs(bar.cells) do
                        elements[#elements + 1] = { type = "rectangle", action = "fill",
                            fillColor = color((cell.active and border.active) or border.inactive or { alpha = 0 }),
                            frame = { x = cell.x, y = 0, w = cell.w, h = height } }
                        elements[#elements + 1] = { type = "text", text = cell.label,
                            textFont = font, textSize = cfg.size, textColor = color(cfg.text),
                            textAlignment = "center", textLineBreak = "truncateTail",
                            frame = { x = cell.x + math.min(cfg.padding, cell.w / 2),
                                y = math.max(0, (height - textH) / 2),
                                w = math.max(0, cell.w - 2 * cfg.padding), h = height } }
                    end
                    bar.canvas:frame({ x = rect.x, y = rect.y, w = rect.w, h = height })
                    bar.canvas:replaceElements(table.unpack(elements))
                    bar.canvas:show()
                end
            end
        end
    end
    for leaf, bar in pairs(bars) do
        if (not onlyLeaf or leaf == onlyLeaf) and not seen[leaf] then
            bar.canvas:delete() bars[leaf] = nil
        end
    end
end

function M.titleChanged(win)
    if not running or not win then return end
    local id = win:id()
    local leaf = Tree.setOf(id)
    local bar = leaf and bars[leaf]
    if not bar then return end
    for _, cell in ipairs(bar.cells) do
        if cell.id == id then
            local title = win:title()
            local label = title and title ~= "" and title or "Untitled"
            -- Terminal emits frequent repeated title notifications. Touch only
            -- the affected group, and redraw only a changed displayed label.
            if cell.label ~= label then M.update(leaf) end
            return
        end
    end
end

function M.focus(id)
    focused = id
    M.update()
end

function M.unfocused(win)
    if win and focused == win:id() then M.focus(nil) end
end

function M.suspend(reason, on)
    suspended[reason] = on and true or nil
    M.update()
end

function M.start()
    running = true
    focused = S.ffmFocusedID
    M.update()
end

function M.stop()
    running = false
    for leaf, bar in pairs(bars) do bar.canvas:delete() bars[leaf] = nil end
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
