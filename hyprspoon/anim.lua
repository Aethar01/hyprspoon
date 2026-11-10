-- hyprspoon/anim.lua: How animations move (the `animations` option).
--
-- Each kind of animation is on a spring (Hyprland's mass, stiffness and
-- dampening) or eased over a duration. The top-level fields of
-- `animations` set every kind, and a kind's own table overrides them for
-- it; `fadeIn` follows `windows` before the top level. The older options
-- count below both: slide.mass/stiffness/damping for workspaces, and
-- tiling.animationDuration for windows.
--
-- The kinds:
--   workspaces  workspace and scratchpad slides (hyprspoon/slide.lua)
--   windows     retiles: the window animations, and with
--               experimental.captureRetile the pictures gliding, in
--               every layout (scrolling columns' scrolls too)
--   fadeIn      new windows fading in as they pop in, and the pictures
--               fading to the real windows once settled
--               (experimental.captureRetile)

local M = {}
package.loaded["hyprspoon.anim"] = M

local S = require("hyprspoon.state")

local FIELDS = { "curve", "duration", "mass", "stiffness", "damping" }
local CURVES = { spring = true, ease = true }

local DEFAULTS = {
    workspaces = { curve = "spring", duration = 0.3, mass = 0.6, stiffness = 800, damping = 38 },
    windows = { curve = "ease", duration = 0, mass = 0.6, stiffness = 800, damping = 38 },
}
DEFAULTS.fadeIn = DEFAULTS.windows

-- Reported once per bad setting.
local warned = {}

local function valid(field, v)
    if field == "curve" then return CURVES[v] == true end
    return type(v) == "number" and v >= 0 and (field == "duration" or v > 0)
end

local function older(kind)
    if kind == "workspaces" then
        local s = type(S.cfg.slide) == "table" and S.cfg.slide or {}
        return { mass = s.mass, stiffness = s.stiffness, damping = s.damping }
    end
    return { duration = S.cfg.tiling and S.cfg.tiling.animationDuration }
end

-- How `kind` moves: { curve = "spring" or "ease", duration =, mass =,
-- stiffness =, damping = }.
function M.get(kind)
    local a = S.cfg and type(S.cfg.animations) == "table" and S.cfg.animations or {}
    local own = function(name) return type(a[name]) == "table" and a[name] or {} end
    local chain = { own(kind) }
    if kind == "fadeIn" then chain[#chain + 1] = own("windows") end
    chain[#chain + 1] = a
    chain[#chain + 1] = older(kind)
    local out = {}
    for _, field in ipairs(FIELDS) do
        for _, t in ipairs(chain) do
            local v = t[field]
            if v ~= nil then
                if valid(field, v) then
                    out[field] = v
                    break
                end
                local key = kind .. "." .. field .. "=" .. tostring(v)
                if not warned[key] then
                    warned[key] = true
                    print(string.format("hyprspoon: animations: ignoring %s = %s for %s",
                        field, tostring(v), kind))
                end
            end
        end
        if out[field] == nil then out[field] = DEFAULTS[kind][field] end
    end
    return out
end

-- Seconds window animations take; 0 when they're off. A spring's own
-- length decides how long its pictures glide, but windows moved through
-- accessibility always ease over this.
function M.windowDuration()
    return M.get("windows").duration
end

return M
