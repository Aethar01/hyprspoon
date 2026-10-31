# Contributing

Bug reports and pull requests are welcome.

## Setup

Clone the repo into your Spoons folder so Hammerspoon runs your working
copy, and build the native modules:

```sh
git clone https://github.com/Aethar01/hyprspoon ~/.hammerspoon/Spoons/hyprspoon.spoon
make -C ~/.hammerspoon/Spoons/hyprspoon.spoon/hyprspoon/native
```

Reload Hammerspoon to pick up changes, including rebuilt native modules.

## Layout

- `init.lua`: the Spoon: the public API, `start`, `stop` and the hotkeys.
- `hyprspoon/*.lua`: the modules. The header of `init.lua` says what each
  one does.
- `hyprspoon/state.lua`: every option, with its default and documentation.
- `hyprspoon/native/`: optional C and Objective-C modules. Each one has a
  Lua path that keeps the basics working without it; borders and slides
  are disabled when their modules are absent. `border.m` draws rings and
  experimental masks; `events.c` filters the extra mask notifications on
  their shared WindowServer connection. Rebuild both when updating.

## Tests

```sh
tests/run.sh        # unit tests, plain Lua 5.4+, no Hammerspoon needed
```

`tests/performance.lua` is a live benchmark that runs inside Hammerspoon
(see its header). With borders and `experimental.borderMask` enabled,
its `border.mask` case measures a fresh snapshot and full mask rebuild.
Try 10 and 30 windows, including overlapping floats; the target is 0.5ms
per update with 30 windows, not a measured guarantee.

Window management depends on timing, so also try a change live: tiling on
and off, several displays if you have them, full-screen windows, and
switching workspaces while windows open and close.

## Style

- Match the surrounding code: 4-space indents, `local` everything, and
  modules that register themselves in `package.loaded` before requiring
  others.
- Comments explain why, in plain sentences.
- Don't add delays to window placement; responsiveness comes first.
- One change per commit, with a message that says what it does.
