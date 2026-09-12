#!/usr/bin/env bash
# launch revdiff in a herdr split pane beside the caller and capture annotations.
# usage: launch-review.sh [ref] [ref2] [--staged] [--untracked] [--only=file] [--all-files]
#                         [--exclude=prefix] [--stdin] [--annotations=path]
#                         [--description=text|--description-file=path] [--send-to=pane_id]
# output: annotation text from revdiff stdout (empty if no annotations)
# exit: 0 clean, 10 annotations captured, other nonzero failure
#
# --send-to=<pane_id> is the human path (a herdr keybinding): the review pane pastes its
# own annotations into that pane's composer and this script returns immediately, so there
# is no waiter at all. Without it, an agent is waiting on stdout.
#
# Forked from umputun/revdiff's launch-revdiff.sh (v1.11.1 era) and cut down to the herdr
# backend only. Two deliberate differences from upstream, both about surviving a killed
# launcher — see computer-help/revdiff/herdr-native-review-skill-handoff.md:
#   - the pane closes itself (`; exit` after the review command) instead of being closed
#     by this script, so a killed launcher cannot orphan it
#   - INT/TERM disarm the EXIT trap, so the captured annotations are left on disk to be
#     recovered instead of being deleted on the way out

set -euo pipefail

if [ "${HERDR_ENV:-}" != "1" ] || ! command -v herdr >/dev/null 2>&1; then
    echo "error: not inside herdr — this launcher only implements the herdr backend" >&2
    echo "run revdiff directly instead, or use the upstream revdiff skill" >&2
    exit 1
fi

REVDIFF_BIN=$(command -v revdiff 2>/dev/null || true)
if [ -z "$REVDIFF_BIN" ]; then
    echo "error: revdiff not found in PATH (pacman -S revdiff, or https://github.com/umputun/revdiff/releases)" >&2
    exit 1
fi

TMPBASE="${TMPDIR:-/tmp}"
OUTPUT_FILE=$(mktemp "$TMPBASE/revdiff-output-XXXXXX")

# --send-to=<pane_id> switches from "an agent is waiting on stdout" to "a human pressed a
# key": the review pane delivers its own annotations into that pane's composer when revdiff
# exits, and this script returns as soon as the pane is up. Consumed here, not passed on.
SEND_TO=""
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --send-to=*) SEND_TO="${arg#--send-to=}" ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# the pane the review belongs beside: our own when an agent runs us, the --send-to pane
# when a keybinding does (a binding's process has no pane of its own)
CALLER_PANE="${SEND_TO:-${HERDR_PANE_ID:-}}"

# every pane inherits HERDR_SOCKET_PATH, but a keybinding does not run in a pane; ask the
# server rather than embedding an empty socat target that would drop the annotations
SOCKET_PATH="${HERDR_SOCKET_PATH:-}"
if [ -z "$SOCKET_PATH" ]; then
    SOCKET_PATH=$(herdr status server 2>/dev/null | awk '/^socket:/{print $2}' || true)
fi

# shell-quote a single argument for safe embedding in sh -c strings.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

REVDIFF_CMD="$(sq "$REVDIFF_BIN")"
if [ -n "${REVDIFF_CONFIG:-}" ] && [ -f "$REVDIFF_CONFIG" ]; then
    REVDIFF_CMD="$REVDIFF_CMD $(sq "--config=$REVDIFF_CONFIG")"
fi
# pass exit-code-on-annotations via env, not a CLI flag: an old revdiff binary
# silently ignores an unknown env var but hard-fails on an unknown flag
REVDIFF_CMD="REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true $REVDIFF_CMD $(sq "--output=$OUTPUT_FILE")"
for arg in "$@"; do
    REVDIFF_CMD="$REVDIFF_CMD $(sq "$arg")"
done

# the pane's shell starts from herdr's environment, which predates the user's rc files,
# so EDITOR/VISUAL are otherwise lost for revdiff's multi-line annotation editor child
ENV_PREFIX=""
for _name in EDITOR VISUAL; do
    if [ "${!_name+x}" = x ]; then
        ENV_PREFIX="$ENV_PREFIX $(sq "${_name}=${!_name}")"
    fi
done
unset _name
if [ -n "$ENV_PREFIX" ]; then
    REVDIFF_CMD="/usr/bin/env$ENV_PREFIX $REVDIFF_CMD"
fi

CWD="$(pwd)"
DIR_NAME=$(basename "$CWD")

TITLE_REF=""
SKIP_NEXT=0
for arg in "$@"; do
    if [ "$SKIP_NEXT" -eq 1 ]; then SKIP_NEXT=0; continue; fi
    case "$arg" in
        -o|--output) SKIP_NEXT=1 ;;
        --output=*) ;;
        -*) ;;
        *) TITLE_REF="$arg"; break ;;
    esac
done

SENTINEL=$(mktemp "$TMPBASE/revdiff-done-XXXXXX")
rm -f "$SENTINEL"
LAUNCH_SCRIPT=$(mktemp "$TMPBASE/revdiff-launch-XXXXXX")

if [ -n "$SEND_TO" ]; then
    # nothing waits, so the review pane owns both temp files and clears them itself. only
    # the launch script is ours to fail on, before the pane is ever told to run it
    trap 'rm -f "$LAUNCH_SCRIPT"' EXIT
    # deliver through pane.send_input on the socket, not `herdr pane send-text`: send-text
    # is raw, so every newline in a multi-comment batch would submit a separate prompt.
    # send_input bracketed-paste-wraps, and keys:[] leaves it unsent for the human to read
    # shellcheck disable=SC2016  # $rc stays literal for the generated inner script
    { printf '#!/bin/sh\n%s; rc=$?\n' "$REVDIFF_CMD"
      printf 'if [ -s %s ]; then\n' "$(sq "$OUTPUT_FILE")"
      printf '  jq -Rsc --arg pane %s %s %s | socat - %s >/dev/null 2>&1\n' \
          "$(sq "$SEND_TO")" \
          "$(sq '{id:"herdr-review",method:"pane.send_input",params:{pane_id:$pane,text:(.|rtrimstr("\n")),keys:[]}}')" \
          "$(sq "$OUTPUT_FILE")" \
          "$(sq "UNIX-CONNECT:$SOCKET_PATH")"
      printf 'fi\nrm -f %s %s\n' "$(sq "$OUTPUT_FILE")" "$(sq "$LAUNCH_SCRIPT")"
      # 10 is "annotations captured", not a failure. any other nonzero is revdiff refusing
      # to start, and exiting nonzero here is what keeps the pane open on the error message
      printf 'case "$rc" in 0|10) exit 0 ;; *) exit "$rc" ;; esac\n'
    } > "$LAUNCH_SCRIPT"
else
    # normal exit removes everything. a signal instead disarms this trap and leaves the
    # output file behind: the review is still running in its own pane, and that file is
    # where its annotations land, so deleting it on the way out is what loses them
    trap 'rm -f "$OUTPUT_FILE" "$SENTINEL" "$SENTINEL.tmp" "$LAUNCH_SCRIPT"' EXIT
    trap 'trap - EXIT; exit 130' INT
    trap 'trap - EXIT; exit 143' TERM

    # shellcheck disable=SC2016  # $? and $rc stay literal for the generated inner script
    printf '#!/bin/sh\n%s; rc=$?; printf "%%s" "$rc" > %s.tmp && mv -f %s.tmp %s\n' \
        "$REVDIFF_CMD" "$(sq "$SENTINEL")" "$(sq "$SENTINEL")" "$(sq "$SENTINEL")" > "$LAUNCH_SCRIPT"
fi
chmod +x "$LAUNCH_SCRIPT"

# direction: explicit right|down via REVDIFF_HERDR_SPLIT_DIRECTION, else auto-detect from
# the caller pane's rect. terminal cells are ~2:1 (height:width), so a pane only reads as
# wide when cols exceed ~2x rows: wide -> side-by-side (right), tall/square -> stacked (down)
RD_SPLIT_DIR="${REVDIFF_HERDR_SPLIT_DIRECTION:-auto}"
if [ "$RD_SPLIT_DIR" != "right" ] && [ "$RD_SPLIT_DIR" != "down" ]; then
    RD_SPLIT_DIR=right
    if [ -n "$CALLER_PANE" ] && command -v jq >/dev/null 2>&1; then
        RD_RECT=$(herdr pane layout --pane "$CALLER_PANE" 2>/dev/null \
            | jq -r --arg p "$CALLER_PANE" \
                '.result.layout.panes[] | select(.pane_id == $p) | "\(.rect.width) \(.rect.height)"' 2>/dev/null \
            | head -1 || true)
        RD_COLS=${RD_RECT%% *}
        RD_ROWS=${RD_RECT##* }
        case "${RD_COLS}:${RD_ROWS}" in
            *[!0-9:]*|:*|*:) ;; # non-numeric or missing -> keep right
            *) if [ "$RD_COLS" -lt $((RD_ROWS * 2)) ]; then RD_SPLIT_DIR=down; fi ;;
        esac
    fi
fi

# split from the caller's own pane ($HERDR_PANE_ID is set by herdr in every pane's env) so
# the review opens beside the session that asked for it; --current would resolve against
# the server's focused pane, which may be elsewhere when the user has switched workspaces.
# a keybinding runs outside any pane, so there it is the --send-to pane that called us.
#
# focus follows who asked: an agent-launched review must not steal the keyboard, but a human
# who just pressed the key wants to land in it. focus returns to the caller when it closes
HERDR_SPLIT_ARGS=(pane split --direction "$RD_SPLIT_DIR" --ratio "${REVDIFF_HERDR_SPLIT_RATIO:-0.5}" --cwd "$CWD")
if [ -n "$SEND_TO" ]; then HERDR_SPLIT_ARGS+=(--focus); else HERDR_SPLIT_ARGS+=(--no-focus); fi
if [ -n "$CALLER_PANE" ]; then
    HERDR_SPLIT_ARGS+=(--pane "$CALLER_PANE")
else
    HERDR_SPLIT_ARGS+=(--current)
fi
HERDR_NEW=$(herdr "${HERDR_SPLIT_ARGS[@]}" 2>&1) || {
    echo "error: herdr pane split failed: $HERDR_NEW" >&2
    exit 1
}

# parse the id: jq when available, falling back to grep when jq is absent OR yields empty
# (e.g. herdr mixed a stderr line into the JSON via 2>&1). the split JSON carries both
# pane_id and tab_id; the first "pane_id" occurrence is the new pane
RD_PANE_ID=""
if command -v jq >/dev/null 2>&1; then
    RD_PANE_ID=$(printf '%s' "$HERDR_NEW" | jq -r '.result.pane.pane_id // empty' 2>/dev/null || true)
fi
if [ -z "$RD_PANE_ID" ]; then
    RD_PANE_ID=$(printf '%s' "$HERDR_NEW" | grep -o '"pane_id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
fi
if [ -z "$RD_PANE_ID" ]; then
    echo "error: herdr pane split did not return a pane id: $HERDR_NEW" >&2
    exit 1
fi

# pane label: caller's agent name and session title (from the caller pane's herdr metadata)
# plus the reviewed file when in --only mode, e.g. "rd - claude - my-session: plan.md"
RD_AGENT=""
RD_SESSION=""
if [ -n "$CALLER_PANE" ] && command -v jq >/dev/null 2>&1; then
    RD_META=$(herdr pane get "$CALLER_PANE" 2>/dev/null || true)
    RD_AGENT=$(printf '%s' "$RD_META" | jq -r '.result.pane.agent // empty' 2>/dev/null || true)
    RD_SESSION=$(printf '%s' "$RD_META" | jq -r '.result.pane.terminal_title_stripped // empty' 2>/dev/null || true)
fi
RD_FILE=""
for arg in "$@"; do
    case "$arg" in
        --only=*) RD_FILE=$(basename "${arg#--only=}"); break ;;
    esac
done
RD_TITLE="rd${RD_AGENT:+ · $RD_AGENT}${RD_SESSION:+ · $RD_SESSION}: ${RD_FILE:-$DIR_NAME}${TITLE_REF:+ [$TITLE_REF]}"
herdr pane rename "$RD_PANE_ID" "$RD_TITLE" >/dev/null 2>&1 || true

# `pane run` types the command into the new pane's shell, so it is dropped silently (rc 0
# either way) when the shell has not finished starting. wait for a prompt to exist rather
# than sleeping a guessed interval
for _ in $(seq 1 100); do
    if [ -n "$(herdr pane read "$RD_PANE_ID" --source visible --lines 5 2>/dev/null | tr -d '[:space:]')" ]; then
        break
    fi
    sleep 0.1
done

# the trailing `; exit` is what makes the pane close ITSELF once revdiff returns. nothing
# here closes it, so killing this launcher cannot leave the pane behind
RD_RUN="sh $(sq "$LAUNCH_SCRIPT"); exit"
[ -n "$SEND_TO" ] && RD_RUN="sh $(sq "$LAUNCH_SCRIPT") && exit"
if ! herdr pane run "$RD_PANE_ID" "$RD_RUN" >/dev/null 2>&1; then
    echo "error: herdr pane run failed for pane $RD_PANE_ID" >&2
    herdr pane close "$RD_PANE_ID" >/dev/null 2>&1 || true
    exit 1
fi

# keybinding mode ends here: the review pane delivers its own annotations, so there is
# nothing to wait for and no process left that could be killed halfway
if [ -n "$SEND_TO" ]; then
    trap - EXIT
    exit 0
fi

while [ ! -f "$SENTINEL" ]; do
    sleep 0.3
done
rc=$(cat "$SENTINEL" 2>/dev/null || echo 1)
cat "$OUTPUT_FILE"
exit "${rc:-1}"
