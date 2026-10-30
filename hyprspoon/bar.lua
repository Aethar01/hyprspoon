-- hyprspoon/bar.lua: Workspace numbers in the menu bar, and the row they're drawn as.

local M = {}
package.loaded["hyprspoon.bar"] = M

local S = require("hyprspoon.state")
local Spaces = require("hyprspoon.spaces")

-- ---------------------------------------------------------------------------
-- The row of numbers
-- ---------------------------------------------------------------------------
--
-- Workspaces 1 to `alwaysShow` and any other in use, in the system font.
-- Current ones sit in a rounded pill, the way macOS draws an enabled menu
-- bar control; empty ones are dimmed. Shared by the menu bar and hyprspoon/hud.lua.

-- { n =, display = UUID showing it or nil, windows = bool } per number.
local function entries()
    local byNumber = {}
    for _, ws in ipairs(Spaces.workspaces()) do byNumber[ws.n] = ws end
    local always = S.cfg.indicators.alwaysShow
    local numbers = {}
    for n = 1, always do numbers[#numbers + 1] = n end
    for n in pairs(byNumber) do
        if n > always or n < 0 then numbers[#numbers + 1] = n end
    end
    table.sort(numbers, Spaces.before)

    local out = {}
    for i, n in ipairs(numbers) do
        local ws = byNumber[n]
        out[i] = { n = n, display = ws and ws.display, windows = ws ~= nil and Spaces.hasWindows(n) }
    end
    return out
end

-- Lays `list` (from entries) out in a row in the system font at `size`,
-- with pills `pill` high. Returns { cells = { entry, x, w, textH }, w, h, size }.
local function layout(list, size, pill)
    local font = hs.styledtext.defaultFonts.menuBar.name
    local pad = math.floor(pill * 5 / 18 + 0.5) -- around a number in its pill
    local gap = math.max(1, math.floor(pill / 9 + 0.5)) -- between numbers
    local row = { cells = {}, h = pill, size = size, font = font }
    local x = 0
    for i, entry in ipairs(list) do
        local text = hs.drawing.getTextDrawingSize(Spaces.label(entry.n), { font = font, size = size })
        local w = math.max(pill, math.ceil(text.w) + 2 * pad)
        row.cells[i] = { entry = entry, x = x, w = w, textH = math.ceil(text.h) }
        x = x + w + gap
    end
    row.w = math.max(x - gap, 1)
    return row
end

-- Draws `row` onto `canvas` with its top-left at (x0, y0). `current(entry)`
-- picks the numbers in a pill. `colors.text` is the numbers and pill;
-- `colors.pillText` the numbers in a pill, or nil to cut them out of it.
local function drawRow(canvas, row, x0, y0, colors, current)
    for _, cell in ipairs(row.cells) do
        local entry = cell.entry
        local inPill = current(entry)
        if inPill then
            canvas:appendElements({
                type = "rectangle", action = "fill",
                frame = { x = x0 + cell.x, y = y0, w = cell.w, h = row.h },
                roundedRectRadii = { xRadius = row.h * 5 / 18, yRadius = row.h * 5 / 18 },
                fillColor = colors.text,
            })
        end
        local color = inPill and colors.pillText or colors.text
        canvas:appendElements({
            type = "text", text = Spaces.label(entry.n),
            textFont = row.font, textSize = row.size,
            textAlignment = "center",
            textColor = { white = color and color.white or 0,
                alpha = (inPill or entry.windows) and 1 or 0.4 },
            compositeRule = (inPill and not colors.pillText) and "destinationOut" or "sourceOver",
            frame = { x = x0 + cell.x, y = y0 + (row.h - cell.textH) / 2, w = cell.w, h = cell.textH },
        })
    end
end

M.entries = entries
M.layout = layout
M.drawRow = drawRow

-- ---------------------------------------------------------------------------
-- Menu bar
-- ---------------------------------------------------------------------------
--
-- The row as a template image, so macOS colours it like its own menu bar
-- items (light or dark, tinted, Reduce Transparency). Every workspace
-- showing on a display is in a pill. Clicking a number goes to that
-- workspace. One image, since one menu bar item per number can't be kept
-- in order.

local HEIGHT = 22 -- the image; macOS centres it in the menu bar

local row = nil -- from the last draw, for clicks
local item = nil

local function draw()
    row = layout(entries(), hs.styledtext.defaultFonts.menuBar.size, 18)
    local canvas = hs.canvas.new({ x = 0, y = 0, w = row.w, h = HEIGHT })
    drawRow(canvas, row, 0, (HEIGHT - row.h) / 2, { text = { white = 0 } },
        function(entry) return entry.display ~= nil end)
    item:setIcon(canvas:imageFromCanvas(), true)
    canvas:delete()
end

-- Workspace changes come in bursts (a switch parks and claims several
-- windows), so the row is redrawn once they're done.
local redraw = hs.timer.delayed.new(0.05, function()
    if item then draw() end
end)

function M.update()
    if item then redraw:start() end
end

-- The item is wider than its image (macOS pads it on both sides and
-- centres the image), so clicks are measured from the image. Every click
-- goes to the nearest number: the gaps and the padding belong to the
-- numbers beside them.
local function onClick()
    local frame = item and item:frame()
    if not frame or not row or #row.cells == 0 then return end
    local x = hs.mouse.absolutePosition().x - frame.x - (frame.w - row.w) / 2
    local best, bestDistance = nil, nil
    for _, cell in ipairs(row.cells) do
        local distance = math.max(cell.x - x, x - (cell.x + cell.w), 0)
        if not bestDistance or distance < bestDistance then best, bestDistance = cell, distance end
    end
    Spaces.gotoWorkspace(best.entry.n)
end

function M.start()
    if not S.cfg.indicators.menuBar then return end
    -- The autosave name keeps its place in the menu bar across reloads.
    item = hs.menubar.new(true, "hyprspoon.workspaces")
    if not item then return end
    item:setClickCallback(onClick)
    draw()
end

-- Removes the menu bar item (reload, shutdown).
function M.stop()
    redraw:stop()
    if item then item:delete() end
    item, row = nil, nil
end

return M
