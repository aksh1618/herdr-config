# herdr-config

The plugins, scripts and agent skill I've built for my [herdr](https://herdr.dev) setup. Most of it exists because I wanted herdr to do one specific thing my way, found it didn't yet, and read enough of the source to find out what it *could* be made to do instead.

These are extremely fine-tuned to my workflows and aren't maintained as published plugins. This is a snapshot copied out of a private dotfiles repo, not the live config, so there's no history here. It's here to be read, and to be stolen from.

[![prefix+a opens the focused pane's thread in neovim, in that pane's own layout slot, to annotate it with vim motions](https://raw.githubusercontent.com/aksh1618/herdr-vimnotate/main/docs/vimnotate-demo.webp)](https://github.com/user-attachments/assets/83c63ee7-5f94-4757-9a08-98532e6a04fd)

Above: `prefix+a` on a pane running an agent. The thread opens in neovim **in that pane's own slot** — the shell below it never moves — paragraphs get marked with vim motions (`p` looks good, `d` delete, `c` comment, `.` to repeat), and `q` puts the review in the agent's composer unsubmitted.

All of it is developed and run against **herdr 0.9**, but each plugin declares its own floor: `vimnotate` is built and tested on 0.9.0, while `agent-pane-labels`, `terminal-browser` and `recent-navigator` set 0.7.4 or 0.7.5.

## Plugins

### `herdr-vimnotate`

`prefix+a` opens the focused pane's thread in neovim, **in that pane's own layout slot**, so I can review an agent's reply with vim motions — `cap` to comment on a paragraph, `dap` to strike one, `pp` for "looks good", `.` to repeat, `u` to undo — and send the whole review back as one unsubmitted message. It's meant to feel like a built-in mode the way herdr's copy mode does, press the key and the pane appears to stay exactly where it was, same size, same content, same place in the layout, except now it takes vim motions. Annotations show as coloured highlights with inline boxes (or a side rail), there's a general note on `Tab`, and the ones I've sent come back dimmed the next time I open the same pane.

herdr has no pane-local placement for a plugin pane (`popup` is centred, `overlay` is a zoomed split), so the slot is taken by capturing the pane's contents first, opening the plugin pane in a temporary tab, moving it into the target's slot, then parking the target in a tab of its own. Reversed on exit, with nothing recreated. The details that actually make it seamless, such as why the capture has to happen before the split, why a `pane move` needs a no-op resize after it, and why that resize has to be issued from inside the alternate screen, are in [its README](https://github.com/aksh1618/herdr-vimnotate#readme), along with the keys, the settings and how to run its tests.

Unlike the rest of this repo it's maintained as a plugin, so it lives in [its own repo](https://github.com/aksh1618/herdr-vimnotate) and is a submodule here, at `plugins/herdr-vimnotate`. Install it from there: `herdr plugin install aksh1618/herdr-vimnotate`.

It used to be `herdr-annotate-thread` (`aksh1618.annotate-thread`) in this repo. The id changed with the rename, so if you installed that, uninstall it and install the new repo instead.

### `herdr-terminal-browser`

Ctrl+click a URL in any pane and it opens in a terminal browser split beside that pane instead of going to the desktop browser via `xdg-open`. It uses a `[[link_handlers]]` entry to intercept Ctrl+click inside herdr. Works with `w3m` and friends, and with [terminal-browser](https://github.com/zenbu-labs/terminal-browser) which draws a real Chromium into the pane over the kitty graphics protocol. [README](plugins/herdr-terminal-browser/README.md)

### `herdr-agent-pane-labels`

Gives every pane an explicit label: the agent's session name where there is one, otherwise the foreground process, otherwise the shell. herdr draws it on the pane border and it shows up in `pane list` where other plugins like [beyondlex/herdr-recent-navigator](https://github.com/beyondlex/herdr-recent-navigator) can read it. Manual renames win permanently. [README](plugins/herdr-agent-pane-labels/README.md)

### Also: alt-tab between panes

`prefix+tab` cycles panes MRU-first with a visual picker, alt-tab style. That one is a **fork** of [beyondlex/herdr-recent-navigator](https://github.com/beyondlex/herdr-recent-navigator), I added the `cycle-panes` action (popup on first press, bare `Tab` to keep cycling, two-tier commit window) and later a fix for herdr 0.9 splitting focus into server-owned focused-pane vs per-client viewed-tab, which made cross-tab focus silently revert a few seconds later. It's a submodule here, at [`plugins/herdr-recent-navigator`](https://github.com/aksh1618/herdr-recent-navigator), pinned to the commit I'm actually running. Clone with `--recurse-submodules` (or run `git submodule update --init`) to pull it down, and install it from its own repo rather than through this one: `herdr plugin install aksh1618/herdr-recent-navigator`. herdr's installer fetches with `git init` + `fetch --depth 1` and never initialises submodules, so asking it for this repo's copy would hand you an empty directory.

## Scripts

Keybinding helpers. Each one exists because herdr has no action for the thing; each header says what was checked in the source before writing it.

| Script | Bound to | What it does |
| --- | --- | --- |
| [`herdr-move-pane.sh`](scripts/herdr-move-pane.sh) | `prefix+m` | Move a pane to another tab or workspace, from an `fzf` popup. herdr's bindable pane actions stop at `swap_pane_*`, which never leaves the current tab, and panes can't be dragged into one — `pane.move` is CLI/socket-only. Splits a placeholder shell in first when the pane is alone in its tab, because a tab dies with its last pane. |
| [`herdr-flip-split.sh`](scripts/herdr-flip-split.sh) | `prefix+/` | Flip the split around the focused pane — the divider you're looking at, at any depth. There's no transpose action and `pane.move` refuses same-tab moves, so the panes under that split are parked in a throwaway tab and re-inserted with the one direction flipped. Processes, scrollback, labels, order and ratios survive; `layout.apply` would kill them. Falls through to focus-right when there's no parent split. |
| [`herdr-split-auto.sh`](scripts/herdr-split-auto.sh) | `prefix+enter` | One key instead of choosing between `prefix+v` and `prefix+minus`: splits the bigger dimension **in pixels**. Pane rects are in cells, cells aren't square (10x22 px here), so a 198x95 pane is 1980x2090 px and wants a horizontal divider. `pane.graphics.info` is the only place the API exposes the cell size. |
| [`herdr-review-pane.sh`](scripts/herdr-review-pane.sh) | `prefix+d` / `prefix+f` | Open a [revdiff](https://github.com/umputun/revdiff) review beside the focused pane — uncommitted changes, or one file picked with `fzf`. The review pane pastes its own annotations into the caller's composer when it exits, so nothing waits on it. Drives the same launcher as the skill below. |
| [`herdr-status.sh`](scripts/herdr-status.sh) | `ui.tab_bar_right` | Agent-state counts plus the focused workspace, as one line. Aggregated into a single segment on purpose: every `command` segment pays a fixed ~120 ms `/bin/sh -lc` login shell whatever it runs, so the cost is per-segment, not per-unit-of-work. |

## `skills/herdr-review`

A Claude Code skill: open revdiff in a herdr pane beside the session, wait for the human to annotate, act on what they wrote. It's a fork of the upstream revdiff skill, and the reason for the fork is structural — the upstream SKILL.md forbids backgrounding, which in Claude Code means the review dies at the 10-minute foreground-Bash cap, and since the launcher is also what closes the pane, every death orphaned it.

The fork inverts who waits. The pane closes **itself** (`pane run "…; exit"`), with `INT`/`TERM` *disarming* the `EXIT` trap rather than firing it — the naive trap fix deletes the annotations on the way out, which is worse than the bug. And a `--send-to=<pane>` mode has the review pane paste into the caller's composer directly, so nothing waits at all.

It's included because [`scripts/herdr-review-pane.sh`](scripts/herdr-review-pane.sh) calls into its launcher; the two halves only make sense together.

## `config-excerpt.toml`

The parts of my `config.toml` that wire the above up, plus the settings they depend on, with comments explaining what was checked in herdr's source. My per-project colour rules are stripped out; everything else is verbatim.

## Installing any of this

herdr 0.9 takes a subdirectory, so the plugins are directly installable (vimnotate and recent-navigator from their own repos, as above):

```sh
herdr plugin install aksh1618/herdr-config/plugins/herdr-terminal-browser
herdr plugin install aksh1618/herdr-config/plugins/herdr-agent-pane-labels
```

That works, but read the second paragraph again — this is a snapshot of a live personal config, and it carries no tags, so pin a commit SHA with `--ref` if you do it. `herdr plugin link <path>` from a clone is the better way to pick one apart.

Dependencies, beyond `jq` which everything uses: `python3` for the pane-labels sweep; `fzf` and `column` for the pane mover; `flock` for the split flipper; `revdiff` for the review script and the skill. The browser plugin needs no particular browser — it falls back through `terminal-browser`, `w3m`, `elinks`, `lynx`, `links`, `cha` and `browsh`, taking the first on `PATH`.

## Not here

- The plugin bootstrap script that links these into herdr, which is specific to my dotfiles layout.
- A `herdr-session-title.sh` hook that put agent session names in the sidebar, retired when herdr 0.7.4 made that native.

## License

MIT.
