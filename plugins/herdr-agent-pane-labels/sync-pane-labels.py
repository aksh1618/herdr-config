#!/usr/bin/env python3
"""Mirror each agent pane's session name onto its herdr pane label.

Herdr surfaces an agent's session name natively as the `terminal_title_stripped`
token — but ONLY inside `[ui.sidebar.agents]` rows. Pane borders have no row/token
config, just the `show_agent_labels_on_pane_borders` boolean, which draws the bare
agent id ("claude"). The only way to put the session name on a border is to set a
manual pane label via `herdr pane rename`, which takes precedence over the agent
label. This script does that sweep; the manifest fires it on agent events.

Scope: every pane gets a label. Agent panes get their session name. Shell panes get
their foreground process name when the title carries one ("vim", "k9s"), else the
shell name — the fallback matters because a shell title reverts to a cwd string on
exit, which would otherwise strand a stale "vim" on the border forever.

Ownership: we record every label we set in a state file. A pane whose current
label differs from the one we last wrote was renamed by hand, so we leave it
alone forever after. Clearing a label opts the pane back in.

Naming filter: a deliberate `/rename` is a dashed token with no whitespace;
Claude's auto-generated summaries contain spaces, and the default title is
"Claude Code". Both are rejected by NAME_RE, so an unnamed session keeps the
plain agent label until you actually name it.
"""

import fcntl
import json
import os
import re
import subprocess
import sys

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
STATE_DIR = os.environ.get("HERDR_PLUGIN_STATE_DIR") or os.path.expanduser(
    "~/.local/state/herdr-agent-pane-labels"
)
STATE_PATH = os.path.join(STATE_DIR, "applied.json")
LOCK_PATH = os.path.join(STATE_DIR, "sync.lock")

# Deliberate /rename names only: no whitespace, no path separators, leading alnum.
# Rejects "Claude Code" (space), "~/mis" and "..is/claudecode" (path-shaped).
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# Fallback for a shell pane sitting at its prompt, where the title is a cwd string
# rather than a process name. Matches herdr's own resolution order for [terminal]
# default_shell: $SHELL, then /bin/sh.
SHELL_NAME = os.path.basename(os.environ.get("SHELL") or "sh")


def herdr(*args):
    """Run a herdr CLI command, returning parsed JSON or None on any failure."""
    try:
        out = subprocess.run(
            [HERDR, *args], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except ValueError:
        return None


def load_state():
    try:
        with open(STATE_PATH) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    tmp = STATE_PATH + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(state, fh, indent=1, sort_keys=True)
        os.replace(tmp, STATE_PATH)
    except OSError:
        pass


def main():
    os.makedirs(STATE_DIR, exist_ok=True)

    # Agent events can arrive in bursts; one sweep covers every pane, so a
    # contended run has nothing left to do. Skip rather than queue.
    lock = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0

    listing = herdr("pane", "list")
    if not listing:
        return 0
    panes = (listing.get("result") or {}).get("panes") or []

    applied = load_state()
    live = set()

    for pane in panes:
        pane_id = pane.get("pane_id")
        if not pane_id:
            continue
        live.add(pane_id)

        current = pane.get("label") or ""
        ours = applied.get(pane_id)

        # Renamed by hand since we last wrote — hands off, permanently.
        if current and current != ours:
            applied.pop(pane_id, None)
            continue

        agent = pane.get("agent") or ""
        title = (pane.get("terminal_title_stripped") or "").strip()

        if NAME_RE.match(title):
            desired = title
        elif agent:
            # Unnamed session ("Claude Code", or an auto-summary with spaces).
            # herdr would draw the agent id on the border itself, but only there —
            # a written label is data every plugin can read, so write it.
            desired = agent
        else:
            # Shell pane at a prompt: the title is a cwd string, so name it for the
            # shell. Without this the pane would keep whatever process name it last
            # had — a stale "vim" long after vim exited.
            desired = SHELL_NAME

        if current == desired:
            continue

        if herdr("pane", "rename", pane_id, desired) is not None:
            applied[pane_id] = desired

    # Drop bookkeeping for panes that no longer exist.
    for pane_id in [p for p in applied if p not in live]:
        del applied[pane_id]

    save_state(applied)
    return 0


if __name__ == "__main__":
    sys.exit(main())
