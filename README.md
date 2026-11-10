# hyprspoon

A Hyprland-inspired tiling window manager for macOS, as a
[Hammerspoon](https://www.hammerspoon.org) Spoon.

- **BSP tiling**, toggled globally or per workspace, with gaps, rotate,
  mirror, balance, preselection and pseudotiling. Drag a tile onto another
  to move it, and resize splits with the mouse, the keyboard or the
  windows' own edges.
- **Workspaces of its own**, numbered 1 to 10 plus named scratchpads, switched
  instantly by hotkey or a three-finger swipe. They don't use macOS
  Spaces, so there's no Mission Control animation. Give displays their
  own workspaces in the config; any other display (a projector, AirPlay)
  gets one workspace of its own.
- **Scrolling columns** (optional, per workspace), like niri: windows in
  columns on a strip wider than the display, scrolled to the focused one
  by keyboard, Option+scroll or a swipe.
- **Workspace slides** on a spring, like Hyprland's animations.
- **Window borders** drawn by WindowServer, fading between the active and
  inactive colours.
- **Modifier + drag** anywhere on a window to move or resize it.
- **Focus follows mouse** (optional), and cursor warping on keyboard focus.
- **Window rules**: float, pin, pseudotile, size, place or send a window to
  a workspace by app, title or role.
- **An overview** of every workspace, in place of Mission Control.
- **Layouts survive** reloads and restarts.
- **Scriptable** from the `hs` command line, like `hyprctl`.

## Requirements

- macOS. Developed and tested on macOS 27 with Hammerspoon 1.1.1; earlier
  versions are untested.
- [Hammerspoon](https://www.hammerspoon.org) 1.1.1 or later.

## Install

1. Download `hyprspoon.spoon.zip` from the
   [latest release](https://github.com/Aethar01/hyprspoon/releases/latest),
   unzip it, and move `hyprspoon.spoon` into `~/.hammerspoon/Spoons/`.
2. The release includes the native modules, which aren't notarized. Clear
   the quarantine flag so Hammerspoon can load them:

   ```sh
   xattr -dr com.apple.quarantine ~/.hammerspoon/Spoons/hyprspoon.spoon
   ```

3. Add the [quick start](#quick-start) to `~/.hammerspoon/init.lua` and
   reload Hammerspoon.

### From source

Building the native modules needs the Xcode command line tools
(`xcode-select --install`):

```sh
git clone https://github.com/Aethar01/hyprspoon ~/.hammerspoon/Spoons/hyprspoon.spoon
make -C ~/.hammerspoon/Spoons/hyprspoon.spoon/hyprspoon/native
```

If Hammerspoon isn't in `/Applications`, pass its path:
`make HS_APP=~/Applications/Hammerspoon.app`.

Every native module is optional. Without one, a slower Lua path takes over,
and slides and borders are off. The `frames` module moves, resizes and
focuses windows and follows modifier-drags. It also checks which window
IDs still exist across all macOS Spaces, so an off-screen window keeps
its workspace when Hammerspoon reloads, and `rescue()` keeps the parked
frames of windows it can't reach yet.

## Permissions

In **System Settings → Privacy & Security**, give Hammerspoon:

| Permission | Needed for |
|---|---|
| Accessibility | Everything: moving windows, hotkeys, mouse bindings |
| Screen Recording | Workspace slides only (they animate pictures of the windows) |

## Quick start

```lua
hs.loadSpoon("hyprspoon")
spoon.hyprspoon:start()
spoon.hyprspoon:bindHotkeys(spoon.hyprspoon.defaultHotkeys)
```

Tiling starts off. Press **Option+B** to turn it on (it stays on across
reloads). See [`examples/init.lua`](examples/init.lua) for a fuller config,
including hooks for a [status bar](#status-bars).

## Configuration

Pass options to `start()`. Only the ones you change are needed: nested
tables merge with the defaults, so `border = { active = "#ff6600" }` keeps
the other border settings. Lists (modifier lists, `namedWorkspaces`,
`rules`, `ignoreApps`) replace the default list whole.

```lua
spoon.hyprspoon:start({
    focusFollowsMouse = true,
    tiling = { outerGap = 12, innerGap = 6 },
    border = { active = "#ff6600" },
    slide = { workspaces = "vertical" },
    rules = { { app = "1Password", float = true } },
})
```

Defaults are in [`hyprspoon/state.lua`](hyprspoon/state.lua).

### General

| Option | Default | Description |
|---|---|---|
| `focusFollowsMouse` | `false` | Focus the window under the pointer as it moves |
| `reassertFocus` | `true` | Undo macOS moving focus away right after hyprspoon sets it |
| `axTimeout` | `1` | Seconds to wait on an unresponsive app's accessibility API before giving up on a call |
| `minWidth` / `minHeight` | `240` / `140` | Smallest size mouse and keyboard resizes shrink a window to, in points |
| `debug` | `false` | Log tiling decisions to the Hammerspoon console |
| `on` | `{}` | Functions called on changes, by event (see [Status bars](#status-bars)) |
| `exec` | `{}` | Shell commands run on changes, by event (see [Status bars](#status-bars)) |

### Tiling (`tiling`)

| Option | Default | Description |
|---|---|---|
| `tiling.outerGap` | `10` | Gap between tiles and the screen edge, in points |
| `tiling.innerGap` | `5` | Gap between tiles, in points |
| `tiling.minRatio` / `tiling.maxRatio` | `0.20` / `0.80` | How far a split can be moved towards either side |
| `tiling.animationDuration` | `0` | Seconds to animate retiles over; `0` snaps. Mouse drags always snap. [`animations`](#animations-animations) overrides it |
| `tiling.dropColor` | `{ red = 0.35, green = 0.6, blue = 1 }` | Colour of the highlight where a dragged tile will land |

### Animations (`animations`)

How animations move, like Hyprland's `animation` lines. The top-level
fields set every kind at once; a kind's own table overrides them for that
kind. `fadeIn` follows `windows` before the top level.

| Field | Default | Description |
|---|---|---|
| `curve` | `"spring"` for workspaces, `"ease"` for windows | `"spring"`, or `"ease"`: quad-out over `duration` |
| `mass` / `stiffness` / `damping` | `0.6` / `800` / `38` | The spring, as Hyprland's mass, stiffness and dampening (`slide.mass`, `slide.stiffness` and `slide.damping` for workspaces when unset) |
| `duration` | `tiling.animationDuration` for windows | Seconds an eased animation takes. Windows animate only while theirs is above `0` |

| Kind | Animates |
|---|---|
| `animations.workspaces` | Workspace and scratchpad slides |
| `animations.windows` | Retiles. Windows moved through accessibility always ease over `duration`; a spring moves the pictures of [`experimental.captureRetile`](#experimental-options) |
| `animations.fadeIn` | With `experimental.captureRetile`: new windows fading in as they pop in, and the pictures fading to the real windows once settled |

```lua
-- Everything on one spring, retiles over 0.2s:
animations = { curve = "spring", stiffness = 600, duration = 0.2 },
-- Or only retiles eased, workspaces as they were:
animations = { windows = { curve = "ease", duration = 0.15 } },
```

### Pseudotiling

A pseudotiled window keeps its own size, centred in its tile and clamped to
fit. Its tile still reserves the full area for splits and navigation.
`togglePseudo()` turns this on or off for the focused tile. Turning it off
makes the window fill its tile again. The initial size is the frame saved
before tiling, or the current frame if none was saved.

Drag a native edge or use modifier-drag resize to change the remembered
size. It is clamped to the tile and centred again on release. Keyboard
resize (Option+arrows) still moves the splits. Moving the window within
its tile snaps it back to the centre; dropping it onto another tile moves
it through the layout as usual.

Pseudotiling follows the window through swaps, moves, drops, floating,
workspace and display changes, and native full screen. It survives reloads
and is restored with matched windows after a restart. Maximizing or filling
temporarily overrides it; returning to the tile restores it.

### Mouse (`mouse`)

Modifiers held while dragging anywhere on a window, as lists of
`"alt"`, `"cmd"`, `"ctrl"`, `"shift"`. Set one to `false` to disable it.

| Option | Default | Description |
|---|---|---|
| `mouse.move` | `{"alt"}` | Left-drag to move (dropping into the tiling layout) |
| `mouse.resize` | `{"alt", "cmd"}` | Left-drag to resize |
| `mouse.rightResize` | `{"alt"}` | Right-drag to resize |

### Workspaces

Workspace assignments and parked frames survive a reload while a native
full-screen Space or another Desktop is showing. Hidden apps keep their
assignments too.

| Option | Default | Description |
|---|---|---|
| `displays` | `{}` | Workspaces kept on particular displays, by display name or UUID (see below) |
| `namedWorkspaces` | `{"A", "S", "D"}` | Named workspaces after 1 to 10: scratchpads, shown over the workspace beneath |
| `scratchpadScale` | `0.95` | Share of the display's area a scratchpad is laid out in, centred |

`displays` maps each display, by name or UUID, to its workspaces. A
display shows the first of them when it connects:

```lua
displays = {
    ["Built-in Retina Display"] = { 1, 2, 3 },
    ["DELL U2723QE"] = { 4, 5, 6 },
},
```

Workspaces of a display that isn't connected, and numbers not given to
any display, live on the primary display (the one with the menu bar), so
with one display everything is on it. Any other display that isn't
listed, such as a projector or an AirPlay screen, gets one workspace of
its own, named after the display rather than numbered; its windows join
the primary display's workspace when it goes. Use UUIDs for two displays
with the same name. To list them:

```sh
hs -c 'for _, s in ipairs(hs.screen.allScreens()) do print(s:name(), s:getUUID()) end'
```

### Pinned windows

A pinned window floats on whichever workspace its display shows. It stays
on that display as you switch, including scratchpads. A scratchpad with
only pinned windows counts as empty and closes when empty scratchpads are
checked. Move the window to another display to have it follow that display.

`togglePin()` pins or unpins the focused window. Pinning a tile centres it
and makes it float. With tiling off, it stays where it is and is marked to
float when tiling resumes. Unpinning leaves it floating on the current
workspace. `toggleFloat` unpins it when turning it back into a tile.
Moving it silently to a hidden workspace also unpins it so it can stay there;
moving it to a visible workspace keeps the pin.

Pins survive reloads, minimizing and native full screen. On return, the
window joins the workspace its display shows. Manual pins do not survive
a reboot; use a `pin = true` rule to pin newly opened windows again.

### Borders (`border`)

Rings around the windows on show, drawn in the gap outside their edges.
Native full-screen windows, including Split View, have no rings.
Colours are `"#rrggbb"` strings or `hs.drawing.color` tables. Set
`border = false` to disable. Needs the native `border` module. Rings show
over windows covering their target unless
[`experimental.borderMask`](#experimental-options) is enabled.

| Option | Default | Description |
|---|---|---|
| `border.active` | `"#6c99ba"` | Colour of the focused window's ring |
| `border.inactive` | `{ hex = "#595959", alpha = 0xaa / 255 }` | Colour of the other windows' rings; `false` for none |
| `border.width` | `3` | Ring width in points |
| `border.radius` | `12` | Corner radius for windows whose own isn't reported (macOS reports it from 26) |
| `border.fade` | `0.15` | Seconds to blend between the colours as focus moves; `0` snaps |

### Slides (`slide`)

Workspaces slide in and out as they switch, moving as
[`animations.workspaces`](#animations-animations) says. Set `slide = false`
to switch without. Needs the native `slide` module and Screen Recording
permission, and costs one ~40ms capture per switch.

| Option | Default | Description |
|---|---|---|
| `slide.workspaces` | `"horizontal"` | Numbered workspaces: `"horizontal"` (the next comes from the right), `"vertical"` (from below), or `false` |
| `slide.scratchpads` | `"bottom"` | Edge scratchpads come from and go back to: `"bottom"`, `"top"`, `"left"`, `"right"`, or `false` |
| `slide.mass` / `slide.stiffness` / `slide.damping` | `0.6` / `800` / `38` | The spring, as Hyprland's mass, stiffness and dampening, where `animations` doesn't set one |
| `slide.wallpaperRefresh` | `false` | Seconds before the wallpaper slid over is taken again, for wallpapers that change; `false` only on reload and display changes |

### Swipe (`swipe`)

Trackpad swipe to the next or previous workspace on the display under the
pointer. Distances are fractions of the trackpad's width. Set
`swipe = false` to disable.

| Option | Default | Description |
|---|---|---|
| `swipe.fingers` | `3` | Number of fingers |
| `swipe.follow` | `true` | With slides on, the workspaces move with the fingers |
| `swipe.span` | `0.35` | With `follow`, how far the fingers move a whole workspace |
| `swipe.distance` | `0.12` | Without `follow`, how far the fingers travel before it switches |
| `swipe.direction` | `nil` | `"horizontal"` or `"vertical"` (fingers up for the next workspace); by default as `slide.workspaces`. Vertical leaves sideways swipes free to scroll columns |

### Scrolling columns (`scrolling`)

niri's scrollable tiling, per workspace. Tiled windows go in columns side
by side on a strip wider than the display, scrolled so the focused column
is in view. A new window opens as a column right of the focused one; a
column holds one window or several, stacked. Focus, move, swap, resize
and maximize act on columns (see [the keymap](#default-keymap)). Dragging
a window onto a column puts it beside the column, or above or below the
window, by the edge it's dropped nearest. A window that joins a column
remembers its own width, and has it again when it leaves.

macOS won't leave a window wholly off its display, so columns out of sight
slide to the edge and are parked in the display's corner, like a hidden
workspace's windows. Set `scrolling = true` for the defaults, or a table:

| Option | Default | Description |
|---|---|---|
| `scrolling.workspaces` | `true` | All workspaces, or a list such as `{ 3, "A" }`. Scratchpads never scroll |
| `scrolling.width` | `0.5` | A new column's share of the tiling area |
| `scrolling.presets` | `{ 1/3, 1/2, 2/3 }` | The widths `cycleColumnWidth` (Option+R) goes through |
| `scrolling.center` | `"never"` | `"never"` scrolls just enough to show the focused column; `"always"` (or `true`) centres it; `"on-overflow"` centres it when it doesn't fit beside the column focused before |
| `scrolling.centerSingle` | `false` | Centre a column that's on its own |
| `scrolling.peek` | `0` | Points kept free at each side, where the columns beside always show (niri's struts) |
| `scrolling.fill` | `false` | Columns of `width` share the area while they fit (not niri's) |
| `scrolling.duration` | `0.2` | Seconds a scroll takes; `0` snaps |
| `scrolling.moveConsumes` | `false` | Move left/right takes the window into the column that way, or out of its own into a new one, instead of moving the column; two moves pass a column (not niri's) |
| `scrolling.edgeToDisplay` | `true` | Past the first or last column, focus and move go on to the display that way; `false` stops there, as niri does |
| `scrolling.ffmMaxScroll` | `nil` | Focus follows mouse only focuses a column if that scrolls the view at most this share of its width; `0` for only columns in view |
| `scrolling.wheel` | `{ "alt" }` | Holding these, scrolling scrolls the columns: two fingers pan them and settle on one, a mouse wheel goes a column a step; `false` for none |
| `scrolling.swipe` | `false` | Fingers whose sideways swipe pans the columns. Not `swipe.fingers` unless workspaces swipe vertically (`swipe.direction`) |
| `scrolling.swipeSpan` | `0.5` | With `swipe`, the share of the trackpad's width that scrolls a whole view |

```lua
scrolling = { workspaces = { 5 }, center = "always", peek = 48 },
```

### Group bars (`group.bar`)

Grouped tiles have an equal-width segment per member. Click its title to show
and focus it. Drag a segment along the bar to reorder the group; a marker
shows where it will go. Drag it off the bar to take that member out: drop it
beside any tile (its own group's included) or into another group, with the
same highlights as a modifier-drag. A native tab set counts as one member and uses its shown tab's
title when selected; native sets outside groups keep their app's own tab bar.
Empty or unavailable titles read “Untitled”; long titles are truncated.

| Option | Default | Meaning |
| --- | --- | --- |
| `group.bar` | table below | `false` disables the strip and removes its inset |
| `group.bar.height` | `24` | Height in points, clamped to leave at least one point of window content; `0` hides it |
| `group.bar.font` | `false` | System menu-bar font, or a font name |
| `group.bar.size` | `12` | Title font size in points |
| `group.bar.padding` | `8` | Horizontal padding in each segment, in points |
| `group.bar.text` | `{ white = 1 }` | Title colour, a `"#rrggbb"` string or `hs.drawing.color` table |
| `group.bar.active` | `false` | Shown segment's colour when focused; `false` uses `border.active` |
| `group.bar.inactive` | `false` | Other segments, and the shown one unfocused; `false` uses `border.inactive` |
| `group.bar.fade` | `false` | Seconds for the shown segment to blend between `active` and `inactive` as focus moves; `false` uses `border.fade`, `0` snaps |
| `group.bar.radius` | `0` | Segment corner radius in points |
| `group.bar.gap` | `0` | Space between segments in points (none at the strip's ends) |
| `group.bar.inset` | `0` | Keep the segments this far in from each side, in points |
| `group.bar.outset` | `0` | Extend the strip past each side of the window, in points; `"border"` uses `border.width` |
| `group.bar.offset` | `0` | Without `tabs`, extra space between the segments and the ring, in points |
| `group.bar.tabs` | `false` | Tab look: segments rise flush from the window's top edge, rounded on top only |
| `group.bar.drop` | `0` | With `tabs`, how far segments other than the shown one sit lower, in points |
| `group.bar.overlap` | `0` | With `tabs`, how far the strip reaches down over the window, in points |
| `group.bar.under` | `false` | With `overlap`, the window's corners and ring show over the strip, as if it sat behind |

The strip is drawn by the native border module (`border.m`) in the shown
window's ring, so it needs that module, and follows the window as its ring
does. With `border = false` the rings are made invisible but still carry the
strips. The shown segment fades between `active` and `inactive` with the ring,
over `fade` seconds (by default the ring's own `border.fade`). A transparent
`hs.canvas` under the strip takes the
clicks; with `under`, the overlap is left to the window. A title change
redraws only that title. The strip reserves space above the window on the
same layout pass, including maximized and pseudotiled groups. It follows layout
and focus events and title changes when the window filter supports them; there
is no polling. Hidden workspaces, full screen, slides and the overview hide it.
Floating or dissolved groups have no strip. Stopping removes the strips and
insets. Rebuild the native slide module for slide visibility notifications.

### Indicators (`indicators`)

Workspace numbers: 1 to `alwaysShow`, and any other in use, with the
current one highlighted. `show` for the pop-up and badge is
`"hiddenMenuBar"` (only on displays whose menu bar auto-hides), `"always"`,
or `false`.

| Option | Default | Description |
|---|---|---|
| `indicators.alwaysShow` | `5` | Workspaces shown even when empty |
| `indicators.menuBar` | `true` | Show them in the menu bar |
| `indicators.popup.show` | `"hiddenMenuBar"` | Pop-up on the display that switched |
| `indicators.popup.duration` | `0.8` | Seconds before the pop-up fades |
| `indicators.popup.size` | `28` | Pop-up number size in points |
| `indicators.badge.show` | `"hiddenMenuBar"` | Badge kept in a corner of the display |
| `indicators.badge.corner` | `"bottomRight"` | `"topLeft"`, `"topRight"`, `"bottomLeft"` or `"bottomRight"` |
| `indicators.badge.margin` | `6` | Points from the display's edges |
| `indicators.badge.size` | `12` | Badge number size in points |
| `indicators.badge.all` | `false` | Show every workspace's number, not just the display's own |

### Rules and ignored apps

| Option | Default | Description |
|---|---|---|
| `rules` | `{}` | Per-window rules, like Hyprland's windowrules (below) |
| `ignoreApps` | `{}` | App names whose windows are never managed or tiled, e.g. `{"Raycast"}` |

Each rule matches on any of `app` (the app's name), `title` (a Lua
pattern), `role` and `subrole` (the window's accessibility role and subrole,
e.g. `"AXWindow"` and `"AXDialog"`), and sets any of:

| Field | Description |
|---|---|
| `float` | `true` to float a standard window, `false` to tile it even if it would float; dialogs and panels always float |
| `workspace` | Workspace to put it on when it first appears: a number, or a named workspace like `"A"` |
| `silent` | With `workspace`, `true` to stay on the current workspace instead of going there |
| `pseudo` | `true` to pseudotile it when first inserted into a tree, using its saved pre-tiling size; off by default |
| `size` | A float's size when it first appears, `{ w, h }`: points, or fractions of the display for `0 < v <= 1`, e.g. `{ 0.5, 0.6 }`; `1` means the full display |
| `position` | A float's top left when it first appears, `{ x, y }` from the display's top left, in points or fractions like `size` |
| `center` | `true` to centre a new float (floats are by default, dialogs aren't), `false` to leave it where the app put it |
| `noborder` | `true` for no ring around the window |
| `opacity` | `0` to `1`: opacity used by border masking for this managed window; overrides reported alpha without changing the window |
| `pin` | `true` to float it on every workspace of its display, overriding `float`; off by default |

Zero and negative `size`/`position` values are points. Placement clamps the
requested frame to the display's usable area, with a minimum size of one
point. Both coordinates must be numbers. Named forms `{ w = 640, h = 480 }`
and `{ x = 20, y = 30 }` also work. A `position` wins over `center`.
These fields only place automatic floats; they do not make a window float.
Add `float = true` for a standard window that would otherwise tile.
Without placement fields, floats are centred and dialogs keep their app's
position. `noborder` defaults to false; `opacity` only affects border masking.

Existing floats keep their frames across reloads. Saved manual floating
choices take precedence over rules and skip initial placement.

All matching fields in a rule must match. App, role and subrole are exact,
case-sensitive strings; only title uses a Lua pattern. A rule without
matching fields applies to every managed window. Rules do not make ignored
windows manageable.

For a pinned window, a `workspace` rule only applies if that workspace is
already showing; it can take the window to that display. A hidden target
is ignored. `pin = false` does not undo a saved manual pin.

`pseudo` does not force a window to tile. Add `float = false` for a standard
window that would automatically float; dialogs and panels always float.
`pseudo = false` prevents rule-based activation but does not clear saved
pseudotiling. A restored leaf keeps its saved size.

Rules are read once per window, when it first appears; later matching rules
win for each field they set. Titles that change later do not update rules.

```lua
rules = {
    { app = "1Password", float = true },
    { app = "Slack", workspace = 4, silent = true },
    { app = "Finder", title = "^Copy", float = true },
    { app = "Terminal", pseudo = true },
    { app = "Activity Monitor", float = true, size = { 0.5, 0.6 } },
    { subrole = "AXDialog", noborder = true },
}
```

### Experimental options

Features still being tried out, off by default, under `experimental`. They
may change or go before they graduate to options of their own.

| Option | Default | Description |
|---|---|---|
| `experimental.borderMask` | `false` | Hide the parts of a ring that windows above its own cover; `true` for the defaults below, or a table |
| `experimental.borderMask.drags` | `"mask"` | While a native drag preview is active: `"mask"` keeps the rings masked as windows move; `"show"` draws them on top, as without masks, and masks them again on drop |
| `experimental.captureRetile` | `false` | Retiles glide pictures of the tiles, as Hyprland's windows do, with the windows moved at once beneath. A picture keeps its size; where the tile outgrows it, a band of its edge is mirrored and the rest stretched from there, and once settled the overlay fades to the real windows; new windows pop in at their tiles. One ~40ms capture per retile; floating windows over the tiles hide until it's done. Moves as `animations.windows` and `animations.fadeIn` say. `true`, or a table: `popin = 0.8` (share of their size new windows grow from; `1` only fades), `hold = 0.05` (seconds the pictures stay after settling), `mirror = 32` (points of a growing window's edge mirrored before the rest is stretched; `0` stretches only), `refresh = false` (capture the windows again mid-glide once resized; an app still redrawing shows as an extra jump). A prototype (#19) |

Rings are drawn above every window, so without masks a ring shows over a
float, a panel or Spotlight covering its window. With `borderMask`, each
ring is cut out where windows above its own cover it. A ring under a faded
window, or a window with an `opacity` rule (e.g. `{ app = "Ghostty",
opacity = 0.85 }`), shows through it, dimmed; the rule wins over what the
window reports. A window whose content alone is see-through (a terminal
background) looks opaque from outside the app, so it needs a rule. Blur
isn't reproduced. `opacity` only affects masks, not the window itself.
Rules apply to managed windows; ignored apps use their reported alpha.
Stacked see-through windows multiply the amount of ring showing through.
Needs the native `border` module and macOS 13. Rebuild native modules
when updating from source so `border` and `events` both support masking.

`drags = "show"` removes every ring's mask while a native ring preview is
active. Without the `frames` module, drags fall back to Lua and keep their
masks. Ordinary app title-bar drags also keep their masks. With masking
off, there is no snapshot or extra window watching.

```lua
experimental = { borderMask = { drags = "show" } },
```

## Default keymap

`defaultHotkeys` uses Option as Hyprland's SUPER. It's a table from action
name to `{ modifiers, key }` (the names are in the table below). To change
it, edit the table before passing it to `bindHotkeys`:

```lua
local keys = spoon.hyprspoon.defaultHotkeys
keys.workspaceS = { { "ctrl", "alt", "cmd" }, "s" } -- move a binding (frees Option+S for ß)
keys.closeWindow = nil                             -- drop one
keys.swapLeft = { { "alt", "cmd" }, "h" }          -- bind one that's unbound by default
spoon.hyprspoon:bindHotkeys(keys)
```

You can also build your own table from scratch, or skip `bindHotkeys` and
bind the actions with `hs.hotkey` yourself (see [Scripting](#scripting)).

The same keymap comes with other modifiers as SUPER:

```lua
-- Ctrl+Option+Cmd as SUPER; Ctrl+Option+Shift where the table below
-- says Ctrl+Option. Display keys are [ / ].
spoon.hyprspoon:bindHotkeys(spoon.hyprspoon.ctrlAltCmdHotkeys)

-- Custom layers: Ctrl+Cmd as SUPER, Shift+Ctrl+Cmd to move windows,
-- and Ctrl+Option+Cmd+Shift (Hyper) for silent moves and preselection.
local keys = spoon.hyprspoon.hotkeysFor(
    { "ctrl", "cmd" }, { "ctrl", "alt", "cmd", "shift" })
-- Hyper+. is sysdiagnose; use brackets for this layer's display moves.
keys.moveWorkspaceToDisplayPrev[2] = "["
keys.moveWorkspaceToDisplayNext[2] = "]"
spoon.hyprspoon:bindHotkeys(keys)
```

`hotkeysFor(super, ctrlSuper)` adds Shift to SUPER for the move layer.
The third layer defaults to Ctrl+SUPER; pass `ctrlSuper` when SUPER already
includes Ctrl. All three modifier sets must be distinct, including when
using aliases such as `control`, `option` or `⌘`. Call it after `start()`
to use the configured named workspaces.

A Caps Lock Hyper key usually sends Ctrl+Option+Cmd+Shift. It cannot drive
`ctrlAltCmdHotkeys` as SUPER, because that chord is already its Shift layer.
Hyper cannot itself be SUPER in `hotkeysFor`, either: adding Shift would
leave the same chord. The custom example above lets Caps Lock drive the
third layer instead. Custom maps can replace app and system shortcuts;
check the chords you choose.

| Keys | Action | Action names |
|---|---|---|
| Option+H/J/K/L | Focus left/down/up/right (past the last window, the display that way, even an empty one) | `focusLeft`, `focusDown`, `focusUp`, `focusRight` |
| Option+Shift+H/J/K/L | Move the window in that direction | `moveLeft` etc. |
| (unbound) | Swap the window with the one in that direction | `swapLeft` etc. |
| Option+arrows | Resize by 10% (repeats while held) | `resizeLeft` etc. |
| Ctrl+Option+arrows | Open the next window on that side (again to cancel) | `preselectLeft` etc. |
| Option+1…0 | Go to workspace 1…10 | `workspace1` … `workspace10` |
| Option+Shift+1…0 | Move the window to workspace 1…10 | `moveToWorkspace1` … |
| Ctrl+Option+1…0 | Move the window there without following | `moveToWorkspaceSilent1` … |
| Option+A/S/D | Toggle scratchpad A/S/D (Shift / Ctrl to move a window there) | `workspaceA`, `moveToWorkspaceA`, `moveToWorkspaceSilentA` … |
| Ctrl+Option+H/L | Previous / next workspace | `previousWorkspace`, `nextWorkspace` |
| Option+\` | Back to the previous workspace | `gotoPreviousWorkspace` |
| Option+, / . | Focus the display to the left / right (Shift: move the window, Ctrl: move the workspace) | `focusDisplayPrev`/`Next`, `moveToDisplayPrev`/`Next`, `moveWorkspaceToDisplayPrev`/`Next` |
| Option+B | Toggle tiling (Shift: just this workspace) | `toggleTiling`, `toggleWorkspaceTiling` |
| Option+T | Toggle floating | `toggleFloat` |
| (unbound) | Pin or unpin the focused window on its display | `togglePin` |
| (unbound) | Pseudotile the focused tile: keep its own size, centred in the tile | `togglePseudo` |
| (unbound) | Create or dissolve the focused tile’s group | `toggleGroup` |
| (unbound) | Join the existing group in a direction | `moveIntoGroupLeft`, `moveIntoGroupRight`, `moveIntoGroupUp`, `moveIntoGroupDown` |
| (unbound) | Show the next / previous window sharing the focused tile | `groupNext`, `groupPrev` |
| (unbound) | Take the focused window out of the tile it shares, into its own | `moveOutOfGroup` |
| (unbound) | Move the focused group member one place along the group's bar | `moveGroupMemberLeft`, `moveGroupMemberRight` |
| Option+G | Cycle through floating windows | `focusFloat` |
| Option+F | Fill the screen without gaps (Shift: maximize inside the gaps) | `toggleFill`, `toggleMaximize` |
| Option+Y | Flip the split | `toggleSplit` |
| Option+= | Balance the splits | `balance` |
| Option+R | Rotate the layout (Shift: mirror it); in scrolling columns, the column's next (Shift: previous) width preset | `rotate`, `mirror` |
| Option+Tab | Overview | `toggleOverview` |
| Option+W | Close the window | `closeWindow` |

With [`scrolling`](#scrolling-columns-scrolling), these act on its
columns (and do nothing elsewhere); focus, move, resize and Option+Shift+F
act on columns too:

| Keys | Action | Name |
|---|---|---|
| Option+[ / ] | Into the column to the left / right, or out of its own into a new one that way | `consumeOrExpelLeft`, `consumeOrExpelRight` |
| Ctrl+Option+Shift+H/L | Move the column left / right | `moveColumnLeft`, `moveColumnRight` |
| Option+C | Centre the column (Ctrl: the columns in view, together) | `centerColumn`, `centerVisibleColumns` |
| Ctrl+Option+F | Widen the column into the room the columns in view leave | `expandColumn` |
| Option+Home / End | Focus the first / last column (Shift: move the column there) | `focusColumnFirst`, `focusColumnLast`, `moveColumnToFirst`, `moveColumnToLast` |
| Option+scroll | Scroll the columns: two fingers pan them and settle on one; a mouse wheel goes a column a step (`scrolling.wheel`) | |
| (unbound) | Next / previous width preset | `cycleColumnWidth`, `cycleColumnWidthBack` |
| (unbound) | The next column's first window into this one; this window out into its own | `consumeIntoColumn`, `expelFromColumn` |

### Characters and shortcuts each keymap takes over

macOS types a character for most Option and Shift+Option keys, and these
hotkeys take their place. With `defaultHotkeys`, on the US and ABC layouts
(other layouts type other characters):

| Keys | Characters you can no longer type |
|---|---|
| Option+1…0 | ¡ ™ £ ¢ ∞ § ¶ • ª º |
| Shift+Option+1…0 | ⁄ € ‹ › ﬁ ﬂ ‡ ° · ‚ |
| Option+W F B T G Y R C | ∑ ƒ ∫ † © ¥ ® ç |
| Shift+Option+F B R | Ï ı ‰ |
| Option+H J K L | ˙ ∆ ˚ ¬ |
| Shift+Option+H J K L | Ó Ô  (the Apple logo) Ò |
| Option+A S D | å ß ∂ |
| Shift+Option+A S D | Å Í Î |
| Option+= , . | ≠ ≤ ≥ |
| Shift+Option+, . | ¯ ˘ |
| Option+[ ] | “ ‘ |
| Option+\` | the grave accent dead key (à, è, …) |

Option+arrows also stop moving the text cursor by word or paragraph. The
Ctrl+Option bindings take over no characters, but may conflict with VoiceOver
commands when VoiceOver is on.

`ctrlAltCmdHotkeys` takes over no characters: every binding includes Ctrl or Cmd.
It uses `[` / `]` instead of `,` / `.` for all display actions (and puts
consume-or-expel on Ctrl+Option+Shift+`,` / `.`, move-column on
Ctrl+Option+Shift+`;` / `'`), which avoids
macOS's Ctrl+Option+Cmd+Shift+`.` sysdiagnose shortcut and the accessibility
shortcuts Ctrl+Option+Cmd+`,` / `.` (contrast down/up). Workspace 8 stays on
Ctrl+Option+Cmd+`8`, which is also the invert-colours shortcut when that's
turned on in System Settings. Its Ctrl+Option+Shift
layer may still conflict with VoiceOver commands. Other app or customised
system shortcuts can also conflict with either map.

Remap or drop the default bindings you need for typing, or use
`ctrlAltCmdHotkeys`.

## Scripting

The actions are plain functions on `spoon.hyprspoon`, so you can bind them
yourself or call them from the `hs` command-line tool
(`require("hs.ipc")` in your config):

```lua
hs.hotkey.bind({ "alt" }, "w", spoon.hyprspoon.closeWindow)
hs.hotkey.bind({ "alt" }, "h", function() spoon.hyprspoon.focus("left") end)
```

```sh
hs -c 'spoon.hyprspoon.gotoWorkspace(3)'
hs -c 'spoon.hyprspoon.togglePin()'
hs -c 'spoon.hyprspoon.togglePseudo()'
hs -c 'return hs.json.encode(spoon.hyprspoon.workspaces())'
hs -c 'return hs.json.encode(spoon.hyprspoon:query())'
```

`togglePin()` takes no arguments and acts on the focused managed window.
With no focused window it does nothing. It also works with tiling off.

`togglePseudo()` takes no arguments. It acts on the focused tile and does
nothing for a floating window, with tiling off, or with no focused tile.

`toggleGroup()` turns the focused tile into a group, or dissolves its group
back into tiles. A group keeps one window on show and parks the others off
screen. `moveIntoGroup("left" | "right" | "up" | "down")` joins the group in
that direction; an ordinary neighbour is left alone. The hotkey names are
`moveIntoGroupLeft`, `moveIntoGroupRight`, `moveIntoGroupUp`, and
`moveIntoGroupDown`. These actions are unbound in every supplied keymap.
With `mouse.move`, dragging a tile onto a group's bar joins the group at the
marked gap between segments; onto the middle of its tile, after the shown
member, with the whole tile highlighted. Either works on any display.
Dropped nearer the group's edges, it splits beside the group as with any
tile.

`moveGroupMember("left" | "right")` moves the focused member one place along
its group's bar, stopping at the ends; the hotkey names are
`moveGroupMemberLeft` and `moveGroupMemberRight`. Dragging a bar's segment
reorders too (see [Group bars](#group-bars-groupbar)). The order survives
reloads and restarts.

`groupNext()` and `groupPrev()` cycle the focused tile's members.
`moveOutOfGroup()` splits the selected member into a tile beside the group.
Native tab sets join and leave as one member. Groups remain groups down to
one member, survive reloads and restarts, and show the next open member when
the shown window closes. Floating groups survive reloads; restoring floating
groups after a restart is not supported yet. Creation, dissolution, joining
and splitting act on tiles; cycling also works for floating groups.
Group creation is explicit; there is no group rule. A window that opens while
a tiled group has focus joins that group and is shown (a torn-off native tab
still gets its own tile). Tiled groups show a clickable
title strip (see [Group bars](#group-bars-groupbar)).

`groupNext()`, `groupPrev()` and `moveOutOfGroup()` take no arguments. They
act on a tile holding several windows, one on show, and do nothing for a
window that's alone in its tile. For native tabs, next/previous presses the
app's tab buttons in bar order; move out uses Window > Move Tab to New Window.
These actions are unbound by default. The app draws its own tab bar.

Native tabs share one tile. A changed WindowServer snapshot hands the tile
and ring to the shown tab on the next coalesced pass; the other tiles stay
in place. Merge All Windows
combines the app's absorbed tiles, and a torn-off tab splits beside the set.
Moving the shown window to another workspace, or floating it, carries its
known tabs with it. Membership is saved across reloads and matched after a
restart, including background tabs and manually floated native sets. There
is no action for moving another window into a native set.

Build `frames.so` with `make -C hyprspoon/native` for detection using the
app's off-screen windows with no macOS Space. Only windows seen as standard,
or confirmed through accessibility, count; minimized, hidden-app and parked
windows retain their Spaces. One asynchronous snapshot is shared by the apps;
quiet apps reuse cached window lists and tab bars. Only direct native window
tab bars count. A count mismatch triggers an asynchronous accessibility scan,
with retries backed off until the window count changes. Remote element IDs
0–0x7fff are searched in yielding worker chunks, stopping when all wanted IDs
are found. Raising a specific background tab uses its cached window element
or that scan, with an unambiguous title as the only button fallback. Without the module, app window lists remove absorbed
tiles and the frame guess handles switches. That fallback cannot reliably
learn never-shown tabs or restore their membership after a restart.

Independent tab sets with indistinguishable titles can be ambiguous after a
restart; unmatched members are left alone until a switch reveals their tile.
Private macOS APIs and the AX element scan underpin native detection;
windows beyond the token range may need to be shown once to learn them. Finder, TextEdit, Terminal and Preview expose native tab bars.
Ghostty needs a native/tabs title bar; a hidden title bar has no native tabs.
Live verification of this implementation, including Xcode, is pending.

`spoon.hyprspoon:rescue()` returns the number of parked windows brought
back. See [Getting windows back](#getting-windows-back) for a command that
also works when the Spoon isn't loaded.

### Status bars

`spoon.hyprspoon:query()` returns the workspaces, windows and focus as one
table for `hs.json.encode`. Call it after `start()` so the options and
window filter are ready. Every key below is always present, with `false`
where there is no value. Lists encode as arrays, including empty lists.

```jsonc
{
  "focus": { "window": 1234, "app": "Safari", "workspace": "2", "display": "<UUID>" },
  // The primary display first, then left to right.
  "displays": [
    { "uuid": "<UUID>", "name": "Built-in Retina Display", "primary": true,
      "workspace": "2", "focused": true }
  ],
  // Workspaces in use, in menu bar order. `number` is what gotoWorkspace
  // takes; `showing` is true beneath a scratchpad too. Windows: tiles first.
  "workspaces": [
    { "name": "2", "number": 2, "display": "<UUID>", "showing": true,
      "focused": true, "scratchpad": false, "windows": [1234] }
  ],
  // Windows with a workspace (not minimized or full screen). `hidden`:
  // parked on a workspace not showing, or beneath a scratchpad.
  "windows": [
    { "id": 1234, "app": "Safari", "title": "hyprspoon", "workspace": "2",
      "floating": false, "hidden": false, "focused": true }
  ]
}
```

`focus.window` is a window ID; `focus.app` is the app's name, not its
bundle ID. The focused window can belong to an app hyprspoon doesn't
manage, so it need not appear in `windows`. With an empty display focused,
its workspace has focus; otherwise the workspace comes from the focused
window, its display, or the pointer's display.

Display `uuid` and `name` identify the screen. `primary` marks the primary
display; `focused` matches `focus.display`. Its `workspace` is the name of
the workspace on top, including a scratchpad when one is open.

Workspace `name` is a string: a number as text, a scratchpad name, or a
display name. `number` is its numeric ID: scratchpads start at 101, and
workspaces belonging to unconfigured displays use negative IDs. Pass that
ID to `gotoWorkspace()`. `display` is the UUID it lives on, even when
hidden, or the primary display while its own is disconnected. `showing`
is true for the workspace beneath a scratchpad too; `focused` matches the
focused workspace, and `scratchpad` identifies named workspaces. `windows`
lists its window IDs, tiles before floats.

Each window has a numeric `id`, app name, title, and workspace name.
`floating` reflects hyprspoon's floating classification, `hidden` means
parked or beneath a scratchpad, and `focused` matches `focus.window`.
Only managed windows in the current macOS Space's filter appear, grouped
by workspace in the same order as `workspaces`. Hidden apps, minimized
windows and full-screen windows are absent. Reading titles costs an
accessibility call per window, so hooks don't call `query()` themselves.

To hear about changes instead of polling, give `start()` functions in `on`
and shell commands in `exec`, by event:

| Event | When |
|---|---|
| `workspace` | Any change to the workspaces: a switch, one made or forgotten, a window joining or leaving one |
| `focus` | Another window, workspace or display takes focus |
| `layout` | A tiling pass applies a layout, even if the frames stay the same |
| `display` | Displays are connected, disconnected or rearranged |

Configured events run on the next turn of the run loop, once per event
however many times it fired, and once each on `start()`. When several are
pending, they run in this order: `display`, `workspace`, `layout`, `focus`.
A focus event with the same window, workspace and display as the last one
is dropped. Hooks describe the focus at delivery time, not each change
along the way. They don't receive the window or workspace that changed.

Each `on` entry is one function. It gets `{ event, window, app, workspace,
display }` (the `focus` table above, plus the event). It runs in Hammerspoon,
so keep it short; use `exec` for external work. Each `exec` entry is a shell
command or list of commands, run asynchronously through `/bin/sh` with
`HYPRSPOON_EVENT`, `HYPRSPOON_WINDOW`, `HYPRSPOON_APP`, `HYPRSPOON_WORKSPACE`
and `HYPRSPOON_DISPLAY`. Values are strings; missing values become empty
strings. For each event and command, a running command gets at most one
rerun with the latest values. Callbacks run before commands for that event.
Errors go to the console, and other hooks still run. `stop()` drops pending
hooks and reruns; commands already running finish.

Hammerspoon's `PATH` may omit Homebrew. Give SketchyBar's full path in
`exec`: `/opt/homebrew/bin/sketchybar` on Apple Silicon, usually
`/usr/local/bin/sketchybar` on Intel. Check with `command -v sketchybar`
in your terminal and change the examples to match.

```lua
spoon.hyprspoon:start({
    on = {
        workspace = function(e) print("on workspace " .. tostring(e.workspace)) end,
    },
    exec = {
        workspace = "/opt/homebrew/bin/sketchybar --trigger hyprspoon_workspace",
        focus = '/opt/homebrew/bin/sketchybar --trigger hyprspoon_focus'
            .. ' WORKSPACE="$HYPRSPOON_WORKSPACE" APP="$HYPRSPOON_APP"',
    },
})
```

[`examples/sketchybar`](examples/sketchybar) is a SketchyBar setup that
shows numbered workspaces 1 to 10 in use and the focused app this way.
Its README covers installation, IPC and initial updates. Scratchpads and
displays' own workspaces are in `query()`, but need extra items to appear
in this example.

## Getting windows back

Windows on hidden workspaces are parked in a corner of their display.
Quitting Hammerspoon brings them back, but a crash (or `kill -9`) leaves
them there. `rescue()` brings back the parked windows it can reach, using
frames from memory and the saved state. It forgets the workspaces (windows
join the one showing on their display at the next start) and turns tiling
off. If hyprspoon is running, it stops and starts again with the same
options. Otherwise it stays stopped. Tiled windows go back to their frames
from before tiling when those frames are still in memory. A saved frame
whose centre is off every connected display is centred on the primary one.

With `require("hs.ipc")` in your config:

```sh
hs -c 'local s = spoon and spoon.hyprspoon or hs.loadSpoon("hyprspoon"); s:rescue()'
```

Or paste the part in quotes into the Hammerspoon console. Turn tiling back
on with Option+B if the default hotkeys are bound and hyprspoon is started.
Hammerspoon must be running with IPC loaded for `hs -c` to work; this command
loads the Spoon if needed, but does not start Hammerspoon.

Windows on another macOS Space (such as a full-screen one) can't be reached
from the current one: the console says how many are left, and running
`rescue()` again from their Space brings them back. Window IDs only last
until macOS restarts, so after a restart there is nothing to bring back by
ID. Saves wait one second after a workspace change, so a crash can lose
the most recent parked frames. Without a working native `frames.liveIDs()`
query, saved IDs that might have closed stay saved too; the remaining
count can therefore include closed windows. Rebuild the native modules
after updating from source.

## Troubleshooting

- **Windows stuck in a corner.** See [Getting windows back](#getting-windows-back).
- **Empty workspaces left behind.** If a close event was missed, the
  native `frames.liveIDs()` query confirms which saved windows have closed.
  Rebuild `frames` if it is missing or outdated. Without this query, or if
  it fails, uncertain IDs are kept so off-screen windows keep their
  assignments; a close event or a later successful query clears them.
- **Placement rules seem unchanged.** Reopen the window after changing
  `size`, `position` or `center`; reloads preserve an existing float's frame.
  Apps may enforce their own minimum size or adjust the requested frame.
- **A pinned window stopped following.** Turning it into a tile or moving
  it silently to a hidden workspace removes the pin. Focus it and call
  `togglePin` to pin it again.
- **Pseudotiling looks unchanged.** If the remembered size fills the tile,
  drag an edge inward to choose a smaller size. Keyboard resize changes the
  tile's splits instead. Leave maximized or filled mode to see pseudotiling.
- **Masks not appearing.** On macOS before 13, the console reports that
  masking is unavailable and rings keep their usual appearance. Rebuild
  the native modules after updating the source. To turn masking off, set
  `experimental = { borderMask = false }` in your config and reload.
- **Logs.** Set `debug = true` in the options to log tiling decisions to
  the Hammerspoon console.
- **Native modules not loading.** The console says which one and why.
  Rebuild with `make`, or clear the quarantine flag (see [Install](#install)).

## Known limitations

- Scrolling columns out of sight are parked in a corner rather than off
  the display, so a scroll is a slide to the edge, not one continuous
  strip, and apps slow to move their windows lag behind it.
- It uses private macOS (SkyLight) APIs for borders, slides and window
  events, so a macOS update can break them. The Lua fallbacks keep the
  basics working.
- Experimental border masks use rounded window bounds and cannot reproduce
  blur. See-through content needs an `opacity` rule. Masks skip Hammerspoon overlays, windows at screen-saver level or above, and
  windows above normal level that cover a whole display.
- Mask snapshots keep at most 256 eligible windows. If truncated, a ring
  whose target is missing is hidden until it appears in the snapshot. Each
  ring uses at most 32 overlapping windows and 16 transparency regions, so
  dense stacks may leave parts of a ring too visible.
- It wraps `hs.reload` to tell a reload apart from a quit, so that windows
  stay parked across a reload.
- Use one macOS Desktop per display. Window management and `query()`
  only see the current Desktop's managed windows. See
  [Getting windows back](#getting-windows-back) for recovery limits after
  a crash or macOS restart.
- Pinned windows stay out of workspace slide pictures, but the picture is
  drawn over them. A pin may be covered until the slide ends.
- After a reload, an already tiled window has no saved pre-tiling frame.
  Enabling pseudotiling uses its current frame, which may fill the tile.
  Existing pseudotiled windows keep their remembered size.
- Apps may enforce minimum sizes larger than a tile, so a pseudotiled
  window may not fit the requested frame exactly.
- Native full-screen windows still get their own Space, which macOS
  manages. Border checks use the Space type before Lua learns a window is
  full screen. If that private call is unavailable, the native check only
  hides windows that fill a display; Lua still removes rings once it
  discovers the full-screen state.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
