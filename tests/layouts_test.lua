-- Run with: lua tests/layouts_test.lua
-- Unit tests for hyprspoon/layouts.lua: which layout a workspace has (the
-- saved choice, then `workspaces`, then `layout`, then bsp),
-- scratchpads, and the order cycling goes through, with a stubbed spaces.
package.path = "./?.lua;" .. package.path

hs = { settings = { get = function() return nil end } }
package.loaded["hyprspoon.spaces"] = {
    label = function(n) return n > 100 and ({ "A", "S", "D" })[n - 100] or tostring(n) end,
    layoutScale = function(key) return tonumber(key:match("%d+")) > 100 and 0.95 or nil end,
}
local S = require("hyprspoon.state")
local Layouts = require("hyprspoon.layouts")
S.layouts = {}

local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
end

local function with(cfg, fn)
    local saved = S.cfg
    S.cfg = cfg
    S.layouts = {}
    local ok, err = pcall(fn)
    S.cfg = saved
    if not ok then error(err, 0) end
end

test("bsp unless something says otherwise", function()
    with({ scrolling = false }, function()
        assert(Layouts.of("ws1") == "bsp" and Layouts.of(nil) == "bsp")
    end)
    with({}, function() assert(Layouts.of("ws1") == "bsp") end)
end)

test("workspaces[n].layout, by number or name, and aliases", function()
    with({ workspaces = { [3] = { layout = "scrolling" }, ["5"] = { layout = "scroll" },
        A = { layout = "scrolling" }, [2] = { layout = "dwindle" } } }, function()
        assert(Layouts.of("ws3") == "scrolling" and Layouts.of("ws5") == "scrolling")
        assert(Layouts.of("ws2") == "bsp" and Layouts.of("ws1") == "bsp")
        assert(Layouts.of("ws101") == "scrolling", "scratchpads by name (A is ws101)")
        assert(Layouts.of("ws102") == "bsp", "other scratchpads keep the default")
    end)
end)

test("scrolling.workspaces is gone: bsp, and a note once per config", function()
    local printed, notes = print, {}
    print = function(m) notes[#notes + 1] = m end
    local ok, err = pcall(function()
        with({ scrolling = { workspaces = { 3 } } }, function()
            assert(Layouts.of("ws3") == "bsp" and Layouts.of("ws3") == "bsp")
        end)
        with({ scrolling = true }, function() assert(Layouts.of("ws1") == "bsp") end)
    end)
    print = printed
    assert(ok, err)
    assert(#notes == 2 and notes[1]:find("scrolling.workspaces is gone", 1, true))
end)

test("layout is every workspace's default", function()
    with({ layout = "scrolling" }, function()
        assert(Layouts.of("ws1") == "scrolling" and Layouts.of("ws10") == "scrolling")
        assert(Layouts.of("ws101") == "scrolling", "scratchpads too")
    end)
    with({ layout = "dwindle" }, function() assert(Layouts.of("ws1") == "bsp") end)
end)

test("precedence: saved choice, workspaces, layout, bsp", function()
    with({ layout = "scrolling",
        workspaces = { [2] = { layout = "bsp" }, [4] = { layout = "scrolling" } } }, function()
        assert(Layouts.of("ws1") == "scrolling", "layout")
        assert(Layouts.of("ws2") == "bsp", "workspaces over layout")
        assert(Layouts.of("ws4") == "scrolling")
        S.layouts.ws2, S.layouts.ws4 = "scrolling", "bsp"
        assert(Layouts.of("ws2") == "scrolling" and Layouts.of("ws4") == "bsp", "the saved choice wins")
        S.layouts.ws101 = "scrolling"
        assert(Layouts.of("ws101") == "scrolling", "a scratchpad's too")
        S.layouts.ws1 = "master"
        assert(Layouts.of("ws1") == "scrolling", "a saved name we no longer have is ignored")
    end)
end)

test("an unknown name in the options falls through", function()
    with({ layout = "scrolling", workspaces = { [1] = { layout = "spiral" } } }, function()
        local printed = print
        print = function() end
        local ok = pcall(function() assert(Layouts.of("ws1") == "scrolling") end)
        print = printed
        assert(ok)
    end)
end)

test("set keeps a choice, returns the layout it had, scratchpads too, refuses unknown names", function()
    with({ workspaces = { [1] = { layout = "scrolling" } } }, function()
        assert(Layouts.set("ws1", "bsp") == "scrolling" and Layouts.of("ws1") == "bsp")
        assert(S.layouts.ws1 == "bsp")
        assert(Layouts.set("ws2", "scroll") == "bsp" and S.layouts.ws2 == "scrolling", "aliases")
        assert(Layouts.set("ws2", "master") == nil and S.layouts.ws2 == "scrolling")
        assert(Layouts.set("ws101", "scrolling") == "bsp" and S.layouts.ws101 == "scrolling")
        assert(Layouts.set(nil, "bsp") == nil)
    end)
end)

test("next goes through the names in order and round", function()
    with({}, function()
        assert(Layouts.next("ws1") == "scrolling")
        S.layouts.ws1 = "scrolling"
        assert(Layouts.next("ws1") == "bsp")
        table.insert(Layouts.names, "master")
        assert(Layouts.next("ws1") == "master" and Layouts.known("master") == "master")
        S.layouts.ws1 = "master"
        assert(Layouts.next("ws1") == "bsp")
        table.remove(Layouts.names)
    end)
end)

test("configured: whether the options put a workspace in a layout", function()
    with({ scrolling = false }, function() assert(not Layouts.configured("scrolling")) end)
    with({ scrolling = true }, function() assert(not Layouts.configured("scrolling")) end)
    with({ layout = "scroll" }, function() assert(Layouts.configured("scrolling")) end)
    with({}, function()
        S.layouts.ws2 = "scrolling"
        assert(Layouts.configured("scrolling"), "a choice kept over a reload")
    end)
    with({ workspaces = { [3] = { layout = "scrolling" } } }, function()
        assert(Layouts.configured("scrolling") and not Layouts.configured("bsp"))
    end)
end)

print("Layouts tests passed")
