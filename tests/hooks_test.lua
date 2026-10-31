-- Run with: lua tests/hooks_test.lua
-- Unit tests for hyprspoon/hooks.lua: hooks run once per turn of the run
-- loop and never inline, a failing callback breaks nothing, commands don't
-- pile up, and query() keeps one shape, with a stubbed `hs`.
package.path = "./?.lua;" .. package.path

-- The run loop: doAfter(0) callbacks wait for turn().
local queue = {}
local function turn()
    local due = queue
    queue = {}
    for _, t in ipairs(due) do
        if not t.stopped then t.fn() end
    end
end

-- Tasks started, each finished by calling exit().
local tasks = {}

hs = {
    settings = { get = function() return nil end, set = function() end },
    timer = {
        doAfter = function(_, fn)
            local t = { fn = fn }
            function t:stop() self.stopped = true end
            queue[#queue + 1] = t
            return t
        end,
    },
    task = {
        new = function(path, callback, args)
            local task = { path = path, args = args, env = { PATH = "/usr/bin:/bin" } }
            function task:environment() return self.env end
            function task:setEnvironment(env) self.env = env end
            function task:start() tasks[#tasks + 1] = self return self end
            function task.exit(code) callback(code or 0, "", "") end
            return task
        end,
    },
}

local function win(id, app, title)
    return {
        id = function() return id end,
        application = function() return { name = function() return app end } end,
        title = function() return title end,
        screen = function() return nil end,
    }
end

local focusedWin = win(11, "Terminal", "zsh")
local focusedN = 1
package.loaded["hyprspoon.focus"] = { currentWindow = function() return focusedWin end }
package.loaded["hyprspoon.spaces"] = {
    focusedWorkspace = function() return focusedN end,
    label = function(n) return n == 101 and "A" or tostring(n) end,
    displayOf = function() return "LAPTOP" end,
    isHidden = function(id) return id == 13 end,
    isScratchpad = function(n) return n > 100 end,
    overview = function()
        return {
            { n = 1, display = "LAPTOP", showing = true, windows = {
                { id = 11, win = win(11, "Terminal", "zsh") },
                { id = 12, win = win(12, "Safari", "docs") },
            } },
            { n = 2, display = "LAPTOP", showing = false, windows = {
                { id = 13, win = win(13, "Mail", "Inbox") },
            } },
            { n = 101, display = "LAPTOP", showing = false, windows = {} },
        }
    end,
    displays = function()
        return { { uuid = "LAPTOP", n = 1, screen = { name = function() return "Built-in Retina Display" end } } }
    end,
}

local S = require("hyprspoon.state")
S.autoFloat = { [12] = true }
local Hooks = require("hyprspoon.hooks")

local calls = {}
local function record(e) calls[#calls + 1] = e end

-- Nothing configured: firing schedules nothing.
S.cfg = { on = {}, exec = {} }
Hooks.fire("workspace")
assert(#queue == 0, "no hooks, no timer")

-- Fired many times in one turn: one call each, on the next turn, display
-- before workspace before layout before focus.
S.cfg = { on = { workspace = record, focus = record, layout = record, display = record }, exec = {} }
for _ = 1, 5 do
    Hooks.fire("focus")
    Hooks.fire("layout")
    Hooks.fire("workspace")
end
Hooks.fire("display")
assert(#calls == 0, "never called inline")
assert(#queue == 1, "one timer for the turn")
turn()
assert(#calls == 4, "each event once")
assert(calls[1].event == "display" and calls[2].event == "workspace"
    and calls[3].event == "layout" and calls[4].event == "focus")
local e = calls[4]
assert(e.window == 11 and e.app == "Terminal" and e.workspace == "1" and e.display == "LAPTOP")

-- The same focus again isn't reported; a change is.
calls = {}
Hooks.fire("focus")
turn()
assert(#calls == 0, "unchanged focus is dropped")
focusedWin, focusedN = nil, 2
Hooks.fire("focus")
turn()
assert(#calls == 1 and calls[1].window == false and calls[1].app == false and calls[1].workspace == "2",
    "nothing focused is false, not nil")

-- A failing callback is reported and the others still run, then and later.
local printed = {}
local realPrint = print
print = function(s) printed[#printed + 1] = s end
calls = {}
S.cfg.on.workspace = function() error("oops") end
Hooks.fire("workspace")
Hooks.fire("layout")
turn()
print = realPrint
assert(#calls == 1 and calls[1].event == "layout", "the layout hook still ran")
assert(printed[1]:find("on.workspace failed", 1, true) and printed[1]:find("oops", 1, true))
Hooks.fire("layout")
turn()
assert(#calls == 2, "still firing after an error")

-- Commands run through /bin/sh with the details in the environment; one
-- still running gets a single rerun, with the latest details.
S.cfg = { on = {}, exec = { workspace = "sketchybar --trigger ws", focus = { "a", "b" } } }
focusedWin, focusedN = win(12, "Safari", "docs"), 1
Hooks.fire("workspace")
turn()
assert(#tasks == 1)
local t = tasks[1]
assert(t.path == "/bin/sh" and t.args[1] == "-c" and t.args[2] == "sketchybar --trigger ws")
assert(t.env.HYPRSPOON_EVENT == "workspace" and t.env.HYPRSPOON_WORKSPACE == "1"
    and t.env.HYPRSPOON_WINDOW == "12" and t.env.HYPRSPOON_APP == "Safari"
    and t.env.HYPRSPOON_DISPLAY == "LAPTOP" and t.env.PATH == "/usr/bin:/bin")
for n = 2, 4 do
    focusedN = n
    Hooks.fire("workspace")
    turn()
end
assert(#tasks == 1, "not started again while running")
t.exit()
assert(#tasks == 2 and tasks[2].env.HYPRSPOON_WORKSPACE == "4", "one rerun, with the latest")
tasks[2].exit()
assert(#tasks == 2, "no more reruns")
Hooks.fire("focus")
turn()
assert(#tasks == 4 and tasks[3].args[2] == "a" and tasks[4].args[2] == "b", "a list runs each")

-- stop() drops what hasn't run.
Hooks.fire("workspace")
Hooks.stop()
turn()
assert(#tasks == 4, "nothing runs after stop")

-- query(): every key there, false where there's no value.
focusedWin, focusedN = win(11, "Terminal", "zsh"), 1
local q = Hooks.query()
assert(q.focus.window == 11 and q.focus.app == "Terminal" and q.focus.workspace == "1"
    and q.focus.display == "LAPTOP")
assert(#q.displays == 1)
local d = q.displays[1]
assert(d.uuid == "LAPTOP" and d.name == "Built-in Retina Display" and d.primary == true
    and d.workspace == "1" and d.focused == true)
assert(#q.workspaces == 3)
local w1, w2, wa = q.workspaces[1], q.workspaces[2], q.workspaces[3]
assert(w1.name == "1" and w1.number == 1 and w1.display == "LAPTOP" and w1.showing == true
    and w1.focused == true and w1.scratchpad == false)
assert(#w1.windows == 2 and w1.windows[1] == 11 and w1.windows[2] == 12)
assert(w2.focused == false and w2.showing == false and #w2.windows == 1)
assert(wa.name == "A" and wa.number == 101 and wa.scratchpad == true and #wa.windows == 0)
assert(#q.windows == 3)
local byID = {}
for _, w in ipairs(q.windows) do byID[w.id] = w end
assert(byID[11].focused == true and byID[11].floating == false and byID[11].hidden == false
    and byID[11].app == "Terminal" and byID[11].title == "zsh" and byID[11].workspace == "1")
assert(byID[12].floating == true and byID[12].focused == false)
assert(byID[13].hidden == true and byID[13].workspace == "2")

-- The same keys whatever the state.
local function keys(t)
    local list = {}
    for k in pairs(t) do list[#list + 1] = k end
    table.sort(list)
    return table.concat(list, ",")
end
focusedWin, focusedN = nil, nil
local empty = Hooks.query()
assert(keys(empty) == keys(q))
assert(keys(empty.focus) == keys(q.focus), "focus keeps its keys with nothing focused")
assert(empty.focus.window == false and empty.focus.workspace == false and empty.focus.display == false)
assert(keys(empty.displays[1]) == keys(d) and empty.displays[1].focused == false)
assert(keys(empty.workspaces[1]) == keys(w1) and empty.workspaces[1].focused == false)

print("Hooks tests passed")
