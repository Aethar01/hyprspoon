-- hyprspoon/hooks.lua: Callbacks and shell commands run on changes, for status bars.

local M = {}
package.loaded["hyprspoon.hooks"] = M

local S = require("hyprspoon.state")
local Spaces = require("hyprspoon.spaces")
local Focus = require("hyprspoon.focus")

-- ---------------------------------------------------------------------------
-- What has focus
-- ---------------------------------------------------------------------------

-- What the hooks are given: { window = id,
-- app = name, workspace = name, display = UUID }, false for any there
-- isn't. Also the focused workspace's number. Accessibility calls only
-- when an app we don't track is in front: for its window and display.
local function focused()
    local win = Focus.currentWindow()
    local n = Spaces.focusedWorkspace(win)
    local app = win and win:application()
    return {
        window = win and win:id() or false,
        app = app and app:name() or false,
        workspace = n and Spaces.label(n) or false,
        display = n and Spaces.displayOf(n) or false,
    }, n
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------
--
-- S.cfg.on[event] is called with the focus table above plus `event`, and
-- S.cfg.exec[event] (a command or a list of them) runs through /bin/sh
-- with the same in HYPRSPOON_* environment variables. The events:
--   display    displays connected, disconnected or rearranged
--   workspace  any change to the workspaces: a switch, one made or
--              forgotten, a window joining or leaving one (each goes
--              through the save in hyprspoon/spaces.lua)
--   layout     a tiling pass moved tiles
--   focus      another window, workspace or display took focus
--
-- They're fired from the middle of switches, layouts and event taps, so
-- firing only notes the event; everything fired runs together on the next
-- turn of the run loop, each event once however often it fired, in the
-- order above. A focus event that would report the same focus as the last
-- one is dropped. Every configured event also runs once on start(), so a
-- status bar has something to show after a reload.

local EVENTS = { "display", "workspace", "layout", "focus" }

local pending = {}    -- event -> true, until the next turn
local timer = nil
local lastFocus = nil -- what the last focus event reported

-- Commands still running, by event and command, and the details for one
-- more run once they exit: a slow command is never started twice at once,
-- and never queues more than one rerun.
local running = {}
local rerun = {}

local ENV = { event = "HYPRSPOON_EVENT", window = "HYPRSPOON_WINDOW", app = "HYPRSPOON_APP",
    workspace = "HYPRSPOON_WORKSPACE", display = "HYPRSPOON_DISPLAY" }

local function launch(key, command, info)
    if running[key] then
        rerun[key] = info
        return
    end
    local ok, err = pcall(function()
        local task = hs.task.new("/bin/sh", function(code, _, stderr)
            running[key] = nil
            if code ~= 0 then
                print(string.format("hyprspoon: exec.%s exited %s: %s", info.event, tostring(code),
                    tostring(stderr)))
            end
            local again = rerun[key]
            rerun[key] = nil
            if again then launch(key, command, again) end
        end, { "-c", command })
        local env = task:environment()
        for field, name in pairs(ENV) do
            local value = info[field]
            env[name] = value and tostring(value) or ""
        end
        task:setEnvironment(env)
        running[key] = task:start()
    end)
    if not ok then
        running[key] = nil
        print(string.format("hyprspoon: exec.%s failed: %s", info.event, tostring(err)))
    end
end

local function run(event, info)
    local fn = (S.cfg.on or {})[event]
    if fn then
        -- A mistake in the user's callback mustn't stop the others, or
        -- anything of ours.
        local ok, err = xpcall(fn, debug.traceback, info)
        if not ok then print(string.format("hyprspoon: on.%s failed: %s", event, tostring(err))) end
    end
    local commands = (S.cfg.exec or {})[event]
    if type(commands) == "string" then commands = { commands } end
    for _, command in ipairs(commands or {}) do
        launch(event .. "\0" .. command, command, info)
    end
end

local function flush()
    timer = nil
    local fired = pending
    pending = {}
    local now = focused()
    if fired.focus then
        local key = table.concat({ tostring(now.window), tostring(now.workspace), tostring(now.display) }, "|")
        if key == lastFocus then fired.focus = nil else lastFocus = key end
    end
    for _, event in ipairs(EVENTS) do
        if fired[event] then
            local info = { event = event }
            for k, v in pairs(now) do info[k] = v end
            run(event, info)
        end
    end
end

-- Notes that `event` happened; cheap enough for any path, and nothing at
-- all when no hook wants it.
function M.fire(event)
    local cfg = S.cfg
    if not (cfg and ((cfg.on and cfg.on[event]) or (cfg.exec and cfg.exec[event]))) then return end
    pending[event] = true
    if not timer then timer = hs.timer.doAfter(0, flush) end
end

function M.start()
    for _, event in ipairs(EVENTS) do M.fire(event) end
end

-- Drops anything not yet run (reload, shutdown). Commands already running
-- finish, without their reruns.
function M.stop()
    if timer then timer:stop() end
    timer, pending, lastFocus, rerun = nil, {}, nil, {}
end

return M
