# herdr-terminal-browser

Ctrl+click a URL in any herdr pane and it opens in a terminal browser split next to that pane, instead of going to the desktop browser via `xdg-open`.

Ctrl+click is herdr's own "open this URL" gesture (`modified_url_click_modifier()` is Control on every platform); a plain click never opened links. This plugin registers a `[[link_handlers]]` entry for `^https?://`, which herdr consults *before* falling back to `xdg-open`.

## Config

`herdr plugin config-dir aksh1618.terminal-browser` prints the directory; the file is `config` inside it. Every key is optional.

```
command = w3m
ignore = ^https?://(localhost|127\.0\.0\.1|\[::1\])([:/]|$)
direction = auto
focus = true
reuse = replace
```

- `command` — any terminal browser. `{url}` marks where the URL goes; without it the URL is appended. The URL is always passed as a separate argument, never interpolated into the shell string. Falls back to `$HERDR_TERMINAL_BROWSER`, then to the first of `terminal-browser w3m elinks lynx links cha carbonyl browsh` on `PATH`. Set `command` to pin a lighter one when both are installed.
- `ignore` — extended regex; matching URLs go to `xdg-open` as before. herdr's own `pattern` is a Rust regex with no lookahead, so exclusions live here.
- `direction` — `auto` (default), `right`, or `down`. `auto` splits right when the clicked pane is at least 160 columns wide, else down when it has at least 24 rows.
- `focus` — `true` (default) focuses the browser pane.
- `reuse` — `replace` (default) closes the previous browser pane when it is in the same tab; `new` stacks a pane per click.

## terminal-browser

`terminal-browser` (zenbu-labs) is checked first, ahead of the text browsers. It is not a text browser at all — it is a real Chromium drawn into the pane with the kitty graphics protocol, so JavaScript, CSS and images work. I run it from a local Arch `terminal-browser-bin` PKGBUILD.

Two things make it fit this plugin without any special-casing:

- **It renders inside a herdr plugin pane.** Verified 2026-08-17 with herdr 0.8.0 and `[experimental] kitty_graphics = true`. Upstream issue #40 additionally claims rendering fails in *any* herdr pane; that report is from macOS/Ghostty and does not reproduce here.
- **The pane entrypoint invokes it bare, as `terminal-browser <url>`**, which is what dodges upstream's actual herdr bug. Given a TTY and no `--split`, it attaches to the pane it is already in. Only `terminal-browser --split …` takes the broken path — it shells out to `herdr pane split … --right-click pane`, and `--right-click` is not a herdr 0.8.0 flag (issue #40, open). This plugin makes the split itself, so it never asks terminal-browser to.

Notes:

- `herdr pane read` on a terminal-browser pane returns nothing. That is correct — the pane holds pixels, not text cells. Use `terminal-browser ls` to see what is running and `terminal-browser action -- …` to drive it.
- The first `terminal-browser action` after a fresh browser can fail with `could not connect agent-browser to … on port <n>`. It is a cold-start race while `agent-browser` brings up its session; the same command succeeds on retry.
- Each click still gets its own browser pane. `reuse = replace` closes the previous one, which also ends that browser session. `terminal-browser new-tab` could instead add a tab to a browser already open in the tab; not wired up.

## Reaching the desktop browser

- **Ctrl+Shift+click** — kitty's own link handler, not herdr's. Its default `mouse_map ctrl+shift+left release grabbed,ungrabbed mouse_handle_click link` applies even while an app grabs the mouse, and the matching press is discarded, so herdr never sees the click. Opens via `open_url_with default` → `xdg-open`. A URL that herdr wrapped across lines inside a narrow pane may only match its first fragment.
- **Ctrl+Shift+E** — the same thing from the keyboard (kitty's `open_url_with_hints`).
- **`ignore`** — for whole classes of URL that should always go to the desktop browser.
- **In the browser** — with `command = w3m -o extbrowser=xdg-open`, `M` opens the current page in the real browser and `Esc M` opens the link under the cursor (prefix `2`…`9` selects `extbrowser2`…`extbrowser9`).
- **Kill switch** — `herdr plugin disable aksh1618.terminal-browser` returns Ctrl+click to `xdg-open`; handler lookup skips disabled plugins, so it takes effect on the next click.

## Interop

herdr checks link handlers plugin by plugin, sorted by plugin id, and takes the first match. `aksh1618.terminal-browser` sorts early and matches all of `http(s)`, so it shadows narrower handlers from plugins that sort later — `official.browser` (herdr-browser's localhost handler), `dotfiles.github-link-preview`, `pickr`, `portfwd`. If one of those goes in, narrow the `pattern` here or rename this plugin's id so it sorts last.

## Layout

- `open-link.sh` — the link-handler action. Picks the split direction, opens the pane, renames it `web · <host>`, retires the previous one.
- `browse.sh` — the pane entrypoint. Resolves the browser command and execs it.
