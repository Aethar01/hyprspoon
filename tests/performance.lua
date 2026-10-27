-- Live, non-focus-changing benchmark. Run through Hammerspoon's hs CLI:
-- wmPerf = dofile(spoon.hyprspoon.spoonPath .. '/tests/performance.lua'); wmPerf.run(20, '/path/out.json')
-- The result is written to the given path as JSON once wmPerf.done is true
-- (and kept in wmPerf.result). Returning it through `hs -c` can hang.
-- Each case runs once untimed first, so samples measure warm calls.
local M = {}

-- Find internal helpers without adding profiling overhead to production.
-- Returns { upvalues = { name = fn }, modules = { Name = module table } }:
-- module-local functions that no module exports (e.g. neighbourInDirection in
-- hyprspoon/actions.lua) are reached by walking upvalues from the exported functions
-- of every loaded wm.* module.
local function internals()
    local upvalues, modules, seen = {}, {}, {}
    local function visit(fn)
        if seen[fn] then return end
        seen[fn] = true
        for i = 1, math.huge do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if type(value) == 'function' then
                upvalues[name] = value
                visit(value)
            end
        end
    end
    for name, module in pairs(package.loaded) do
        local short = type(name) == 'string' and name:match('^hyprspoon%.(.+)$')
        if short and type(module) == 'table' then
            modules[short:sub(1, 1):upper() .. short:sub(2)] = module
            for _, fn in pairs(module) do
                if type(fn) == 'function' then visit(fn) end
            end
        end
    end
    return { upvalues = upvalues, modules = modules }
end

function M.run(rounds, outPath)
    assert(not M.timer, 'benchmark already running')
    rounds = rounds or 20
    local wm = require('hyprspoon')
    assert(wm.isTiling(), 'enable tiling before benchmarking')
    local found = internals()
    local m, up = found.modules, found.upvalues
    assert(m.Layout and m.Discover and m.Focus and m.Ffm and m.State and m.Util,
        'hyprspoon modules are not loaded')
    local S, Util = m.State, m.Util
    assert(up.neighbourInDirection, 'neighbourInDirection not reachable from exports')
    local cases = {}
    -- `setup` runs untimed before each sample.
    local function add(name, fn, setup)
        cases[#cases + 1] = { name = name, fn = fn, setup = setup, samples = {} }
    end
    add('layout.unchanged', function() m.Layout.tileNow(true) end)
    -- A full pass: reconcile every tree, but every tile is already applied.
    add('layout.forced', function() m.Layout.tileNow(false) end)
    -- As after a reload: read each window's frame to confirm it's in place.
    add('layout.verify', function() m.Layout.tileNow(false) end, function() S.applied = {} end)
    add('discovery.group', function() m.Discover.windowsByScreen() end)
    -- As after the filter's window list changes or windows move displays.
    add('discovery.cold', function() m.Discover.windowsByScreen() end, function()
        S.windowInfo = {}
        Util.forgetManagedWindows()
    end)
    add('snapshot.fresh', function() m.Focus.windowSnapshot(true) end)
    add('snapshot.cached', function() m.Focus.windowSnapshot() end)
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
        add('focus.current', function() m.Focus.currentWindow() end)
        for _, direction in ipairs({'left', 'right', 'up', 'down'}) do
            add('focus.neighbour.' .. direction, function()
                up.neighbourInDirection(win, direction, true)
            end)
        end
    end
    -- Hover over the focused window, so focus-follows-mouse has nothing to do.
    -- Focus is only recorded on a focus event, which a reload doesn't send.
    if win and not S.ffmFocusedID and Util.windowKind(win) ~= 'ignored' then
        m.Focus.noteFocus(win)
    end
    local focusedID = S.ffmFocusedID
    local hovered = nil
    for _, entry in ipairs(m.Focus.windowSnapshot(true)) do
        if entry.id == focusedID then hovered = entry end
    end
    local point = hovered and { x = hovered.frame.x + hovered.frame.w / 2,
        y = hovered.frame.y + hovered.frame.h / 2 }
    if S.cfg.focusFollowsMouse and point and m.Focus.snapshotEntryAt(point) == hovered then
        local event = hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.mouseMoved, point)
        local function hover()
            -- Focus moved meanwhile: the hover would start focusing a window.
            if S.ffmFocusedID == focusedID then m.Ffm.onMouseMoved(event) end
        end
        add('ffm.sameWindow', hover, function() S.ffmLastWindow = hovered end)
        add('ffm.crossing', hover, function() S.ffmLastWindow = nil end)
    end
    local index, round = 1, 0
    M.done, M.result = false, nil
    local function finish(result)
        M.timer:stop(); M.timer = nil
        M.result, M.done = result, true
        if outPath then
            local file = assert(io.open(outPath, 'w'))
            file:write(hs.json.encode(result, true))
            file:close()
        end
    end
    M.timer = hs.timer.doEvery(0.02, function()
        local case = cases[index]
        if case.setup then case.setup() end
        local start = hs.timer.absoluteTime()
        local ok, err = pcall(case.fn)
        local ms = (hs.timer.absoluteTime() - start) / 1e6
        if not ok then
            finish({ error = tostring(err), case = case.name })
            return
        end
        if round > 0 then case.samples[#case.samples + 1] = ms end
        index = index + 1
        if index > #cases then index, round = 1, round + 1 end
        if round <= rounds then return end
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
        finish(result)
        print('WM performance benchmark complete')
    end)
end

return M
