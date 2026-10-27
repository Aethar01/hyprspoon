# Changelog

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
- Saved state moved to `hyprspoon.`-prefixed keys; state under the old
  keys is migrated on first start.
