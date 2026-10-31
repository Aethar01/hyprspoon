#!/bin/bash
# SketchyBar plugin for hyprspoon: the workspace items (space.1 to space.10)
# and front_app, from examples/sketchybar/sketchybarrc.
#
# hyprspoon_focus brings the focused workspace and app with it, so needs
# nothing else. hyprspoon_workspace and forced updates (`sketchybar --update`) ask
# hyprspoon for everything once with spoon.hyprspoon:query(), through the
# hs command-line tool (require("hs.ipc") in your Hammerspoon config) and
# jq (`brew install jq` if missing). See ../README.md for installation.
# Scratchpads and displays' own workspaces have no items in this example.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

args=()
case "$SENDER" in
  hyprspoon_focus)
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if [ "$i" = "$WORKSPACE" ]; then focused=on; else focused=off; fi
      args+=(--set "space.$i" background.drawing="$focused")
    done
    args+=(--set front_app label="$APP")
    ;;
  *)
    state=$(hs -c 'return hs.json.encode(spoon.hyprspoon:query())') || exit 0
    # One line per item: name, drawing, background.drawing, icon.highlight.
    while read -r item drawing focused showing; do
      args+=(--set "$item" drawing="$drawing" background.drawing="$focused" icon.highlight="$showing")
    done < <(jq -r '
      def onoff: if . then "on" else "off" end;
      (.workspaces | map({ key: .name, value: . }) | from_entries) as $ws
      | range(1; 11) | tostring as $n | $ws[$n] as $w
      | "space.\($n) \($w != null | onoff) \($w.focused == true | onoff) \($w.showing == true | onoff)"
    ' <<<"$state")
    args+=(--set front_app label="$(jq -r '.focus.app // ""' <<<"$state")")
    ;;
esac

sketchybar "${args[@]}"
