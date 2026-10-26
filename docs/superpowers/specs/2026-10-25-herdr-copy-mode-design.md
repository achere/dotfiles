# herdr copy mode with relative line numbers — design

**Date:** 2026-10-25
**Status:** implemented 2026-10-25: `herdr/.config/herdr/plugins/panes/`
(plugin `dotfiles.panes`, which display-panes moved into), the `prefix+]`
binding in `config.toml`, the link lines in `bootstrap.sh`. The user has not
yet pressed the keys in their own session.

Design history:
- first written with history read on demand, screen by screen as the cursor
  reached it; the user rejected that ("you need to get the whole pane text
  right away"), so all of it is read when copy mode opens;
- the numbers first covered the first cells of each row ("left, over the
  text"); after trying it the user asked for them to push the text instead,
  with the view shifting sideways for full-width rows;
- herdr gives a popup every key, its prefix included, so prefix bindings did
  nothing in copy mode; the user wanted copy mode to stay on while they
  switch panes, tabs and workspaces, as in tmux. A popup cannot stay on one
  pane while others are used, and the API cannot put a pane in another's
  place without resizing it (`pane.swap` refuses across tabs, `pane.move`
  splits its target), so copy mode pauses and resumes instead. Patching
  herdr's own copy mode, which already behaves so, was offered and declined.

Verified by an agent on herdr 0.9.5 with real keypresses: `ctrl+space ]`
typed into a herdr client running in a pty for an isolated named session,
its output replayed through a terminal emulator (pyte) and checked frame by
frame (the harness is throwaway, not in the repo):
- the first frame is every row of the pane pushed right of its number, its
  colours with it; blank frames: 2 in 105 idle opens over seven runs, 0 in
  75 with another pane scrolling, and 0/60 against display-panes' 0/60 in
  one session; keypress to frame median 50-85 ms, as display-panes;
- `$` on a full-width row shifts the view so the cursor stays in the pane,
  `0` shifts it back;
- prefix bindings in copy mode: `prefix+l` focuses the right pane and pauses
  copy mode; `prefix+h` back reopens it with its cursor and selection, in a
  median 80 ms (10/10, at most 102 ms); `prefix+c` makes a tab and
  `prefix+p` back reopens it; `prefix+z` twice zooms and unzooms with copy
  mode back each time; `prefix+q` opens display-panes; `prefix+x` shows its
  confirm, naming copy mode's pane, in copy mode's popup and `n` brings copy
  mode back; `prefix+@` goes to workspace 2 and `prefix+!` back reopens copy
  mode on the same row; `prefix+s`
  (herdr's own) only pauses, and `prefix+]` takes the paused view back;
  `prefix+]` inside copy mode and the prefix twice change nothing; after `q`
  focusing the pane opens nothing;
- `5k`, `gg`, `G`; `/` then `v e y`; `V 2j y` on a row wrapped over three
  rows copies one joined line; `ctrl+v j j e y` copies a rectangle; Esc
  clears a selection, then exits; `q` and `y` close the popup;
- a 10,000-row history: frame at ~90 ms, `gg` typed right after it reaches
  row 1, `/big row 5000` finds it, the pane's scroll is back where it was
  while copy mode is still open; a pane scrolled back 3000 rows keeps that
  offset;
- an alternate-screen pane rewriting itself every 30 ms: `V y` copies the
  frozen row; less: the screen only; neither gets a `pane.scroll`, nor does
  a history under 1000 rows (counted in the server log, which logged 410
  `pane.scroll` lines for one open on a 10,000-row pane);
- a zoomed tab stays zoomed; prefix+q's checks still pass after the move
  (0/20 blank, median 58 ms).
`perl copy-mode.t` and `perl display-panes.t` cover the pure layer.

## Goal

A copy mode that shows vim-style relative line numbers, so `5k` or `12j`
can be read off the screen. herdr's own copy mode cannot do this and cannot
be extended from outside: its state, keys and drawing live in the client
(`src/client/shell/copy_mode.rs`), and herdr refuses popups while it is
open. So this is a second copy mode, built like display-panes: a full-size
popup that repaints the screen beneath it, with a Perl viewer running over
the focused pane.

What the user asked for:
- colours kept ("you must preserve color");
- no zoom ("i don't want it to zoom");
- the numbers on the left, pushing the text right;
- prefix bindings working in copy mode, which stays on its pane while they
  go elsewhere;
- the whole history at once, not read on demand;
- `prefix+]` for the new mode; herdr's own stays on `prefix+[`.

## Behavior

- `prefix+]` turns the focused pane into copy mode in place. The pane looks
  as it did — same colours, same rows, scrolled back as far as it was — plus
  a number column and a cursor. The other panes stay on screen as they are.
- Zoomed tab: copy mode covers the zoomed pane; the tab stays zoomed.
- The cursor starts on the last non-empty row of the view, column 1. tmux
  and herdr's own copy mode start at the pane's cursor, but herdr's API does
  not give a plugin the cursor position (herdr's own mode takes it from
  frame data inside the client).
- **Numbers:** a column over the first cells of each row, dim (one-dark
  overlay0). Each row shows its distance from the cursor row; the cursor row
  shows its absolute number, in accent, counting from 1 at the oldest
  history row (vim's `number` + `relativenumber`). Numbers are
  right-aligned, followed by one space. Width: the digits of the row count +
  1, at least 3 — 5 cells for a 3000-row history. The text moves right of
  the column, as in vim, and the cursor reaches every character. So the
  pane shows that many fewer columns of each row: when the cursor goes past
  the right edge the view shifts left, at most the column's width, and back
  when it returns to the left (vim without wrap). (Earlier versions drew the
  numbers over the text: the cursor cell showing its text hid the number's
  first digit; the cursor on the number, then the cursor kept off the
  hidden cells, the user rejected - they wanted the text pushed.)
- **Keys** (tmux `copy-mode-vi` / vim). A count (`1`-`9`, then any digits)
  repeats a motion; `0` with no count is a motion.
  - `h j k l`, arrows; `w b e W B E`; `0 ^ $`, Home/End; `{ }`
  - `gg`, `Ngg`; `G`, `NG` (absolute row N, the number the cursor row
    shows); `H M L`. These go to the row's first non-blank, as in vim.
  - `ctrl+u` / `ctrl+d` half a page, `ctrl+b` / `ctrl+f` and
    PageUp / PageDown a page, `ctrl+y` / `ctrl+e` one row
  - `/` and `?` search forward and back, `n` / `N` repeat. Case-insensitive
    unless the query has a capital letter (smartcase, as herdr's own search).
    The search wraps at the ends of the history. A match must fit in one row.
    Matches in view get a one-dark yellow background, the current one
    orange. While the prompt is open it uses the pane's bottom row;
    Backspace edits it, Esc cancels it.
  - `v` character selection, `V` line selection, `ctrl+v` rectangle (toggles
    in an open selection), `o` swaps the selection's ends. Selected cells
    are drawn in reverse video.
  - `y` or Enter: copy the selection to the macOS clipboard and exit. With
    no selection: exit, nothing copied.
  - Esc: clear the selection; with no selection, exit. `q` and `ctrl+c`: exit.
- **The prefix** (`ctrl+space`, from `config.toml`) and the key after it run
  that binding, as herdr would, and pause copy mode: its view (frozen
  history, cursor, view, selection, search) is kept for that pane, the popup
  closes. When the pane gets focus back from another one, by any means,
  copy mode reopens as it was, ~80 ms after the focus change, the live
  pane showing until then. `prefix+]` on the pane takes it back too. A
  paused view does not resume on a pane whose size changed (zoom, resize):
  copy mode starts afresh there. `q`, `y` and Esc end it for good.
  - Run through herdr's API: `focus_pane_*`, `cycle_pane_*`, `last_pane`
    (from a focus history the plugin keeps), `zoom`, `split_*` (in the
    pane's cwd), `new_tab`, `next_tab` / `previous_tab`, `switch_tab`,
    `switch_workspace`, `edit_scrollback`, `reload_config`, `close_pane` and
    `close_tab` (which end copy mode), plugin actions (prefix+q). After
    `zoom` and `reload_config` focus stays, so copy mode reopens at once.
  - `[[keys.command]]` popups (prefix+x, prefix+&) run inside copy mode's
    popup, full size; copy mode comes back when they exit.
  - Only herdr can run the rest - workspace picker, Settings, navigate mode,
    renames, resize mode, detach, help, sidebar, its own copy mode, new
    workspace or worktree: copy mode only pauses, and the binding is
    pressed again.
  - The prefix twice, or Esc, cancels it; `prefix+]` does nothing; an
    unbound key does nothing. No prefix while the search prompt is open.
  - A popup gets plain characters, so `prefix+shift+5` is `%` and
    `prefix+shift+7` is `&`: the named bindings (`percent`, `ampersand`)
    win, and workspaces 5 and 7 cannot be reached from copy mode. Bindings
    with alt (`focus_agent`) are left out.
- The view follows the cursor with no margin (tmux): it scrolls only when
  the cursor leaves it. The pane's scrollbar shows where the view is in the
  history — except for a pane on the area's right edge (a single pane, a
  zoomed one, the rightmost split): its scrollbar column lies under the
  popup's reserved column, which the popup cannot draw. The cursor row's
  absolute number gives the position there.
- **Copied text:** characters only, no colours.
  - `v` and `V` get their text from herdr (`pane.selection.read`), so it is
    the same text herdr's own copy mode copies: wrapped rows joined into one
    line, trailing blanks dropped, wide characters whole. If that text is
    not the frozen rows' text (the pane changed since copy mode opened),
    the frozen rows' text is copied instead, one line per row.
  - `ctrl+v` takes the same columns from each row, trailing blanks dropped,
    one line per row, wrapped rows not joined (tmux does the same).
  - On the alternate screen everything comes from the frozen rows.
- **History:** the pane's whole history, up to herdr's scrollback limit
  (`scrollback_limit_bytes`, 10 MB), all of it read when copy mode opens.
  Nothing is read on demand later. Keys typed while it is read apply when
  it is done. On 2026-10-25 the user's largest pane history was 331 rows.
- The history is frozen when copy mode opens, as in tmux: output that
  arrives later does not show.
- **Alternate-screen apps** (less, vim, and the Claude Code and pi panes):
  the screen only, as in tmux and herdr's own copy mode. herdr keeps no
  history for them (`max_offset_from_bottom` is 0, measured with less and
  in all of the user's Claude and pi panes). Their earlier conversation is
  deferred (see Out of scope).
- When Copy mode, Settings or another modal is open, herdr refuses the popup
  (`ui_busy`) and nothing happens (as for display-panes).

## Design

**Reading history**, once, when the viewer starts, before it handles a key:
- **None** when `max_offset_from_bottom` is 0 (alternate screen, or no
  scrollback): the screen read when copy mode opened is the history.
- **Up to 1000 rows:** one `pane.read --source recent --format ansi
  --lines 1000` (0.6 ms, measured). herdr returns at most 1000 rows
  (`lines.min(1000)`, `src/app/api_helpers.rs`), and on the primary screen
  the read ends at the last row with content or the cursor, not at the last
  row (`ghostty_recent_read_range`, `src/pane/terminal.rs`). So its row i is
  absolute row i only while it starts at row 0: only when the history has
  at most 1000 rows. A `pane.get` before and after checks that; if the
  history grew past 1000 rows meanwhile, the next way is used.
- **Longer:** every row, screen by screen. `pane.scroll` moves the pane under
  the popup to an offset, then `pane.read --source visible --format ansi`
  returns that screen. The popup covers the pane, so the scrolling does not
  show; it cannot run before the popup opens, where it would. Measured: the
  9004 older rows of a 10,000-row history in 215 screens, 64 ms.
- **Row numbers:** a row's absolute number is the one herdr's own copy mode
  uses (`src/client/shell/copy_mode.rs`): screen top =
  `max_offset_from_bottom - offset_from_bottom`, both from the `pane.scroll`
  reply, because new output moves the offset (50 became 56 after 6 rows of
  output, measured). A screen whose `max_offset_from_bottom` changed before
  a `pane.get` after the read is read again.
- The history ends at the last row there was when copy mode opened; rows
  added later are dropped. Then the rows of the open-time view are put back
  over what was read, so a redraw shows what the first frame showed.
- **Restore:** right after the screen-by-screen read, the pane goes back to
  its offset. If output arrived meanwhile, the offset grows by the same
  number of rows, so the same rows are in view; a pane that was at the
  bottom stays at the bottom. An `END` block (and HUP/TERM handlers, so it
  runs) restores it if the viewer dies during the read.
- If herdr drops the oldest history (at its byte limit) during the read,
  screens read after that are off by the dropped rows. Accepted: it needs
  a working pane near 10 MB of history.

**Copying.**
- `v` and `V` call `pane.selection.read {pane_id, anchor, cursor}` with
  absolute rows, ends in order, the end column inclusive. `V` runs from
  column 0 of the first row to the end of the last row's text. herdr
  refuses an end column at the terminal's right edge
  (`selection_unavailable`: column 131 of a 132-cell pane was refused,
  column 50 of an empty row was accepted), so the end column is clamped to
  the end of that row's text. A one-row selection that starts past its
  row's text copies nothing.
- herdr reads the live buffer, the view is frozen: its text is compared
  with the frozen rows' text, all whitespace removed from both, and the
  frozen rows' text is copied when they differ. On the alternate screen
  (`max_offset_from_bottom` 0) herdr is not asked at all: a working Claude
  pane redraws all the time.
- `ctrl+v` uses the rows' plain text.
- The text goes to `pbcopy`, with `LANG=en_US.UTF-8` (pbcopy decodes its
  input by the locale, and the popup's environment may have none).

**Search** runs in the viewer over the rows' plain text. herdr's
`pane.copy_search` searches all history in the server, but it needs the
pane's current `content_revision` (`pane.copy_motion` returns it). Any
output from the pane makes that value stale, so on a working pane the search
fails until the pane is quiet. The local search works on the frozen rows the
user sees.

**Text model.** Each ANSI row is split into cells: a character plus the SGR
escapes in force for it since the last reset, kept as they came so they are
written back unchanged. A character is a grapheme cluster (`\X`). It takes
two cells when it starts East Asian wide or fullwidth (`\p{Ea=W}`,
`\p{Ea=F}`) or carries VS16 (U+FE0F). This matches the columns herdr 0.9.5
reports through `pane.selection.read` (measured): 🐍, 中, ス, ❤️ (with VS16)
and a ZWJ family are 2 cells; ☸, ✓, → and é with a combining accent are 1.
OSC sequences (hyperlinks) and other control sequences are dropped. A view
row is the number column, then the row's cells from the view's left edge
for tw - gw columns, each drawn with its own style, written only when it
changes, except where an overlay takes the cell: search match (replaces the
style), selection (reverse video on top of the style; `\e[27m` on a cell
that is already reversed). A wide character cut by either edge becomes a
space.

**Cursor:** the popup terminal's own cursor, put on the cursor cell as a
steady block (`\e[2 q`, `\e[?25h`). herdr draws a popup's cursor:
`blit_pane_surface` (`src/client/shell.rs`) copies the popup frame's cursor
and its visibility.

**Opening without a flash** reuses display-panes' path, unchanged:
1. an early observer marker started in `BEGIN`;
2. the whole first frame built before the popup exists — every pane's
   visible text, borders and scrollbars, and for the focused pane the number
   column and cursor too;
3. `plugin.pane.open` right after a render, found with fences
   (`pane.report_metadata`) and the marker.

The focused pane's visible read is taken between two `pane.get`s and read
again if the history grew in between, so the rows and their numbers belong
together. In a zoomed tab the frame has the zoomed pane only, on the whole
area: the snapshot keeps the unzoomed rects (measured), so the area is used.
The pane's text width is its inner width less one: the terminal leaves the
last column to the scrollbar (a 300-character row came back 64 cells wide
in a 65-cell pane, measured).

The popup command is `stty -icanon -echo -isig -iexten -ixon -icrnl min 1
time 0; cat frame; exec perl copy-mode.pl run`, so a key typed early is not
lost and reaches the viewer unchanged: without `-isig`, ctrl+c kills it;
without `-iexten`, the tty eats ctrl+v (LNEXT) and macOS takes ctrl+y
(DSUSP); without `-ixon`, ctrl+s/ctrl+q; without `-icrnl`, Enter arrives as
`\n`. The viewer sets the same with POSIX::Termios. It gets the focused
pane's visible rows, geometry and scroll numbers from files that open saved
with the frame.

**Drawing after a key:** the focused pane's rows, scrollbar and border only,
in one synchronized update (DEC 2026). Other panes stay as the first frame
drew them.

**Keys in the popup** come as legacy sequences (measured): arrows `\e[A`-`D`
(a `\eOB` sent in is re-encoded as `\e[B`), PageUp/PageDown `\e[5~`/`\e[6~`,
Home `\e[H`, ctrl keys as their control bytes, Esc as a lone `\e`, Enter as
`\r`. herdr passes Esc to the popup and does not close it. A lone `\e` is
Esc when nothing follows it within 25 ms. Every key comes, the prefix too:
herdr routes keys to an open popup before it looks for its prefix
(`route_key_press`, `src/client/shell/input.rs`); ctrl+space arrives as NUL.

**Prefix bindings.** The viewer reads the prefix from `config.toml`
(`HERDR_CONFIG_PATH`, else `~/.config/herdr/config.toml`) when it starts.
After the prefix and a key it reads the bindings: herdr's defaults from
`herdr --default-config`, where they are commented out, replaced per action
by `config.toml`'s `[keys]`, then `[[keys.command]]` entries. Key names
follow herdr's parser (`parse_key_combo`, `src/config/keybinds.rs`):
`percent` is `%`, an upper-case letter or `shift+` a letter is that capital,
`shift+1..9` are the US shifted digits as herdr's `shifted_number_symbol`.
`plan_binding` turns the binding into API calls with the pane's tab,
workspace, cwd, its tab's panes in layout order, the tabs and workspaces by
number, and the last pane. The calls run while the popup still covers the
panes, so the screen it uncovers is the final one.

**Pausing and resuming.** Pausing writes the view's state and frozen rows as
JSON to `<session>/paused/<pane>.json` under `$HERDR_PLUGIN_STATE_DIR`. The
state dir is one for all herdr sessions (`plugin_state_dir`,
`src/plugin_paths.rs`: `~/.local/state/herdr/plugins/dotfiles.panes`) and
pane ids repeat across sessions, so `<session>` is the session's socket
path, made a file name. A `[[events]]` hook on `pane.focused`
(`copy-mode.pl focused`) keeps `<session>/focus`
(the focused pane and the one before; a popup's own pane, in no layout, is
left out), drops paused files of panes that are gone, and when focus comes
to a paused pane from another one opens copy mode on it with that state, if
the pane's size is unchanged, else afresh. The hook starts its render marker
early only when there is a paused file, since it runs on every focus
change. A binding that keeps focus (zoom, reload config, a custom popup
command) forks `copy-mode.pl later <pid> resume <pane>`, detached with
`setsid` so closing the popup does not end it: it waits for the viewer to
exit, then opens copy mode on the pane, retried for up to a second while
herdr still refuses popups. A plugin action is invoked the same way, after
the popup has closed (`plugin.action.invoke` would start display-panes
while copy mode's popup still blocks its own).

**Files.** `plugins/display-panes` became `plugins/panes` (plugin
`dotfiles.panes`), holding:
- `Panes.pm` — moved out of `display-panes.pl`: the socket API, layout,
  scrollbar, drawing a pane's text and chrome, marker, fence, open after
  render, and state files;
- `display-panes.pl` — as before, on top of `Panes.pm`;
- `copy-mode.pl` — `open` (plugin action), `run` (in the popup), `focused`
  (the event hook) and `later` (the detached resume), its pure layer
  testable as in `display-panes.pl`;
- `display-panes.t`, `copy-mode.t`.

Scripts load `Panes.pm` from their own directory
(`BEGIN { unshift @INC, __FILE__ =~ m{^(.*)/} ? $1 : '.' }`). The manifest
has the actions `display-panes` and `copy-mode`, the popup panes `picker`
and `copy`, and the `pane.focused` event hook.

**Wiring.**
- `config.toml`: `prefix+q` → `dotfiles.panes.display-panes`, `prefix+]` →
  `dotfiles.panes.copy-mode`, both `type = "plugin_action"`; `copy_mode`
  stays on `prefix+[`. `prefix+]` is proven by a keypress (the harness),
  not only by `herdr config check`.
- `bootstrap.sh`: `herdr plugin unlink dotfiles.display-panes` (errors
  ignored) for machines that linked the old id, then `herdr plugin link
  …/plugins/panes`.
- The registry keeps the repo path, so the `git mv` broke prefix+q until the
  relink; stow removed the old `~/.config/herdr/plugins/display-panes` link
  itself on restow.

## Testing

- `perl copy-mode.t`: ANSI to cells (SGR, wide characters as herdr counts
  them, OSC dropped); drawing a row (SGR kept, overlays, a wide character
  half covered); the number column; every motion with a count on a fixture;
  the view following the cursor; search (smartcase, both directions,
  wrapping, columns after wide characters); selection, the
  `pane.selection.read` request, local and rectangle text; keys and the key
  handler, the prefix in it; parsing bindings (defaults, overrides, ranges,
  shifted digits, custom commands, the prefix) and the plan for every kind
  of binding; a paused view's record and its return, and whether it fits;
  the focus history; the screens a long history needs and the offset
  restored after output; drawing the view pushed right and shifted, the
  prompt and the cursor.
- `perl display-panes.t` passes after the move to `Panes.pm`.
- With real keys, in the pty harness on an isolated session: the list at
  the top of this file.
- Harness caveat: pyte cannot parse the kitty keyboard sequences
  (`\e[<1u`, `\e[>31u`, `\e[>7u`) the client sends when focus moves to or
  from a popup and prints their last byte, a stray `u`; the harness strips
  them. herdr's pane is not affected (`pane.read`, and a raw-mode logger in
  the pane received no bytes).

## Out of scope

- Deferred by the user: the earlier conversation of Claude Code and pi
  panes. They draw on the alternate screen, so herdr holds only their
  screen. herdr can collect more by scrolling an idle agent with wheel
  events (`src/server/alt_screen_read.rs`), but only as text with no
  colours.
- Raising herdr's 1000-row read limit upstream, which would remove the
  screen-by-screen read. An upstream issue or PR is public, so it needs the
  user's approval first.
- Mouse selection; copying with colours.
- `f F t T ; ,`, `%`, marks, text objects, `*` / `#`, append, copy-pipe.
- Hiding or moving the number column.
- Following new output while copy mode is open.
- Showing a paused copy mode on its pane while another pane is in use (a
  popup cannot); prefix bindings only herdr can run; alt bindings;
  workspaces 5 and 7 by `shift+digit` from copy mode.
