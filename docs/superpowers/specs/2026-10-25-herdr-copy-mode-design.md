# herdr copy mode with relative line numbers — design

**Date:** 2026-10-25
**Status:** design agreed in chat 2026-10-25; this spec awaits the user's
review. Not implemented. Revised 2026-10-25: the whole history is read at
open, not on demand (the user rejected reading on demand).

Measured on herdr 0.9.5 by an agent, against an isolated named session (the
probes are throwaway, not in the repo). The display-panes checks of the
2026-10-24 spec pass on 0.9.5 too: every functional check, 0/20 blank opens,
keypress to digits median 60 ms.

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
- the numbers "left, over the text";
- `prefix+]` for the new mode; herdr's own stays on `prefix+[`.

## Behavior

- `prefix+]` turns the focused pane into copy mode in place. The pane looks
  as it did — same colours, same rows, scrolled back as far as it was — plus
  a number column and a cursor. The other panes stay on screen as they are.
- Zoomed tab: copy mode covers the zoomed pane; the tab stays zoomed.
- The cursor starts on the last non-empty row of the view, column 1. tmux
  and herdr's own copy mode start at the pane's cursor, but herdr's API
  does not give a plugin the cursor position (herdr's own mode takes it from
  frame data inside the client).
- **Numbers:** a column over the first cells of each row, dim (one-dark
  overlay0). Each row shows its distance from the cursor row; the cursor row
  shows its absolute number, in accent, counting from 1 at the oldest
  history row (vim's `number` + `relativenumber`). Numbers are
  right-aligned, followed by one space. Width: the digits of the highest row
  number + 1, at least 3 — 5 cells for a 3000-row history. The text does not
  move, so those cells are hidden while copy mode is open. The cursor cell
  stays visible, drawn over the column.
- **Keys** (tmux `copy-mode-vi` / vim). A count (`1`-`9`, then any digits)
  repeats a motion; `0` with no count is a motion.
  - `h j k l`, arrows; `w b e W B E`; `0 ^ $`; `{ }`
  - `gg`; `G`, `NG` (absolute row N, the number the cursor row shows); `H M L`
  - `ctrl+u` / `ctrl+d` half a page, `ctrl+b` / `ctrl+f` and
    PageUp / PageDown a page, `ctrl+y` / `ctrl+e` one row
  - `/` and `?` search forward and back, `n` / `N` repeat. Case-insensitive
    unless the query has a capital letter (smartcase, as herdr's own search).
    The search wraps at the ends of the history. A match must fit in one row.
    Matches in view get a one-dark yellow background, the current one
    orange. While the prompt is open it uses the pane's bottom row. Esc
    cancels it.
  - `v` character selection, `V` line selection, `ctrl+v` rectangle (toggles
    in an open selection), `o` swaps the selection's ends. Selected cells
    are drawn in reverse video.
  - `y` or Enter: copy the selection to the macOS clipboard and exit. With
    no selection: exit, nothing copied.
  - Esc: clear the selection; with no selection, exit. `q` and `ctrl+c`: exit.
- The view follows the cursor with no margin (tmux): it scrolls only when
  the cursor leaves it. The pane's scrollbar shows where the view is in the
  history.
- **Copied text:** characters only, no colours.
  - `v` and `V` get their text from herdr (`pane.selection.read`), so it is
    the same text herdr's own copy mode copies: wrapped rows joined into one
    line, trailing blanks dropped, wide characters whole.
  - `ctrl+v` takes the same columns from each row, trailing blanks dropped,
    one line per row, wrapped rows not joined (tmux does the same).
- **History:** the pane's whole history, up to herdr's scrollback limit
  (`scrollback_limit_bytes`, 10 MB), all of it read when copy mode opens.
  Nothing is read on demand later. Up to 1000 rows come in one read; a
  longer history is read in one pass right after the popup appears (see
  Design), and keys typed during that pass apply when it ends. On
  2026-10-25 the user's largest pane history was 331 rows.
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

**Reading history.** All of it is read once, when the viewer starts,
before it handles a key.
- **The last 1000 rows:** one `pane.read --source recent --format ansi
  --lines 1000`. herdr returns at most 1000 rows (`lines.min(1000)`,
  `src/app/api_helpers.rs`). 0.6 ms for 1000 rows (55 KB), measured.
- **Older rows**, only when the history is longer than 1000 rows: read
  screen by screen in one pass. `pane.scroll` moves the pane under the
  popup to an offset, then `pane.read --source visible --format ansi`
  returns that screen. The popup covers the pane, so the scrolling does not
  show. This cannot run before the popup opens: there it would show.
  Measured: the 9004 older rows of a 10,000-row history in 215 screens,
  64 ms, every row in its right place.
- **Row numbers:** a row's absolute number is the one herdr's own copy mode
  uses (`src/client/shell/copy_mode.rs`): screen top =
  `max_offset_from_bottom - offset_from_bottom`, both from the `pane.scroll`
  reply, because new output moves the offset (50 became 56 after 6 rows of
  output, measured). For the `recent` read, the history length comes from a
  `pane.get` before and after it. The same applies to each screen: if
  `max_offset_from_bottom` changed between the two, it is read again.
- The history ends at the last row there was when copy mode opened; rows
  added later are dropped.
- **Restore:** before the popup closes, the pane goes back to its offset. If
  output arrived meanwhile, the offset grows by the same number of rows, so
  the same rows are in view; a pane that was at the bottom stays at the
  bottom.
- There is no `pane.scroll` when the history fits in 1000 rows. In
  particular, there is none in an alternate-screen app
  (`max_offset_from_bottom` 0), where a scroll can become wheel input to
  the app.
- If herdr drops the oldest history (at its byte limit) during the pass,
  screens read after that are off by the dropped rows. Accepted: it needs
  a working pane near 10 MB of history.

**Copying.**
- `v` and `V` call `pane.selection.read {pane_id, anchor, cursor}` with
  absolute rows. `V` runs from column 0 of the first row to the end of the
  last row's text. herdr refuses an end column at the terminal's right
  edge (`selection_unavailable`: column 131 of a 132-cell pane was refused,
  column 50 of an empty row was accepted). So the end column is clamped to
  the end of that row's text. An empty result is an empty copy.
- `ctrl+v` uses the rows' plain text.
- The text goes to `pbcopy`.

**Search** runs in the viewer over the rows' plain text. herdr's
`pane.copy_search` searches all history in the server, but it needs the
pane's current `content_revision` (`pane.copy_motion` returns it). Any
output from the pane makes that value stale, so on a working pane the search
fails until the pane is quiet. The local search works on the frozen rows the
user sees.

**Text model.** Each ANSI row is split into cells: a character plus the SGR
state in force for it. A wide character (`\p{Ea=W}`, `\p{Ea=F}`) takes two
cells. OSC sequences (hyperlinks) are dropped. A row is drawn cell by cell,
with its own SGR, except where an overlay takes the cell: number column,
selection, search match. So everything not overlaid keeps its colours.

**Cursor:** the popup terminal's own cursor, put on the cursor cell and
shown (`\e[?25h`). If herdr does not show a popup's cursor, the viewer draws
the cursor cell in reverse video and hides the terminal cursor.

**Opening without a flash** reuses display-panes' path, unchanged:
1. an early observer marker started in `BEGIN`;
2. the whole first frame built before the popup exists — every pane's
   visible text, borders and scrollbars, and for the focused pane the number
   column and cursor too;
3. `plugin.pane.open` right after a render, found with fences
   (`pane.report_metadata`) and the marker.

In a zoomed tab the frame has the zoomed pane only, on the whole area. The
popup command is `stty -icanon -echo min 1 time 0; cat frame; exec perl
copy-mode.pl run`, so a key typed early is not lost. The viewer gets the
focused pane's visible rows and scroll numbers from files that open saved
with the frame, then reads the history (above) before it handles the first
key.

**Drawing after a key:** the focused pane's rows only, in one synchronized
update (DEC 2026). Other panes stay as the first frame drew them.

**Keys in the popup:** raw mode. Arrows, PageUp and PageDown come as escape
sequences; a lone Esc is an Esc when nothing follows it within 25 ms.

**Files.** `plugins/display-panes` becomes `plugins/panes` (plugin
`dotfiles.panes`), holding:
- `Panes.pm` — moved out of `display-panes.pl`: the socket API, layout,
  scrollbar, drawing panes with borders, marker, fence, open after render,
  and state files;
- `display-panes.pl` — as now, on top of `Panes.pm`;
- `copy-mode.pl` — `open` (plugin action) and `run` (in the popup), with its
  pure parts testable as in `display-panes.pl`;
- `display-panes.t`, `copy-mode.t`.

Scripts load `Panes.pm` from their own directory. The manifest has the
actions `display-panes` and `copy-mode`, and the popup panes `picker` and
`copy`.

**Wiring.**
- `config.toml`: `prefix+q` → `dotfiles.panes.display-panes`, `prefix+]` →
  `dotfiles.panes.copy-mode`, both `type = "plugin_action"`; `copy_mode`
  stays on `prefix+[`. `prefix+]` must be proven by a keypress, not only
  `herdr config check` (the lesson in `config.toml` about `[` and `"`).
- `bootstrap.sh`: `herdr plugin link …/plugins/panes`, and
  `herdr plugin unlink dotfiles.display-panes` for machines that linked the
  old id. Unlinking a missing id must not stop bootstrap.
- The stowed `~/.config/herdr/plugins/display-panes` link is left dangling
  by the rename. Check it after the restow and delete it if stow left it.

## Testing

- `perl copy-mode.t` checks:
  - ANSI to cells: SGR, 256 and truecolor, wide characters, OSC dropped;
  - a drawn row keeps its SGR outside the overlays;
  - every motion with a count on a fixture history;
  - the view following the cursor;
  - the number column's width and numbers;
  - search: smartcase, `n` / `N`, wrapping;
  - rectangle text;
  - the `pane.selection.read` request for `v` and `V`, end column clamped;
  - the offsets that read the rows older than the last 1000, and the offset
    restored after output.
- `perl display-panes.t` passes after the move to `Panes.pm`.
- With real keys, in the pty harness on an isolated session:
  - the first frame equals the pane except the number column and cursor, and
    no blank frame shows (idle and busy, as display-panes);
  - `5k` moves the cursor row and the numbers;
  - `v e y` and `V y` on a wrapped row copy the expected text (the harness
    saves and restores the clipboard);
  - on a 10,000-row history: `gg` reaches row 1, a key typed during the
    read applies after it, and the pane's scroll offset is back afterwards;
  - a pane under 1000 rows gets no `pane.scroll`;
  - a zoomed tab stays zoomed;
  - less on the alternate screen shows its screen and sends no scroll;
  - Esc, `q` and `y` close the popup.
- Display-panes' checks again after the move (`prefix+q` must not change).

## Out of scope

- Deferred by the user: the earlier conversation of Claude Code and pi
  panes. They draw on the alternate screen, so herdr holds only their
  screen. herdr can collect more by scrolling an idle agent with wheel
  events (`src/server/alt_screen_read.rs`), but only as text with no
  colours.
- Raising herdr's 1000-row read limit upstream, which would remove the
  screen-by-screen pass. An upstream issue or PR is public, so it needs the
  user's approval first.
- Mouse selection; copying with colours.
- `f F t T ; ,`, `%`, marks, text objects, `*` / `#`, append, copy-pipe.
- Hiding or moving the number column.
- Following new output while copy mode is open.
