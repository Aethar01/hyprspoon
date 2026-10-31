-- tests/tabs_probe.lua: what Hammerspoon sees of native tabs (#11), next to
-- tests/tabs_probe.m's WindowServer view. Runs inside Hammerspoon:
--
--   hs -c 'return dofile("/path/to/tests/tabs_probe.lua").list()' </dev/null
--   hs -c 'return dofile("/path/to/tests/tabs_probe.lua").list({"TextEdit"})' </dev/null
--
-- (hs -c waits on stdin when it isn't a terminal, hence </dev/null.)
--
-- list(apps) is read-only. For each app it prints hs.application:allWindows()
-- (what hs.window.allWindows() is built from), what hyprspoon's running
-- window filter reports, and each window's tab bar (AXTabGroup) with its
-- buttons.
--
-- press(windowID, n) presses the n-th tab button of that window's tab bar
-- (default: the one after the selected tab, as groupNext would) and prints the wall-clock time just before and after, to line up with
-- `tabs_probe -w`. Only use it on windows you opened for the test.

local P = {}

local DEFAULT_APPS = { "Finder", "TextEdit", "Terminal", "Ghostty", "Preview", "Xcode" }

local function attr(el, name)
    local ok, v = pcall(function() return el:attributeValue(name) end)
    if ok then return v end
end

-- The first AXTabGroup under a window, breadth first a few levels deep:
-- apps put the tab bar in the title bar, a toolbar or a split group.
local function tabGroup(axWin)
    local level = { axWin }
    for depth = 0, 4 do
        local nextLevel = {}
        for _, el in ipairs(level) do
            if depth > 0 and attr(el, "AXRole") == "AXTabGroup" then return el end
            for _, child in ipairs(attr(el, "AXChildren") or {}) do nextLevel[#nextLevel + 1] = child end
        end
        level = nextLevel
    end
end

local function frameText(f)
    return string.format("%d,%d %dx%d", f.x, f.y, f.w, f.h)
end

local function filterIDs()
    local ok, S = pcall(require, "hyprspoon.state")
    local filter = ok and S.running and S.running.windowFilter
    if not filter then return nil end
    local ids = {}
    for _, w in ipairs(filter:getWindows()) do ids[w:id()] = true end
    return ids
end

function P.list(apps)
    local out = {}
    local function say(...) out[#out + 1] = string.format(...) end
    local inFilter = filterIDs()
    for _, name in ipairs(apps or DEFAULT_APPS) do
        local app = hs.application.get(name)
        if not app then
            say("%s: not running", name)
        else
            local wins = app:allWindows()
            say("%s (pid %d): %d windows from allWindows()", name, app:pid(), #wins)
            for _, w in ipairs(wins) do
                say("  %-7d vis=%-5s std=%-5s min=%-5s filter=%-5s %-20s %q", w:id(), tostring(w:isVisible()),
                    tostring(w:isStandard()), tostring(w:isMinimized()),
                    inFilter and tostring(inFilter[w:id()] == true) or "-", frameText(w:frame()), w:title())
                local axWin = hs.axuielement.windowElement(w)
                local group = axWin and tabGroup(axWin)
                if group then
                    local tabs = attr(group, "AXTabs")
                    local kids = attr(group, "AXChildren") or {}
                    say("    tab group: AXTabs %s, %d children", tabs and #tabs or "-", #kids)
                    for i, el in ipairs(kids) do
                        local actions = el:actionNames() or {}
                        say("      %d %s%s value=%s actions=%s %q", i, attr(el, "AXRole") or "?",
                            attr(el, "AXSubrole") and ("/" .. attr(el, "AXSubrole")) or "",
                            tostring(attr(el, "AXValue")), table.concat(actions, ","),
                            attr(el, "AXTitle") or attr(el, "AXDescription") or "")
                    end
                end
            end
        end
    end
    return table.concat(out, "\n")
end

function P.press(windowID, n)
    local w = hs.window.get(windowID)
    local axWin = w and hs.axuielement.windowElement(w)
    local group = axWin and tabGroup(axWin)
    if not group then return "no tab group for window " .. tostring(windowID) end
    -- The tab bar also holds a "new tab" AXButton; tabs are AXTabButtons.
    local tabs, selected = {}, nil
    for _, el in ipairs(attr(group, "AXChildren") or {}) do
        if attr(el, "AXSubrole") == "AXTabButton" then
            tabs[#tabs + 1] = el
            -- Unselected tabs read 0, false or nothing, depending on the app.
            local v = attr(el, "AXValue")
            if v == true or v == 1 then selected = #tabs end
        end
    end
    if #tabs == 0 then return "no tab buttons" end
    n = n or ((selected or 0) % #tabs) + 1
    local button = tabs[n]
    if not button then return "no tab button " .. tostring(n) end
    local before = hs.timer.secondsSinceEpoch()
    local ok, err = pcall(function() return button:performAction("AXPress") end)
    local after = hs.timer.secondsSinceEpoch()
    return string.format("%.3f press start\n%.3f press returned ok=%s %s", before, after, tostring(ok),
        ok and "" or tostring(err))
end

return P
