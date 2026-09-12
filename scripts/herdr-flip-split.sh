#!/usr/bin/env bash
# Flip the split between the focused pane and whatever sits on the other side of
# it, keeping every pane's process, scrollback, label, order and split ratio.
#
# Herdr has no transpose/rotate action, and `pane move` refuses same-tab moves,
# so the panes under that split are parked in a throwaway tab and re-inserted
# top-down with the one direction flipped. A leaf sibling costs two moves; a
# whole block costs 2x(k-1).
#
# Bind it as a shell command:
#   [[keys.command]]
#   key = "prefix+/"
#   type = "shell"
#   command = "~/.config/herdr/scripts/herdr-flip-split.sh"
#
# A focused pane with no parent split (the only pane in its tab) falls through to
# focus-right rather than erroring.

set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
SOCKET="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"
PANE="${HERDR_ACTIVE_PANE_ID:-${HERDR_PANE_ID:-}}"
SCRATCH_LABEL="flip-scratch"

SCRATCH_TAB=""

notify() {
	"$HERDR" notification show "$1" --body "${2-}" >/dev/null 2>&1
}

focus_right() {
	if [ -n "$PANE" ]; then
		"$HERDR" pane focus --pane "$PANE" --direction right >/dev/null 2>&1
	else
		"$HERDR" pane focus --current --direction right >/dev/null 2>&1
	fi
	exit 0
}

# A refused move (a zoomed tab, a same-tab destination) is a *success* response
# carrying changed:false, so the CLI exits 0. Only `changed` proves it happened.
moved() {
	jq -e '.result.move_result.changed == true' >/dev/null 2>&1 <<<"$1"
}

api() {
	printf '{"id":"f","method":"%s","params":%s}\n' "$1" "$2" |
		socat -t 5 - "UNIX-CONNECT:$SOCKET" 2>/dev/null |
		jq -c 'select(.id == "f")' 2>/dev/null
}

# The scratch tab closes itself once its last pane leaves, and its panes move
# back during a restore, so neither it nor any pane in it is a durable target.
# Omitting --target-pane lands on whatever the tab currently focuses, and a dead
# tab falls back to opening a fresh one.
park() {
	local out
	if [ -n "$SCRATCH_TAB" ]; then
		out=$("$HERDR" pane move "$1" --tab "$SCRATCH_TAB" --split down --no-focus 2>&1)
		moved "$out" && return 0
	fi
	out=$("$HERDR" pane move "$1" --new-tab --label "$SCRATCH_LABEL" --no-focus 2>&1)
	moved "$out" || return 1
	SCRATCH_TAB=$(jq -r '.result.move_result.pane.tab_id' <<<"$out")
}

insert() {
	local focus=--no-focus out
	[ "$1" = "$focused" ] && focus=--focus
	out=$("$HERDR" pane move "$1" --tab "$tab" --target-pane "$2" \
		--split "$3" --ratio "$4" "$focus" 2>&1)
	moved "$out"
}

step() {
	jq -r --argjson i "$1" '.[$i] | "\(.pane) \(.target) \(.dir) \(.ratio)"' <<<"$plan"
}

settle() {
	"$HERDR" pane resize --pane "$PANE" --direction right --amount 0 >/dev/null 2>&1 || true
}

stranded() {
	settle
	notify "Flip split failed" "panes left in tab ${SCRATCH_TAB:-?} (\"$SCRATCH_LABEL\")"
	exit 1
}

command -v jq >/dev/null && command -v socat >/dev/null || {
	notify "Flip split" "jq and socat are required"
	exit 1
}

exec 9>"${XDG_RUNTIME_DIR:-/tmp}/herdr-flip-split.lock"
flock -n 9 || exit 0

[ -n "$PANE" ] || focus_right
layout=$(api layout.export "$(jq -cn --arg p "$PANE" '{pane_id: $p}')")
[ -n "$layout" ] || focus_right

read -r tab focused zoomed <<<"$(jq -r '.result.layout
	| "\(.tab_id) \(.focused_pane_id) \(.zoomed)"' <<<"$layout" 2>/dev/null)"
[ "$zoomed" = "false" ] || focus_right

# Pre-order over the focused pane's parent split: each entry re-creates one split
# by dropping a pane onto the leftmost leaf of the half it belongs to. Replaying
# the list from a bare anchor rebuilds the subtree exactly; replaying a prefix of
# it rebuilds a prefix of the subtree, which is what makes the restore below work.
#
# parent($p) is also the only thing limiting this script. A node is nameable only
# if one of its children is a pane, so a split whose children are both splits can
# never be flipped: in a 2x2 grid, right(down(A,B), down(C,D)), no press flips
# left-vs-right. The rebuild itself can flip *any* node, so if that ever matters,
# bind a second key to a copy that swaps `parent($p)` for `.result.layout.root`
# and drops the empty-plan fallthrough. Nothing else changes; it costs 2x(n-1)
# moves for a tab of n panes, and the rollback works the same way.
plan=$(jq -c --arg p "$PANE" '
	def leftmost: if .type == "pane" then .pane_id else (.first | leftmost) end;
	def plan: if .type == "pane" then []
		else [{pane: (.second | leftmost), target: (.first | leftmost),
			dir: .direction, ratio: .ratio}]
			+ (.first | plan) + (.second | plan)
		end;
	def parent($id): if .type != "split" then null
		elif .first.pane_id == $id or .second.pane_id == $id then .
		else (.first | parent($id)) // (.second | parent($id))
		end;
	(.result.layout.root | parent($p)) // empty | plan' <<<"$layout" 2>/dev/null)
[ -n "$plan" ] || focus_right

n=$(jq 'length' <<<"$plan")
flipped=$(jq -r 'if .[0].dir == "right" then "down" else "right" end' <<<"$plan")

# Park in reverse plan order, so the tab always holds a prefix of the plan.
for ((i = n - 1; i >= 0; i--)); do
	read -r pane _ _ _ <<<"$(step "$i")"
	park "$pane" && continue
	for ((j = i + 1; j < n; j++)); do
		read -r pane target dir ratio <<<"$(step "$j")"
		insert "$pane" "$target" "$dir" "$ratio" || stranded
	done
	settle
	notify "Flip split failed" "layout restored"
	exit 1
done

for ((i = 0; i < n; i++)); do
	read -r pane target dir ratio <<<"$(step "$i")"
	[ "$i" -eq 0 ] && dir=$flipped
	insert "$pane" "$target" "$dir" "$ratio" && continue
	for ((j = i - 1; j >= 0; j--)); do
		read -r pane _ _ _ <<<"$(step "$j")"
		park "$pane" || stranded
	done
	for ((j = 0; j < n; j++)); do
		read -r pane target dir ratio <<<"$(step "$j")"
		insert "$pane" "$target" "$dir" "$ratio" || stranded
	done
	settle
	notify "Flip split failed" "layout restored"
	exit 1
done
settle
