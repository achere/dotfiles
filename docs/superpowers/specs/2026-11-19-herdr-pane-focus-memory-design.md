# herdr pane focus memory (tmux's directional pick) — design

**Date:** 2026-11-19
**Status:** proposed

## Goal

`prefix+h/j/k/l` should go back to the pane you came from when more than one
pane is next to you. In a tab with pane 1 on the left and panes 2 (top) and
3 (bottom) on the right, `[3] h → [1] l` must land on 3. herdr lands on 2.

Why herdr picks 2: `find_in_direction` (`src/layout.rs`, same in v0.9.5 and
on `main` of 2026-11-19) ranks the panes beyond the edge by edge distance,
then overlap, then centre distance, then layout order. From pane 1, panes 2
and 3 tie on the first three, so layout order picks 2. tmux breaks the same
tie by the most recently active pane (`window_pane_choose_best`,
`active_point`). This config mirrors tmux, so it takes tmux's rule.

## Behavior

On `prefix+h/j/k/l`, from the focused pane:

1. Zoomed tab: herdr's `pane.focus_direction` decides. No change from today.
2. Candidates: the panes herdr itself would consider — beyond the edge being
   crossed and overlapping the focused pane along that edge — cut to those
   at the smallest edge distance. A pane in a column further away is never a
   candidate when a nearer one exists.
3. Two or more candidates, at least one with a focus record: focus the
   candidate with the latest record. A candidate with no record loses to one
   with a record. Equal records: the first in layout order.
4. Otherwise (no candidate, one candidate, or no records):
   `pane.focus_direction` decides, which gives herdr's usual choice.

In the tab above:

| Keys | herdr today | With this |
|---|---|---|
| `[3] h → [1] l` | 2 | 3 |
| `[2] h → [1] l` | 2 | 2 |
| `[1] l` with no records (fresh server) | 2 | 2 |
| a tab where one pane is next to you | unchanged | unchanged |

Unchanged: NAVIGATE mode's `h/j/k/l` and arrow keys (they keep herdr's own
choice; this change covers the prefix bindings only), and no wrap-around at
the edge of the tab, as in herdr.

## Design

### Focus records

A "last focused" time per pane: `Time::HiRes` seconds, kept in a `stamps`
file, one `<pane_id>\t<time>` line per pane, in the session directory copy
mode already uses (`$HERDR_PLUGIN_STATE_DIR/<socket key>/`, next to its
`focus` file).

Two writers:
- the existing `pane.focused` hook (`copy-mode.pl focused`) records the pane
  that got focus — so the mouse, `prefix+q`, `prefix+;`, tab switches and the
  rest all count;
- the focus action records the pane it left and then the pane it landed on,
  in that order, in one write. So the first press after install already
  counts the pane you came from, and fast presses do not wait for the hook.

A write takes an exclusive `flock` on `stamps.lock`, reads the file, sets the
new times, drops panes absent from the snapshot's layouts, writes a temp file
and renames it over `stamps`. Readers do not lock: the rename is atomic.

Copy mode's `focus` file (`[current, previous]`, for `last_pane` and for
reopening a paused copy mode) stays separate and unchanged. Sharing one store
would break the reopen: the action's record for the landing pane, written
before the hook runs, would make the hook see focus as not having moved, so a
paused copy mode on that pane would not come back.

### Files

All in `herdr/.config/herdr/plugins/panes/`.

- `Panes.pm`
  - `direction_target($layout, $from, $dir, \%stamps)`: pure. Rules 1-4
    above over `layout()`'s panes (rects from `session.snapshot`). Returns
    the pane id to focus, or `undef` for "let herdr decide".
  - `read_stamps()` and `stamp($live, @panes)`: the store above.
    `$live` is the set of pane ids in the snapshot, for dropping closed panes.
- `focus.pl <left|down|up|right>`: new, loads only `Panes.pm`. Takes
  `session.snapshot`, `layout($s, 1)` (all panes, not the first nine),
  `direction_target`; then `pane.focus` on the target or
  `pane.focus_direction` from the focused pane; then records the pane it left
  and the pane focused after the call (the target, or the one
  `pane.focus_direction`'s reply names).
- `herdr-plugin.toml`: four actions, `focus-left`, `focus-down`, `focus-up`,
  `focus-right`, each `["perl", "focus.pl", "<dir>"]`. No new event hook.
- `copy-mode.pl`
  - `on_focused` also records the newly focused pane in `stamps`. It already
    has the snapshot, so dropping closed panes costs nothing extra.
  - `plan_binding` recognises a `plugin_action` binding to
    `dotfiles.panes.focus-<dir>` and plans it in-process: `pane.focus` on
    `direction_target`'s pane, or `pane.focus_direction` when it returns
    `undef`. The context gains the layout and the stamps. On this path the
    records come from the hook only. The existing `focus_pane_*` branch
    stays, for a config that keeps herdr's bindings.
- `focus.t`: new, the pure layer (see Testing).

`herdr/.config/herdr/config.toml`:
- `[keys]`: `focus_pane_left/down/up/right = ""`, unbinding herdr's
  actions the way `close_pane` is unbound.
- Four `[[keys.command]]` entries, `prefix+h/j/k/l`,
  `type = "plugin_action"`, `command = "dotfiles.panes.focus-<dir>"`, with a
  comment that says why (the tie, tmux's rule, this spec).

The manifest change needs herdr to read the manifest again. Check that
`herdr plugin list` shows the four actions; if not, re-run the
`herdr plugin link` line from `bootstrap.sh`. `bootstrap.sh` itself needs no
change.

### Cost

Measured 2026-11-19 on this machine: perl with `Panes.pm`, one
`session.snapshot` and one more request take a median ~13 ms (20 runs).
herdr's start of the plugin action comes on top. A key typed before focus
moves still goes to the old pane, as with any plugin binding.

## Testing

- `perl focus.t`, table cases for `direction_target`:
  - the 1 | 2/3 tab in all four directions, including `[3] h → [1] l` → 3
    and `[2] h → [1] l` → 2;
  - no records → `undef`; one candidate → `undef`; zoomed → `undef`;
  - a nearer column beats a more recently focused column further away;
  - a candidate without a record loses to one with a record;
  - equal records → first in layout order;
  - the same for a top/bottom split with `j`/`k`.
- `perl copy-mode.t`: the plan for the four plugin bindings (`pane.focus`
  on the chosen pane, `pane.focus_direction` on `undef`).
- `perl display-panes.t` and `perl copy-mode.t` still pass;
  `herdr config check` is clean.
- Real keys in the user's herdr: `[3] h → [1] l` lands on 3; a two-pane tab
  and a zoomed tab behave as before; `prefix+h` inside `prefix+]` moves the
  same way; a closed pane leaves `stamps` on the next write.

## Follow-up

After the user approves the dotfiles version, port it to
`~/Code/personal/herdr-tmuxify`: the same plugin code and bindings, through
that repo's installer, uninstaller, tests and README.

## Out of scope

- NAVIGATE mode's pane movement.
- Wrap-around at the tab edge.
- An upstream herdr change (tie-break in `find_in_direction`) or an issue
  asking for one.
