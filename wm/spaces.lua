-- wm/spaces.lua: Numbered workspaces backed by macOS Spaces.

local M = {}
package.loaded["wm.spaces"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")
local Focus = require("wm.focus")

-- ---------------------------------------------------------------------------
-- Workspaces (macOS Spaces)
-- ---------------------------------------------------------------------------
--
-- Workspaces are dynamically numbered:
--   1. user Spaces on the primary display
--   2. user Spaces on the other displays, ordered left-to-right/top-to-bottom
--
-- Fullscreen/tiled-app Spaces are excluded from numbering.

local function orderedScreens()
    local all = hs.screen.allScreens()
    local primary = hs.screen.primaryScreen()
    local result = {}

    if primary then
        table.insert(result, primary)
    end

    local rest = {}
    for _, screen in ipairs(all) do
        if not primary or screen:id() ~= primary:id() then
            table.insert(rest, screen)
        end
    end

    table.sort(rest, function(a, b)
        local af = a:fullFrame()
        local bf = b:fullFrame()
        if af.x == bf.x then
            return af.y < bf.y
        end
        return af.x < bf.x
    end)

    for _, screen in ipairs(rest) do
        table.insert(result, screen)
    end

    return result
end

local function userSpaces()
    local result = {}

    for _, screen in ipairs(orderedScreens()) do
        local spaces = hs.spaces.spacesForScreen(screen) or {}
        for _, spaceID in ipairs(spaces) do
            if hs.spaces.spaceType(spaceID) == "user" then
                table.insert(result, spaceID)
            end
        end
    end

    return result
end

local function spaceAt(index)
    return userSpaces()[index]
end

-- After a Space switch macOS often leaves no window focused until the mouse
-- moves. Once the switch has settled, restore focus on the new Space while
-- leaving the pointer in place. The
-- switch animation length varies, so this waits for the Space-changed event
-- (with a timer as a fallback) and retries while the window list is empty.
S.spaceFocusPending = false
-- Timers are kept in variables so they can't be garbage collected early.
local spaceRetryTimer, spaceSettleTimer, spaceFallbackTimer

local function focusCurrentSpaceWindow(attempt)
    -- The window we last used in this Space, from our own tree and focus
    -- record; only when there's none do we ask what is under the pointer.
    local win = nil
    local screen = hs.mouse.getCurrentScreen()
    local tree = S.tilingEnabled and screen and S.trees[Tree.keyForScreen(screen)]
    if tree then
        local ids = Tree.collectIDs(tree)
        for _, fid in ipairs(Util.focusHistory) do
            if ids[fid] and Util.winByID[fid] and Util.winByID[fid]:id() == fid then
                win = Util.winByID[fid]
                break
            end
        end
    end

    if not win then
        -- Fresh each attempt: the Space has just changed, and a snapshot
        -- taken mid-switch would otherwise be reused by the retries.
        win = Focus.windowUnderPoint(hs.mouse.absolutePosition(), true)
    end
    if not win then
        local entry = Focus.windowSnapshot()[1]
        win = entry and entry.win
    end

    if win then
        Focus.focus(win)
    elseif attempt < 6 then
        spaceRetryTimer = hs.timer.doAfter(0.15, function() focusCurrentSpaceWindow(attempt + 1) end)
    end
end

local function settleSpaceFocus()
    if not S.spaceFocusPending then return end
    S.spaceFocusPending = false
    spaceSettleTimer = hs.timer.doAfter(0.1, function() focusCurrentSpaceWindow(1) end)
end

local function switchToSpace(target)
    local ok, err = hs.spaces.gotoSpace(target)
    if not ok then
        hs.alert.show("Could not switch Space: " .. tostring(err))
        return false
    end

    S.spaceFocusPending = true
    spaceFallbackTimer = hs.timer.doAfter(1.0, settleSpaceFocus)
    return true
end

function M.gotoWorkspace(index)
    local target = spaceAt(index)
    if not target then
        hs.alert.show("No macOS Space " .. tostring(index))
        return
    end

    switchToSpace(target)
end

-- Previous/next Space on the screen the pointer is on (no wrap-around).
function M.gotoWorkspaceRelative(delta)
    local screen = hs.mouse.getCurrentScreen()
    if not screen then return end

    local current = hs.spaces.activeSpaceOnScreen(screen)
    local spaces = {}
    for _, id in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
        if hs.spaces.spaceType(id) == "user" then table.insert(spaces, id) end
    end

    for i, id in ipairs(spaces) do
        if id == current then
            local target = spaces[i + delta]
            if target then switchToSpace(target) end
            return
        end
    end
end

-- Move the focused window to a workspace and follow it there, like
-- Hyprland's movetoworkspace (not movetoworkspacesilent).
function M.moveToWorkspace(index)
    local win = Focus.currentWindow()
    if not win then return end

    local target = spaceAt(index)
    if not target then
        hs.alert.show("No macOS Space " .. tostring(index))
        return
    end

    local ok, err = hs.spaces.moveWindowToSpace(win, target, true)
    if not ok then
        hs.alert.show("Could not move window: " .. tostring(err))
        return
    end

    hs.spaces.gotoSpace(target)

    hs.timer.doAfter((hs.spaces.MCwaitTime or 0.3) + 0.15, function()
        win:focus()
    end)
end

M.settleSpaceFocus = settleSpaceFocus

return M
