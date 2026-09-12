#!/usr/bin/env bash
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
CONFIG="${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/config"
STATE="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-terminal-browser}/last-pane"

setting() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG" 2>/dev/null | tail -n1; }

url="${HERDR_PLUGIN_CLICKED_URL:-}"
[ -n "$url" ] || exit 1

ignore="$(setting ignore)"
if [ -n "$ignore" ] && printf '%s' "$url" | grep -Eq "$ignore"; then
	if [ "$(uname)" = Darwin ]; then opener=open; else opener=xdg-open; fi
	exec "$opener" "$url"
fi

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
pane="$(printf '%s' "$ctx" | jq -r '.focused_pane_id // empty')"
[ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
[ -n "$pane" ] || exit 1
tab="$(printf '%s' "$ctx" | jq -r '.tab_id // empty')"
[ -n "$tab" ] || tab="${HERDR_TAB_ID:-}"

direction="$(setting direction)"
case "$direction" in
right | down) ;;
*)
	read -r w h < <("$HERDR" pane layout --pane "$pane" 2>/dev/null |
		jq -r --arg p "$pane" 'first(.result.layout.panes[] | select(.pane_id == $p) | .rect | "\(.width) \(.height)") // "0 0"') || true
	if [ "${w:-0}" -ge 160 ]; then
		direction=right
	elif [ "${h:-0}" -ge 24 ]; then
		direction=down
	else
		direction=right
	fi
	;;
esac

if [ "$(setting focus)" = false ]; then focus=--no-focus; else focus=--focus; fi

if ! out="$("$HERDR" plugin pane open \
	--plugin "${HERDR_PLUGIN_ID:?}" \
	--entrypoint browser \
	--placement split \
	--target-pane "$pane" \
	--direction "$direction" \
	--env "HERDR_LINK_URL=$url" \
	"$focus")"; then
	printf '%s\n' "$out" >&2
	exit 1
fi
new="$(printf '%s' "$out" | jq -r '.result.plugin_pane.pane.pane_id // empty')"
[ -n "$new" ] || { printf '%s\n' "$out" >&2; exit 1; }

host="${url#*://}"
host="${host%%/*}"
"$HERDR" pane rename "$new" "web · ${host#www.}" >/dev/null 2>&1 || true

if [ "$(setting reuse)" != new ] && [ -f "$STATE" ]; then
	prev="$(cat "$STATE")"
	if [ -n "$prev" ] && [ "$prev" != "$new" ]; then
		prev_tab="$("$HERDR" pane get "$prev" 2>/dev/null | jq -r '.result.pane.tab_id // empty')"
		if [ -n "$prev_tab" ] && [ "$prev_tab" = "$tab" ]; then
			"$HERDR" plugin pane close "$prev" >/dev/null 2>&1 || true
		fi
	fi
fi

mkdir -p "$(dirname "$STATE")"
printf '%s' "$new" >"$STATE"
