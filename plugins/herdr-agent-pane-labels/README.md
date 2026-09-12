# herdr-agent-pane-labels

Gives every herdr pane an explicit label: an agent's session name where there is one, otherwise the foreground process or the shell name.

Labels are written rather than left to herdr's own border rendering, because a label is *data*. herdr's `show_agent_labels_on_pane_borders` draws the agent id on the border and nowhere else; a real label shows up in `pane list`, so plugins can read it too — recent-navigator's `PaneInfo` deserializes `label`, and its `title` field never populates (herdr emits `terminal_title`), making the label the only pane name it sees. That setting is therefore turned **off** in this repo's `config-excerpt.toml`.

## Why a plugin

herdr already knows the session name — agents set the terminal title (Claude does it from `/rename`), and herdr exposes it as the `terminal_title_stripped` token. But that token only works in `[ui.sidebar.agents]` rows. Pane borders have no row/token config, so the only way to get a custom string onto one is a manual pane label (`herdr pane rename`).

herdr has no `pane.title_changed` event, so the sweep hangs off `pane.agent_detected` and `pane.agent_status_changed` (session renames) plus `pane.focused` (shell panes, which emit no agent events at all). Handlers get no payload — herdr just fires the command — so each run is a full sweep over `pane list`, ~40ms.

## Behaviour

Per pane, in order:

1. Title matches `^[A-Za-z0-9][A-Za-z0-9._-]*$` → use it. That's a deliberate `/rename` on an agent pane, or a foreground process name (`vim`, `k9s`) on a shell pane. The pattern rejects whitespace and path separators, which is what filters out Claude's auto-generated summaries, the default `Claude Code`, and cwd-shaped titles.
2. Otherwise, an agent pane → the agent id (`claude`, `codex`).
3. Otherwise → the shell name, from `$SHELL` (herdr's own fallback order for `[terminal] default_shell`). Without this a shell pane would keep whatever process name it last had — a stale `vim` long after vim exited.

**Manual renames win.** Every label written is recorded in `$HERDR_PLUGIN_STATE_DIR/applied.json`. If a pane's current label doesn't match what we last wrote, you renamed it by hand and we back off permanently. To opt a pane back in, clear the label (`herdr pane rename <pane_id> --clear`); the next sweep re-adopts it.

**Known lag.** A title that changes while its pane stays focused — launching vim in the pane you're already in — isn't picked up until focus moves away and back, since there is no title-change event to hook.

## Install

    herdr plugin install aksh1618/herdr-config/plugins/herdr-agent-pane-labels

or, from a clone:

    herdr plugin link <clone>/plugins/herdr-agent-pane-labels

Force a sweep without waiting for an event:

    herdr plugin action invoke aksh1618.herdr-agent-pane-labels.sync
