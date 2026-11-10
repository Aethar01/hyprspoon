-- Run with: lua tests/layouts_test.lua
-- Unit tests for hyprspoon/layouts.lua: which layout a workspace has (the
-- saved choice, then `workspaces`, then `scrolling.workspaces`, then bsp),
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
        assert(Layouts.of("ws101") == "bsp", "scratchpads never scroll, named by label or not")
    end)
end)

test("scrolling.workspaces still picks workspaces", function()
    with({ scrolling = true }, function()
        assert(Layouts.of("ws1") == "scrolling" and Layouts.of("ws10") == "scrolling")
        assert(Layouts.of("ws101") == "bsp")
    end)
    with({ scrolling = { workspaces = { 3, "A" } } }, function()
        assert(Layouts.of("ws3") == "scrolling" and Layouts.of("ws4") == "bsp")
        assert(Layouts.of("ws101") == "bsp", "A is a scratchpad")
    end)
    with({ experimental = { scrolling = { workspaces = { 2 } } } }, function()
        assert(Layouts.of("ws2") == "scrolling" and Layouts.of("ws3") == "bsp")
    end)
end)

test("precedence: saved choice, workspaces, scrolling.workspaces, bsp", function()
    with({ scrolling = { workspaces = { 1, 2, 3 } },
        workspaces = { [2] = { layout = "bsp" }, [4] = { layout = "scrolling" } } }, function()
        assert(Layouts.of("ws1") == "scrolling", "the list")
        assert(Layouts.of("ws2") == "bsp", "workspaces over the list")
        assert(Layouts.of("ws4") == "scrolling" and Layouts.of("ws5") == "bsp")
        S.layouts.ws2, S.layouts.ws4 = "scrolling", "bsp"
        assert(Layouts.of("ws2") == "scrolling" and Layouts.of("ws4") == "bsp", "the saved choice wins")
        S.layouts.ws101 = "scrolling"
        assert(Layouts.of("ws101") == "bsp", "even a stale one on a scratchpad")
        S.layouts.ws1 = "master"
        assert(Layouts.of("ws1") == "scrolling", "a saved name we no longer have is ignored")
    end)
end)

test("an unknown name in the options falls through", function()
    with({ scrolling = { workspaces = { 1 } }, workspaces = { [1] = { layout = "spiral" } } }, function()
        local printed = print
        print = function() end
        local ok = pcall(function() assert(Layouts.of("ws1") == "scrolling") end)
        print = printed
        assert(ok)
    end)
end)

test("set keeps a choice, returns the layout it had, refuses scratchpads and unknown names", function()
    with({ scrolling = { workspaces = { 1 } } }, function()
        assert(Layouts.set("ws1", "bsp") == "scrolling" and Layouts.of("ws1") == "bsp")
        assert(S.layouts.ws1 == "bsp")
        assert(Layouts.set("ws2", "scroll") == "bsp" and S.layouts.ws2 == "scrolling", "aliases")
        assert(Layouts.set("ws2", "master") == nil and S.layouts.ws2 == "scrolling")
        assert(Layouts.set("ws101", "scrolling") == nil and S.layouts.ws101 == nil)
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
    with({ scrolling = true }, function() assert(Layouts.configured("scrolling")) end)
    with({ workspaces = { [3] = { layout = "scrolling" } } }, function()
        assert(Layouts.configured("scrolling") and not Layouts.configured("bsp"))
    end)
end)

print("Layouts tests passed")
