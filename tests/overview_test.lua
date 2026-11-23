-- Run with: lua tests/overview_test.lua
-- Unit tests for hyprspoon/overview.lua (niri-style overview geometry,
-- hit-testing, navigation, scroll settling, native + Lua fallback lifecycles,
-- drag-and-drop between workspaces, column reordering, and classic grid mode).
package.path = "./?.lua;" .. package.path

local function runIsolated(fn)
    local saved = {}
    for k, v in pairs(package.loaded) do
        if k:match("^hyprspoon") then
            saved[k] = v
            package.loaded[k] = nil
        end
    end
    local prevHs = hs
    local ok, err = pcall(fn)
    hs = prevHs
    for k in pairs(package.loaded) do
        if k:match("^hyprspoon") then package.loaded[k] = nil end
    end
    for k, v in pairs(saved) do package.loaded[k] = v end
    if not ok then error(err, 0) end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 0.01)
end

-- 1. Pure config, layout geometry, hit-testing, panBounds, navigate, settleScrollY.
runIsolated(function()
    hs = { settings = { get = function() return nil end } }
    local S = require("hyprspoon.state")
    S.cfg = {}
    local Overview = require("hyprspoon.overview")

    -- Config defaults and clamping.
    local cfg = Overview.config()
    assert(cfg.style == "niri", "default style is niri")
    assert(near(cfg.zoom, 0.5), "default zoom is 0.5")
    assert(cfg.backdrop == "wallpaper", "default backdrop uses macOS wallpaper")
    assert(near(cfg.backdropBlur, 20), "default backdropBlur is 20")
    assert(near(cfg.backdropDim, 0.35), "default backdropDim is 0.35")
    assert(cfg.workspaceGap == 24)
    assert(cfg.workspaceRadius == 12)
    assert(cfg.workspaceShadow == true)
    assert(cfg.showLabels == true)
    assert(cfg.emptyWorkspace == true)
    assert(cfg.captures == true)
    assert(cfg.swipe == false)
    assert(Overview.swipeFingers() == nil)

    S.cfg.overview = { style = "grid", zoom = 5, workspaceGap = -10, swipe = 4, captures = false,
        backdrop = "color", backdropBlur = false, backdropDim = 2 }
    cfg = Overview.config()
    assert(cfg.style == "grid")
    assert(near(cfg.zoom, 0.95), "zoom clamps to 0.95")
    assert(cfg.backdrop == "color")
    assert(cfg.backdropBlur == 0, "backdropBlur=false disables blur")
    assert(near(cfg.backdropDim, 1), "backdropDim clamps to 1")
    assert(cfg.workspaceGap == 0, "negative gap clamps to 0")
    assert(cfg.captures == false)
    assert(Overview.swipeFingers() == 4)

    S.cfg.overview = { zoom = 0.01, swipe = 2, backdropBlur = 500, backdropDim = -0.5 }
    cfg = Overview.config()
    assert(near(cfg.zoom, 0.1), "zoom clamps to 0.1")
    assert(near(cfg.backdropBlur, 100), "backdropBlur clamps to 100")
    assert(near(cfg.backdropDim, 0), "backdropDim clamps to 0")
    assert(Overview.swipeFingers() == nil, "swipe requires >= 3 fingers")

    -- Exact 1:1 match at zoom = 1.0, panX = 0.
    local display = { x = 100, y = 50, w = 1440, h = 900 }
    local workspaces = {
        {
            n = 1, label = "1", showing = true, panX = 0,
            windows = {
                -- Off-screen column to the left (scrolling layout).
                { id = 10, frame = { x = 100 - 720, y = 50, w = 700, h = 900 } },
                -- On-screen left & right columns.
                { id = 11, frame = { x = 100, y = 50, w = 710, h = 900 }, focused = true },
                { id = 12, frame = { x = 820, y = 50, w = 710, h = 900 } },
                -- Off-screen column to the right.
                { id = 13, frame = { x = 1540, y = 50, w = 700, h = 900 } },
                -- Floating window on top of 11.
                { id = 14, frame = { x = 300, y = 200, w = 400, h = 300 }, floating = true },
            },
        },
        {
            n = 2, label = "2", showing = false, panX = 0,
            windows = {
                { id = 20, frame = { x = 100, y = 50, w = 1440, h = 900 } },
            },
        },
        {
            n = 3, label = "3", showing = false, empty = true, panX = 0,
            windows = {},
        },
    }

    local oneToOne = Overview.computeLayout(display, workspaces, { zoom = 1.0, workspaceGap = 24 }, { scrollY = 1 })
    assert(near(oneToOne.rows[1].rect.x, 0) and near(oneToOne.rows[1].rect.y, 0))
    assert(near(oneToOne.rows[1].rect.w, 1440) and near(oneToOne.rows[1].rect.h, 900))
    assert(near(oneToOne.rows[1].windows[2].rect.x, 0) and near(oneToOne.rows[1].windows[2].rect.w, 710))

    -- Zoomed out to 0.5: workspace 1 centred, workspace 2 peeking below, off-screen columns visible!
    local zoomed = Overview.computeLayout(display, workspaces, { zoom = 0.5, workspaceGap = 24 }, { scrollY = 1 })
    assert(near(zoomed.wsX, 360) and near(zoomed.wsW, 720) and near(zoomed.wsH, 450))
    assert(near(zoomed.rows[1].rect.y, 225), "ws1 vertically centred")
    assert(near(zoomed.rows[2].rect.y, 225 + 450 + 24), "ws2 sits below ws1 by wsH + gap")
    -- Off-screen left column (id 10): x = 360 + (-720)*0.5 = 0, width = 350 -> wholly visible!
    local leftCol = zoomed.rows[1].windows[1].rect
    assert(near(leftCol.x, 0) and near(leftCol.w, 350), "off-screen left scrolling column is visible in overview")
    -- Off-screen right column (id 13): x = 360 + 1440*0.5 = 1080, width = 350 -> wholly visible!
    local rightCol = zoomed.rows[1].windows[4].rect
    assert(near(rightCol.x, 1080) and near(rightCol.w, 350), "off-screen right scrolling column is visible in overview")

    -- Hit-testing: float wins over tile beneath it, off-screen columns are clickable, backdrop returns backdrop.
    local hitFloat = Overview.hitTest(zoomed, 360 + 250 * 0.5, 225 + 200 * 0.5)
    assert(hitFloat.kind == "window" and hitFloat.win.id == 14, "floating window wins hit test over tile")
    local hitLeftCol = Overview.hitTest(zoomed, 100, 400)
    assert(hitLeftCol.kind == "window" and hitLeftCol.win.id == 10, "off-screen scrolling column is hittable")
    local hitRightCol = Overview.hitTest(zoomed, 1200, 400)
    assert(hitRightCol.kind == "window" and hitRightCol.win.id == 13, "off-screen right column is hittable")
    local hitWs2 = Overview.hitTest(zoomed, 500, 750)
    assert(hitWs2.kind == "window" and hitWs2.wsIdx == 2 and hitWs2.win.id == 20, "peeking ws2 window is hittable")
    local hitBackdrop = Overview.hitTest(zoomed, 50, 50)
    assert(hitBackdrop.kind == "backdrop", "empty area outside workspaces hits backdrop")

    -- Empty workspace surface hit test.
    local atWs3 = Overview.computeLayout(display, workspaces, { zoom = 0.5, workspaceGap = 24 }, { scrollY = 3 })
    local hitEmpty = Overview.hitTest(atWs3, 720, 450)
    assert(hitEmpty.kind == "workspace" and hitEmpty.ws.n == 3, "empty workspace surface hits workspace")

    -- Horizontal panBounds & navigation across workspaces, columns, and displays.
    local minPan, maxPan = Overview.panBounds(display, workspaces[1])
    assert(minPan < 0 and maxPan > 0, "scrolling strip with columns on both sides has negative and positive pan bounds")

    local model = {
        cfg = { zoom = 0.5, workspaceGap = 24 },
        activeDisplay = 1,
        focusRank = { [11] = 1, [20] = 2 },
        displays = {
            {
                uuid = "D1",
                frame = display,
                workspaces = workspaces,
                activeWs = 1,
                scrollY = 1,
                selectedWin = 11,
            },
            {
                uuid = "D2",
                frame = { x = 1540, y = 50, w = 1440, h = 900 },
                workspaces = { { n = 4, label = "4", showing = true, panX = 0, windows = {} } },
                activeWs = 1,
                scrollY = 1,
                selectedWin = nil,
            },
        },
    }

    -- Right moves across columns left-to-right (11 -> 14 -> 12 -> 13).
    assert(Overview.navigate(model, "left"))
    assert(model.displays[1].selectedWin == 10, "left from 11 selects off-screen left column 10")
    assert(Overview.navigate(model, "last"))
    assert(model.displays[1].selectedWin == 13, "last selects rightmost column 13")
    assert(Overview.navigate(model, "first"))
    assert(model.displays[1].selectedWin == 10, "first selects leftmost column 10")

    -- Down moves to workspace 2, then workspace 3 (empty), stops at bottom.
    assert(Overview.navigate(model, "down"))
    assert(model.displays[1].activeWs == 2 and model.displays[1].scrollY == 2 and model.displays[1].selectedWin == 20)
    assert(Overview.navigate(model, "down"))
    assert(model.displays[1].activeWs == 3 and model.displays[1].selectedWin == nil, "empty workspace has nil selectedWin")
    assert(not Overview.navigate(model, "down"), "down stops at last workspace")
    assert(Overview.navigate(model, "nextWorkspace"), "nextWorkspace wraps around to workspace 1")
    assert(model.displays[1].activeWs == 1 and model.displays[1].selectedWin == 11)

    -- Display switching.
    assert(Overview.navigate(model, "nextDisplay"))
    assert(model.activeDisplay == 2)
    assert(Overview.navigate(model, "prevDisplay"))
    assert(model.activeDisplay == 1)

    -- Vertical scroll settle with velocity.
    assert(Overview.settleScrollY(1.2, 0, 3) == 1)
    assert(Overview.settleScrollY(1.2, 3.0, 3) == 2, "downward flick advances to next workspace")
    assert(Overview.settleScrollY(2.8, 4.0, 3) == 3, "clamps at max workspace count")
    assert(Overview.settleScrollY(1.1, -5.0, 3) == 1, "clamps at 1")
end)

-- 2. Full interactive lifecycle with native renderer: open, navigate, close window,
--    drag-and-drop to trailing empty workspace, column reorder, and commit zoom-in.
runIsolated(function()
    local noop = function() end
    local tapHandler = nil
    local tapStopped = 0
    local suspended = {}
    local closedWins = {}
    local sentMoves = {}
    local reorders = {}
    local focusedWins = {}
    local gotoCalls = {}
    local revealCalls = {}
    local nativeLog = {}
    local scrollOffset = 0

    local screen = {
        getUUID = function() return "MAIN" end,
        fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end,
        currentMode = function() return { scale = 2 } end,
    }
    local function fakeWin(id, appName, title)
        return {
            id = function() return id end,
            application = function() return { name = function() return appName end, bundleID = function() return "com." .. appName end } end,
            title = function() return title end,
            close = function() closedWins[#closedWins + 1] = id end,
        }
    end
    local w1 = fakeWin(101, "Ghostty", "zsh")
    local w2 = fakeWin(102, "Safari", "Docs")
    local w3 = fakeWin(201, "Slack", "General")

    local wsData = {
        { n = 1, display = "MAIN", showing = true, windows = {
            { id = 101, win = w1, frame = { x = 0, y = 0, w = 700, h = 900 } },
            { id = 102, win = w2, frame = { x = 720, y = 0, w = 700, h = 900 } },
        } },
        { n = 2, display = "MAIN", showing = false, windows = {
            { id = 201, win = w3, frame = { x = 0, y = 0, w = 1440, h = 900 } },
        } },
    }

    local TYPES = {
        keyDown = 1, mouseMoved = 2, leftMouseDown = 3, leftMouseDragged = 4,
        leftMouseUp = 5, rightMouseDown = 6, rightMouseUp = 7, otherMouseDown = 8, scrollWheel = 9,
    }
    local KEYMAP = {
        escape = 53, ["return"] = 36, space = 49, tab = 48, delete = 51, forwarddelete = 117,
        [53] = "escape", [36] = "return", [49] = "space", [48] = "tab", [51] = "delete",
        [126] = "up", [125] = "down", [123] = "left", [124] = "right",
        [7] = "x", [4] = "h", [38] = "j", [40] = "k", [37] = "l",
        [18] = "1", [19] = "2",
    }
    local pendingTimer = nil
    hs = {
        settings = { get = function() return nil end },
        screen = { allScreens = function() return { screen } end },
        mouse = { getCurrentScreen = function() return screen end },
        keycodes = { map = KEYMAP },
        drawing = { color = { asRGB = function() return { red = 0.2, green = 0.4, blue = 0.6, alpha = 1 } end } },
        timer = {
            secondsSinceEpoch = function() return 100 end,
            doAfter = function(d, fn)
                pendingTimer = { d = d, fn = fn, stop = function() pendingTimer = nil end }
                return pendingTimer
            end,
        },
        eventtap = {
            event = {
                types = TYPES,
                properties = {
                    mouseEventButtonNumber = 3,
                    scrollWheelEventScrollPhase = 10,
                    scrollWheelEventMomentumPhase = 11,
                    scrollWheelEventIsContinuous = 12,
                    scrollWheelEventPointDeltaAxis1 = 13,
                    scrollWheelEventPointDeltaAxis2 = 14,
                },
            },
            new = function(_, cb)
                tapHandler = cb
                return {
                    start = function(self) return self end,
                    stop = function() tapStopped = tapStopped + 1; tapHandler = nil end,
                }
            end,
        },
    }

    local nativeSlide = {
        overviewOpen = function(spec) nativeLog[#nativeLog + 1] = { "open", spec }; return true end,
        overviewUpdate = function(spec) nativeLog[#nativeLog + 1] = { "update", spec } end,
        overviewDrag = function(spec) nativeLog[#nativeLog + 1] = { "drag", spec } end,
        overviewClose = function(spec) nativeLog[#nativeLog + 1] = { "close", spec }; return 0.2 end,
        overviewStop = function() nativeLog[#nativeLog + 1] = { "stop" } end,
    }

    package.loaded["hyprspoon.util"] = {
        focusHistory = { 101, 102, 201 },
        native = function(name) return name == "slide" and nativeSlide or nil end,
        warpToWindow = noop,
    }
    package.loaded["hyprspoon.focus"] = {
        currentWindow = function() return w1 end,
        focus = function(w) focusedWins[#focusedWins + 1] = w:id() end,
    }
    package.loaded["hyprspoon.spaces"] = {
        overview = function() return wsData end,
        label = function(n) return tostring(n) end,
        isHidden = function(id) return id == 201 end,
        nextEmptyWorkspace = function() return 3 end,
        gotoWorkspace = function(n) gotoCalls[#gotoCalls + 1] = n end,
        sendWindowToWorkspace = function(w, n)
            sentMoves[#sentMoves + 1] = { w:id(), n }
            return true
        end,
    }
    package.loaded["hyprspoon.border"] = {
        suspend = function(on) suspended[#suspended + 1] = on end,
    }
    package.loaded["hyprspoon.anim"] = {
        get = function() return { curve = "spring", mass = 0.6, stiffness = 800, damping = 38 } end,
    }
    package.loaded["hyprspoon.scroll"] = {
        viewOffset = function() return scrollOffset end,
        reveal = function(id)
            revealCalls[#revealCalls + 1] = id
            if id == 102 then scrollOffset = 500 end
        end,
        reorderWindow = function(key, fromID, targetID, side)
            reorders[#reorders + 1] = { key, fromID, targetID, side }
            return true
        end,
    }

    local S = require("hyprspoon.state")
    S.cfg = { overview = { style = "niri", zoom = 0.5, workspaceGap = 24 }, border = { active = "#6c99ba" } }
    S.autoFloat = {}
    local Overview = require("hyprspoon.overview")

    local function keyEvent(code, flags)
        return {
            getType = function() return TYPES.keyDown end,
            getKeyCode = function() return code end,
            getFlags = function() return flags or {} end,
        }
    end
    local function mouseEvent(kind, x, y, button)
        return {
            getType = function() return kind end,
            location = function() return { x = x, y = y } end,
            getProperty = function(_, prop)
                if prop == 3 then return button or 0 end
                return 0
            end,
        }
    end

    -- Open overview: suspends borders, calls native overviewOpen with 3 workspaces (including trailing empty ws 3).
    Overview.toggle()
    assert(S.overviewOpen == true)
    assert(suspended[#suspended] == true)
    assert(nativeLog[1][1] == "open")
    assert(#nativeLog[1][2].displays[1].workspaces == 3, "includes dynamic trailing empty workspace 3")
    assert(nativeLog[1][2].displays[1].workspaces[3].empty == true)

    -- Keyboard navigation updates native overlay.
    assert(tapHandler(keyEvent(125))) -- down -> ws2
    assert(nativeLog[#nativeLog][1] == "update")
    assert(nativeLog[#nativeLog][2].displays[1].activeWs == 2)
    assert(nativeLog[#nativeLog][2].displays[1].selectedWin == 201)

    -- Pressing 'x' closes selected window 201 without closing overview.
    assert(tapHandler(keyEvent(7))) -- x
    assert(S.overviewOpen == true, "closing window keeps overview open")
    assert(closedWins[1] == 201, "win:close() was called for 201")

    -- Navigate back up to ws1, then drag window 101 onto peeking workspace 2!
    assert(tapHandler(keyEvent(126))) -- up -> ws1
    -- ws1 is at x=360..1080, y=225..675; win 101 is at x=360..710, y=225..675.
    -- ws2 is at x=360..1080, y=699..1149.
    assert(tapHandler(mouseEvent(TYPES.leftMouseDown, 500, 400)))
    assert(tapHandler(mouseEvent(TYPES.leftMouseDragged, 500, 760)))
    assert(nativeLog[#nativeLog][1] == "drag" and nativeLog[#nativeLog][2].wid == 101)
    assert(nativeLog[#nativeLog][2].dropWs == 2, "highlights ws2 as drop target")
    assert(tapHandler(mouseEvent(TYPES.leftMouseUp, 500, 760)))
    assert(#sentMoves == 1 and sentMoves[1][1] == 101 and sentMoves[1][2] == 2,
        "dropping onto ws2 calls Spaces.sendWindowToWorkspace(w1, 2)")
    assert(S.overviewOpen == true, "drag-and-drop keeps overview open")

    -- Drag window 101 horizontally onto window 102 in same workspace -> column reorder!
    assert(tapHandler(mouseEvent(TYPES.leftMouseDown, 500, 400)))
    assert(tapHandler(mouseEvent(TYPES.leftMouseDragged, 950, 400)))
    assert(tapHandler(mouseEvent(TYPES.leftMouseUp, 950, 400)))
    assert(#reorders == 1 and reorders[1][1] == "ws1" and reorders[1][2] == 101 and reorders[1][3] == 102 and reorders[1][4] == "right",
        "dropping onto right half of sibling column reorders column")

    -- Click window 102 -> focuses, reveals (updating scrollOffset 0 -> 500), closes with panX = 500!
    assert(tapHandler(mouseEvent(TYPES.leftMouseDown, 850, 400)))
    assert(tapHandler(mouseEvent(TYPES.leftMouseUp, 850, 400)))
    assert(S.overviewOpen == false)
    assert(focusedWins[1] == 102)
    assert(revealCalls[1] == 102)
    local closeCall = nativeLog[#nativeLog]
    assert(closeCall[1] == "close", "calls native overviewClose")
    assert(closeCall[2].displays[1].targetWs == 1)
    assert(closeCall[2].displays[1].panX == 500, "passes scroll delta panX for seamless zoom-in")
    assert(suspended[#suspended] == false, "borders resume immediately behind the level-102 closing overlay")

    -- Reopen and press Escape to cancel cleanly.
    Overview.toggle()
    assert(S.overviewOpen == true)
    assert(tapHandler(keyEvent(53))) -- Escape
    assert(S.overviewOpen == false)
    assert(#gotoCalls == 0, "Escape does not switch workspace")
    assert(suspended[#suspended] == false, "borders resume after Escape")

    -- Stop while open tears down immediately via native overviewStop.
    Overview.toggle()
    Overview.stop()
    assert(S.overviewOpen == false)
    assert(nativeLog[#nativeLog][1] == "stop")
    assert(suspended[#suspended] == false)
end)

-- 3. Pure-Lua hs.canvas fallback (when native slide has no overviewOpen) and classic grid mode.
runIsolated(function()
    local noop = function() end
    local canvasShown, canvasDeleted = 0, 0
    local screen = {
        getUUID = function() return "MAIN" end,
        fullFrame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
    }
    local w1 = {
        id = function() return 10 end,
        application = function() return { name = function() return "Term" end, bundleID = function() return "com.term" end } end,
        title = function() return "shell" end,
    }
    hs = {
        settings = { get = function() return nil end },
        screen = { allScreens = function() return { screen } end },
        mouse = { getCurrentScreen = function() return screen end },
        keycodes = { map = { escape = 53 } },
        canvas = {
            windowLevels = { overlay = 102 },
            new = function()
                return {
                    level = noop, behavior = noop, mouseCallback = noop,
                    appendElements = noop, replaceElements = noop,
                    show = function() canvasShown = canvasShown + 1 end,
                    delete = function() canvasDeleted = canvasDeleted + 1 end,
                }
            end,
        },
        eventtap = {
            event = { types = { keyDown = 1, mouseMoved = 2, leftMouseDown = 3, leftMouseDragged = 4,
                leftMouseUp = 5, rightMouseDown = 6, rightMouseUp = 7, otherMouseDown = 8, scrollWheel = 9 } },
            new = function() return { start = function(self) return self end, stop = noop } end,
        },
    }
    package.loaded["hyprspoon.util"] = { focusHistory = {}, native = function() return nil end, warpToWindow = noop }
    package.loaded["hyprspoon.focus"] = { currentWindow = function() return w1 end, focus = noop }
    package.loaded["hyprspoon.spaces"] = {
        overview = function()
            return { { n = 1, display = "MAIN", showing = true, windows = {
                { id = 10, win = w1, frame = { x = 0, y = 0, w = 500, h = 800 } },
            } } }
        end,
        label = function(n) return tostring(n) end,
        isHidden = function() return false end,
        nextEmptyWorkspace = function() return nil end,
    }
    package.loaded["hyprspoon.border"] = { suspend = noop }
    package.loaded["hyprspoon.anim"] = { get = function() return { curve = "ease", duration = 0 } end }
    package.loaded["hyprspoon.scroll"] = {}

    local S = require("hyprspoon.state")
    S.cfg = { overview = { style = "niri" }, border = { active = "#6c99ba" } }
    S.autoFloat = {}
    local Overview = require("hyprspoon.overview")

    -- Niri Lua canvas fallback.
    Overview.toggle()
    assert(S.overviewOpen and canvasShown == 1)
    Overview.toggle()
    assert(not S.overviewOpen and canvasDeleted == 1)

    -- Classic grid mode.
    S.cfg.overview = { style = "grid" }
    Overview.toggle()
    assert(S.overviewOpen and canvasShown == 2)
    Overview.stop()
    assert(not S.overviewOpen and canvasDeleted == 2)
end)

-- 4. Spaces.nextEmptyWorkspace & Spaces.sendWindowToWorkspace.
runIsolated(function()
    local noop = function() end
    local scrA = {
        getUUID = function() return "A" end, name = function() return "A" end, id = function() return 1 end,
        frame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
        fullFrame = function() return { x = 0, y = 0, w = 1000, h = 800 } end,
    }
    local parkedAt = {}
    local w1 = {
        id = function() return 10 end,
        frame = function() return { x = 0, y = 0, w = 500, h = 800 } end,
        screen = function() return scrA end,
        application = function() return { bundleID = function() return "com.test" end } end,
        moveToScreen = noop,
    }
    local settings = {}
    hs = {
        settings = { get = function(k) return settings[k] end, set = function(k, v) settings[k] = v end },
        timer = { doAfter = function() return { stop = noop } end, secondsSinceEpoch = function() return 1000 end },
        screen = { allScreens = function() return { scrA } end, primaryScreen = function() return scrA end },
        mouse = { getCurrentScreen = function() return scrA end, absolutePosition = noop },
        window = { list = function() return { { kCGWindowNumber = 10 } } end },
        focus = noop,
    }
    package.loaded["hyprspoon.util"] = {
        focusHistory = {}, winByID = { [10] = w1 },
        managedWindows = function() return { w1 } end,
        rulesFor = function() return {} end,
        setFrame = function(w, f) parkedAt[w:id()] = f end,
        pointInFrame = function() return true end,
        native = function() return { liveIDs = function() return { [10] = true } end } end,
    }
    package.loaded["hyprspoon.tree"] = {
        bootTime = 1000, setOf = noop, tabsOf = noop, rectFor = noop, findByID = noop,
        membersOf = function() return {} end, removeID = function() return nil end, saveTrees = noop,
    }
    package.loaded["hyprspoon.focus"] = { invalidateWindowCache = noop, focus = noop, currentWindow = noop, noteFocus = noop }
    package.loaded["hyprspoon.discover"] = { cancelLayoutCheck = noop, windowInfoFor = function() return { uuid = "A" } end }
    package.loaded["hyprspoon.layout"] = { tileNow = noop, scheduleRetile = noop, BSP_SETTLE = 0 }
    package.loaded["hyprspoon.bar"] = { update = noop }
    package.loaded["hyprspoon.hud"] = { update = noop, switched = noop }
    package.loaded["hyprspoon.border"] = { forget = noop, sync = noop, syncNow = noop, hide = noop }
    package.loaded["hyprspoon.restore"] = { savedActive = function() return {} end, match = noop, forget = noop }
    package.loaded["hyprspoon.slide"] = { reset = noop, forget = noop, switch = function() return false end, hideScratchpad = function() return false end }
    package.loaded["hyprspoon.hooks"] = { fire = noop }

    local S = require("hyprspoon.state")
    S.cfg = { namedWorkspaces = {}, displays = {} }
    S.trees, S.maximized, S.filled, S.untiled, S.layouts, S.windowInfo, S.applied = {}, {}, {}, {}, {}, {}, {}
    S.fullscreen, S.offSpace = {}, {}
    S.settleUntil = 0

    local Spaces = require("hyprspoon.spaces")
    Spaces.start()
    -- Workspace 1 is currently empty -> no trailing empty workspace needed.
    assert(Spaces.nextEmptyWorkspace("A") == nil, "empty workspace 1 needs no extra trailing empty slot")
    Spaces.claim(w1, "A")
    -- Workspace 1 now has w1 -> trailing empty workspace is 2.
    assert(Spaces.nextEmptyWorkspace("A") == 2, "next empty workspace after occupied ws1 is 2")
    -- Drag w1 to workspace 2 without switching away from workspace 1.
    assert(Spaces.sendWindowToWorkspace(w1, 2) == true)
    assert(Spaces.workspaceOf(10) == 2 and Spaces.isHidden(10) and parkedAt[10] ~= nil,
        "w1 moved to hidden workspace 2 and parked")
    -- Now workspace 2 is the last numbered workspace and has w1 -> trailing empty workspace is 3!
    assert(Spaces.nextEmptyWorkspace("A") == 3, "next empty workspace after occupied ws2 is 3")
end)

print("Overview tests passed")
