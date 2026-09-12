#!/usr/bin/env bash
# Split the focused pane, picking the direction from the pane's own size.
#
# Bind it as a shell command:
#   [[keys.command]]
#   key = "prefix+enter"
#   type = "shell"
#   command = "~/.config/herdr/scripts/herdr-split-auto.sh"
#
# No --cwd is passed, so the new pane follows terminal.new_cwd exactly like the
# built-in prefix+v / prefix+minus splits do.

set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
PANE="${HERDR_ACTIVE_PANE_ID:-${HERDR_PANE_ID:-}}"

notify() {
	"$HERDR" notification show "$1" --body "${2-}" >/dev/null 2>&1
}

command -v jq >/dev/null || {
	notify "Auto split" "jq is required"
	exit 1
}

if [ -n "$PANE" ]; then
	layout=$("$HERDR" pane layout --pane "$PANE" 2>/dev/null)
else
	layout=$("$HERDR" pane layout --current 2>/dev/null)
fi || {
	notify "Auto split" "no pane layout available"
	exit 1
}

target=${PANE:-$(jq -r '.result.layout.focused_pane_id // ""' <<<"$layout")}
[ -n "$target" ] || {
	notify "Auto split" "no focused pane"
	exit 1
}

read -r width height < <(jq -r --arg p "$target" '.result.layout.panes[]
	| select(.pane_id == $p)
	| "\(.rect.width) \(.rect.height)"' <<<"$layout" 2>/dev/null)

read -r cell_w cell_h < <(printf '{"id":"c","method":"pane.graphics.info","params":{"pane_id":"%s"}}\n' "$target" |
	socat -t 2 - "UNIX-CONNECT:${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}" 2>/dev/null |
	jq -r 'select(.id == "c" and .result.cell_width_px != null)
		| "\(.result.cell_width_px) \(.result.cell_height_px)"' 2>/dev/null)
case "${cell_w:-}${cell_h:-}" in
*[!0-9]* | "") cell_w=10 cell_h=22 ;;
esac

# Split the bigger dimension, in pixels: rect is in cells and cells are not square.
if [ $((width * cell_w)) -gt $((height * cell_h)) ]; then
	direction=right
else
	direction=down
fi

out=$("$HERDR" pane split "$target" --direction "$direction" --focus 2>&1) || {
	notify "Auto split failed" "$(jq -r '.error.message // .' <<<"$out" 2>/dev/null || printf '%s' "$out")"
	exit 1
}
