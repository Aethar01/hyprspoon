-- hyprspoon/state.lua: Configuration and state shared between the window manager modules.

local S = {}
package.loaded["hyprspoon.state"] = S

S.defaults = {
    -- Focus the window under the pointer as it moves.
    focusFollowsMouse = false,
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

    -- Workspaces kept on particular displays, by the display's name (as
    -- hs.screen:name() gives it) or UUID, e.g.
    --   displays = { ["Built-in Retina Display"] = { 1, 2, 3 }, ["DELL U2723QE"] = { 4, 5, 6 } }
    -- A display shows its first when it connects. Other numbered
    -- workspaces, and those of displays not connected, live on the primary
    -- display; any other display gets one workspace of its own, named
    -- after it (see hyprspoon/spaces.lua).
    displays = {},

    -- Workspaces with names, after 1 to 10: scratchpads, shown over the
    -- workspace on the display (see hyprspoon/spaces.lua).
    namedWorkspaces = { "A", "S", "D" },
    -- The share of the display's area a scratchpad is laid out in, centred
    -- (Hyprland's special_scale_factor).
    scratchpadScale = 0.95,

    -- Workspaces slide in and out as they switch, like Hyprland's, on a
    -- spring (Hyprland's mass, stiffness and dampening). Set to false to
    -- switch without. Needs hyprspoon.native.slide (make -C hyprspoon/native) and Screen
    -- Recording permission; costs one ~40ms capture per switch.
    slide = {
        mass = 0.6,
        stiffness = 800,
        damping = 38,
        -- Numbered workspaces: "horizontal" (the next comes from the
        -- right), "vertical" (from below), or false.
        workspaces = "horizontal",
        -- The edge scratchpads come from and go back to: "bottom", "top",
        -- "left", "right", or false.
        scratchpads = "bottom",
        -- Seconds before the wallpaper slid over is taken again (once a
        -- slide is over, in the background), for wallpapers that change;
        -- false only on reload and display changes.
        wallpaperRefresh = false,
    },

    -- Trackpad swipe between workspaces (next/previous on the display under
    -- the pointer). With slides and `follow`, the workspaces move with the
    -- fingers, `span` of the trackpad's width moving a whole one; else it
    -- switches once the fingers travel `distance`. Both are fractions of
    -- the trackpad's width. Set to false to disable.
    swipe = {
        fingers = 3,
        follow = true,
        span = 0.35,
        distance = 0.12,
    },

    -- Rings around the windows on show, except native full screen (Split
    -- View too), `width` points outside their edges,
    -- in the gap between tiles: the focused window's `active`, the others'
    -- `inactive` (false for none). Colours are "#rrggbb" or hs.drawing.color
    -- tables. `radius` is the corner radius for windows whose own macOS
    -- doesn't report (it does from macOS 26); `fade` is seconds to
    -- blend between the colours as focus moves (0 snaps). Set to false to
    -- disable. Needs hyprspoon.native.border (make -C hyprspoon/native).
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

    -- Per-window rules, like Hyprland's windowrules. Each matches on any of
    -- `app` (the app's name), `title` (a Lua pattern), and `role` and
    -- `subrole` (the accessibility role, e.g. "AXWindow", and subrole, e.g.
    -- "AXDialog"), and sets:
    --   float = true/false   float/tile a standard window; dialogs always float
    --   workspace = n        put it on workspace n when it first appears,
    --                        and go there unless `silent = true` (n can
    --                        be a named workspace, e.g. "A")
    --   pin = true           float it on every workspace of its display,
    --                        overriding float; off by default. A workspace
    --                        target must already be showing, else ignored.
    --                        false does not clear a saved manual pin.
    -- Pins follow scratchpads too and survive reload/minimize/full screen,
    -- but not reboot. Unpinning leaves a float; tiling it or silently moving
    -- it to a hidden workspace removes the pin.
    --   size = { w, h }      a float's size when it first appears, in points
    --                        or fractions when 0 < v <= 1 (1 is the full
    --                        display); zero and negatives are points
    --   position = { x, y }  likewise its top left, measured from the
    --                        display's top left
    --   center = true/false  centre a new float (they are by default, but
    --                        not dialogs), or leave it where the app put it
    --   noborder = true      no ring around it
    --   opacity = 0..1       how see-through the window itself is, for
    --                        border masking (experimental, PR #38;
    --                        not read on this branch)
    -- Match fields must all match; only title is a pattern, the others are
    -- exact strings. With no match fields, a rule matches all managed windows.
    -- size/position also accept { w = ..., h = ... } / { x = ..., y = ... };
    -- both coordinates must be numbers. A position wins over centring.
    -- Placement fields do not enable floating. Without them, standard floats
    -- centre and dialogs keep their app's position. noborder defaults false;
    -- opacity has no effect. Saved manual float choices override float rules
    -- and skip placement. No fields are set by default (rules = {}).
    -- Placement clamps the requested frame to the display's usable area,
    -- with a minimum size of one point. Reloads keep existing float frames.
    -- Rules are read once per window, when it first appears (titles that
    -- change later don't count); later matching rules win. E.g.
    --   rules = {
    --       { app = "1Password", float = true },
    --       { app = "Slack", workspace = 4, silent = true },
    --       { app = "Activity Monitor", float = true, size = { 0.5, 0.6 } },
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
S.SETTINGS_KEY = "hyprspoon.tiling"
S.tilingEnabled = hs.settings.get(S.SETTINGS_KEY) == true

-- Long-lived objects (taps, watchers, filters). Kept here so they're
-- reachable from the module and never garbage collected.
S.running = {}

return S
