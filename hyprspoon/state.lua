-- hyprspoon/state.lua: Configuration and state shared between the window manager modules.

local S = {}
package.loaded["hyprspoon.state"] = S

-- Native tabs need no option. groupNext/groupPrev press the app's tab
-- buttons; moveOutOfGroup uses Window > Move Tab to New Window. They are
-- unbound by default. Native sets use the app's bar, with no hyprspoon bar.
-- frames.so supplies Space-based detection and exact member raising;
-- without it, discovery uses app lists and the frame guess.

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
        -- A move drags a slightly shrunk, see-through picture of the window,
        -- like Hyprland's (a prototype, #26): { scale = 0.95, opacity = 0.8,
        -- duration = 0.15 }, true for those, or false. macOS ignores alpha
        -- on other apps' windows, so it's a capture (about 40ms): the drag
        -- starts with the window itself and the picture takes over once
        -- it's up, the window parked out of sight meanwhile. Its contents
        -- are as they were when the drag began; `duration` is seconds to
        -- shrink and fade, and to fade over the window on drop. Moves only:
        -- resizes drag the window. Needs hyprspoon.native.frames and
        -- hyprspoon.native.slide (make -C hyprspoon/native) and Screen
        -- Recording permission; without them drags are as with false.
        dragEffect = false,
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

    -- How animations move, like Hyprland's `animation` lines. These fields
    -- set every kind; a kind's own table overrides them for it:
    --   curve = "spring"   or "ease" (quad-out over `duration`)
    --   mass, stiffness, damping   the spring (Hyprland's dampening)
    --   duration           seconds an eased animation takes. Windows
    --                      animate only while theirs is above 0
    --                      (tiling.animationDuration by default)
    -- The kinds:
    --   workspaces = {}    workspace and scratchpad slides (default: the
    --                      spring below, mass 0.6, stiffness 800, damping 38)
    --   windows = {}       retiles (default: ease over
    --                      tiling.animationDuration). Windows moved through
    --                      accessibility always ease; a spring moves the
    --                      pictures of experimental.captureRetile
    --   fadeIn = {}        with captureRetile: new windows fading in as
    --                      they pop in, and the pictures fading to the
    --                      real windows once settled (default: as windows)
    -- e.g. { curve = "spring", duration = 0.2 } springs everything, and
    -- { windows = { curve = "ease", duration = 0.15 } } only retiles.
    animations = {},

    -- Workspaces slide in and out as they switch, like Hyprland's, moving
    -- as animations.workspaces says (mass, stiffness and damping here are
    -- its spring when that doesn't set one). Set to false to switch without. Needs hyprspoon.native.slide (make -C hyprspoon/native) and Screen
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
        -- The axis: "horizontal" or "vertical" (fingers up for the next
        -- workspace). nil: as slide.workspaces.
        direction = nil,
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

    -- Title strips for tiled groups; group.bar = false disables them.
    -- Backgrounds reuse border.active/inactive (default colours when borders
    -- are off). Native tab sets outside groups never get a strip.
    group = { bar = {
        height = 24, -- points reserved above the shown window; 0 hides it
        font = false, -- false uses the system menu-bar font, or a font name
        size = 12, -- title font size in points
        padding = 8, -- horizontal padding inside each equal-width segment
        radius = 0, -- segment corner radius in points
        gap = 0, -- space between segments, in points
        inset = 0, -- keep the strip this far from each side, e.g. the window's corner radius
        overlap = 0, -- with tabs, how far they extend down over the window's top edge, in points
        outset = 0, -- points past each side of the window; "border" matches the border width
        under = false, -- with overlap, the tabs look to sit behind the window: its corners and ring show over them
        tabs = false, -- tab look: flush with the window, rounded on top, inactive ones lowered
        drop = 0, -- with tabs, how far inactive tabs sit below the active one, in points
        offset = 0, -- extra space between the segments and the border ring, in points
        text = { white = 1 }, -- title colour: "#rrggbb" or hs.drawing.color table
        active = false, -- shown tab when focused; false uses border.active
        inactive = false, -- other tabs, and the shown one unfocused; false uses border.inactive
        fade = false, -- seconds for the shown tab to blend as focus moves; false uses border.fade, 0 snaps
    } },

    -- App names whose windows are never managed or tiled (palettes, overlays,
    -- anything noisy). Border masking still watches them as occluders.
    ignoreApps = {},

    -- Per-window rules, like Hyprland's windowrules. Each matches on any of
    -- `app` (the app's name), `title` (a Lua pattern), and `role` and
    -- `subrole` (the accessibility role, e.g. "AXWindow", and subrole, e.g.
    -- "AXDialog"), and sets:
    --   float = true/false   float/tile a standard window; dialogs always float
    --   workspace = n        put it on workspace n when it first appears,
    --                        and go there unless `silent = true` (n can
    --                        be a named workspace, e.g. "A")
    --   pseudo = true        on first insertion into a tree, use its saved
    --                        pre-tiling size, centred and clamped to its tile.
    --                        Off by default; does not force floating windows
    --                        to tile. false does not clear saved pseudotiling.
    -- Pseudotiling follows moves, swaps and floating, and persists with the
    -- layout across reloads/restarts. Mouse edges change its remembered size;
    -- keyboard resize changes splits. Maximize/fill temporarily overrides it.
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
    --   opacity = 0..1       override alpha for border masking only; does
    --                        not change the window (managed windows only)
    -- Match fields must all match; only title is a pattern, the others are
    -- exact strings. With no match fields, a rule matches all managed windows.
    -- size/position also accept { w = ..., h = ... } / { x = ..., y = ... };
    -- both coordinates must be numbers. A position wins over centring.
    -- Placement fields do not enable floating. Without them, standard floats
    -- centre and dialogs keep their app's position. noborder defaults false;
    -- opacity only affects border masking. Saved manual float choices override float rules
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

    -- Status bar hooks, by event: `workspace` (membership or showing),
    -- `focus` (window/workspace/display), `layout` (a layout applied, even
    -- with unchanged frames), `display` (screens changed). See hooks.lua.
    -- Each configured event runs once on start() and once per run-loop
    -- turn, in display/workspace/layout/focus order. Unchanged focus is
    -- dropped. Callbacks get the focus at delivery, not what changed:
    -- { event =, window = id, app = name, workspace = name, display = UUID },
    -- false for missing values. Keep callbacks short; they run in Hammerspoon.
    -- `on[event]` is one function; `exec[event]` is a command or list run
    -- asynchronously through /bin/sh. The same fields are strings in
    -- HYPRSPOON_EVENT, HYPRSPOON_WINDOW, HYPRSPOON_APP, HYPRSPOON_WORKSPACE,
    -- HYPRSPOON_DISPLAY; missing values are empty strings. A running
    -- command gets at most one rerun with the latest values per event.
    -- Hammerspoon's PATH may omit Homebrew, so use full paths. E.g.
    --   on = { workspace = function(e) print("now on " .. tostring(e.workspace)) end },
    --   exec = { workspace = "/opt/homebrew/bin/sketchybar --trigger hyprspoon_workspace" },
    on = {},
    exec = {},

    tiling = {
        outerGap = 10,  -- gap between tiles and the screen edge
        innerGap = 5,   -- gap between tiles
        minRatio = 0.20, -- how far a split can be dragged towards either side
        maxRatio = 0.80,
        -- Seconds to animate retiles over; 0 snaps. Mouse drags always snap.
        -- animations.windows.duration (or animations.duration) overrides it.
        animationDuration = 0,
        -- Drag-and-drop landing highlight.
        dropColor = { red = 0.35, green = 0.6, blue = 1 },
    },

    -- The layout workspaces are tiled in, unless `workspaces` says
    -- otherwise: "bsp" (also "dwindle") or "scrolling" (also "scroll";
    -- see `scrolling`). Hyprland's general:layout.
    layout = "bsp",

    -- The layout of particular workspaces, by number or name (a name as
    -- `namedWorkspaces` gives it, or a display's), e.g.
    --   workspaces = { [3] = { layout = "scrolling" }, A = { layout = "bsp" } }
    -- cycleLayout and setLayout choose another while running; that's kept
    -- with the workspace, over a reload, and wins over this and `layout`.
    -- Scratchpads are always "bsp".
    workspaces = {},

    -- niri's scrollable tiling, for workspaces whose layout is "scrolling"
    -- (`layout`, `workspaces`, cycleLayout). Tiled windows go in columns
    -- side by side, scrolled sideways so the focused one is in view; a new
    -- window opens as a column right of the focused one. In a workspace
    -- laid out in columns:
    --   focus      left/right: the column beside (its window focused
    --              last); up/down: within the column
    --   move       left/right: the whole column (move-column-*), or with
    --              moveConsumes, into and out of columns; up/down: the
    --              window within its column
    --   swap       left/right: windows with the column beside
    --   resize     width by a percentage of the area, height within
    --              the column; window edges and modifier-drag too
    --   toggleMaximize  the column full width (maximize-column)
    --   rotate/mirror   cycleColumnWidth forward/back (columns don't
    --              rotate); toggleSplit does nothing
    --   consumeOrExpel(dir), moveColumn(dir), consumeIntoColumn,
    --   expelFromColumn, cycleColumnWidth(back), centerColumn,
    --   centerVisibleColumns, expandColumn, focusColumnEnd(last),
    --   moveColumnToEnd(last); defaultHotkeys binds most of them
    -- Dragging a window onto a column puts it beside the column, or above
    -- or below the window, by the edge it's dropped nearest. A window that
    -- joins a column remembers its own width, and has it again when it
    -- leaves. Columns out of sight are parked in the display's corner.
    -- Its options (false for the defaults below), a table:
    --   width = 0.5         a new column's share of the tiling area
    --   presets = { 1/3, 1/2, 2/3 }  the widths cycleColumnWidth goes
    --                       through
    --   center = "never"    "always" (or true) keeps the focused column
    --                       centred; "on-overflow" centres it when it
    --                       doesn't fit beside the column focused before
    --   centerSingle = false  centre a column that's alone
    --                       (always-center-single-column)
    --   peek = 0            points kept free at each side, where the
    --                       columns beside always show (niri's struts);
    --                       widths are shares of what's left
    --   fill = false        columns of `width` share the area while they
    --                       fit (not niri's: one fills it, two take half...)
    --   duration = 0.2      seconds a scroll takes; 0 snaps
    --   moveConsumes = false  move left/right takes the window into the
    --                       column that way, or out of its own into a new
    --                       one (consume-or-expel), instead of moving the
    --                       column: two moves swap columns (moveColumn
    --                       still moves columns)
    --   edgeToDisplay = true  past the first or last column, focus and
    --                       move go on to the display that way; false
    --                       stops there, as niri does
    --   ffmMaxScroll = nil  focus follows mouse only focuses a column if
    --                       that scrolls the view at most this share of
    --                       its width; 0 for only columns in view (niri's
    --                       max-scroll-amount)
    --   wheel = { "alt" }   holding these, scrolling (two fingers, or a
    --                       mouse wheel a column a step) scrolls the
    --                       columns, as niri's Mod+scroll; false: none
    --                       (wheel and swipe only run when `layout`,
    --                       `workspaces` or a kept cycleLayout choice has
    --                       a workspace scroll as the Spoon starts)
    --   swipe = false       fingers whose sideways swipe scrolls the
    --                       columns, settling on one; not the same as
    --                       swipe.fingers unless workspaces swipe
    --                       vertically (swipe.direction)
    --   swipeSpan = 0.5     share of the trackpad that scrolls a view
    scrolling = false,

    -- Features still being tried out, off by default. They may change or
    -- go before they graduate to options of their own.
    experimental = {
        -- Hide the parts of a ring that windows above its own cover (a
        -- float over a tile, Spotlight, another app's panel). false, true
        -- (the defaults below), or a table:
        --   drags = "mask"      while a native ring preview is active:
        --                       "mask" keeps the rings masked as windows
        --                       move; "show" draws them on top, as without
        --                       masks, and masks them again on drop
        -- A ring shows through a faded window, and through a window with an
        -- `opacity` rule (e.g. { app = "Ghostty", opacity = 0.85 }), dimmed.
        -- The rule wins over reported alpha and changes only the mask.
        -- Ignored windows use reported alpha; content transparency needs a
        -- rule, and blur is not reproduced. Stacked windows multiply.
        -- "show" removes all masks during native previews; Lua fallback
        -- drags and ordinary title-bar drags keep their masks.
        -- Needs hyprspoon.native.border and macOS 13. Rebuild native modules
        -- after updating. Off means no snapshot or extra window watching.
        borderMask = false,
        -- Retiles glide pictures of the tiles to their new places, as
        -- Hyprland's windows do, instead of easing each window through
        -- accessibility moves: one capture of the display's tiles (about
        -- 40ms, before anything moves) over the wallpaper, while the
        -- windows move at once beneath. A picture keeps its size; where its
        -- tile outgrows it, a band of its edge is mirrored and the rest
        -- stretched from there, and the pictures show the apps' latest
        -- frames as they glide (refresh). Once it settles the overlay fades
        -- to the real windows. New windows pop in at their tiles. Not while
        -- dragging. Scrolling columns scroll the same way: columns going
        -- out of sight glide off the display's edge, and come back in with
        -- the picture they went with (or pop in without one).
        -- Floating windows over the tiles are hidden until it's done.
        -- Moves as animations.windows and animations.fadeIn say; on while
        -- windows animate (in scrolling workspaces, while
        -- scrolling.duration is above 0). true, or a table:
        --   popin = 0.8   share of their size new windows grow from (1:
        --                 they only fade in)
        --   hold = 0.05   seconds the pictures stay after they settle
        --   mirror = 32   points of a growing window's edge mirrored before
        --                 the rest is stretched (0: stretched only)
        --   refresh = "live"  capture the windows back to back while they
        --                 glide (about every 40ms), each picture in place of
        --                 the last, so they show the apps' latest frames;
        --                 true: once each has its new size, faded in;
        --                 false: never
        -- A prototype (#19); needs hyprspoon.native.slide and Screen
        -- Recording.
        captureRetile = false,
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
