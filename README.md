# hyprspoon

A Hyprland-inspired tiling window manager for macOS, as a
[Hammerspoon](https://www.hammerspoon.org) Spoon.

- **BSP tiling**, toggled globally or per workspace, with gaps, rotate,
  mirror, balance and preselection. Drag a tile onto another to move it, and
  resize splits with the mouse, the keyboard or the windows' own edges.
- **Workspaces of its own**, numbered 1 to 10 plus named scratchpads, switched
  instantly by hotkey or a three-finger swipe. They don't use macOS
  Spaces, so there's no Mission Control animation. Give displays their
  own workspaces in the config; any other display (a projector, AirPlay)
  gets one workspace of its own.
- **Workspace slides** on a spring, like Hyprland's animations.
- **Window borders** drawn by WindowServer, fading between the active and
  inactive colours.
- **Modifier + drag** anywhere on a window to move or resize it.
- **Focus follows mouse** (optional), and cursor warping on keyboard focus.
- **Window rules**: float a window, pin it, or send it to a workspace by app
  or title.
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
and slides and borders are off.

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
reloads). See [`examples/init.lua`](examples/init.lua) for a fuller config.

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

### Tiling (`tiling`)

| Option | Default | Description |
|---|---|---|
| `tiling.outerGap` | `10` | Gap between tiles and the screen edge, in points |
| `tiling.innerGap` | `5` | Gap between tiles, in points |
| `tiling.minRatio` / `tiling.maxRatio` | `0.20` / `0.80` | How far a split can be moved towards either side |
| `tiling.animationDuration` | `0` | Seconds to animate retiles over; `0` snaps. Mouse drags always snap |
| `tiling.dropColor` | `{ red = 0.35, green = 0.6, blue = 1 }` | Colour of the highlight where a dragged tile will land |

### Mouse (`mouse`)

Modifiers held while dragging anywhere on a window, as lists of
`"alt"`, `"cmd"`, `"ctrl"`, `"shift"`. Set one to `false` to disable it.

| Option | Default | Description |
|---|---|---|
| `mouse.move` | `{"alt"}` | Left-drag to move (dropping into the tiling layout) |
| `mouse.resize` | `{"alt", "cmd"}` | Left-drag to resize |
| `mouse.rightResize` | `{"alt"}` | Right-drag to resize |

### Workspaces

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
Colours are `"#rrggbb"` strings or `hs.drawing.color` tables. Set
`border = false` to disable. Needs the native `border` module.

| Option | Default | Description |
|---|---|---|
| `border.active` | `"#6c99ba"` | Colour of the focused window's ring |
| `border.inactive` | `{ hex = "#595959", alpha = 0xaa / 255 }` | Colour of the other windows' rings; `false` for none |
| `border.width` | `3` | Ring width in points |
| `border.radius` | `12` | Corner radius for windows whose own isn't reported (macOS reports it from 26) |
| `border.fade` | `0.15` | Seconds to blend between the colours as focus moves; `0` snaps |

### Slides (`slide`)

Workspaces slide in and out on a spring as they switch. Set `slide = false`
to switch without. Needs the native `slide` module and Screen Recording
permission, and costs one ~40ms capture per switch.

| Option | Default | Description |
|---|---|---|
| `slide.workspaces` | `"horizontal"` | Numbered workspaces: `"horizontal"` (the next comes from the right), `"vertical"` (from below), or `false` |
| `slide.scratchpads` | `"bottom"` | Edge scratchpads come from and go back to: `"bottom"`, `"top"`, `"left"`, `"right"`, or `false` |
| `slide.mass` / `slide.stiffness` / `slide.damping` | `0.6` / `800` / `38` | The spring, as Hyprland's mass, stiffness and dampening |
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
| `ignoreApps` | `{}` | App names whose windows are never watched or tiled, e.g. `{"Raycast"}` |

Each rule matches on `app` (the app's name) and/or `title` (a Lua
pattern), and sets any of:

| Field | Description |
|---|---|
| `float` | `true` to float the window, `false` to tile it even if it would float |
| `workspace` | Workspace to put it on when it first appears: a number, or a named workspace like `"A"` |
| `silent` | With `workspace`, `true` to stay on the current workspace instead of going there |
| `pin` | `true` to float it on every workspace of its display, overriding `float`; off by default |

For a pinned window, a `workspace` rule only applies if that workspace is
already showing; it can take the window to that display. A hidden target
is ignored. Saved manual floating choices take precedence over float rules.
`pin = false` does not undo a saved manual pin.

Rules are read once per window, when it first appears; later matching rules
win.

```lua
rules = {
    { app = "1Password", float = true },
    { app = "Slack", workspace = 4, silent = true },
    { app = "Finder", title = "^Copy", float = true },
}
```

## Default keymap

`defaultHotkeys` uses Option as Hyprland's SUPER. To change a binding, edit
the table before passing it to `bindHotkeys`. Each key is an action name, so
you can also build your own table from scratch.

| Keys | Action |
|---|---|
| Option+H/J/K/L | Focus left/down/up/right (past the last window, the display that way, even an empty one) |
| Option+Shift+H/J/K/L | Move the window in that direction (`swapLeft` etc. swap instead, unbound) |
| Option+arrows | Resize by 10% (repeats while held) |
| Ctrl+Option+arrows | Open the next window on that side (again to cancel) |
| Option+1…0 | Go to workspace 1…10 |
| Option+Shift+1…0 | Move the window to workspace 1…10 |
| Ctrl+Option+1…0 | Move the window there without following |
| Option+A/S/D | Toggle scratchpad A/S/D (Shift / Ctrl to move a window there) |
| Ctrl+Option+H/L | Previous / next workspace |
| Option+\` | Back to the previous workspace |
| Option+, / . | Focus the display to the left / right (Shift: move the window, Ctrl: move the workspace) |
| Option+B | Toggle tiling (Shift: just this workspace) |
| Option+T | Toggle floating |
| Unbound | `togglePin`: pin or unpin the focused window on its display |
| Option+G | Cycle through floating windows |
| Option+F | Fill the screen without gaps (Shift: maximize inside the gaps) |
| Option+Y | Flip the split |
| Option+= | Balance the splits |
| Option+R | Rotate the layout (Shift: mirror it) |
| Option+Tab | Overview |
| Option+W | Close the window |

To bind pinning before calling `bindHotkeys`:

```lua
local keys = spoon.hyprspoon.defaultHotkeys
keys.togglePin = { { "alt", "shift" }, "p" }
spoon.hyprspoon:bindHotkeys(keys)
```

Option+letter shortcuts replace the characters macOS types with Option
(å, ß, ∂ and so on). Remap the ones you need for typing.

## Scripting

The actions are plain functions on `spoon.hyprspoon`, so you can bind them
yourself or call them from the `hs` command-line tool
(`require("hs.ipc")` in your config):

```sh
hs -c 'spoon.hyprspoon.gotoWorkspace(3)'
hs -c 'spoon.hyprspoon.togglePin()'
hs -c 'return hs.json.encode(spoon.hyprspoon.workspaces())'
```

`togglePin()` takes no arguments and acts on the focused managed window.
With no focused window it does nothing. It also works with tiling off.

## Troubleshooting

- **Windows stuck in a corner.** Windows on hidden workspaces are parked in
  a corner of the display. Quitting Hammerspoon brings them back, but a
  crash leaves them there. Start Hammerspoon again, then switch to their
  workspace or quit it normally.
- **A pinned window stopped following.** Turning it into a tile or moving
  it silently to a hidden workspace removes the pin. Focus it and call
  `togglePin` to pin it again.
- **Logs.** Set `debug = true` in the options to log tiling decisions to
  the Hammerspoon console.
- **Native modules not loading.** The console says which one and why.
  Rebuild with `make`, or clear the quarantine flag (see [Install](#install)).

## Known limitations

- It uses private macOS (SkyLight) APIs for borders, slides and window
  events, so a macOS update can break them. The Lua fallbacks keep the
  basics working.
- It wraps `hs.reload` to tell a reload apart from a quit, so that windows
  stay parked across a reload.
- Pinned windows stay out of workspace slide pictures, but the picture is
  drawn over them. A pin may be covered until the slide ends.
- Native full-screen windows still get their own Space, which macOS
  manages.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
