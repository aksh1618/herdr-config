#!/usr/bin/env bash
# open a revdiff review beside the focused pane and paste the annotations back into it.
# usage: herdr-review-pane.sh [diff|file]
#   diff  uncommitted changes of the focused pane's directory (default)
#   file  pick one file with fzf and review it, repo or not
#
# bound to prefix+d / prefix+f. The review pane delivers its own annotations through
# launch-review.sh --send-to, so this script exits as soon as the pane is up.

set -euo pipefail

MODE="${1:-diff}"

LAUNCHER="$HOME/.agents/skills/herdr-review/scripts/launch-review.sh"
[ -x "$LAUNCHER" ] || LAUNCHER="$HOME/dotfiles/agents/skills/herdr-review/scripts/launch-review.sh"

# a `shell` binding has nowhere to print, so the notification is the only channel the user
# sees; stderr is kept as well for when this is run by hand or from the `popup` binding
die() {
    herdr notification show "revdiff review" --body "$1" >/dev/null 2>&1 || true
    echo "$1" >&2
    exit 1
}

[ -x "$LAUNCHER" ] || die "launch-review.sh not found — run ~/dotfiles/agents/install-skills.sh"

# a keybinding does not run inside a pane, so it inherits none of the per-pane herdr
# variables. the launcher refuses to run without this one, and resolving a pane below
# proves herdr is up more directly than the variable ever did
export HERDR_ENV=1

# a keybinding's process has no pane of its own: popups get HERDR_ACTIVE_PANE_ID, and the
# focused pane is the fallback for any binding type that does not set it
CALLER="${HERDR_ACTIVE_PANE_ID:-}"
if [ -z "$CALLER" ]; then
    # || true is load-bearing: under `set -e` with pipefail, jq failing on a herdr error
    # response kills the script here, and every die() message below becomes unreachable
    CALLER=$(herdr pane list 2>/dev/null | jq -r '.result.panes[] | select(.focused) | .pane_id' 2>/dev/null | head -1 || true)
fi
[ -n "$CALLER" ] || die "could not resolve the focused pane"

# foreground_cwd follows the pane's running process (an agent that cd'd, a shell that did);
# cwd is where the pane started and is the fallback
META=$(herdr pane get "$CALLER" 2>/dev/null || true)
CWD=$(printf '%s' "$META" | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty' 2>/dev/null || true)
[ -n "$CWD" ] && [ -d "$CWD" ] || die "pane $CALLER has no usable directory"
cd "$CWD"

case "$MODE" in
    diff)
        git rev-parse --git-dir >/dev/null 2>&1 || die "$CWD is not a git repo — use prefix+f to review a file"
        git status --porcelain 2>/dev/null | grep -q . || die "no uncommitted changes in $CWD"
        exec "$LAUNCHER" --untracked --send-to="$CALLER"
        ;;
    file)
        if git rev-parse --git-dir >/dev/null 2>&1; then
            LIST=(git ls-files --cached --others --exclude-standard)
        else
            LIST=(find . -type f -not -path '*/.*' -printf '%P\n')
        fi
        FILE=$("${LIST[@]}" 2>/dev/null | fzf --prompt="review > " --height=100% --border --preview 'head -200 {}' --preview-window=right,60%) || exit 0
        [ -n "$FILE" ] || exit 0
        exec "$LAUNCHER" --only="$CWD/$FILE" --send-to="$CALLER"
        ;;
    *)
        die "unknown mode '$MODE' (expected diff or file)"
        ;;
esac
