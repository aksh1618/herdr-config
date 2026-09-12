#!/usr/bin/env bash
set -euo pipefail
herdr="${HERDR_BIN_PATH:-herdr}"
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
pane="$(printf '%s' "$ctx" | jq -r '.focused_pane_id // empty')"
[ -n "$pane" ] || pane="${HERDR_ACTIVE_PANE_ID:-}"
[ -n "$pane" ] || exit 1
info="$("$herdr" pane get "$pane")"
tab="$(printf '%s' "$info" | jq -r '.result.pane.tab_id')"
workspace="$(printf '%s' "$info" | jq -r '.result.pane.workspace_id')"
lines="${ANNOTATE_LINES:-1000}"
dir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-annotate.XXXXXX")"
"$herdr" pane read "$pane" --source visible --format ansi >"$dir/visible.ansi" 2>/dev/null || true
"$herdr" pane read "$pane" --source recent-unwrapped --format ansi --lines "$lines" >"$dir/thread.ansi" 2>/dev/null \
  || "$herdr" pane read "$pane" --source recent --format ansi --lines "$lines" >"$dir/thread.ansi"
printf '%s' "$ctx" | jq -r '.selected_text // empty' >"$dir/selected.txt"
resp="$("$herdr" plugin pane open --plugin "${HERDR_PLUGIN_ID:?}" --entrypoint annotate --placement tab --workspace "$workspace" --no-focus \
  --env "ANNOTATE_DIR=$dir" --env "ANNOTATE_TARGET_PANE=$pane" --env "ANNOTATE_TAB=$tab")" || { rm -rf "$dir"; exit 1; }
new="$(printf '%s' "$resp" | jq -r '.result.plugin_pane.pane.pane_id // empty')"
[ -n "$new" ] || { rm -rf "$dir"; exit 1; }
"$herdr" pane move "$new" --tab "$tab" --target-pane "$pane" --split down --focus >/dev/null
"$herdr" pane move "$pane" --new-tab --workspace "$workspace" --no-focus --label "annotate · parked" >/dev/null
