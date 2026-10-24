# herdr display-panes (tmux `prefix q`) — design

**Date:** 2026-10-24
**Status:** implemented 2026-10-24 — `herdr/.config/herdr/plugins/display-panes/`
(plugin `dotfiles.display-panes`), the `prefix+q` binding in `config.toml`,
the `herdr plugin link` line in `bootstrap.sh`.

CONFIRMED by the user pressing keys: the final version below works (an
earlier version, drawing inside the popup, worked but flashed).

Verified by an agent with real keypresses — `ctrl+space q <digit>` typed into
a herdr 0.9.3 client running in a pty for an isolated named session, its
output replayed through a terminal emulator (pyte) and checked frame by frame
(the harness is throwaway, not in the repo):
- pick, Esc, another key (not passed to the pane), the 3 s timeout, zoomed +
  Esc (re-zoomed), zoomed + another digit (stays unzoomed), zoomed + its own
  digit (zoom kept), a single-pane tab;
- no blank frame before the digits: idle 0/240 opens; another pane scrolling
  0/80; the focused pane redrawing in place, like a working agent, 1/240;
- keypress to digits on screen: median ~50-60 ms, p90 under 90 ms; zoomed
  ~150-190 ms;
- inside the popup's border the frame matches the screen underneath cell for
  cell — characters, colours (16/256/truecolor backgrounds, reverse),
  scrollbars — plain and zoomed;
- a digit typed fast after `q` (8 tries each): at 100 ms and later it always
  picks; at 60 ms 6/8 pick; at 30 ms or less it reaches the focused pane
  (see Behavior).
`perl display-panes.t` covers the pure layer.

## Goal

An analog of tmux `display-panes`: `prefix+q` shows a number on each pane of
the focused tab, and one bare digit focuses that pane. herdr 0.9.x has no such
feature (issue #41 discussed one; nothing shipped).

## Behavior

- `prefix+q` numbers the focused tab's panes 1-9 in layout order (tmux.conf
  has `pane-base-index 1`): each pane's screen stays as it is, with a big
  digit in the middle — red for the active pane, blue for the others (tmux's
  defaults).
- `1`-`9` focuses that pane. Any other key, Esc, or 3 s with no key
  (tmux.conf: `display-panes-time 3000`) closes it and changes nothing; the
  key is not passed on.
- Unlike tmux, the numbers take ~30 ms to start taking keys: until the
  popup exists (~30 ms after `q`) a key goes to the focused pane, and for the
  ~16 ms after that, until the client hears of the popup, herdr drops it
  (`popup_blocks_input`, `src/server/headless.rs`). A same-hand `q 2` roll is
  slower than both.
- Zoomed tab: unzoomed while the numbers show; zoomed again on cancel or on
  the zoomed pane's own digit; left unzoomed when another pane is picked.
- One pane: shown as `1`; `1` closes the numbers, the pane is untouched.
- Panes 10 and up get no digit.
- While Copy mode, Settings or another modal is open herdr refuses the popup
  (`ui_busy`) and nothing happens.

## Design

**Capturing the digit needs a popup.** herdr disables every binding on an
unmodified printable key ("unsafe direct keybinding", `src/config/keybinds.rs`,
no opt-out), resize and navigate modes give plain keys only fixed meanings,
and nothing in the API redirects a pane's input. A popup is session-modal and
takes every key.

**The popup repaints what it covers.** It is full size: a 100% popup's outer
rect is exactly the tab's pane area and it draws a 1-cell border there
(`src/popup_size.rs`); every pane has a full 1-cell border
(`ui.pane_gaps = true` by default). So the popup draws each pane's
`pane.read --source visible --ansi` text at the cells it occupies underneath,
plus what herdr draws around it: borders (`┌─┐│└┘`, overlay0, accent for the
focused pane — one-dark palette, `src/app/state.rs`) and scrollbars
(`render_pane_scrollbar_buffer`, `src/ui/scrollbar.rs`). Then the digits.
What cannot match: the popup's own border, drawn by the client on the area's
outer edge in accent, so while the numbers show that edge is accent all round
and edge junction corners are straight; and herdr's `panel_bg` (#282c34)
behind the reserved column, against Dracula's #282a36.

**Not flashing blank.** herdr renders at most every 16 ms
(`MIN_RENDER_INTERVAL`, `src/app/mod.rs`). A popup's first render shows its
terminal as it is at that moment; if its process has not printed yet, that
is an empty box for a frame. So:
1. `show` builds the whole frame before the popup exists, and the popup's
   command is `cat` of it (~3 ms), wrapped in synchronized output (DEC 2026).
2. `show` opens the popup right after a render, so the popup's first render
   is ~16 ms away and the frame is there. A render is located with a fresh
   `herdr terminal session observe`: its first record comes at the first
   render after it attaches, ~1.5 ms after the client's frame. (Later records
   cannot be used: they skip renders that only patch a pane in place.) Fences
   — `pane.report_metadata` clearing a token never set: flagged `changes_ui`
   (`src/api/schema/operations.rs`) so it asks for a render, but changes
   nothing — are sent every 5 ms so a render comes when nothing is drawing.
   The observer (~16 ms to attach: 7 ms to exec the herdr CLI, then its
   handshake) is started in a `BEGIN` block on `HERDR_PANE_ID`, before any
   module loads, so it attaches while the frame is built; it is replaced if
   a render used up its first record first. Fences go every 2 ms.

**Unzooming** happens before the frame is built: wait one render interval
for the resize (the API exposes no pane width to wait on), then until the
pane's text has been unchanged for 40 ms, at most 100 ms (a working agent
never stops changing).

**Files** (`herdr/.config/herdr/plugins/display-panes/`):
- `herdr-plugin.toml` — action `show` (`perl display-panes.pl show`), bound to
  `prefix+q` in `config.toml` as `type = "plugin_action"`; pane `picker`,
  `placement = "popup"`, 100%×100%, title U+200B (an empty title becomes
  "popup"; a zero-width space survives herdr's trim and draws nothing),
  command `cat "$DISPLAY_PANES_STATE/frame"; exec perl display-panes.pl pick`.
- `display-panes.pl` — `show` (plugin action) and `pick` (in the popup: one
  key, then `pane.focus` or `pane.zoom`, applied before the popup closes so
  the screen it uncovers is final). State passes through a temp dir under
  `HERDR_PLUGIN_STATE_DIR`.
- `display-panes.t` — Test::More checks of the pure layer.

Perl, not bash: macOS bash 3.2 cannot wait under a second and reads a file a
byte per syscall (22 ms for one frame); the bash version spent most of its
~300 ms starting jq and herdr CLI processes. System perl 5.34 has JSON::XS and
Test::More; JSON::PP is the fallback. Only light modules load (~10 ms): File::Temp,
File::Path, IO::Socket::UNIX and POSIX added ~12 ms, and every ms before the
popup opens is a ms in which a typed digit goes to the pane. POSIX loads in
`pick` only. The popup command runs `stty -icanon -echo` before `cat`: a
digit typed before `pick` switched to raw mode itself was lost in the line
buffer.

## Approaches tried and dropped

- Full-size popup that draws inside itself: blank for ~100 ms (~350 ms
  zoomed) — the flash the user reported.
- Same, frame pre-built: shorter flash — the 16 ms render cadence above.
- Numbers as pane border titles (`pane.report_metadata --title`, TTL'd) plus a
  small popup with a mini-map to take the key: a box in the middle of the
  screen; the user rejected it.
- Plain digit bindings armed for 3 s by editing `config.toml` and reloading:
  herdr disables them as unsafe direct keybindings.
- Re-entering prefix mode after `q` via a Ghostty `text:` binding: works, but
  the user wanted herdr only.
- One observer per pane as render markers: misses in-place patches (a working
  agent) — 15/40 blank in that case; replaced by the single fresh marker.

## Testing

- `perl display-panes.t`.
- Keypress check in herdr: a tab with 3 panes, `prefix+q 2`; Esc; wait 3 s; a
  zoomed tab with Esc and with another digit; a single-pane tab; once with a
  working agent in the focused pane.

## Out of scope

- Panes in other tabs or workspaces; multi-digit selection for 10+ panes.
- Feature B (scrollback in nvim with relative line numbers) — a separate
  design.
