# herdr display-panes (tmux `prefix q`) — design

**Date:** 2026-10-24
**Status:** approved design, not implemented.

## Goal

An analog of tmux `display-panes` for herdr: `prefix+q` shows a number on
each pane of the focused tab, and one digit key moves focus to that pane.
Success: one keystroke after `prefix+q` lands focus on the intended pane;
any other key leaves the session as it was.

herdr 0.9.5 has no such feature (issue #41 discussed a navigate-mode overlay
but nothing shipped), and herdr cannot draw over live panes. The design
therefore redraws the panes' visible screens inside a full-size popup and
puts the numbers on top.

## Behavior

- `prefix+q` opens a full-size popup over the focused tab. `goto` goes back
  to its default `prefix+g` only.
- The popup shows each pane's current visible screen with its original
  colors, at the pane's own position, and thin lines where the pane borders
  are. Content is not dimmed — it looks like tmux.
- Each pane gets a big block digit at its center: red for the active pane,
  blue for the others (tmux's default `display-panes-active-colour` and
  `display-panes-colour`).
- Numbers start at 1 (tmux.conf has `pane-base-index 1`) and follow the
  order of `panes` in the tab's layout snapshot.
- Keys:
  - `1`–`9`: focus that pane, close the popup.
  - Any other key, including Esc: close the popup, change nothing else.
  - No key for 3 s (tmux.conf has `display-panes-time 3000`): close the
    popup, change nothing else.
- Zoomed tab: unzoom it first, then show all panes. If the result is a
  cancel (other key, Esc, timeout) or the digit of the pane that was zoomed,
  zoom that pane again. If the digit names a different pane, leave the tab
  unzoomed and focus that pane.
- One pane only: the popup shows it as `1`. Pressing `1` closes the popup;
  the pane is not touched.
- More than 9 panes: panes 10 and above get no digit and cannot be reached
  this way.
- When Copy mode, Settings or another modal is open, herdr refuses to open
  the popup (`ui_busy`), so `prefix+q` does nothing.

## Build

No plugin manifest. The popup is a `[[keys.command]]` entry, the same
mechanism as the existing `prefix+x` and `prefix+ampersand` prompts:

```toml
[[keys.command]]
key = "prefix+q"
type = "popup"
width = "100%"
height = "100%"
command = "bash ~/.config/herdr/display-panes.sh"
```

Files:

- `herdr/.config/herdr/display-panes.sh` — the script (beside
  `sysload.sh`, linked by the existing `herdr` stow package).
- `herdr/.config/herdr/display-panes_test.sh` — tests for the pure layer.
- `herdr/.config/herdr/config.toml` — the binding above; remove
  `goto = "prefix+q"` and update its comment.

### Popup geometry (from herdr source, `src/popup_size.rs`)

A popup is centered in the server's tab-surface area — the same `area` that
`herdr api snapshot` reports per layout. At 100%×100% the outer rect equals
that area, and the popup draws a 1-cell border, so the inner terminal
starts at `(area.x+1, area.y+1)` and is 2 rows shorter and 3 columns
narrower (border plus one reserved column). A pane at `rect` is drawn in
popup coordinates at `(rect.x - area.x - 1, rect.y - area.y - 1)`, clipped
to the popup size.

### Script layers

1. Pure functions (tested; input is JSON or plain values, output is text):
   - `numbered_panes SNAPSHOT_JSON` — the focused tab's layout → lines of
     `N pane_id x y width height focused`, popup-relative, N = 1..9.
   - `digit_glyph N` — the block glyph rows for digit N.
   - `pane_for_key KEY NUMBERED` — the pane ID for a key, or nothing.
2. Side effects:
   1. `herdr api snapshot`. If the focused tab is zoomed, run
      `herdr pane zoom <id> --off`, wait briefly for the panes to redraw,
      and read the snapshot again.
   2. For each pane, `herdr pane read <id> --source visible --ansi`; print
      each line at the pane's position with cursor-positioning escapes.
   3. Draw borders and digits; hide the cursor.
   4. `read -s -n 1 -t 3` for one key.
   5. On a digit for another pane, send
      `{"id":"display-panes","method":"pane.focus","params":{"pane_id":…}}`
      to the herdr socket with `nc -U`. The CLI cannot focus a pane by ID
      (`herdr pane focus` takes only `--direction`); the socket API can.
   6. Zoom again when the zoom rule above says so.

### Facts to verify during implementation

These are not yet confirmed and decide details of the drawing:

- Whether a layout pane `rect` includes the pane's border
  (`ui.pane_borders = "always"`), which decides a 1-cell offset of the text.
- Which environment variable gives the socket path inside a popup; the
  fallback is `~/.config/herdr/herdr.sock`.
- That a 100% popup leaves no gap at the edges on the real client.
- Whether `pane read --source visible` lines can be wider than the pane;
  if yes, clip them.

## Testing

- `display-panes_test.sh`, in the style of `numbering/renumber_test.sh`:
  numbering order, coordinate offset, zoomed and single-pane snapshots, and
  key-to-pane mapping, with fixture snapshot JSON taken from a real session.
- Manual check in herdr at the keyboard: a tab with 3 panes,
  `prefix+q 2` focuses pane 2; Esc and the timeout change nothing; a zoomed
  tab unzooms, and re-zooms on cancel; a single-pane tab closes on `1`.

## Out of scope

- Panes in other tabs or workspaces.
- Multi-digit selection for 10+ panes.
- Feature B (scrollback in nvim with relative line numbers) — a separate
  design after this one.
