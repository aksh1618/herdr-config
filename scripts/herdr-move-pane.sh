#!/usr/bin/env bash
# Interactive pane mover for Herdr.
#
# Herdr has no built-in UI for moving a pane across tabs (swap_pane_* only works
# within a tab, and the pane context menu stops at split/zoom/close), so this
# drives `herdr pane move` from an fzf picker instead.
#
# Opens straight into the destination picker, moving the focused pane. Press
# ctrl-s there to move some other pane instead.
#
# Bind it as a popup command:
#   [[keys.command]]
#   key = "prefix+m"
#   type = "popup"
#   command = "~/.config/herdr/scripts/herdr-move-pane.sh"
#   description = "Move a pane to another tab"
#   width = "85%"
#   height = "60%"

set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
ACTIVE_PANE="${HERDR_ACTIVE_PANE_ID:-}"

die() {
	printf '\n  %s\n\n  press any key to close ' "$1" >&2
	read -r -n 1 -s
	exit 1
}

for bin in fzf jq; do
	command -v "$bin" >/dev/null || die "$bin is required but not installed"
done

panes_json=$("$HERDR" pane list) || die "herdr pane list failed"
tabs_json=$("$HERDR" tab list) || die "herdr tab list failed"
ws_json=$("$HERDR" workspace list) || die "herdr workspace list failed"

# Short "workspace/tab · title" description of a pane, for prompts.
describe_pane() {
	jq -r --slurpfile ws <(printf '%s' "$ws_json") \
	      --slurpfile tabs <(printf '%s' "$tabs_json") --arg p "$1" '
		($ws[0].result.workspaces | map({key: .workspace_id, value: (.label // .workspace_id)}) | from_entries) as $wsl |
		($tabs[0].result.tabs      | map({key: .tab_id,       value: (.label // .tab_id)})       | from_entries) as $tl |
		first(.result.panes[] | select(.pane_id == $p))
		| ($wsl[.workspace_id] // .workspace_id) + "/" + ($tl[.tab_id] // .tab_id)
		  + " · " + (.terminal_title_stripped // .label // .pane_id)' <<<"$panes_json"
}

tab_of_pane() {
	jq -r --arg p "$1" 'first(.result.panes[] | select(.pane_id == $p) | .tab_id) // ""' <<<"$panes_json"
}

# ---------------------------------------------------------------- pick source

# Only reached via ctrl-s, or when the popup somehow launched without an active
# pane. Columns: pane_id, workspace/tab, agent+state, title, cwd.
pick_source() {
	local line
	line=$(
		jq -r --slurpfile ws <(printf '%s' "$ws_json") \
		      --slurpfile tabs <(printf '%s' "$tabs_json") \
		      --arg active "$ACTIVE_PANE" '
			($ws[0].result.workspaces | map({key: .workspace_id, value: (.label // .workspace_id)}) | from_entries) as $wsl |
			($tabs[0].result.tabs      | map({key: .tab_id,       value: (.label // .tab_id)})       | from_entries) as $tl |
			.result.panes
			| map({
				id: .pane_id,
				active: (.pane_id == $active),
				loc: (($wsl[.workspace_id] // .workspace_id) + "/" + ($tl[.tab_id] // .tab_id)),
				who: (if .agent then .agent + "·" + (.agent_status // "?") else "shell" end),
				what: (.terminal_title_stripped // .label // ""),
				cwd: (.cwd // "" | sub("^" + env.HOME; "~"))
			  })
			| sort_by(if .active then 0 else 1 end)
			| .[]
			| [.id, (if .active then "▸ " else "  " end) + .loc, .who, .what, .cwd]
			| @tsv' <<<"$panes_json" |
			column -t -s $'\t' |
			fzf --ansi --no-multi --layout=reverse --height=100% \
				--prompt='move which pane? ' \
				--header='enter select · esc keep current pane   (▸ = current pane)'
	) || return 1
	[ -n "$line" ] || return 1
	printf '%s\n' "${line%% *}"
}

# ----------------------------------------------------------- pick destination

# Tabs, plus "+ new tab" per workspace and "+ new workspace". The source pane's
# own tab is filtered out.
pick_dest() {
	{
		jq -r --slurpfile ws <(printf '%s' "$ws_json") --arg skip "$1" '
			($ws[0].result.workspaces | map({key: .workspace_id, value: (.label // .workspace_id)}) | from_entries) as $wsl |
			.result.tabs
			| map(select(.tab_id != $skip))
			| .[]
			| ["tab:" + .tab_id,
			   ($wsl[.workspace_id] // .workspace_id) + "/" + (.label // .tab_id),
			   (.pane_count | tostring) + "p",
			   (.agent_status // "")]
			| @tsv' <<<"$tabs_json"
		jq -r '.result.workspaces[] | ["newtab:" + .workspace_id, (.label // .workspace_id) + "/+ new tab", "", ""] | @tsv' <<<"$ws_json"
		printf 'newws:\t+ new workspace\t\t\n'
	} |
		column -t -s $'\t' |
		fzf --ansi --no-multi --layout=reverse --height=100% \
			--expect=ctrl-r,ctrl-d,ctrl-s \
			--prompt="move $2 → " \
			--header='enter auto-split · ctrl-r force right · ctrl-d force down · ctrl-s move a different pane · esc cancel'
}

source_pane=$ACTIVE_PANE
[ -n "$source_pane" ] || source_pane=$(pick_source) || exit 0
[ -n "$source_pane" ] || exit 0

while :; do
	dest_line=$(pick_dest "$(tab_of_pane "$source_pane")" "$(describe_pane "$source_pane")") || exit 0
	[ -n "$dest_line" ] || exit 0
	override=$(sed -n 1p <<<"$dest_line")
	dest_key=$(sed -n 2p <<<"$dest_line" | cut -d' ' -f1)
	[ -n "$dest_key" ] || exit 0

	# ctrl-s backs out to the pane picker, then returns here with a new source.
	if [ "$override" = ctrl-s ]; then
		picked=$(pick_source) && [ -n "$picked" ] && source_pane=$picked
		continue
	fi
	break
done

# ------------------------------------------------------------------- the move

# Auto-split rule: only go right when both halves stay readable (>=80 cols),
# otherwise stack down when both halves keep >=12 rows.
auto_split() {
	local tab_id=$1 probe w h
	probe=$(jq -r --arg t "$tab_id" 'first(.result.panes[] | select(.tab_id == $t) | .pane_id) // ""' <<<"$panes_json")
	[ -n "$probe" ] || { printf 'down\n'; return; }
	read -r w h < <("$HERDR" pane layout --pane "$probe" | jq -r '.result.layout.area | "\(.width) \(.height)"')
	if [ "${w:-0}" -ge 160 ]; then printf 'right\n'
	elif [ "${h:-0}" -ge 24 ]; then printf 'down\n'
	else printf 'right\n'; fi
}

# A tab dies with its last pane — and a workspace dies with its last tab — so
# when we're taking the only pane, leave a fresh shell behind first. Inherits the
# departing pane's cwd so the leftover lands in the same project.
keep_tab_alive() {
	local tab_id=$1 count cwd out
	local -a split_cmd=(pane split "$source_pane" --direction down --no-focus)
	count=$(jq -r --arg t "$tab_id" '[.result.panes[] | select(.tab_id == $t)] | length' <<<"$panes_json")
	[ "${count:-0}" -eq 1 ] || return 0
	cwd=$(jq -r --arg p "$source_pane" 'first(.result.panes[] | select(.pane_id == $p) | .cwd) // ""' <<<"$panes_json")
	[ -n "$cwd" ] && split_cmd+=(--cwd "$cwd")
	out=$("$HERDR" "${split_cmd[@]}" 2>&1) || die "could not keep source tab alive: $out"
}

keep_tab_alive "$(tab_of_pane "$source_pane")"

# Follow the pane only when it is the one being used right now.
if [ "$source_pane" = "$ACTIVE_PANE" ]; then focus=--focus; else focus=--no-focus; fi

case $dest_key in
	tab:*)
		dest_tab=${dest_key#tab:}
		case $override in
			ctrl-r) split=right ;;
			ctrl-d) split=down ;;
			*) split=$(auto_split "$dest_tab") ;;
		esac
		out=$("$HERDR" pane move "$source_pane" --tab "$dest_tab" --split "$split" $focus 2>&1)
		rc=$?
		;;
	newtab:*)
		out=$("$HERDR" pane move "$source_pane" --new-tab --workspace "${dest_key#newtab:}" $focus 2>&1)
		rc=$?
		;;
	newws:*)
		out=$("$HERDR" pane move "$source_pane" --new-workspace $focus 2>&1)
		rc=$?
		;;
	*) die "unrecognized destination: $dest_key" ;;
esac

[ "$rc" -eq 0 ] || die "move failed: $out"
"$HERDR" pane resize --pane "$source_pane" --direction right --amount 0 >/dev/null 2>&1 || true
