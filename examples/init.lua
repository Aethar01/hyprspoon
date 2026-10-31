-- An example ~/.hammerspoon/init.lua for hyprspoon.
--
-- Every option and its default is in hyprspoon/state.lua (S.defaults);
-- only the ones you change need to be here.

-- Lets the `hs` command-line tool drive the window manager, e.g.
--   hs -c 'spoon.hyprspoon.gotoWorkspace(3)'
--   hs -c 'return hs.json.encode(spoon.hyprspoon:query())'
require("hs.ipc")

hs.loadSpoon("hyprspoon")

spoon.hyprspoon:start({
	focusFollowsMouse = false,
	-- Modifier + drag anywhere on a window. Set any to false to disable it.
	mouse = {
		move = { "alt" },          -- Option + left-drag
		resize = { "alt", "cmd" }, -- Option+Command + left-drag
		rightResize = { "alt" },   -- Option + right-drag
	},
	tiling = {
		outerGap = 10,
		innerGap = 5,
		animationDuration = 0.2,
	},
	-- Hyprland-style window rules.
	rules = {
		{ app = "System Settings", float = true },
		-- { app = "Slack", workspace = 4, silent = true },
	},
	-- Status bars hear about changes as they happen, e.g. SketchyBar with
	-- examples/sketchybar/README.md for installation. Uncomment this table
	-- inside start(); a second start() replaces these options. Hammerspoon's
	-- PATH may omit Homebrew, so use the full path from `command -v sketchybar`
	-- (/opt/homebrew/bin on Apple Silicon, usually /usr/local/bin on Intel).
	-- exec = {
	-- 	workspace = "/opt/homebrew/bin/sketchybar --trigger hyprspoon_workspace",
	-- 	focus = '/opt/homebrew/bin/sketchybar --trigger hyprspoon_focus'
	-- 		.. ' WORKSPACE="$HYPRSPOON_WORKSPACE" APP="$HYPRSPOON_APP"',
	-- },
})

-- The default keymap, with Option as SUPER (see defaultHotkeys in the
-- Spoon's init.lua for every action). Change or drop entries before
-- binding, e.g. to keep Option+S for typing ß:
--   local keys = spoon.hyprspoon.defaultHotkeys
--   keys.workspaceS = { { "alt", "ctrl", "cmd" }, "s" }
spoon.hyprspoon:bindHotkeys(spoon.hyprspoon.defaultHotkeys)

-- Your own bindings can call the API directly.
hs.hotkey.bind({ "alt", "cmd" }, "r", hs.reload)
