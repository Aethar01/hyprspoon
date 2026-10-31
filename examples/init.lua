-- An example ~/.hammerspoon/init.lua for hyprspoon.
--
-- Every option and its default is in hyprspoon/state.lua (S.defaults);
-- only the ones you change need to be here.

-- Lets the `hs` command-line tool drive the window manager, e.g.
--   hs -c 'spoon.hyprspoon.gotoWorkspace(3)'
--   hs -c 'return hs.json.encode(spoon.hyprspoon.workspaces())'
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
		-- Placement only applies once; reopen the window to try changes.
		-- { app = "Activity Monitor", float = true,
		--   size = { w = 640, h = 480 }, position = { x = 20, y = 30 } },
		-- { subrole = "AXDialog", center = true, noborder = true },
	},
})

-- The default keymap, with Option as SUPER (see defaultHotkeys in the
-- Spoon's init.lua for every action). Change or drop entries before
-- binding, e.g. to keep Option+S for typing ß:
--   local keys = spoon.hyprspoon.defaultHotkeys
--   keys.workspaceS = { { "alt", "ctrl", "cmd" }, "s" }
spoon.hyprspoon:bindHotkeys(spoon.hyprspoon.defaultHotkeys)

-- Your own bindings can call the API directly.
hs.hotkey.bind({ "alt", "cmd" }, "r", hs.reload)
