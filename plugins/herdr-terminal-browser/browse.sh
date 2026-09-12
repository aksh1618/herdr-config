#!/usr/bin/env bash
set -uo pipefail

CONFIG="${HERDR_PLUGIN_CONFIG_DIR:-/nonexistent}/config"

setting() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG" 2>/dev/null | tail -n1; }

url="${HERDR_LINK_URL:-}"

cmd="$(setting command)"
[ -n "$cmd" ] || cmd="${HERDR_TERMINAL_BROWSER:-}"
if [ -z "$cmd" ]; then
	for candidate in terminal-browser w3m elinks lynx links cha carbonyl browsh; do
		if command -v "$candidate" >/dev/null 2>&1; then
			cmd="$candidate"
			break
		fi
	done
fi

if [ -z "$url" ] || [ -z "$cmd" ]; then
	[ -n "$url" ] || printf 'no url was passed to the browser pane\n'
	[ -n "$cmd" ] || printf 'no terminal browser found on PATH (tried terminal-browser w3m elinks lynx links cha carbonyl browsh)\n\nset one with a line like\n    command = w3m\nin %s\n' "$CONFIG"
	trap '' WINCH
	printf '\npress any key to close '
	read -r -n 1 -s
	exit 1
fi

case "$cmd" in
*'{url}'*) ;;
*) cmd="$cmd {url}" ;;
esac

exec sh -c "${cmd//\{url\}/\"\$0\"}" "$url"
