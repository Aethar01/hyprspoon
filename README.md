# hyprspoon

A Hyprland-inspired tiling window manager for macOS, as a
[Hammerspoon](https://www.hammerspoon.org) Spoon.

- **BSP tiling**, toggled globally or per workspace, with gaps, rotate,
  mirror, balance and preselection. Drag a tile onto another to move it, and
  resize splits with the mouse, the keyboard or the windows' own edges.
- **Workspaces of its own**, numbered 1 to 10 plus named scratchpads, switched
  instantly by hotkey or a three-finger swipe. They don't use macOS
  Spaces, so there's no Mission Control animation.
- **Workspace slides** on a spring, like Hyprland's animations.
- **Window borders** drawn by WindowServer, fading between the active and
  inactive colours.
- **Modifier + drag** anywhere on a window to move or resize it.
- **Focus follows mouse** (optional), and cursor warping on keyboard focus.
- **Window rules**: float a window or send it to a workspace by app or title.
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

Pass options to `start()`. Only the ones you change are needed. Every option
and its default is documented in [`hyprspoon/state.lua`](hyprspoon/state.lua).
The main ones:

| Option | Default | |
|---|---|---|
| `focusFollowsMouse` | `false` | Focus the window under the pointer |
| `mouse.move` / `mouse.resize` / `mouse.rightResize` | `{"alt"}` / `{"alt","cmd"}` / `{"alt"}` | Modifiers for dragging anywhere on a window |
| `tiling.outerGap` / `tiling.innerGap` | `10` / `5` | Gaps in points |
| `tiling.animationDuration` | `0` | Seconds to animate retiles over |
| `border.active` / `border.inactive` | `"#6c99ba"` / `{ hex = "#595959", alpha = 0xaa / 255 }` | Ring colours, `"#rrggbb"` or `hs.drawing.color` tables (`inactive = false` for none); `border = false` to disable |
| `border.width` / `border.fade` | `3` / `0.15` | Ring width in points; seconds to blend between the colours |
| `slide.workspaces` / `slide.scratchpads` | `"horizontal"` / `"bottom"` | How workspaces slide (`"horizontal"`, `"vertical"`) and the edge scratchpads come from (`"bottom"`, `"top"`, `"left"`, `"right"`), or `false`; `slide = false` to disable |
| `slide.mass` / `slide.stiffness` / `slide.damping` | `0.6` / `800` / `38` | The slide's spring |
| `swipe.fingers` | `3` | Trackpad swipe between workspaces; `swipe = false` to disable |
| `namedWorkspaces` | `{"A","S","D"}` | Scratchpads shown over the current workspace |
| `rules` | `{}` | e.g. `{ app = "1Password", float = true }`, `{ app = "Slack", workspace = 4, silent = true }` |
| `ignoreApps` | `{}` | Apps whose windows are never managed |
| `indicators.menuBar` | `true` | Workspace numbers in the menu bar |
| `indicators.popup.show` / `indicators.badge.show` | `"hiddenMenuBar"` / `"hiddenMenuBar"` | A pop-up on switching and a corner badge: `"hiddenMenuBar"` (displays whose menu bar auto-hides), `"always"` or `false` |

## Default keymap

`defaultHotkeys` uses Option as Hyprland's SUPER. To change a binding, edit
the table before passing it to `bindHotkeys`. Each key is an action name, so
you can also build your own table from scratch.

| Keys | Action |
|---|---|
| Option+H/J/K/L | Focus left/down/up/right |
| Option+Shift+H/J/K/L | Swap with the window in that direction |
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
| Option+G | Cycle through floating windows |
| Option+F | Fill the screen without gaps (Shift: maximize inside the gaps) |
| Option+Y | Flip the split |
| Option+= | Balance the splits |
| Option+R | Rotate the layout (Shift: mirror it) |
| Option+Tab | Overview |
| Option+W | Close the window |

Option+letter shortcuts replace the characters macOS types with Option
(å, ß, ∂ and so on). Remap the ones you need for typing.

## Scripting

The actions are plain functions on `spoon.hyprspoon`, so you can bind them
yourself or call them from the `hs` command-line tool
(`require("hs.ipc")` in your config):

```sh
hs -c 'spoon.hyprspoon.gotoWorkspace(3)'
hs -c 'return hs.json.encode(spoon.hyprspoon.workspaces())'
```

## Troubleshooting

- **Windows stuck in a corner.** Windows on hidden workspaces are parked in
  a corner of the display. Quitting Hammerspoon brings them back, but a
  crash leaves them there. Start Hammerspoon again, then switch to their
  workspace or quit it normally.
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
- Native full-screen windows still get their own Space, which macOS
  manages.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
