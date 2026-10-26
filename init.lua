-- ~/.hammerspoon/init.lua
--
-- Hyprland-inspired Hammerspoon config for macOS.
-- Primary modifier ("SUPER") is Option.
--
-- Linux/Hyprland-specific pieces intentionally omitted:
--   monitor declarations, VRR/HDR, systemd/dbus, Wayland env vars,
--   hyprctl, awww, waybar/qs, dunst, clipse, playerctl/MPD,
--   Hyprland groups/special workspaces/tags and compositor-only rules.

-- Lets the `hs` command-line tool talk to this config.
require("hs.ipc")

local SUPER       = { "alt" }
local SUPER_SHIFT = { "alt", "shift" }
local SUPER_CMD   = { "alt", "cmd" } -- replacement for Hyprland SUPER+ALT

-- Window manager (tiling, mouse move/resize, focus follows mouse,
-- workspaces). See wm/state.lua for all options and their defaults.
-- Global, so the `hs` tool can drive it like hyprctl, e.g.
--   hs -c 'wm.gotoWorkspace(3)'
--   hs -c 'return hs.json.encode(wm.workspaces())'
wm                = require("wm")

wm.setup({
	focusFollowsMouse = true,
	minWidth = 240,
	minHeight = 140,
	mouse = {
		move = SUPER,        -- Option + left-drag
		resize = SUPER_CMD,  -- Option+Command + left-drag
		rightResize = SUPER, -- Option + right-drag
	},
	tiling = {
		outerGap = 15,
		innerGap = 10,
		minRatio = 0.20,
		maxRatio = 0.80,
		animationDuration = 0.2,
	},
	-- Hyprland-style window rules (see wm/state.lua), e.g.
	--   { app = "1Password", float = true },
	--   { app = "Slack", workspace = 4, silent = true },
	rules = {},
	-- Which workspace is showing. The pop-up and badge are for displays
	-- whose menu bar auto-hides; set `show = "always"` or false to change.
	indicators = {
		alwaysShow = 5,
		menuBar = true,
		popup = { show = "hiddenMenuBar", duration = 0.8 },
		badge = { show = false, corner = "bottomRight", all = false },
	},
	-- Hyprland's borders: active rgba(6C99BAff), inactive rgba(595959aa),
	-- blending as focus moves. Set to false to turn them off.
	border = {
		active = "#6c99ba",
		inactive = { hex = "#595959", alpha = 0xaa / 255 },
		width = 3,   -- points, outside the window edges
		radius = 12, -- corner radius when macOS doesn't report a window's own
		fade = 0.15, -- seconds
	},
})

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function bindRepeat(mods, key, fn)
	hs.hotkey.bind(mods, key, fn, nil, fn)
end

local function appNewWindow(name)
	local app = hs.application.get(name)
	if app then
		app:activate()
		hs.timer.doAfter(0.05, function()
			hs.eventtap.keyStroke({ "cmd" }, "n", 0, app)
		end)
	else
		hs.application.launchOrFocus(name)
	end
end

-- Control whatever app owns macOS Now Playing (MPD watcher, browsers, etc.).
-- Synthetic media-key events never reached it, so go through MediaRemote.
local function media(cmd)
	hs.task.new("/opt/homebrew/bin/media-control", nil, { cmd }):start()
end

-- ---------------------------------------------------------------------------
-- Core window controls
-- ---------------------------------------------------------------------------

-- SUPER+W: close focused window
hs.hotkey.bind(SUPER, "w", wm.closeWindow)

-- Hyprland SUPER+ALT+R -> Option+Command+R: reload Hammerspoon
hs.hotkey.bind(SUPER_CMD, "r", function()
	hs.reload()
end)

-- SUPER+F: native macOS full screen
hs.hotkey.bind(SUPER, "f", wm.toggleFullScreen)

-- SUPER+Shift+F: maximize without creating a fullscreen Space (again to
-- go back; a tile also goes back when another tile takes focus).
hs.hotkey.bind(SUPER_SHIFT, "f", wm.toggleMaximize)

-- SUPER+B: toggle BSP tiling (persists across reloads).
hs.hotkey.bind(SUPER, "b", wm.toggleTiling)

-- SUPER+Shift+B: toggle tiling for just this workspace (persists too).
hs.hotkey.bind(SUPER_SHIFT, "b", wm.toggleWorkspaceTiling)

-- SUPER+T: toggle floating for the focused window.
hs.hotkey.bind(SUPER, "t", wm.toggleFloat)

-- SUPER+G: cycle focus through floating windows (reaches covered ones).
hs.hotkey.bind(SUPER, "g", wm.focusFloat)

-- SUPER+Y: flip the focused window's split (horizontal <-> vertical).
hs.hotkey.bind(SUPER, "y", wm.toggleSplit)

-- SUPER+=: split every tile of the workspace evenly again.
hs.hotkey.bind(SUPER, "=", wm.balance)

-- SUPER+R: turn the workspace's layout a quarter clockwise;
-- SUPER+Shift+R: mirror it left to right.
hs.hotkey.bind(SUPER, "r", wm.rotate)
hs.hotkey.bind(SUPER_SHIFT, "r", wm.mirror)

-- SUPER+Return: always open a fresh Ghostty window on the current Space and
-- screen, regardless of where existing Ghostty windows live.
--
-- Activating Ghostty and sending Cmd+N jumps to its last-used window first
-- (e.g. a fullscreen Space on another display). Ghostty's AppleScript
-- `new window` avoids that, but Ghostty makes a new window fullscreen
-- whenever its last-focused window is fullscreen. In that case spawn a
-- separate, throwaway Ghostty instance instead; it quits when its last window
-- closes so instances don't pile up.
local ghosttyPoller = nil

local function ghosttyNewWindow()
	local app = hs.application.get("Ghostty")
	if not app then
		hs.application.launchOrFocus("Ghostty")
		return
	end

	local prev = hs.window.focusedWindow()
	local targetScreen = (prev and prev:screen()) or hs.mouse.getCurrentScreen()

	local existing = {}
	local anyFullscreen = false
	for _, w in ipairs(app:allWindows()) do
		existing[w:id()] = true
		if w:isFullScreen() then anyFullscreen = true end
	end

	local lastGhostty = app:focusedWindow()
	local parentFullscreen
	if lastGhostty then
		parentFullscreen = lastGhostty:isFullScreen()
	else
		parentFullscreen = anyFullscreen
	end

	if parentFullscreen then
		hs.task.new("/usr/bin/open", nil, {
			"-na", "Ghostty", "--args",
			"--quit-after-last-window-closed=true",
			"--window-save-state=never",
		}):start()
	else
		local ok = hs.osascript.applescript('tell application "Ghostty" to new window')
		if not ok then
			appNewWindow("Ghostty")
			return
		end
	end

	-- Wait for the new window to take focus, then pull it onto the screen we
	-- were working on (Ghostty cascades from wherever its last window was).
	local deadline = hs.timer.secondsSinceEpoch() + 3
	if ghosttyPoller then ghosttyPoller:stop() end
	ghosttyPoller = hs.timer.doEvery(0.05, function()
		local win = hs.window.focusedWindow()
		local winApp = win and win:application()
		local isNew = win
			and winApp and winApp:name() == "Ghostty"
			and not existing[win:id()]

		if isNew or hs.timer.secondsSinceEpoch() > deadline then
			ghosttyPoller:stop()
			ghosttyPoller = nil
			if not isNew then return end
			if targetScreen and win:screen():id() ~= targetScreen:id() then
				win:moveToScreen(targetScreen, false, true, 0)
			end
			win:focus()
		end
	end)
end

hs.hotkey.bind(SUPER, "return", ghosttyNewWindow)

-- SUPER+E: Finder
hs.hotkey.bind(SUPER, "e", function()
	hs.application.launchOrFocus("Finder")
end)

-- SUPER+Space: macOS Spotlight (tofi-drun replacement).
-- hs.hotkey.bind(SUPER, "space", function()
--     hs.eventtap.keyStroke({"cmd"}, "space", 0)
-- end)

-- SUPER+Tab: an overview of every workspace (click a window or workspace
-- to go there, 1-0 to switch, Escape to close).
hs.hotkey.bind(SUPER, "tab", wm.toggleOverview)

-- ---------------------------------------------------------------------------
-- Window manager keybindings
-- ---------------------------------------------------------------------------

local directions = { h = "left", l = "right", k = "up", j = "down" }

-- Set once the clipboard chooser exists: moves its selection and returns true
-- when the chooser is open, so Command+J/K don't need to go through key events.
local chooserMove = nil

for key, dir in pairs(directions) do
	-- SUPER+H/J/K/L: focus in a direction (warps the cursor).
	hs.hotkey.bind(SUPER, key, function() wm.focus(dir) end)

	-- SUPER+Shift+H/J/K/L: swap with the neighbour in that direction.
	hs.hotkey.bind(SUPER_SHIFT, key, function() wm.swap(dir) end)

	-- Command+H/J/K/L: arrow keys, Command+Shift+H/J/K/L: Shift+arrows
	-- (keyd's Alt layer on Linux; repeats while held). Flags are set
	-- explicitly: otherwise the held Command leaks into the event and apps
	-- (e.g. the clipboard chooser) see Command+Arrow instead of the arrow.
	for _, shift in ipairs({ false, true }) do
		bindRepeat(shift and { "cmd", "shift" } or { "cmd" }, key, function()
			if not shift and chooserMove and chooserMove(dir) then return end
			for _, isDown in ipairs({ true, false }) do
				hs.eventtap.event.newKeyEvent(dir, isDown)
					:setFlags(shift and { shift = true } or {}):post()
			end
		end)
	end
end

-- Command+0 / Command+4: start / end of line (keyd's Alt+0 / Alt+4).
-- Ghostty gets real Home/End; Cocoa text fields scroll on those instead of
-- moving the cursor, so everything else gets Command+Left/Right.
local lineKeys = { ["0"] = { "home", "left" }, ["4"] = { "end", "right" } }

for key, target in pairs(lineKeys) do
	hs.hotkey.bind({ "cmd" }, key, function()
		local app = hs.application.frontmostApplication()
		if app and app:name() == "Ghostty" then
			hs.eventtap.keyStroke({}, target[1], 0, app)
		else
			hs.eventtap.keyStroke({ "cmd" }, target[2], 0)
		end
	end)
end

-- Ctrl+Command+H/J/K/L/0/4: send the real Command+key to the focused app
-- (native Cmd+L, Cmd+0 etc.). Posted straight to the app's process so it
-- bypasses the Command hotkeys above.
for _, key in ipairs({ "h", "j", "k", "l", "0", "4" }) do
	hs.hotkey.bind({ "ctrl", "cmd" }, key, function()
		local app = hs.application.frontmostApplication()
		if app then hs.eventtap.keyStroke({ "cmd" }, key, 0, app) end
	end)
end

-- Resize by 10% of the window's size: SUPER + arrows or
-- SUPER+ALT (Option+Command) + H/J/K/L. Floating windows grow with right/down
-- and shrink with left/up; tiled windows move the split bordering them in
-- the key's direction.
local resizeSteps = {
	right = { 10, 0 }, left = { -10, 0 }, down = { 0, 10 }, up = { 0, -10 },
}
local resizeVimKeys = { right = "l", left = "h", down = "j", up = "k" }

for dir, step in pairs(resizeSteps) do
	local fn = function() wm.resize(step[1], step[2]) end
	bindRepeat(SUPER, dir, fn)
	bindRepeat(SUPER_CMD, resizeVimKeys[dir], fn)
end

-- Ctrl+Option+arrows: open the next new window on that side of the focused
-- tile (again to cancel).
for _, dir in ipairs({ "left", "right", "up", "down" }) do
	hs.hotkey.bind({ "ctrl", "alt" }, dir, function() wm.preselect(dir) end)
end

-- Ctrl+Option+H/L: previous/next workspace on this display (also a
-- three-finger swipe; see `swipe` in wm/state.lua).
hs.hotkey.bind({ "ctrl", "alt" }, "h", function() wm.gotoWorkspaceRelative(-1) end)
hs.hotkey.bind({ "ctrl", "alt" }, "l", function() wm.gotoWorkspaceRelative(1) end)

-- SUPER+1..0: go to workspace; SUPER+Shift+1..0: move window there;
-- Ctrl+SUPER+1..0: move it there without following.
for i = 1, 10 do
	local key = tostring(i % 10)
	hs.hotkey.bind(SUPER, key, function() wm.gotoWorkspace(i) end)
	hs.hotkey.bind(SUPER_SHIFT, key, function() wm.moveToWorkspace(i) end)
	hs.hotkey.bind({ "ctrl", "alt" }, key, function() wm.moveToWorkspaceSilent(i) end)
end

-- Named workspaces A/S/D, as scratchpads: SUPER+A/S/D goes there, or
-- back to where you were; SUPER+Shift+A/S/D moves the window there;
-- Ctrl+SUPER+A/S/D moves it without following.
for _, name in ipairs({ "A", "S", "D" }) do
	local key = name:lower()
	hs.hotkey.bind(SUPER, key, function() wm.toggleWorkspace(name) end)
	hs.hotkey.bind(SUPER_SHIFT, key, function() wm.moveToWorkspace(name) end)
	hs.hotkey.bind({ "ctrl", "alt" }, key, function() wm.moveToWorkspaceSilent(name) end)
end

-- SUPER+`: back to the previous workspace.
hs.hotkey.bind(SUPER, "`", wm.gotoPreviousWorkspace)

-- SUPER+,/.: focus the display to the left/right; SUPER+Shift+,/.: send
-- the window there; Ctrl+SUPER+,/.: send the whole workspace there.
for key, delta in pairs({ [","] = -1, ["."] = 1 }) do
	hs.hotkey.bind(SUPER, key, function() wm.focusDisplay(delta) end)
	hs.hotkey.bind(SUPER_SHIFT, key, function() wm.moveToDisplay(delta) end)
	hs.hotkey.bind({ "ctrl", "alt" }, key, function() wm.moveWorkspaceToDisplay(delta) end)
end

-- ---------------------------------------------------------------------------
-- Clipboard history: SUPER+V
-- ---------------------------------------------------------------------------
--
-- Self-contained Hammerspoon replacement for clipse. Text entries only;
-- keeps the most recent 50 unique items, persisted across reloads and
-- restarts via hs.settings (stored in plain text in Hammerspoon's prefs).
--
-- Copies that password managers mark as concealed/transient (the
-- nspasteboard.org convention) are never recorded, so they don't end up
-- on disk. Very large copies are skipped too, to keep the prefs file small.

local CLIPBOARD_LIMIT = 50
local CLIPBOARD_MAX_CHARS = 100000
local CLIPBOARD_SETTINGS_KEY = "clipboardHistory"

local CLIPBOARD_IGNORED_TYPES = {
	["org.nspasteboard.ConcealedType"] = true,
	["org.nspasteboard.TransientType"] = true,
	["org.nspasteboard.AutoGeneratedType"] = true,
	["com.agilebits.onepassword"] = true,
}

local clipboardHistory = hs.settings.get(CLIPBOARD_SETTINGS_KEY) or {}

-- Saving rewrites the whole history into the preferences file, so it's
-- debounced and flushed on reload/quit.
local clipboardSaveTimer = nil

local function saveClipboardNow()
	if clipboardSaveTimer then
		clipboardSaveTimer:stop()
		clipboardSaveTimer = nil
	end
	hs.settings.set(CLIPBOARD_SETTINGS_KEY, clipboardHistory)
end

local function saveClipboard()
	if clipboardSaveTimer then clipboardSaveTimer:stop() end
	clipboardSaveTimer = hs.timer.doAfter(2, saveClipboardNow)
end

do
	local previous = hs.shutdownCallback
	hs.shutdownCallback = function()
		if clipboardSaveTimer then saveClipboardNow() end
		if previous then previous() end
	end
end

local function clipboardIsSensitive()
	for _, uti in ipairs(hs.pasteboard.contentTypes() or {}) do
		if CLIPBOARD_IGNORED_TYPES[uti] then return true end
	end
	return false
end

local function addClipboard(text)
	if type(text) ~= "string" or text == "" then return end
	if #text > CLIPBOARD_MAX_CHARS or clipboardIsSensitive() then return end

	for i = #clipboardHistory, 1, -1 do
		if clipboardHistory[i] == text then
			table.remove(clipboardHistory, i)
		end
	end

	table.insert(clipboardHistory, 1, text)

	while #clipboardHistory > CLIPBOARD_LIMIT do
		table.remove(clipboardHistory)
	end

	saveClipboard()
end

local initialClipboard = hs.pasteboard.getContents()
if initialClipboard then addClipboard(initialClipboard) end

clipboardWatcher = hs.pasteboard.watcher.new(function(text)
	addClipboard(text)
end)

local clipboardChooser = hs.chooser.new(function(choice)
	if not choice then return end

	hs.pasteboard.setContents(choice.value)
	hs.timer.doAfter(0.08, function()
		hs.eventtap.keyStroke({ "cmd" }, "v", 0)
	end)
end)

clipboardChooser:placeholderText("Clipboard history")
clipboardChooser:rows(10)
clipboardChooser:searchSubText(true)
clipboardChooser:choices(function()
	local choices = {}

	for _, text in ipairs(clipboardHistory) do
		local oneLine = text:gsub("%s+", " ")
		local preview = oneLine
		if #preview > 100 then
			preview = preview:sub(1, 100) .. "…"
		end

		table.insert(choices, {
			text = preview,
			subText = text,
			value = text,
		})
	end

	return choices
end)

chooserMove = function(dir)
	if (dir ~= "up" and dir ~= "down") or not clipboardChooser:isVisible() then
		return false
	end
	local row = clipboardChooser:selectedRow() or 1
	row = row + (dir == "down" and 1 or -1)
	clipboardChooser:selectedRow(math.max(1, math.min(#clipboardHistory, row)))
	return true
end

hs.hotkey.bind(SUPER, "v", function()
	clipboardChooser:refreshChoicesCallback()
	clipboardChooser:show()
end)

-- ---------------------------------------------------------------------------
-- Media controls
-- ---------------------------------------------------------------------------
--
-- Original MPD/playerctl shortcuts become macOS system media controls.
-- Physical volume/brightness/media keys are left to macOS directly.

hs.hotkey.bind(SUPER, "z", function() media("previous-track") end)
hs.hotkey.bind(SUPER, "x", function() media("toggle-play-pause") end)
hs.hotkey.bind(SUPER, "c", function() media("next-track") end)

hs.hotkey.bind(SUPER_CMD, "z", function() media("previous-track") end)
hs.hotkey.bind(SUPER_CMD, "x", function() media("toggle-play-pause") end)
hs.hotkey.bind(SUPER_CMD, "c", function() media("next-track") end)

-- ---------------------------------------------------------------------------
-- A few macOS-native replacements for useful one-off bindings
-- ---------------------------------------------------------------------------

-- SUPER+N: Notification Center.
hs.hotkey.bind(SUPER, "n", function()
	hs.eventtap.keyStroke({ "fn" }, "n", 0)
end)

-- SUPER+M: Apps (Launchpad's replacement since macOS 26).
hs.hotkey.bind(SUPER, "m", function()
	hs.task.new("/usr/bin/open", nil, { "-a", "Apps" }):start()
end)

-- SUPER+Command+V: open TextEdit as a lightweight "edit anywhere" fallback.
-- Change "TextEdit" to your preferred macOS editor if desired.
hs.hotkey.bind(SUPER_CMD, "v", function()
	hs.application.launchOrFocus("TextEdit")
end)

-- SUPER+Command+Z: already media previous above, so no extra binding here.

-- ---------------------------------------------------------------------------
-- Hide the cursor while typing (Hyprland's cursor:hide_on_key_press)
-- ---------------------------------------------------------------------------
--
-- A small helper in ~/Projects/hide-cursor (build it with its build.sh).
-- It exits along with Hammerspoon; the old copy is killed on reload.

local hideCursorPath = os.getenv("HOME") .. "/Projects/hide-cursor/hide-cursor"
if hs.fs.attributes(hideCursorPath) then
	-- Start the new copy only once the old one has been killed.
	hs.task.new("/usr/bin/pkill", function()
		hideCursorTask = hs.task.new(hideCursorPath, function(code, _, stderr)
			if code ~= 0 then
				print("hide-cursor exited " .. code .. ": " .. stderr)
			end
		end, { "--parent", tostring(hs.processInfo.processID) })
		hideCursorTask:start()
	end, { "-x", "hide-cursor" }):start()
end

-- ---------------------------------------------------------------------------
-- Config reload watcher + startup notification
-- ---------------------------------------------------------------------------

-- Config files and rebuilt native modules (`make -C wm/native` writes them
-- one at a time, hence the wait), but not the tests.
local configDir = hs.configdir .. "/"
local reloadSoon = hs.timer.delayed.new(0.3, hs.reload)
configWatcher = hs.pathwatcher.new(configDir, function(files)
	for _, file in ipairs(files) do
		local rel = file:sub(#configDir + 1)
		if not rel:match("^tests/") and (rel:match("%.lua$") or rel:match("^wm/native/.*%.so$")) then
			reloadSoon:start()
			return
		end
	end
end):start()

hs.alert.show("Hammerspoon config loaded")


-- ---------------------------------------------------------------------------
-- Karabiner replacement
-- ---------------------------------------------------------------------------
-- Laptop-keyboard remaps (caps -> esc, fn <-> left ctrl) live in
-- ~/Library/LaunchAgents/local.hidutil.builtin-keyboard.plist (hidutil,
-- matched to the built-in keyboard only).

-- Ctrl+click -> Cmd+click.
ctrlClickTap = hs.eventtap.new({
	hs.eventtap.event.types.leftMouseDown,
	hs.eventtap.event.types.leftMouseUp,
	hs.eventtap.event.types.leftMouseDragged,
}, function(event)
	local t = event:getType()
	if t == hs.eventtap.event.types.leftMouseDown then
		local flags = event:getFlags()
		ctrlClickActive = flags.ctrl and not (flags.cmd or flags.alt or flags.shift)
	elseif not ctrlClickActive then
		return false -- drags/releases of ordinary clicks: nothing to do
	end
	if ctrlClickActive then
		event:setFlags({ cmd = true })
		if t == hs.eventtap.event.types.leftMouseUp then ctrlClickActive = false end
	end
	return false
end):start()
