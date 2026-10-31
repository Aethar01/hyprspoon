# SketchyBar example

Shows workspaces 1 to 10 while in use, and the focused app. Workspace icons
are highlighted while showing on any display; a background marks the
focused workspace. Click an icon to go there. Scratchpads and displays'
own workspaces need extra items; they are still included in `query()`.

Install [SketchyBar](https://felixkratz.github.io/SketchyBar/setup) first.
The plugin needs `jq` (`brew install jq` if missing) and the `hs` command.
Add `require("hs.ipc")` to your Hammerspoon config, then install its CLI
with `hs.ipc.cliInstall()` in the Hammerspoon console if `hs` isn't already
available. hyprspoon must be loaded and started for the plugin's query to
work.

From the root of this repository, install the plugin:

```sh
mkdir -p ~/.config/sketchybar/plugins
cp examples/sketchybar/plugins/hyprspoon.sh ~/.config/sketchybar/plugins/
chmod +x ~/.config/sketchybar/plugins/hyprspoon.sh
```

Add the contents of [sketchybarrc](sketchybarrc) to your existing
`~/.config/sketchybar/sketchybarrc`. It is a snippet, not a complete bar
config. It uses SketchyBar's `CONFIG_DIR` and reserves item names `space.1`
to `space.10` and `front_app`. Remove or rename conflicting
items in your config. If your config directory is elsewhere, copy the
plugin into its `plugins` directory instead.

Uncomment the `exec` table in [../init.lua](../init.lua) inside your
existing `spoon.hyprspoon:start({ ... })` call. Use the full path printed
by `command -v sketchybar` in your terminal. Hammerspoon's `PATH` may omit
Homebrew: `/opt/homebrew/bin/sketchybar` is usual on Apple Silicon and
`/usr/local/bin/sketchybar` on Intel. The plugin adds both directories to
its own `PATH`; the click commands also need `hs` in SketchyBar's `PATH`.

After installing, reload your Hammerspoon config and SketchyBar config,
then run `sketchybar --update` in your terminal for the initial state. This
also refreshes the bar if it was started before Hammerspoon. Each configured
hook runs once when hyprspoon starts.

The focus trigger carries `WORKSPACE` and `APP`, so that update needs no
query. A workspace trigger, or a forced update, calls `query()` once via
`hs -c` and parses it with `jq`. There is no polling. A focused scratchpad
or display workspace clears the numbered workspace's background; it does
not create an item for that workspace.
