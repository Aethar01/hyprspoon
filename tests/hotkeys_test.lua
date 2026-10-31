-- Run with: lua tests/hotkeys_test.lua
-- Unit tests for the keymaps in init.lua: defaultHotkeys keeps its bindings,
-- and hotkeysFor puts the given modifiers in place of Option.
package.path = "./?.lua;" .. package.path

-- init.lua only needs the other modules at runtime, so empty ones will do.
hs = { settings = { get = function() return nil end } }
for _, name in ipairs({ "actions", "util", "tree", "float", "focus", "discover", "layout",
    "resize", "mouse", "ffm", "spaces", "swipe", "bar", "hud", "border", "slide", "overview",
    "restore" }) do
    package.loaded["hyprspoon." .. name] = {}
end
local M = dofile("init.lua")

local function mods(spec) return table.concat(spec[1], "+") end

-- A sample of the default keymap, as it was before hotkeysFor.
local expected = {
    closeWindow = { "alt", "w" },
    toggleMaximize = { "alt+shift", "f" },
    toggleOverview = { "alt", "tab" },
    previousWorkspace = { "ctrl+alt", "h" },
    focusLeft = { "alt", "h" },
    moveDown = { "alt+shift", "j" },
    resizeUp = { "alt", "up" },
    preselectRight = { "ctrl+alt", "right" },
    workspace10 = { "alt", "0" },
    moveToWorkspace3 = { "alt+shift", "3" },
    moveToWorkspaceSilent1 = { "ctrl+alt", "1" },
    workspaceS = { "alt", "s" },
    moveToWorkspaceSilentD = { "ctrl+alt", "d" },
    focusDisplayNext = { "alt", "." },
    moveWorkspaceToDisplayPrev = { "ctrl+alt", "," },
}
for name, want in pairs(expected) do
    local spec = assert(M.defaultHotkeys[name], name .. " must be bound")
    assert(mods(spec) == want[1] and spec[2] == want[2],
        name .. " is " .. mods(spec) .. " " .. spec[2])
end
local count = 0
for _ in pairs(M.defaultHotkeys) do count = count + 1 end
assert(count == 76, "defaultHotkeys has " .. count .. " bindings")

-- The Ctrl+Option+Cmd map changes modifiers and avoids system shortcuts.
local function sorted(list)
    list = { table.unpack(list) }
    table.sort(list)
    return table.concat(list, "+")
end
local ctrlAltCmd = {
    alt = sorted({ "ctrl", "alt", "cmd" }),
    ["alt+shift"] = sorted({ "ctrl", "alt", "cmd", "shift" }),
    ["ctrl+alt"] = sorted({ "ctrl", "alt", "shift" }),
}
local changedKeys = {
    focusDisplayPrev = "[", focusDisplayNext = "]",
    moveToDisplayPrev = "[", moveToDisplayNext = "]",
    moveWorkspaceToDisplayPrev = "[", moveWorkspaceToDisplayNext = "]",
    workspace8 = "i", moveToWorkspace8 = "i", moveToWorkspaceSilent8 = "i",
}
assert(M.hyperHotkeys == nil, "the old Hyper name must not be exposed")
for name, spec in pairs(M.defaultHotkeys) do
    local got = assert(M.ctrlAltCmdHotkeys[name], name .. " must be in ctrlAltCmdHotkeys")
    assert(got[2] == (changedKeys[name] or spec[2]), name .. " changed key")
    assert(sorted(got[1]) == ctrlAltCmd[mods(spec)], name .. " is " .. mods(got) .. " in ctrlAltCmdHotkeys")
end
for name in pairs(M.ctrlAltCmdHotkeys) do
    assert(M.defaultHotkeys[name], name .. " is only in ctrlAltCmdHotkeys")
end

-- No two actions share keys (hs.hotkey ignores the modifiers' order).
for _, map in ipairs({ M.defaultHotkeys, M.ctrlAltCmdHotkeys }) do
    local seen = {}
    for name, spec in pairs(map) do
        local id = sorted(spec[1]) .. " " .. spec[2]
        assert(not seen[id], name .. " and " .. tostring(seen[id]) .. " are both " .. id)
        seen[id] = name
    end
end

-- Without a ctrlSuper, Ctrl is added to SUPER for the third layer...
local cmdKeys = M.hotkeysFor({ "cmd" })
assert(mods(cmdKeys.focusLeft) == "cmd")
assert(mods(cmdKeys.moveLeft) == "cmd+shift")
assert(mods(cmdKeys.preselectLeft) == "ctrl+cmd")
-- ...which can't work when SUPER already has it.
assert(not pcall(M.hotkeysFor, { "ctrl", "alt" }))

-- Aliases, case, order and duplicate modifiers must not disguise equal layers.
local function rejects(super, ctrlSuper)
    local ok, err = pcall(M.hotkeysFor, super, ctrlSuper)
    assert(not ok and err:find("use the same modifiers", 1, true), tostring(err))
end
for _, ctrl in ipairs({ "ctrl", "control", "⌃", "CONTROL" }) do
    rejects({ ctrl, "alt" })
end
rejects({ "cmd", "shift" }, { "alt" })
rejects({ "⌘", "⇧" }, { "alt" })
rejects({ "command", "option" }, { "ALT", "CMD", "command" })
rejects({ "cmd", "alt" }, { "⇧", "⌥", "⌘" })
rejects({ "ctrl", "alt", "cmd", "shift" }, { "alt" })
local custom = M.hotkeysFor({ "control", "command" }, { "⌃", "⌥", "⌘", "⇧" })
assert(mods(custom.focusLeft) == "control+command")
assert(mods(custom.moveLeft) == "control+command+shift")
assert(mods(custom.preselectLeft) == "⌃+⌥+⌘+⇧")

-- The README's Caps Lock Hyper example avoids Hyper+. (sysdiagnose).
local capsLock = M.hotkeysFor({ "ctrl", "cmd" }, { "ctrl", "alt", "cmd", "shift" })
capsLock.moveWorkspaceToDisplayPrev[2] = "["
capsLock.moveWorkspaceToDisplayNext[2] = "]"

-- Model the configuration installed by start(), without starting live services.
local S = require("hyprspoon.state")
S.cfg = { namedWorkspaces = { "Q" } }
local configured = M.hotkeysFor({ "alt" })
assert(not configured.workspaceA and not configured.moveToWorkspaceSilentD)
assert(configured.workspaceQ[2] == "q")
assert(mods(configured.moveToWorkspaceQ) == "alt+shift")
assert(mods(configured.moveToWorkspaceSilentQ) == "ctrl+alt")
local bound = 0
hs.hotkey = { bind = function()
    bound = bound + 1
    return { delete = function() end }
end }
M:bindHotkeys({
    workspaceQ = configured.workspaceQ,
    moveToWorkspaceQ = configured.moveToWorkspaceQ,
    moveToWorkspaceSilentQ = configured.moveToWorkspaceSilentQ,
})
assert(bound == 3, "configured named workspaces must have matching actions")
S.cfg = { namedWorkspaces = {} }
assert(not M.hotkeysFor({ "alt" }).workspaceA)
S.cfg = {}
assert(not M.hotkeysFor({ "alt" }).workspaceA)
S.cfg = nil

-- Neither the accessibility chords nor sysdiagnose may remain in the map.
for _, map in ipairs({ M.ctrlAltCmdHotkeys, capsLock }) do
    for name, spec in pairs(map) do
        local chord = sorted(spec[1])
        assert(not (chord == sorted({ "ctrl", "alt", "cmd" })
            and (spec[2] == "," or spec[2] == "." or spec[2] == "8")), name)
        assert(not (chord == sorted({ "ctrl", "alt", "cmd", "shift" })
            and spec[2] == "."), name)
    end
end
