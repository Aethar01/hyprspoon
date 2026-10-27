# Changelog

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
