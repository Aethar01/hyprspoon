-- Live benchmark for the scrolling columns prototype (issue #18, phase 0):
-- is scrolling smooth with 6+ columns? Run inside Hammerspoon, e.g. from
-- its console:
--
--   wmScroll = dofile(spoon.hyprspoon.spoonPath .. '/tests/scroll_bench.lua')
--   wmScroll.run({ passes = 2 }, '/tmp/hyprspoon-scroll.json')
--
-- Before running:
--   * rebuild the native modules (make -C hyprspoon/native) and reload:
--     this needs hyprspoon.native.frames' stats()
--   * turn tiling on, and experimental.scrolling on for the workspace
--   * focus a tiled window on a workspace with 6 or more columns, from
--     several apps (a terminal, a browser, an editor, Finder...)
--
-- It focuses each column in turn, left to right and back (`passes` times),
-- the way directional focus does, waiting for each scroll to finish. It
-- moves and focuses your windows while it runs; don't touch anything until
-- it prints its summary. Options: passes (2), settle (seconds after each
-- scroll's animation, 0.25).
--
-- For each scroll it measures:
--   mainMs    time the main thread spent focusing and laying out (while
--             it runs, hotkeys and the pointer wait)
--   per app   animation frames stepped and how many ran late (the app took
--             longer than a 60Hz frame to take its moves, so a frame was
--             skipped), with the average and worst time a frame took
-- The summary's verdict is "smooth" when no more than 5% of frames ran
-- late in any app and mainMs stayed under a frame (16.7ms); watch it too,
-- since numbers can't see a window flash in its corner.
local M = {}

local FRAME_MS = 1000 / 60

function M.run(options, outPath)
    assert(not M.running, 'benchmark already running')
    options = options or {}
    local passes = options.passes or 2
    local settle = options.settle or 0.25

    local S = require('hyprspoon.state')
    local Util = require('hyprspoon.util')
    local Tree = require('hyprspoon.tree')
    local Focus = require('hyprspoon.focus')
    local Scroll = require('hyprspoon.scroll')
    local frames = Util.native('frames')
    assert(frames and frames.stats, 'hyprspoon.native.frames is missing stats(): rebuild it and reload')
    assert(S.tilingEnabled, 'turn tiling on first')

    local current = Focus.currentWindow()
    local _, _, key = Tree.findByID(current and current:id())
    assert(key, 'focus a tiled window first')
    assert(Scroll.enabled(key), 'experimental.scrolling is off for ' .. key)
    local leaves = Tree.leaves(S.trees[key])
    assert(#leaves >= 6, 'want 6 or more columns, have ' .. #leaves)

    local scroll = S.cfg.experimental.scrolling
    local duration = type(scroll) == 'table' and scroll.duration or 0.2

    -- Left to right and back, `passes` times, from the first column.
    local order = {}
    for _ = 1, passes do
        for i = 2, #leaves do order[#order + 1] = i end
        for i = #leaves - 1, 1, -1 do order[#order + 1] = i end
    end

    local names = {}
    local function appName(pid)
        if names[pid] == nil then
            local app = hs.application.applicationForPID(pid)
            names[pid] = app and app:name() or tostring(pid)
        end
        return names[pid]
    end

    local result = { columns = #leaves, duration = duration, scrolls = {} }
    M.running, M.done, M.result = true, false, result

    local function finish()
        local apps, mainMs, worstMain = {}, 0, 0
        for _, s in ipairs(result.scrolls) do
            mainMs = mainMs + s.mainMs
            worstMain = math.max(worstMain, s.mainMs)
            for name, a in pairs(s.apps) do
                local t = apps[name] or { steps = 0, late = 0, worstMs = 0, totalMs = 0 }
                apps[name] = t
                t.steps = t.steps + a.steps
                t.late = t.late + a.late
                t.totalMs = t.totalMs + a.avgMs * a.steps
                t.worstMs = math.max(t.worstMs, a.worstMs)
            end
        end
        local smooth = worstMain < FRAME_MS
        local lines = {}
        for name, t in pairs(apps) do
            t.lateShare = t.steps > 0 and t.late / t.steps or 0
            t.avgMs = t.steps > 0 and t.totalMs / t.steps or 0
            t.totalMs = nil
            if t.lateShare > 0.05 then smooth = false end
            lines[#lines + 1] = string.format('  %-24s %4d frames, %3d late (%4.1f%%), avg %5.2fms, worst %6.2fms',
                name, t.steps, t.late, t.lateShare * 100, t.avgMs, t.worstMs)
        end
        table.sort(lines)
        result.apps = apps
        result.mainMsAvg = #result.scrolls > 0 and mainMs / #result.scrolls or 0
        result.mainMsWorst = worstMain
        result.verdict = smooth and 'smooth' or 'not smooth'
        print(string.format('hyprspoon scroll bench: %d columns, %d scrolls of %.2fs: %s',
            #leaves, #result.scrolls, duration, result.verdict))
        print(string.format('  main thread per scroll: avg %.2fms, worst %.2fms',
            result.mainMsAvg, result.mainMsWorst))
        for _, line in ipairs(lines) do print(line) end
        if outPath then
            local file = io.open(outPath, 'w')
            if file then
                file:write(hs.json.encode(result, true))
                file:close()
            end
        end
        if current then Focus.focus(current) end
        M.running, M.done, M.timer = false, true, nil
    end

    local step = 0
    local function scrollTo(index)
        local leaf = leaves[index]
        local win = leaf and Util.winByID[leaf.windowID]
        if not win then return false end
        frames.stats(true)
        local t0 = hs.timer.absoluteTime()
        Focus.focus(win)
        Scroll.reveal(leaf.windowID)
        local mainMs = (hs.timer.absoluteTime() - t0) / 1e6
        M.timer = hs.timer.doAfter(duration + settle, function()
            local apps = {}
            for pid, s in pairs(frames.stats(true)) do apps[appName(pid)] = s end
            result.scrolls[#result.scrolls + 1] = { column = index, mainMs = mainMs, apps = apps }
            M.next()
        end)
        return true
    end

    function M.next()
        step = step + 1
        if step > #order then return finish() end
        if not scrollTo(order[step]) then return M.next() end
    end

    -- Start from the first column, unmeasured.
    local first = Util.winByID[leaves[1].windowID]
    if first then
        Focus.focus(first)
        Scroll.reveal(leaves[1].windowID)
    end
    M.timer = hs.timer.doAfter(duration + settle, function()
        frames.stats(true)
        M.next()
    end)
end

function M.stop()
    if M.timer then M.timer:stop() end
    M.running, M.timer = false, nil
end

return M
