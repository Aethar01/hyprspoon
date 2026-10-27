-- wm/layout.lua: Laying the BSP trees out onto windows, and scheduling retiles.

local M = {}
package.loaded["wm.layout"] = M

local S = require("wm.state")
local Util = require("wm.util")
local Tree = require("wm.tree")
local Float = require("wm.float")
local Focus = require("wm.focus")
local Discover = require("wm.discover")
local Spaces = require("wm.spaces")
local Border = require("wm.border")
local Drop = require("wm.drop")
local Restore = require("wm.restore")

-- ---------------------------------------------------------------------------
-- BSP tiling: layout
-- ---------------------------------------------------------------------------
-- Moves we caused ourselves fire windowMoved shortly after; see
-- Resize.onWindowMoved.
local BSP_SETTLE = 0.35

-- Pre-tiling frames of windows, restored when tiling is turned off.
S.floatingFrames = {}
-- True while a layout is being applied, so its moves aren't taken as the user's.
S.applyingLayout = false

-- Where a new window goes relative to a tile: split top/bottom unless the
-- width exceeds 1.5 times the height. The pointer's position along that axis picks the
-- side; in the middle third (or outside the tile) it's right/bottom.
local function splitSide(rect, point)
    local horizontal = rect.w > 1.5 * rect.h
    local t = horizontal and (point.x - rect.x) / rect.w
                         or (point.y - rect.y) / rect.h
    if Util.pointInFrame(point, rect) then
        if t < 1 / 3 then return horizontal and "left" or "top" end
    end
    return horizontal and "right" or "bottom"
end

-- When a window goes away, focus returns to its sibling in the tree: the
-- tile it was split from, or the most recently used surviving window in that
-- subtree. Climbs to the parent's sibling if a whole subtree is gone too.
-- Returns that window's id.
local function siblingToFocus(tree, windowID, valid)
    local path = Tree.ancestors(tree, windowID)
    for _, step in ipairs(path or {}) do
        local sibling = step.node[step.branch == "a" and "b" or "a"]
        local ids = Tree.collectIDs(sibling)
        for _, fid in ipairs(Util.focusHistory) do
            if ids[fid] and valid[fid] then return fid end
        end
        for fid in pairs(ids) do
            if valid[fid] then return fid end
        end
    end
end

-- macOS focused `win` as the focused window `goneID` closed or minimized,
-- before telling us it went: hand focus to its tree sibling now instead of
-- after the retile (which holds back in case the close was a tab swap). Not
-- when `win` is a native tab taking over the same tile. True if focus moved.
local function handFocusBack(goneID, win)
    local path, leaf, key = Tree.findByID(goneID)
    if not path or S.autoFloat[goneID] then return false end
    if leaf.rect and win:pid() == (Util.pidByID[goneID] or win:pid()) then
        local f = win:frame()
        if Util.pointInFrame({ x = f.x + f.w / 2, y = f.y + f.h / 2 }, leaf.rect) then return false end
    end
    local tree = S.trees[key]
    local valid = {}
    for id in pairs(Tree.collectIDs(tree)) do
        local w = Util.winByID[id]
        if id ~= goneID and w and w:id() == id then valid[id] = true end
    end
    local pick = siblingToFocus(tree, goneID, valid)
    if not pick or pick == win:id() then return false end
    Util.dlog("focused %s closing -> refocus %s", tostring(goneID), tostring(pick))
    Focus.focus(Util.winByID[pick])
    return true
end

-- Whether a window that has just vanished was the one we consider focused.
-- Judged from our own focus record, not macOS's current focus: if macOS has
-- already moved focus elsewhere in the last moment (stealing it on close),
-- the vanished window is the one before that.
local BSP_STEAL_WINDOW = 0.5
local function wasFocused(windowID)
    if Util.focusHistory[1] == windowID then return true end
    local stolen = Util.focusHistory[1]
    return Util.focusHistory[2] == windowID and stolen ~= nil
        and hs.timer.secondsSinceEpoch() - (Util.focusTimes[stolen] or 0) < BSP_STEAL_WINDOW
end

-- What each screen last laid out (window IDs + screen frame). Retiles caused
-- by window set changes are skipped for screens whose signature is unchanged.
local signatures = {}

local pendingRefocus = nil -- window id to focus once the next retile is done

-- Window id -> { key =, seq =, slot = (Tree.slotOf) }: where a window that
-- went full screen or to another Space sat, to go back to on its return.
S.slots = {}
local slotSeq = 0

local function rememberSlot(key, tree, id)
    local slot = Tree.slotOf(tree, id)
    slotSeq = slotSeq + 1
    S.slots[id] = slot and { key = key, seq = slotSeq, slot = slot } or nil
end

-- Running while a window moves into or out of a full-screen Space: no
-- passes until macOS reports the Space change (see holdForSpaceMove).
local spaceMoveTimer = nil

-- Where the next new window goes, chosen ahead (like bspwm's preselection):
-- { id = tiled window, side = "left"/"right"/"top"/"bottom", key = its
-- tree }, shown by a highlight over that half of the tile until used.
S.presel = nil
local preselCanvas = nil

-- Shows the preselection where its tile is now, or drops it once its
-- window has left the tree or the workspace isn't showing.
local function showPresel()
    local p = S.presel
    local leaf, key
    if p then _, leaf, key = Tree.findByID(p.id) end
    if p and (key ~= p.key or not leaf.rect or Spaces.isHidden(p.id)) then
        S.presel, p = nil, nil
    end
    if not p then
        if preselCanvas then preselCanvas:delete() preselCanvas = nil end
        return
    end
    local rect = Drop.sideRect(leaf.fullRect or leaf.rect, p.side)
    if preselCanvas then preselCanvas:frame(rect) else preselCanvas = Drop.highlight(rect) end
    preselCanvas:show()
end

local function reconcileTree(key, windows)
    local valid = {}
    local byID = {}

    for _, win in ipairs(windows) do
        local id = win:id()
        valid[id] = true
        byID[id] = win
        Util.winByID[id] = win
        Util.pidByID[id] = win:pid()

        if not S.floatingFrames[id] then
            S.floatingFrames[id] = win:frame()
        end
    end

    -- Windows in the tree that are no longer present: if one was focused,
    -- remember its surviving sibling so the retile can hand focus back.
    local previous = S.trees[key]

    -- Switching, opening or closing a native tab swaps which window id is the
    -- live one, in the same place. A window that vanished and a new window of
    -- the same app now centred inside its tile are the same tile: hand it
    -- over (and its focus) instead of splitting a new one in.
    local before = Tree.collectIDs(previous)
    local beforeIDs = {}
    for id in pairs(before) do beforeIDs[#beforeIDs + 1] = id end
    if S.cfg.debug then
        local removed, added = {}, {}
        for id in pairs(before) do if not valid[id] then removed[#removed + 1] = id end end
        for id in pairs(valid) do if not before[id] then added[#added + 1] = id end end
        if #removed > 0 or #added > 0 or #S.ghosts > 0 then
            Util.dlog("reconcile %s removed=%s added=%s ghosts=%s focus=%s",
                key:sub(-6), Util.idList(removed), Util.idList(added),
                Util.idList(S.ghosts, function(w) return w:id() end),
                Util.idList(Util.focusHistory):sub(1, 40))
        end
    end
    for _, oldID in ipairs(beforeIDs) do
        if not valid[oldID] then
            local _, leaf = Tree.ancestors(previous, oldID)
            local candidates = {}
            for _, win in ipairs(windows) do candidates[#candidates + 1] = win end
            for _, win in ipairs(S.ghosts) do candidates[#candidates + 1] = win end
            for _, win in ipairs(candidates) do
                local newID = win:id()
                if not before[newID] and win:pid() == Util.pidByID[oldID]
                   and leaf and leaf.rect then
                    local f = win:frame()
                    Util.dlog("candidate %s for %s: frame=%d,%d,%d,%d rect=%d,%d,%d,%d", tostring(newID),
                        tostring(oldID), f.x, f.y, f.w, f.h,
                        leaf.rect.x, leaf.rect.y, leaf.rect.w, leaf.rect.h)
                    if Util.pointInFrame({ x = f.x + f.w / 2, y = f.y + f.h / 2 }, leaf.rect) then
                        Util.dlog("handoff %s -> %s", tostring(oldID), tostring(newID))
                        leaf.windowID = newID
                        valid[newID] = true
                        byID[newID] = win
                        Util.winByID[newID] = win
                        Util.pidByID[newID] = win:pid()
                        for i, fid in ipairs(Util.focusHistory) do
                            if fid == oldID then Util.focusHistory[i] = newID end
                        end
                        Util.focusTimes[newID] = Util.focusTimes[oldID]
                        if S.ffmFocusedID == oldID then S.ffmFocusedID = newID end
                        before[newID], before[oldID] = true, nil
                        break
                    end
                end
            end
        end
    end

    -- Windows that left the tree but are still open keep focus.
    for id in pairs(before) do
        if not valid[id] and not S.autoFloat[id] and not S.openIDs[id]
           and wasFocused(id) then
            pendingRefocus = siblingToFocus(previous, id, valid) or pendingRefocus
            Util.dlog("closed focused %s -> refocus %s", tostring(id), tostring(pendingRefocus))
            break
        end
    end

    -- Windows leaving for another macOS Space (full screen) remember their
    -- slots, taken out one at a time after the closed ones so that putting
    -- them back in reverse undoes it.
    local away = {}
    for id in pairs(before) do
        if not valid[id] and (S.fullscreen[id] or S.offSpace[id]) then away[#away + 1] = id end
    end
    local keep = valid
    if #away > 0 then
        table.sort(away)
        keep = {}
        for id in pairs(valid) do keep[id] = true end
        for _, id in ipairs(away) do keep[id] = true end
    end
    previous = Tree.prune(previous, keep)
    for _, id in ipairs(away) do
        rememberSlot(key, previous, id)
        previous = Tree.removeID(previous, id)
    end

    local tree = Restore.rebuild(key, previous, valid)
    local present = Tree.collectIDs(tree)

    -- Windows back from another Space return to their slots, latest first.
    local returning = {}
    for _, win in ipairs(windows) do
        local id = win:id()
        local s = S.slots[id]
        if s and not present[id] then
            S.slots[id] = nil
            if s.key == key then returning[#returning + 1] = { id = id, seq = s.seq, slot = s.slot } end
        end
    end
    table.sort(returning, function(a, b) return a.seq > b.seq end)
    for _, r in ipairs(returning) do
        local inserted
        tree, inserted = Tree.insertSlot(tree, r.id, r.slot)
        if inserted then present[r.id] = true end
    end

    for _, win in ipairs(windows) do
        local id = win:id()

        if not present[id] then
            -- A window arriving from another display or workspace leaves
            -- that tree (only its own workspace's pass lists it).
            for otherKey, other in pairs(S.trees) do
                if otherKey ~= key and Tree.treeContains(other, id) then
                    S.trees[otherKey] = Tree.removeID(other, id)
                    signatures[otherKey] = nil
                end
            end

            if not tree then
                tree = Tree.leaf(id)
            else
                -- A new window is usually focused before we retile, so walk
                -- the focus history for the most recent window already tiled.
                local target = nil

                for _, fid in ipairs(Util.focusHistory) do
                    if fid ~= id and Tree.treeContains(tree, fid) then
                        target = fid
                        break
                    end
                end

                target = target or Tree.rightmostLeafID(tree)

                -- Split the previously focused tile along its longer axis;
                -- the mouse picks which side the new window goes on. A
                -- preselection decides both instead, once.
                local inserted = false
                local p = S.presel
                if p and p.key == key and Tree.treeContains(tree, p.id) then
                    S.presel = nil
                    tree, inserted = Tree.insertBeside(tree, p.id, id, p.side)
                end
                local _, targetLeaf = Tree.ancestors(tree, target)
                if not inserted and targetLeaf and targetLeaf.rect then
                    tree, inserted = Tree.insertBeside(tree, target, id,
                        splitSide(targetLeaf.rect, hs.mouse.absolutePosition()))
                end

                if not inserted then
                    tree, inserted = Tree.insertAt(tree, target, id, 0)
                end

                -- Defensive fallback; target should always be in the tree.
                if not inserted then
                    local fallback = Tree.rightmostLeafID(tree)
                    tree = select(1, Tree.insertAt(tree, fallback, id, 0))
                end
            end

            present[id] = true
        end
    end

    S.trees[key] = tree
    S.keyIndex = {}
    return tree, byID
end

local function inset(rect, amount)
    return hs.geometry.rect(
        rect.x + amount,
        rect.y + amount,
        math.max(1, rect.w - amount * 2),
        math.max(1, rect.h - amount * 2)
    )
end

local function framesMatch(a, b)
    return math.abs(a.x - b.x) <= 1 and math.abs(a.y - b.y) <= 1
        and math.abs(a.w - b.w) <= 1 and math.abs(a.h - b.h) <= 1
end

-- Accessibility setters can return before an app applies the frame, or be
-- ignored during startup. Cache only observed success and retry a bounded
-- number of times; minimum-size constraints must not create a retry loop.
-- `animating` is how long the window is still easing towards `rect` (with
-- wm.native.frames it reports the frames on the way, not the end).
local function verifyLayout(win, rect, rectKey, animating)
    local id = win:id()
    Discover.cancelLayoutCheck(id)
    local pending = { key = rectKey, started = hs.timer.secondsSinceEpoch() }
    Discover.layoutChecks[id] = pending
    local delays = { 0.15 + (animating or 0), 0.35, 0.7 }
    local function check(step)
        pending.timer = hs.timer.doAfter(delays[step], function()
            if Discover.layoutChecks[id] ~= pending then return end
            local _, leaf, key = Tree.findByID(id)
            if not S.tilingEnabled or not S.running.windowFilter or win:id() ~= id
               or S.autoFloat[id] or S.dragState or hs.mouse.getButtons().left
               or S.lastMouseTime > pending.started
               or not leaf or not leaf.rect or not framesMatch(leaf.fullRect or leaf.rect, rect) then
                Discover.layoutChecks[id] = nil
                return
            end
            if framesMatch(win:frame(), rect) then
                S.applied[id] = rectKey
                Discover.layoutChecks[id] = nil
            elseif step < #delays then
                -- Only query screen/visibility/fullscreen when a correction
                -- is needed. Matching frames require no further AX calls.
                local screen = win:screen()
                if not screen or key ~= Tree.keyForScreen(screen)
                   or not win:isVisible() or win:isFullScreen() or Util.isPictureInPicture(win) then
                    Discover.layoutChecks[id] = nil
                    return
                end
                S.settleUntil = hs.timer.secondsSinceEpoch() + BSP_SETTLE
                Util.setFrame(win, rect, 0)
                Focus.invalidateWindowCache()
                check(step + 1)
            else
                Discover.layoutChecks[id] = nil
                Util.dlog("frame did not settle for %s after retries", tostring(id))
            end
        end)
    end
    check(1)
end

-- `full` is { id =, rect = } for the workspace's maximized window: it gets
-- the whole area, while its tile (`rect`) is kept for navigation and for
-- coming back to.
local function applyTree(node, rect, byID, full)
    if not node then return end

    -- Remembered so resizing knows each split's and tile's size.
    node.rect = rect

    if Tree.isLeaf(node) then
        node.fullRect = nil
        if full and full.id == node.windowID then
            node.fullRect = full.rect
            rect = full.rect
        end
        local win = byID[node.windowID]
        if win then
            local id = node.windowID
            local rectKey = string.format("%.0f,%.0f,%.0f,%.0f", rect.x, rect.y, rect.w, rect.h)
            if S.applied[id] == rectKey then return end
            local pending = Discover.layoutChecks[id]
            if pending and pending.key == rectKey then return end
            Discover.cancelLayoutCheck(id)
            -- setFrame is several accessibility calls and fires windowMoved,
            -- so leave windows that are already in place alone.
            local f = win:frame()
            local moved = math.abs(f.x - rect.x) > 1 or math.abs(f.y - rect.y) > 1
            local resized = math.abs(f.w - rect.w) > 1 or math.abs(f.h - rect.h) > 1
            -- setFrame is size, position, size; one call is enough when only
            -- one of them changes. Only setFrame animates. wm.native.frames
            -- makes the same choice itself, off the main thread.
            local duration = S.cfg.tiling.animationDuration
            if S.dragState or hs.mouse.getButtons().left then duration = 0 end
            local native = Util.native("frames")
            if native and (moved or resized) then
                Util.setFrame(win, rect, duration)
            elseif duration > 0 and (moved or resized) then
                win:setFrame(rect, duration)
            elseif moved and resized then
                win:setFrame(rect, 0)
            elseif moved then
                win:setTopLeft(rect)
            elseif resized then
                win:setSize(rect)
            end
            if moved or resized then
                S.applied[id] = nil
                verifyLayout(win, hs.geometry.copy(rect), rectKey, native and duration or 0)
            else
                S.applied[id] = rectKey
            end
        end
        return
    end

    local gap = S.cfg.tiling.innerGap
    local ratio = math.max(S.cfg.tiling.minRatio,
        math.min(S.cfg.tiling.maxRatio, node.ratio or 0.5))
    node.ratio = ratio

    if node.split == "vertical" then
        local usable = math.max(1, rect.w - gap)
        local first = math.floor(usable * ratio)

        local aRect = hs.geometry.rect(rect.x, rect.y, first, rect.h)
        local bRect = hs.geometry.rect(
            rect.x + first + gap,
            rect.y,
            usable - first,
            rect.h
        )

        applyTree(node.a, aRect, byID, full)
        applyTree(node.b, bRect, byID, full)
    else
        local usable = math.max(1, rect.h - gap)
        local first = math.floor(usable * ratio)

        local aRect = hs.geometry.rect(rect.x, rect.y, rect.w, first)
        local bRect = hs.geometry.rect(
            rect.x,
            rect.y + first + gap,
            rect.w,
            usable - first
        )

        applyTree(node.a, aRect, byID, full)
        applyTree(node.b, bRect, byID, full)
    end
end

-- `onlyScreenUUID` limits the pass to one screen (resizes, swaps and split
-- flips only ever affect the layout of the window's own screen).
local function tileNow(onlyIfChanged, onlyScreenUUID)
    if not S.tilingEnabled or S.applyingLayout or not S.running.windowFilter
       or spaceMoveTimer then
        return
    end

    S.applyingLayout = true
    local changed = false

    -- An error mid-pass must not leave applyingLayout set, or every later
    -- retile would be skipped. Run guarded, report, and force the next pass.
    local function pass()
    local byScreen = Discover.windowsByScreen(onlyScreenUUID)

    for _, screen in ipairs(hs.screen.allScreens()) do
        local windows = byScreen[screen:getUUID()] or {}

        local key = #windows > 0 and Tree.keyForScreen(screen)
        if key and not S.untiled[key] then
            local usableFrame = inset(screen:frame(), S.cfg.tiling.outerGap)
            local scale = Spaces.layoutScale(key)
            if scale and scale < 1 then
                usableFrame = hs.geometry.rect(
                    usableFrame.x + usableFrame.w * (1 - scale) / 2,
                    usableFrame.y + usableFrame.h * (1 - scale) / 2,
                    usableFrame.w * scale,
                    usableFrame.h * scale)
            end

            local ids = {}
            for i, win in ipairs(windows) do ids[i] = win:id() end
            local signature = key .. "|" .. table.concat(ids, ",") .. "|"
                .. string.format("%.0f,%.0f,%.0f,%.0f",
                    usableFrame.x, usableFrame.y, usableFrame.w, usableFrame.h)

            if not (onlyIfChanged and signatures[key] == signature) then
                changed = true
                signatures[key] = signature
                local tree, byID = reconcileTree(key, windows)
                -- The maximized window left the tree (moved, floated). One not
                -- seen at all may only not be found yet (an app after a
                -- reload); a closed one is forgotten as it closes.
                local maxID = S.maximized[key]
                if maxID and not byID[maxID] and S.openIDs[maxID] then
                    S.maximized[key], maxID = nil, nil
                    Border.sync()
                end
                local fullRect = S.filled[key] and screen:frame() or usableFrame
                applyTree(tree, usableFrame, byID, maxID and { id = maxID, rect = fullRect } or nil)
            end
        end
    end
    end

    local ok, err = xpcall(pass, debug.traceback)
    if not ok then
        print("wm: tiling pass failed: " .. tostring(err))
        signatures = {}
    end

    S.applyingLayout = false
    if S.presel or preselCanvas then showPresel() end
    if changed or not ok then
        Tree.saveTrees()
        Float.raiseFloating()
        -- Each animation step fires windowMoved too.
        S.settleUntil = hs.timer.secondsSinceEpoch() + BSP_SETTLE
            + S.cfg.tiling.animationDuration
        Focus.invalidateWindowCache()
    end

    -- A closed window hands focus back to its tree sibling without moving
    -- the pointer. Re-check in case macOS focuses its own pick late.
    local pick = pendingRefocus
    pendingRefocus = nil
    if pick then
        local function refocus()
            local win = Util.winByID[pick]
            if not win or win:id() ~= pick then return end
            local cur = Util.focusedWindow()
            if not cur or cur:id() ~= pick then Focus.focus(win) else Focus.noteFocus(win) end
        end
        refocus()
        hs.timer.doAfter(0.1, refocus)
    end
end

local BSP_RETILE_DELAY = 0.06

-- A window that opens exactly over another of its app's windows may be a new
-- native tab, which the app's window list only settles on a moment later.
-- Anything else can be placed the moment it appears.
local function mayBeTab(win)
    local id, pid = win:id(), win:pid()
    local f = win:frame()
    for _, other in ipairs(Util.managedWindows()) do
        if other:pid() == pid and other:id() ~= id and framesMatch(other:frame(), f) then
            return true
        end
    end
    return false
end

local BSP_TAB_SETTLE = 0.15

local retileTimer = nil
local retilePending = false
local retileForce = false

local function retileFlush()
    retileTimer = nil
    if not retilePending then return end
    local force = retileForce
    retilePending, retileForce = false, false
    tileNow(not force)
end

-- `force` drops the unchanged-screen shortcut (Space/display changes, where
-- the same windows may need re-laying out).
--
-- Events are normally coalesced behind a short delay. With `immediate`
-- (windows going away, and new windows that can't be native tabs) the first
-- event retiles straight away and any burst after it is coalesced.
local retileDue = 0

-- `delay` holds the retile back for events whose follow-ups arrive a moment
-- later (a tab swap announces the old tab leaving before the new one
-- appears). A pending retile is never brought forward by a later request.
local function scheduleRetile(force, immediate, delay)
    if not S.tilingEnabled then return end

    if force then
        for id in pairs(Discover.layoutChecks) do Discover.cancelLayoutCheck(id) end
        signatures = {}
        S.windowInfo = {}
        S.applied = {}
    end

    local now = hs.timer.secondsSinceEpoch()
    local due = now + (delay or BSP_RETILE_DELAY)

    if immediate and not force and not retileTimer then
        tileNow(true)
    else
        retilePending = true
        retileForce = retileForce or force or false
        if retileTimer then
            retileTimer:stop()
            if retileDue > due then due = retileDue end
        end
    end

    retileDue = due
    retileTimer = hs.timer.doAfter(math.max(0, due - now), retileFlush)
end

-- The Space showing changed: the filter has caught up with every window.
local function spaceChanged()
    if spaceMoveTimer then spaceMoveTimer:stop() spaceMoveTimer = nil end
    scheduleRetile(true)
end

-- A window is going into or out of full screen. The filter moves the other
-- windows across one app at a time (over half a second apart), and a pass
-- in between would drop the ones not yet across from their layouts, so
-- hold passes until the Space has changed. Behind the system's animation,
-- so nothing on screen waits.
local SPACE_MOVE_MAX = 2
local function holdForSpaceMove()
    if spaceMoveTimer then spaceMoveTimer:stop() end
    spaceMoveTimer = hs.timer.doAfter(SPACE_MOVE_MAX, spaceChanged)
end

-- Takes a window going full screen out of its layout, remembering its
-- slot. The other tiles stay put: they aren't on the full-screen Space, so
-- nothing lays them out again before it comes back.
local function setAside(id)
    local _, _, key = Tree.findByID(id)
    if not key then return end
    rememberSlot(key, S.trees[key], id)
    S.trees[key] = Tree.removeID(S.trees[key], id)
    S.keyIndex = {}
    signatures[key] = nil
    Tree.saveTrees()
end

-- Apps update their window lists a little after the events that announce a
-- change (notably native tabs opening and closing), so look again shortly
-- after windows come or go. Skipped by the signature check when nothing
-- changed.
S.recheckTimer = nil
local function scheduleRecheck(step)
    step = step or 1
    local delays = { 0.2, 0.4, 0.8 }
    if S.recheckTimer then S.recheckTimer:stop() end
    S.recheckTimer = hs.timer.doAfter(delays[step], function()
        S.recheckTimer = nil
        tileNow(true)
        -- A slow app can still be absent at the first check.
        if step < #delays then scheduleRecheck(step + 1) end
    end)
end

-- Every window with a remembered frame was tiled, so winByID holds it; that
-- avoids hs.window.allWindows(), which asks every running app over AX.
-- Parked windows stay parked and get the frame once their workspace shows.
local function restoreFloatingFrames()
    for id, frame in pairs(S.floatingFrames) do
        local win = Util.winByID[id]
        if Spaces.isHidden(id) then
            Spaces.setParkedFrame(id, frame)
        elseif win and win:id() == id and win:isStandard() and not Util.isPictureInPicture(win) then
            win:setFrame(frame, 0)
        end
    end

    S.floatingFrames = {}
    S.applied = {}
end

-- The tree path and leaf for a tiled window, or nil if it isn't tiled.
local function locate(win)
    if not S.tilingEnabled or not win or S.autoFloat[win:id()] then return nil end
    local path, leaf, key = Tree.findByID(win:id())
    if not path then return nil end
    return path, leaf, key
end

-- Fill the workspace's tiling area with tiled window `win`, over the other
-- tiles, or put it back in its tile. False if it isn't tiled.
-- With `fill`, over the whole display rather than inside the outer gaps.
-- Asking for the other kind switches to it.
local function toggleMaximized(win, fill)
    local id = win:id()
    local _, _, key = locate(win)
    if not key then return false end
    fill = fill or nil
    if S.maximized[key] == id and S.filled[key] == fill then
        S.maximized[key], S.filled[key] = nil, nil
    else
        S.maximized[key], S.filled[key] = id, fill
    end
    Border.sync()
    tileNow(false, Tree.keyUUID(key))
    -- Above the tiles of its own app too.
    if S.maximized[key] then Util.focusWindow(win, true) end
    Focus.invalidateWindowCache()
    return true
end

-- Focus went to `id`: another tile of a workspace with a maximized window
-- puts that window back in its tile, so the focused one can be seen.
local function focused(id)
    if not S.tilingEnabled or next(S.maximized) == nil or not id or S.autoFloat[id] then return end
    local _, _, key = Tree.findByID(id)
    local maxID = key and S.maximized[key]
    if not maxID or maxID == id then return end
    S.maximized[key] = nil
    Border.sync()
    tileNow(false, Tree.keyUUID(key))
end

-- Turns tiling off or back on for one workspace. Its windows go back to
-- the frames they had before they were tiled, and its tree is kept for
-- when tiling comes back.
local function toggleWorkspaceTiling(key)
    if S.untiled[key] then
        S.untiled[key] = nil
        S.keyIndex = {}
        scheduleRetile(true)
        return true
    end
    S.untiled[key] = true
    S.maximized[key] = nil
    S.keyIndex = {}
    signatures[key] = nil
    for id in pairs(Tree.collectIDs(S.trees[key])) do
        Discover.cancelLayoutCheck(id)
        local win, frame = Util.winByID[id], S.floatingFrames[id]
        S.floatingFrames[id], S.applied[id] = nil, nil
        if frame and win and win:id() == id and not Spaces.isHidden(id) then
            S.settleUntil = hs.timer.secondsSinceEpoch() + BSP_SETTLE + S.cfg.tiling.animationDuration
            Util.setFrame(win, frame, S.cfg.tiling.animationDuration)
        end
    end
    Tree.saveTrees()
    Border.sync()
    Focus.invalidateWindowCache()
    return false
end

-- Preselect `side` of tiled window `win` for the next new window, or
-- cancel the preselection if it's already that.
local function preselect(win, side)
    local _, _, key = locate(win)
    if not key then return end
    local p = S.presel
    if p and p.id == win:id() and p.side == side then
        S.presel = nil
    else
        S.presel = { id = win:id(), side = side, key = key }
    end
    showPresel()
end

-- Cancels the pending retile and recheck (reload, shutdown).
local function stop()
    S.presel = nil
    showPresel()
    if retileTimer then retileTimer:stop() end
    if spaceMoveTimer then spaceMoveTimer:stop() spaceMoveTimer = nil end
    if S.recheckTimer then S.recheckTimer:stop() S.recheckTimer = nil end
    retileTimer, retilePending, retileForce = nil, false, false
end

M.stop = stop
M.tileNow = tileNow
M.mayBeTab = mayBeTab
M.handFocusBack = handFocusBack
M.BSP_TAB_SETTLE = BSP_TAB_SETTLE
M.BSP_SETTLE = BSP_SETTLE
M.scheduleRetile = scheduleRetile
M.scheduleRecheck = scheduleRecheck
M.spaceChanged = spaceChanged
M.holdForSpaceMove = holdForSpaceMove
M.setAside = setAside
M.restoreFloatingFrames = restoreFloatingFrames
M.locate = locate
M.toggleMaximized = toggleMaximized
M.focused = focused
M.preselect = preselect
M.toggleWorkspaceTiling = toggleWorkspaceTiling

return M
