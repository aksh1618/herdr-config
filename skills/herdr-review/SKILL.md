---
name: herdr-review
description: Open a review in a herdr split pane beside this session and act on the reviewer's inline annotations. Use for reviewing a diff, a single file, a plan or design document, a patch or PR diff, or an explanation you wrote. Triggers on "review this", "review the diff", "review this file", "annotate this", "revdiff", "open this in revdiff", "review my plan", "review PR #N".
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, AskUserQuestion
---

# herdr review

Open [revdiff](https://github.com/umputun/revdiff) in a herdr pane next to this session, let the
user annotate, then act on what they wrote. The TUI is revdiff; the plumbing is ours.

**Always launch with `run_in_background: true`.** The upstream revdiff skill says the opposite,
and it is right for tmux, where the review lives in a client-owned `display-popup` that dies with
its client. In herdr the review runs in a **server-owned pane**: the launcher is only a waiter, so
backgrounding it costs nothing and removes the 10-minute foreground cap that otherwise kills every
review longer than ten minutes. A foreground call here is a bug.

## Launching

```typescript
Bash({
  command: `~/.agents/skills/herdr-review/scripts/launch-review.sh [ref] [ref2] [flags…]`,
  run_in_background: true,
  description: "revdiff review",
})
```

Then **keep working or wait** — the notification arrives when the reviewer quits. Do not poll in a
loop, do not relaunch, and do not ask the user whether they are done.

Flags, all optional and passed straight to revdiff:

| Flag | Use |
| --- | --- |
| `[ref] [ref2]` | diff against a ref, or between two |
| `--staged` | index only (nothing unstaged) |
| `--untracked` | include untracked files in the tree |
| `--only=<path>` | one file: a plan, a doc, any text — **works outside a repo** |
| `--all-files` | browse every tracked file |
| `--exclude=<prefix>` | drop a path prefix, repeatable |
| `--stdin` | read a unified diff from stdin (PR/patch review) |
| `--annotations=<path>` | preload annotations from a markdown file |
| `--description=<text>` / `--description-file=<path>` | context shown under `i` |

Pane placement is automatic (`REVDIFF_HERDR_SPLIT_DIRECTION=right\|down` and
`REVDIFF_HERDR_SPLIT_RATIO` override it).

### Picking the mode

- **A path that exists on disk** (`test -f`), or a token starting with `/` or `./`, or one with a
  `/` and an extension → `--only=<path>`. No ref. This is the plan/document review path and the
  only mode that works outside a VCS repo.
- **"all files" / "browse all files"** → `--all-files`, plus `--exclude=<prefix>` per exclusion.
- **An explicit ref** → pass it through.
- **A PR or patch** → pipe the diff in with `--stdin`
  (`gh pr diff 123 | …/launch-review.sh --stdin`). Mutually exclusive with refs, `--staged`,
  `--only`, `--all-files`, and `--annotations`.
- **Nothing given** → run `scripts/detect-ref.sh` (same directory as this file). It prints
  `suggested_ref`, `use_staged`, and `needs_ask`; pass `--staged` when `use_staged` is true, and
  when `needs_ask` is true use AskUserQuestion to offer "Uncommitted only" vs
  "Branch vs `<main_branch>`".

When you are the one asking for the review (you just refactored something), pass
`--description=…` so `i` explains what changed and what to look at, and `--untracked` when the
work created files that are not staged yet.

## Reading the result

The background task's output **is** the annotations. Exit codes: **`10` means annotations were
captured and is a success**, `0` means the user quit without annotating, anything else is a real
failure (the message is on stderr).

```
## file.go:43 (+)
use errors.Is() instead of direct comparison
```

`## <file>:<line> (<type>)` where type is `+` added, `-` removed, `file-level` a whole-file note;
the comment follows underneath.

**No output means the review is complete.** Say so and stop.

### If the task dies before the reviewer quits

Only the waiter died — the pane and revdiff are untouched, and the launcher deliberately leaves
the captured annotations on disk when it is signalled. Recover, newest first:

```bash
output_file="$(ls -t "${TMPDIR:-/tmp}"/revdiff-output-* 2>/dev/null | head -1)"
[ -n "$output_file" ] && cat "$output_file" && rm -f "$output_file"
```

**Delete the file once you have read it.** A stale `revdiff-output-*` is worse than none: the next
recovery reads the newest file and would replay annotations that were already handled.

If that is empty, fall back to the durable history, which survives even when the temp file is
gone: `scripts/read-latest-history.sh` prints the newest entry for this repo from
`~/.config/revdiff/history/<repo>/`. Only if both are empty did the user quit without annotating.

The reviewer can also press `O` mid-session to flush annotations without quitting. If they say
"I flushed my notes, go ahead", read the same output file and process it — **do not relaunch**;
they reload with `R` in the still-open pane after you make the changes.

## Acting on annotations

Split them in two:

**Questions** — the text contains `??` anywhere, or starts with `explain`, `remind`, `describe`,
`what is`, `what are`, `how does`, `how do`, `clarify` (case-insensitive). Answer these; do not
change code for them. Write the answer to a temp markdown file and reopen the review with
`--only=<that file>` so they can annotate the explanation itself. Loop until they quit without
annotating, then carry on with any pending code changes.

**Directives** — everything else. Plan the changes (EnterPlanMode) with each annotation's file and
line, get approval, then make them.

Afterwards relaunch with the same arguments so the user can check the fixes. They annotate again,
or quit clean and the review is done.

## Answering questions instead of reviewing

If the user asks *about* revdiff — keybindings, config, themes, output format — answer from
`references/config.md` and `references/usage.md`. Do not launch the TUI.

## Notes

- `revdiff` must be on PATH (`pacman -S revdiff` here).
- The launcher is herdr-only by design and exits 1 elsewhere. Outside herdr, run `revdiff` directly.
- Nothing closes the review pane but revdiff's own exit, so a killed launcher cannot orphan it.
