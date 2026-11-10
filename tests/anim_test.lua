-- Run with: lua tests/anim_test.lua
-- Unit tests for hyprspoon/anim.lua: the `animations` option sets every
-- kind at once or each on its own, over the older slide spring and
-- tiling.animationDuration, with a stubbed `hs`.
package.path = "./?.lua;" .. package.path

hs = { settings = { get = function() return nil end, set = function() end } }

local S = require("hyprspoon.state")
local Anim = require("hyprspoon.anim")

local printed = {}
print = function(s) printed[#printed + 1] = s end

local function config(c)
    S.cfg = {
        slide = c.slide or { mass = 0.6, stiffness = 800, damping = 38 },
        tiling = { animationDuration = c.animationDuration or 0 },
        animations = c.animations or {},
    }
end

local function check(kind, want)
    local got = Anim.get(kind)
    for k, v in pairs(want) do
        assert(got[k] == v, string.format("%s.%s: want %s, got %s", kind, k, tostring(v), tostring(got[k])))
    end
end

-- Defaults: workspaces spring as before; windows ease over
-- tiling.animationDuration, off when it's 0.
config({})
check("workspaces", { curve = "spring", mass = 0.6, stiffness = 800, damping = 38 })
check("windows", { curve = "ease", duration = 0 })
check("fadeIn", { curve = "ease", duration = 0 })
assert(Anim.windowDuration() == 0)

-- The older options still count.
config({ animationDuration = 0.2, slide = { mass = 1, stiffness = 500, damping = 20 } })
check("workspaces", { curve = "spring", mass = 1, stiffness = 500, damping = 20 })
check("windows", { duration = 0.2 })
check("fadeIn", { duration = 0.2 })

-- The top level sets every kind, over the older options.
config({
    animationDuration = 0.2,
    animations = { curve = "ease", duration = 0.4, stiffness = 300 },
})
check("workspaces", { curve = "ease", duration = 0.4, stiffness = 300, mass = 0.6 })
check("windows", { curve = "ease", duration = 0.4, stiffness = 300 })
check("fadeIn", { curve = "ease", duration = 0.4 })
assert(Anim.windowDuration() == 0.4)

-- A kind's own table overrides the top level for it alone; fadeIn
-- follows windows before the top level.
config({
    animationDuration = 0.2,
    animations = {
        curve = "spring", stiffness = 600,
        windows = { curve = "ease", duration = 0.15 },
        fadeIn = { duration = 0.3 },
    },
})
check("workspaces", { curve = "spring", stiffness = 600, damping = 38 })
check("windows", { curve = "ease", duration = 0.15, stiffness = 600 })
check("fadeIn", { curve = "ease", duration = 0.3, stiffness = 600 })

-- A bad value is reported once and skipped for the next in line.
config({ animationDuration = 0.2, animations = { curve = "bounce", windows = { duration = -1 } } })
check("workspaces", { curve = "spring" })
check("windows", { curve = "ease", duration = 0.2 })
Anim.get("windows")
local reports = 0
for _, line in ipairs(printed) do
    if line:find("animations: ignoring", 1, true) then reports = reports + 1 end
end
assert(reports == 3, "want 3 reports (curve for workspaces and windows, duration), got " .. reports)

io.write("Animation tests passed\n")
