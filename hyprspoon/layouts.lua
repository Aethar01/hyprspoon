-- hyprspoon/layouts.lua: which layout each workspace is tiled with.
--
-- Everything asks M.of(key) rather than the options. The first of these
-- that names a layout wins:
--   1. the choice made while running (cycleLayout, setLayout), saved with
--      the workspace in S.layouts (hyprspoon/tree.lua)
--   2. `workspaces[n].layout`, n the number or name of the workspace
--   3. `layout`, the default for every workspace
--   4. "bsp"
-- Scratchpads are always "bsp": they're laid out smaller over the workspace
-- beneath. A layout is registered by adding its name to M.names (cycleLayout
-- goes through them in order) and handling it where windows are laid out.

local M = {}
package.loaded["hyprspoon.layouts"] = M

local S = require("hyprspoon.state")

-- Required on first use: this is loaded (alone, in the unit tests) before
-- the workspaces it asks.
local function spaces() return require("hyprspoon.spaces") end

M.names = { "bsp", "scrolling" }
M.aliases = { dwindle = "bsp", scroll = "scrolling" }

-- The registered name `name` stands for, or nil.
function M.known(name)
    name = M.aliases[name] or name
    for _, n in ipairs(M.names) do
        if n == name then return name end
    end
    return nil
end

local warned = {}

-- `name` from the options, nil (once with a message) if it's none we have.
local function fromOptions(name)
    if name == nil then return nil end
    local known = M.known(name)
    if not known and not warned[name] then
        warned[name] = true
        print(string.format("hyprspoon: unknown layout %q in the options (have %s)",
            tostring(name), table.concat(M.names, ", ")))
    end
    return known
end

-- Workspace `n` named in `list`, by number or name: its table, or nil.
local function entry(list, n)
    if type(list) ~= "table" then return nil end
    local e = list[n] or list[spaces().label(n)] or list[tostring(n)]
    return type(e) == "table" and e or nil
end

-- `scrolling.workspaces` (and `scrolling = true` turning columns on) went
-- with #17: say so once per set of options, rather than quietly tile in BSP.
local checked = nil
local function checkOld()
    if checked == S.cfg then return end
    checked = S.cfg
    local c = S.cfg and S.cfg.scrolling
    if not c then c = S.cfg and S.cfg.experimental and S.cfg.experimental.scrolling end
    if c == true or (type(c) == "table" and c.workspaces ~= nil) then
        print('hyprspoon: scrolling.workspaces is gone; use layout = "scrolling" '
            .. 'or workspaces = { [n] = { layout = "scrolling" } }')
    end
end

-- The layout of workspace `key` ("ws<n>"): a name from M.names.
function M.of(key)
    if not key or spaces().layoutScale(key) then return "bsp" end
    local saved = S.layouts and S.layouts[key]
    if saved and M.known(saved) then return M.known(saved) end
    local n = tonumber(key:match("^ws(%-?%d+)$"))
    local e = n and entry(S.cfg and S.cfg.workspaces, n)
    local name = e and fromOptions(e.layout)
    if name then return name end
    checkOld()
    return fromOptions(S.cfg and S.cfg.layout) or "bsp"
end

-- Whether the options, or a choice kept from before a reload, put any
-- workspace in layout `name` (the scroll wheel and swipe taps are only
-- started for scrolling that's in use).
function M.configured(name)
    if fromOptions(S.cfg and S.cfg.layout) == name then return true end
    for _, saved in pairs(S.layouts or {}) do
        if M.known(saved) == name then return true end
    end
    for _, e in pairs(S.cfg and S.cfg.workspaces or {}) do
        if type(e) == "table" and fromOptions(e.layout) == name then return true end
    end
    return false
end

-- Workspace `key` laid out in `name` from now on, kept with the workspace.
-- Nil for a name we don't have, and for a scratchpad; otherwise the name
-- the workspace had before (the caller retiles if it changed).
function M.set(key, name)
    name = M.known(name)
    if not name or not key or spaces().layoutScale(key) then return nil end
    local before = M.of(key)
    S.layouts = S.layouts or {}
    S.layouts[key] = name
    return before
end

-- The layout after `key`'s own in M.names.
function M.next(key)
    local current = M.of(key)
    for i, n in ipairs(M.names) do
        if n == current then return M.names[i % #M.names + 1] end
    end
    return M.names[1]
end

return M
