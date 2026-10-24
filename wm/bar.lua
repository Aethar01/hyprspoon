-- wm/bar.lua: Menu bar indicator of the workspaces.

local M = {}
package.loaded["wm.bar"] = M

local S = require("wm.state")
local Spaces = require("wm.spaces")

-- ---------------------------------------------------------------------------
-- Menu bar
-- ---------------------------------------------------------------------------
--
-- Workspaces 1 to `alwaysShow` and any other in use, as numbers in the menu
-- bar's own font. Those showing sit in a rounded pill with the number cut
-- out, the way macOS draws an enabled menu bar control; empty ones are
-- dimmed. It's a template image, so macOS colours it like its own menu bar
-- items (light or dark, tinted, Reduce Transparency). Clicking a number
-- goes to that workspace. Drawn as one image, since one menu bar item per
-- number can't be kept in order.

local HEIGHT = 22 -- the image; macOS centres it in the menu bar
local PILL = 18   -- height of the pill behind workspaces showing
local PAD = 5     -- around a number inside its pill
local GAP = 2     -- between numbers

-- Cells: { n =, x =, w = } from the last draw, for clicks.
local cells = {}
local item = nil

local function draw()
    local font = hs.styledtext.defaultFonts.menuBar
    local style = { font = font.name, size = font.size }
    local used = {}
    for _, ws in ipairs(Spaces.workspaces()) do used[ws.n] = ws end

    local numbers = {}
    for n = 1, S.cfg.menuBar.alwaysShow do numbers[#numbers + 1] = n end
    for n in pairs(used) do
        if n > S.cfg.menuBar.alwaysShow then numbers[#numbers + 1] = n end
    end
    table.sort(numbers)

    cells = {}
    local x = 0
    for i, n in ipairs(numbers) do
        local size = hs.drawing.getTextDrawingSize(tostring(n), style)
        local w = math.max(PILL, math.ceil(size.w) + 2 * PAD)
        cells[i] = { n = n, x = x, w = w, textH = math.ceil(size.h) }
        x = x + w + GAP
    end

    local canvas = hs.canvas.new({ x = 0, y = 0, w = math.max(x - GAP, 1), h = HEIGHT })
    for _, cell in ipairs(cells) do
        local ws = used[cell.n]
        local shown = ws and ws.shown
        if shown then
            canvas:appendElements({
                type = "rectangle", action = "fill",
                frame = { x = cell.x, y = (HEIGHT - PILL) / 2, w = cell.w, h = PILL },
                roundedRectRadii = { xRadius = 5, yRadius = 5 },
                fillColor = { white = 0, alpha = 1 },
            })
        end
        canvas:appendElements({
            type = "text", text = tostring(cell.n),
            textFont = font.name, textSize = font.size,
            textAlignment = "center",
            textColor = { white = 0, alpha = (shown or Spaces.hasWindows(cell.n)) and 1 or 0.4 },
            -- Cut out of the pill rather than drawn on it.
            compositeRule = shown and "destinationOut" or "sourceOver",
            frame = { x = cell.x, y = (HEIGHT - cell.textH) / 2, w = cell.w, h = cell.textH },
        })
    end
    item:setIcon(canvas:imageFromCanvas(), true)
    canvas:delete()
end

-- Workspace changes come in bursts (a switch parks and claims several
-- windows), so the strip is redrawn once they're done.
local redraw = hs.timer.delayed.new(0.05, function()
    if item then draw() end
end)

function M.update()
    if item then redraw:start() end
end

local function onClick()
    local frame = item and item:frame()
    if not frame then return end
    local x = hs.mouse.absolutePosition().x - frame.x
    for _, cell in ipairs(cells) do
        if x >= cell.x and x < cell.x + cell.w then
            Spaces.gotoWorkspace(cell.n)
            return
        end
    end
end

function M.start()
    if not S.cfg.menuBar then return end
    -- The autosave name keeps its place in the menu bar across reloads.
    item = hs.menubar.new(true, "wmWorkspaces")
    if not item then return end
    item:setClickCallback(onClick)
    draw()
end

-- Removes the menu bar item (reload, shutdown).
function M.stop()
    redraw:stop()
    if item then item:delete() end
    item, cells = nil, {}
end

return M
