-- wm/state.lua: Configuration and state shared between the window manager modules.

local S = {}
package.loaded["wm.state"] = S

S.defaults = {
    -- Focus the window under the pointer as it moves.
    focusFollowsMouse = true,
    debug = false, -- log tab/tile decisions to the Hammerspoon console
    reassertFocus = true, -- undo macOS moving focus right after we set it

    -- Seconds to wait on an unresponsive app's accessibility API before
    -- giving up on a call.
    axTimeout = 1,

    -- Smallest size the mouse/keyboard resizes will shrink a window to.
    minWidth = 240,
    minHeight = 140,

    -- Modifiers held while dragging anywhere on a window. Set any to false
    -- to disable that binding.
    mouse = {
        move = {"alt"},          -- + left-drag: move (drops into tiling layout)
        resize = {"alt", "cmd"}, -- + left-drag: resize
        rightResize = {"alt"},   -- + right-drag: resize
    },

    -- Workspace numbers: 1..alwaysShow (even when empty) and any other in
    -- use, the current one highlighted.
    indicators = {
        alwaysShow = 5,
        menuBar = true, -- in the menu bar
        -- `show` for the two below: "hiddenMenuBar" (displays whose menu
        -- bar auto-hides), "always", or false.
        -- Pop-up on the display that switched, fading after `duration`.
        popup = { show = "hiddenMenuBar", duration = 0.8, size = 28 },
        -- Badge kept in a corner ("topLeft", "topRight", "bottomLeft",
        -- "bottomRight"), `margin` points from the edges. `all` shows every
        -- number rather than just the display's own.
        badge = { show = "hiddenMenuBar", corner = "bottomRight", margin = 6, size = 12, all = false },
    },

    -- Trackpad swipe between workspaces (next/previous on the display under
    -- the pointer). `distance` is how far the fingers travel sideways, as a
    -- fraction of the trackpad's width. Set to false to disable.
    swipe = {
        fingers = 3,
        distance = 0.12,
    },

    -- Rings around the windows on show, `width` points outside their edges,
    -- in the gap between tiles: the focused window's `active`, the others'
    -- `inactive` (false for none). Colours are "#rrggbb" or hs.drawing.color
    -- tables. `radius` is the corner radius for windows whose own macOS
    -- doesn't report (it does from macOS 26); `fade` is seconds to
    -- blend between the colours as focus moves (0 snaps). Set to false to
    -- disable. Needs wm.native.border (make -C wm/native).
    border = {
        active = "#6c99ba",
        inactive = { hex = "#595959", alpha = 0xaa / 255 },
        width = 3,
        radius = 12,
        fade = 0.15,
    },

    -- App names whose windows are never watched or tiled (palettes, overlays,
    -- anything noisy). Fewer watched windows means fewer events to process.
    ignoreApps = {},

    -- Per-window rules, like Hyprland's windowrules. Each matches on `app`
    -- (the app's name) and/or `title` (a Lua pattern), and sets:
    --   float = true/false   float it, or tile it even if it would float
    --   workspace = n        put it on workspace n when it first appears,
    --                        and go there unless `silent = true`; or
    --                        "scratchpad" to start out in the scratchpad
    -- Rules are read once per window, when it first appears (titles that
    -- change later don't count); later matching rules win. E.g.
    --   rules = {
    --       { app = "1Password", float = true },
    --       { app = "Slack", workspace = 4, silent = true },
    --   }
    rules = {},

    tiling = {
        outerGap = 10,  -- gap between tiles and the screen edge
        innerGap = 5,   -- gap between tiles
        minRatio = 0.20, -- how far a split can be dragged towards either side
        maxRatio = 0.80,
        -- Seconds to animate retiles over; 0 snaps. Mouse drags always snap.
        animationDuration = 0,
        -- Drag-and-drop landing highlight.
        dropColor = { red = 0.35, green = 0.6, blue = 1 },
    },
}

S.cfg = nil

-- Tiling on/off persists across reloads.
S.SETTINGS_KEY = "bspTilingEnabled"
S.tilingEnabled = hs.settings.get(S.SETTINGS_KEY) == true

-- Long-lived objects (taps, watchers, filters). Kept here so they're
-- reachable from the module and never garbage collected.
S.running = {}

return S
