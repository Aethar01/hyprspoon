-- Live, non-focus-changing benchmark. Run through Hammerspoon's hs CLI:
-- wmPerf = dofile(hs.configdir .. '/tests/performance.lua'); wmPerf.run()
-- Then inspect wmPerf.result once wmPerf.done is true.
local M = {}

-- Find internal helpers without adding profiling overhead to production.
local function internals(root)
    local found, seen = {}, {}
    local function visit(fn)
        if seen[fn] then return end
        seen[fn] = true
        for i = 1, math.huge do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if type(value) == 'function' then
                found[name] = value
                visit(value)
            end
        end
    end
    for _, fn in pairs(root) do if type(fn) == 'function' then visit(fn) end end
    return found
end

function M.run(rounds)
    assert(not M.timer, 'benchmark already running')
    rounds = rounds or 20
    local wm = require('wm')
    assert(wm.isTiling(), 'enable tiling before benchmarking')
    local f = internals(wm)
    local cases = {}
    local function add(name, fn) cases[#cases + 1] = { name = name, fn = fn, samples = {} } end
    add('layout.unchanged', function() f.bspTileNow(true) end)
    add('discovery.group', function() f.bspWindowsByScreen() end)
    add('snapshot.fresh', function() f.windowSnapshot(true) end)
    add('snapshot.cached', function() f.windowSnapshot() end)
    add('windows.ordered', function() hs.window.orderedWindows() end)
    add('spaces.active', function() hs.spaces.activeSpaceOnScreen(hs.screen.mainScreen()) end)
    local windows = hs.window.orderedWindows()
    local apps = {}
    for _, win in ipairs(windows) do
        local app = win:application()
        if app and not apps[app:pid()] then
            apps[app:pid()] = true
            local prefix = app:name() .. '.'
            add(prefix .. 'allWindows', function() app:allWindows() end)
            for _, method in ipairs({'id', 'frame', 'screen', 'isVisible', 'isFullScreen'}) do
                add(prefix .. method, function() win[method](win) end)
            end
        end
    end
    local win = hs.window.focusedWindow()
    if win then
        add('focus.current', function() f.currentWindow() end)
        add('focus.neighbour', function() f.neighbourInDirection(win, 'up') end)
    end
    local index, round = 1, 1
    M.done, M.result = false, nil
    M.timer = hs.timer.doEvery(0.02, function()
        local case = cases[index]
        local start = hs.timer.absoluteTime()
        local ok, err = pcall(case.fn)
        local ms = (hs.timer.absoluteTime() - start) / 1e6
        if not ok then
            M.timer:stop(); M.timer = nil
            M.result, M.done = { error = tostring(err), case = case.name }, true
            return
        end
        case.samples[#case.samples + 1] = ms
        index = index + 1
        if index > #cases then index, round = 1, round + 1 end
        if round <= rounds then return end
        M.timer:stop(); M.timer = nil
        local result = { windows = #windows, rounds = rounds, timings = {} }
        for _, c in ipairs(cases) do
            table.sort(c.samples)
            local total = 0
            for _, value in ipairs(c.samples) do total = total + value end
            result.timings[c.name] = {
                median_ms = c.samples[math.ceil(#c.samples / 2)],
                p95_ms = c.samples[math.ceil(#c.samples * 0.95)],
                max_ms = c.samples[#c.samples], mean_ms = total / #c.samples,
            }
        end
        M.result, M.done = result, true
        print('WM performance benchmark complete')
    end)
end

return M
