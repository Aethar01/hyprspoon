-- hyprspoon/hooks.lua: Callbacks and shell commands run on changes, and query() for status bars.

local M = {}
package.loaded["hyprspoon.hooks"] = M

local S = require("hyprspoon.state")
local Spaces = require("hyprspoon.spaces")
local Focus = require("hyprspoon.focus")

-- ---------------------------------------------------------------------------
-- What has focus
-- ---------------------------------------------------------------------------

-- What the hooks are given and query() reports as `focus`: { window = id,
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
--   layout     a tiling pass applied a layout (frames may be unchanged)
--   focus      another window, workspace or display took focus
--
-- They're fired from the middle of switches, layouts and event taps, so
-- firing only notes the event; everything fired runs together on the next
-- turn of the run loop, each event once however often it fired, in the
-- order above. A focus event that would report the same focus as the last
-- one is dropped (window, workspace and display are compared). Hooks
-- receive the focus at delivery time, not the object that changed.
-- Every configured event also runs once on start(), so a status bar has
-- something to show after a reload.

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

-- ---------------------------------------------------------------------------
-- query()
-- ---------------------------------------------------------------------------
--
-- Everything a status bar shows, as a table for hs.json.encode. Its shape
-- doesn't change: every key is always there, false where there's no value,
-- and lists are lists (possibly empty). Call after start() so the options
-- and window filter are ready. App fields are names, not bundle IDs.
--   focus       as above: { window, app, workspace, display }
--   displays    { uuid, name, primary, workspace = the name of the one it
--               shows (a scratchpad over its own), focused }, the primary
--               first, then left to right
--   workspaces  { name, number = what gotoWorkspace takes, display = UUID
--               it's on, showing (also beneath a scratchpad), focused,
--               scratchpad, windows = ids, tiles first }, in use only, in
--               the order the menu bar shows them
--   windows     { id, app, title, workspace = name, floating, hidden =
--               parked or beneath a scratchpad, focused }, those with a
--               workspace and in the current Space's managed-window filter
--               (not hidden apps, minimized or full-screen windows). Grouped
--               by workspace in the order above. focus.window may be an
--               unmanaged window absent from this list. Hidden group
--               members are omitted, as they are from the overview.
-- Titles take an accessibility call per window.
function M.query()
    local focus, focusedN = focused()
    local out = { focus = focus, displays = {}, workspaces = {}, windows = {} }
    for _, ws in ipairs(Spaces.overview()) do
        local name = Spaces.label(ws.n)
        local ids = {}
        for i, entry in ipairs(ws.windows) do
            local id, win = entry.id, entry.win
            ids[i] = id
            local app = win:application()
            out.windows[#out.windows + 1] = {
                id = id,
                app = app and app:name() or false,
                title = win:title() or false,
                workspace = name,
                floating = S.autoFloat[id] == true,
                hidden = Spaces.isHidden(id) == true,
                focused = id == focus.window,
            }
        end
        out.workspaces[#out.workspaces + 1] = {
            name = name,
            number = ws.n,
            display = ws.display or false,
            showing = ws.showing == true,
            focused = ws.n == focusedN,
            scratchpad = Spaces.isScratchpad(ws.n),
            windows = ids,
        }
    end
    for i, d in ipairs(Spaces.displays()) do
        out.displays[i] = {
            uuid = d.uuid,
            name = d.screen:name() or false,
            primary = i == 1,
            workspace = d.n and Spaces.label(d.n) or false,
            focused = d.uuid == focus.display,
        }
    end
    return out
end

return M
