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
  Lua fallback, and the Lua side must keep working without it.

## Tests

```sh
tests/run.sh        # unit tests, plain Lua 5.4+, no Hammerspoon needed
```

`tests/performance.lua` is a live benchmark that runs inside Hammerspoon
(see its header).

`tests/opaque_probe.m` is a standalone macOS diagnostic for window alpha
and the private opaque flag. Build and run it from the repo root:

```sh
clang -fobjc-arc -framework AppKit -framework Foundation -framework CoreGraphics \
    tests/opaque_probe.m -o /tmp/opaque_probe
/tmp/opaque_probe
```

It is read-only by default. `-s` also creates, changes and closes an
off-screen test window. See its header for options and output columns.
It is separate from the unit tests and needs no Hammerspoon reload.

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
