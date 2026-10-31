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

-- Only the modifiers change, never the keys or the set of actions.
local function sorted(list)
    list = { table.unpack(list) }
    table.sort(list)
    return table.concat(list, "+")
end
local hyper = {
    alt = sorted({ "ctrl", "alt", "cmd" }),
    ["alt+shift"] = sorted({ "ctrl", "alt", "cmd", "shift" }),
    ["ctrl+alt"] = sorted({ "ctrl", "alt", "shift" }),
}
for name, spec in pairs(M.defaultHotkeys) do
    local got = assert(M.hyperHotkeys[name], name .. " must be in hyperHotkeys")
    assert(got[2] == spec[2], name .. " changed key")
    assert(sorted(got[1]) == hyper[mods(spec)], name .. " is " .. mods(got) .. " in hyperHotkeys")
end
for name in pairs(M.hyperHotkeys) do
    assert(M.defaultHotkeys[name], name .. " is only in hyperHotkeys")
end

-- No two actions share keys (hs.hotkey ignores the modifiers' order).
for _, map in ipairs({ M.defaultHotkeys, M.hyperHotkeys }) do
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
