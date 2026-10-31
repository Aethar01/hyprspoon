# Changelog

## 0.3.0 (2026-10-31)

Rebuild the native modules (`make -C hyprspoon/native`) after updating.

- Event hooks for status bars: `start()` takes `on` (functions) and
  `exec` (shell commands, given `HYPRSPOON_*` variables) for the
  `workspace`, `focus`, `layout` and `display` events, and
  `spoon.hyprspoon:query()` returns the focus, displays, workspaces and
  windows as a table. `examples/sketchybar` shows a SketchyBar setup.
- Pin a float to every workspace of its display, like Hyprland's `pin`:
  the new `togglePin` action (unbound) or a `pin = true` rule.
- Pseudotiling: `togglePseudo` (unbound) or a `pseudo = true` rule keeps
  a tile at its own size, centred in its tile. Dragging its edges
  resizes it rather than the split.
- More rule fields: match on `role` and `subrole`; `size` and
  `position` (in points or fractions of the display) and `center` for a
  new float; `noborder`; and `opacity`, for border masking.
- Choice of keymap: `hotkeysFor(super, ctrlSuper)` builds the default
  keymap on other modifiers, and `ctrlAltCmdHotkeys` uses Ctrl+Option+Cmd
  so Option still types characters.
- `spoon.hyprspoon:rescue()` brings back every parked window and turns
  tiling off, even after a crash with hyprspoon not started.
- Experimental `experimental.borderMask`, off by default: hides the parts
  of a ring covered by other windows (floats, other apps, Spotlight).
  Needs macOS 13.
- Native full-screen windows no longer get a ring, in Split View, below
  a camera housing, or when already full screen at start or reload.
- Fixed reloading while a full-screen Space shows forgetting the
  workspaces of the windows on the desktop.
- Fixed a workspace sliding in with its windows out of place after
  switching back and forth quickly.

## 0.2.0 (2026-10-30)

- Option+Shift+H/J/K/L now move the window, like Hyprland's movewindow:
  it leaves its tile and splits the one in that direction (on another
  display too), instead of trading places with it. The new `moveLeft`,
  `moveRight`, `moveUp` and `moveDown` actions do this; `swapLeft` etc.
  still exist, unbound.
- New `displays` option to keep workspaces on particular displays, by
  name or UUID. Other workspaces live on the primary display, and a
  display that isn't listed (a projector, an AirPlay screen) gets one
  workspace of its own, named after it. Switching to a workspace brings it
  up on its own display, wherever the pointer is.
- Ctrl+Super+, / . no longer move a workspace given to a display, or a
  display's own.
- An empty display can take focus, like Hyprland's focused monitor:
  Option+H/J/K/L past the last window focuses the display that way even
  with nothing on it (and works from one with nothing on it), and with
  focus follows mouse the pointer coming onto it does. A window opening
  then goes to that display.
- Fixed Option+Shift+H/J/K/L not moving a tile to the display beside it
  when the outer gap is wider than the inner one (and the move being
  undone when it did). A float now goes on to that display once it's
  against the edge.
- Fixed dragging a window to another display with the modifier: it
  snapped back to the display it came from (and a float kept its old
  workspace).

## 0.1.4 (2026-10-27)

- Fixed focus follows mouse doing nothing on macOS 27, where the Dock keeps
  an invisible window over each display that was mistaken for an open menu.
  Rebuild the native modules (`make -C hyprspoon/native`) after updating.

## 0.1.3 (2026-10-27)

- Fixed the picture of a workspace slide staying over the screen after
  every switch, so the windows looked frozen (a regression in 0.1.2).

## 0.1.2 (2026-10-27)

- Fixed Hammerspoon hanging or crashing when it reloads just after a
  workspace slide.
- Removed the code that read state saved by versions before 0.1.0.

## 0.1.1 (2026-10-27)

- Native modules still marked as quarantined (a release zip unzipped
  without clearing the flag) are skipped with the command to fix it in the
  console, instead of holding Hammerspoon up for seconds each while macOS
  refuses them.

## 0.1.0 (2026-10-27)

First public release.

- BSP tiling per workspace, with drag-and-drop, mouse and keyboard resizing,
  rotate, mirror, balance and preselection.
- Workspaces of its own, with named scratchpads, trackpad swipes and
  spring slides.
- Window borders, focus follows mouse, window rules, and an overview.
- Layouts and workspaces restored after reloads and restarts.
- Packaged as a Spoon with `start`, `stop`, `bindHotkeys` and
  `defaultHotkeys`.
