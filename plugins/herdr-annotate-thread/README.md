# herdr-annotate-thread

`prefix+a` opens the focused pane's thread in a neovim buffer, in that pane's own layout slot, so you can quote-reply to an agent with vim motions and send the whole batch back as one message. It is meant to feel like a built-in mode, the way herdr's copy mode does — not like a popup that landed on top of your work.

The point is the seam you don't see. Press the key and the pane appears to stay exactly where it was, same size, same content, same position in the layout, except now it takes vim motions. Quit and your pane is back with the reply sitting unsubmitted in the composer.

## Flow

1. Select in copy mode first (optional). A copy-mode selection reaches the action as `selected_text` and arrives pre-quoted, already annotated.
2. `prefix+a`. The thread opens in place; `q` or `:qa` quits and sends, `:Cancel` discards.
3. In the thread buffer: `a` on a line, or `v`/`V`/mouse-drag then `a`/`Enter` on a selection, appends a `> quote` block plus a comment line to the reply. `Tab` jumps between thread and reply.
4. On quit, a non-empty reply is pasted into the original pane's composer **unsubmitted**, via `pane.send_input` — so you read it back and press Enter yourself.

## How it takes the pane's slot

herdr has no pane-local placement. `popup` is centred over everything, `overlay` is a zoomed split, and a plugin pane can only be placed in a tab. So the slot is taken rather than asked for, in `open.sh`:

1. **Capture first, split second.** `pane read --source visible` and `--source recent-unwrapped --format ansi` both run *before* anything moves, because a split resizes the target pane and rewraps its scrollback — capture afterwards and you have recorded the wrong layout.
2. Open the plugin pane in a temporary tab, unfocused.
3. `pane move` it into the target's tab, split below the target, focused.
4. `pane move` the *target* out into its own tab, labelled `annotate · parked`.

The annotate pane is now the only pane in that slot, at the target's dimensions. On exit the two moves run in reverse. Pane ids, processes, scrollback and labels all survive — nothing is recreated.

Then the part that makes it invisible: the pane enters the alternate screen, prints the captured `visible.ansi` and only then starts nvim over it, so there is no flash of an empty shell between the two.

### The resize that isn't

**`pane move` never resizes the pane it moves** — geometry is not on the allowlist of things a move touches, so the pane arrives carrying its old dimensions and renders at the wrong width. The fix is a no-op resize (`pane resize --direction right --amount 0`) after every move, which forces herdr to re-apply the real geometry.

It has to be issued from *inside* the alternate screen. A pane on the primary screen keeps a column reserved for its scrollbar, so a resize there settles one column narrower than the slot, and the copy stops being pixel-perfect by exactly one column. The script waits for `stty size` to actually change rather than sleeping a fixed interval.

## Rendering

The thread is a **normal, non-modifiable buffer**, not a terminal buffer, with the pane's ANSI parsed into extmark highlights by hand. A terminal buffer looked like the obvious host and is the wrong one: it pre-maps the mouse and cancels visual mode on `nvim_set_current_win`, which kills the selection gesture this plugin is built around.

`pane read --lines` caps at 1000 lines; `ANNOTATE_LINES` sets it lower.

## Sending

A reply goes back through `pane.send_input` over the socket, which pastes as one bracketed chunk. Raw `send-text` is not usable — its newlines each submit, so a multi-line reply would fire as several messages.

If the target pane has **no agent** and the reply is multi-line, it is copied to the clipboard and a notification says so, instead of being typed into a shell a line at a time. `ANNOTATE_FORCE_SEND=1` overrides that. A failed send also falls back to the clipboard, so a reply you spent five minutes on cannot evaporate.

## Requirements

- herdr **0.9.0+** (`min_herdr_version`; the placement dance needs `pane move`'s `--target-pane` and `--new-tab`)
- `nvim`, `jq`, `socat`
- `wl-copy`, `xclip` or `xsel` for the clipboard fallback (optional)

## Tuned to me

This one is the least portable thing in the repo, and knowingly so:

- It assumes left-mouse events are free to bind. My own config Nops them globally, and the session deletes those maps on entry — on a config that maps the mouse differently, the drag-select gesture may not reach it.
- `a` in normal mode is deliberately shadowed. If your config has `a`-prefixed operator or text-object maps (`mini.ai`'s `aL`/`aN`, matchit's `a%`, nvim's built-in `an`), the keypress waits out `timeoutlen` before deciding — a buffer-local exact match does *not* escape the ambiguity wait. Deleting the shadowing maps took this from 1.28 s to 0.10 s here, but that fix lives in my nvim config, not in this plugin.
- It hides `lualine` if you have it, and sets `filetype=markdown` on both buffers, which pulls in whatever markdown stack you load for that filetype. Mine is pre-warmed on a throwaway buffer so it doesn't load inside the keypress.

## Layout

- `open.sh` — the action. Captures, opens the plugin pane, performs the two moves.
- `herdr-annotate-thread.sh` — the pane entrypoint. Alternate screen, geometry re-apply, runs nvim, restores the layout, sends or falls back to the clipboard.
- `annotate-thread.lua` — the nvim session: ANSI→extmark rendering, the annotate maps, the reply split, `:Send` / `:Cancel`.
