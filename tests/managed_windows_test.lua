-- Util.managedWindows: the filter's windows plus the shown native windows
-- that discovery found in an app's own window list but the filter misses
-- (the window left holding the other tabs after a tear-off).
package.path = "./?.lua;" .. package.path

hs = { axuielement = {}, timer = { secondsSinceEpoch = function() return 0 end,
    delayed = { new = function() return { start = function() end, stop = function() end } end } } }

local function win(id, subrole)
    return {
        id = function() return id end,
        subrole = function() return subrole or "AXStandardWindow" end,
    }
end

local filterWins = {}
local S = { defaults = {}, running = { windowFilter = { getWindows = function() return filterWins end } } }
package.loaded["hyprspoon.state"] = S
package.loaded["hyprspoon.tree"] = {}
local synced = 0
package.loaded["hyprspoon.border"] = { sync = function() synced = synced + 1 end }

local Util = require("hyprspoon.util")

local function ids(list)
    local out = {}
    for _, w in ipairs(list) do out[#out + 1] = w:id() end
    return table.concat(out, ",")
end

local a, b, torn = win(1), win(2), win(3)
filterWins = { a, b }
assert(ids(Util.managedWindows()) == "1,2")

-- After a tear-off the filter reports only the torn-off window (2); the
-- old window (3) still shows the other tabs and discovery lists it.
S.nativeShown = { { id = 3, win = torn }, { id = 2, win = b } }
Util.forgetManagedWindows()
assert(ids(Util.managedWindows()) == "1,2,3", "app-listed shown windows are managed")
assert(synced == 1, "forgetting the list resyncs the rings")

-- A stale object (closed window answering for another id) is skipped.
S.nativeShown = { { id = 4, win = win(5) } }
Util.forgetManagedWindows()
assert(ids(Util.managedWindows()) == "1,2")

-- Ignored kinds stay ignored however they're found.
S.nativeShown = { { id = 6, win = win(6, "AXFloatingWindow") } }
hs.axuielement.windowElement = function() return nil end
Util.forgetManagedWindows()
assert(ids(Util.managedWindows()) == "1,2")

print("Managed windows tests passed")
