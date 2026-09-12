#!/bin/sh

herdr_bin=${HERDR_BIN_PATH:-herdr}
sep=" · "
out=""

append() {
    [ -n "$1" ] || return 0
    if [ -n "$out" ]; then
        out="$out$sep$1"
    else
        out="$1"
    fi
}

part_agents() {
    "$herdr_bin" agent list 2>/dev/null | jq -r '
        .result.agents
        | reduce .[] as $a ({blocked:0, working:0, done:0, idle:0}; .[$a.agent_status] += 1)
        | [ (if .blocked > 0 then " \(.blocked)" else empty end),
            (if .working > 0 then " \(.working)" else empty end),
            (if .done > 0 then " \(.done)" else empty end),
            (if .idle > 0 then " \(.idle)" else empty end) ]
        | join("  ")' 2>/dev/null
}

part_space() {
    [ -n "${HERDR_ACTIVE_WORKSPACE_ID:-}" ] || return 0
    "$herdr_bin" workspace get "$HERDR_ACTIVE_WORKSPACE_ID" 2>/dev/null |
        jq -r '.result.workspace.label // empty' 2>/dev/null
}

for part in "$@"; do
    case $part in
        agents) append "$(part_agents)" ;;
        space) append "$(part_space)" ;;
    esac
done

printf '%s\n' "$out"
