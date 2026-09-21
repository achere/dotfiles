# herdr tab and space numbering plugin — design

**Date:** 2026-09-21
**Status:** designed, not implemented. The spaces mechanism was verified live
against herdr 0.9.1 before writing (see "Verified before designing");
everything else is read from the v0.9.1 source and marked as such.

## Goal

Make a tab's number visible whatever its name is, and put the same number on
spaces in the expanded sidebar — so `prefix+1..9` and `prefix+shift+1..9` are
readable off the screen instead of counted. herdr 0.9.1 has no setting for
either; this is a local plugin that drives herdr's own event hooks.

## Context: what herdr 0.9.1 actually shows

Established by reading the source at tag `v0.9.1`, not from the docs — the
config reference and `configuration.mdx` both omit things the parser accepts
(the `copy_mode` lesson from the keybindings spec), so the parser and the
render path were treated as the authority.

| Surface | What it shows | Source |
|---|---|---|
| Tab bar | `tab.label` only, plus `" Z"` when zoomed | `src/client/shell/tabs.rs:374` |
| Tab label | `custom_name`, else `tab_idx + 1` | `src/workspace.rs:442` |
| Expanded sidebar space row | tokens only: `state_icon`, `state_text`, `workspace`, `branch`, `git_status`, `$custom` | `src/config/sidebar.rs:380-390` |
| Collapsed sidebar rail | `index + 1` per space | `src/client/shell/sidebar.rs:62-77` |

The consequence that drives this whole design: **a tab's number is not a
decoration beside its name, it *is* its auto-name.** Naming a tab replaces the
number; there is nothing to toggle back on.

`prefix+N` resolves by **position** in the workspace-filtered tab list
(`src/client/shell/actions.rs:924` — `tabs.get(index)`), not by the `number`
field the API returns. That field is a monotonic public id which diverges from
position after closes and moves (`src/app/mod.rs:2312-2313`). Anything that
numbers tabs must count positions and must not trust `number`.

The tabs half rests on `herdr tab list` returning tabs in position order, so
that was checked rather than assumed: both list paths walk `ws.tabs` by index
and neither sorts (`src/app/api/tabs.rs:23-29` unfiltered, `290-300` filtered
by `--workspace`). List order is position order. This mattered because the
current session cannot tell the hypotheses apart — every tab in it happens to
have `number == position`, so a list sorted by `number` would look identical
today and silently misnumber after the first close-then-create.

## Verified before designing

Run live against the running 0.9.1 server, not inferred:

- `herdr workspace report-metadata w1 --source numbering --token n=1` is
  accepted, and `herdr api snapshot` then reports `tokens: {"n":"1"}` on that
  workspace. Cleared again with `--clear-token n`. The spaces half of this
  design rests on that call, and it works.
- That CLI's `--help` **lies about argument order**. It prints
  `[OPTIONS] --source <ID> <WORKSPACE_ID>`, but the hand-rolled parser reads
  the workspace id positionally first (`src/cli/workspace.rs:144`); passing it
  last fails with `unknown option: numbering`. Same class of trap as `quote`
  naming the apostrophe: herdr's help text is not a contract.

Not verified, deliberately: how `$n` renders in the sidebar. That needs eyes on
the screen, so it belongs to the user in verification layer 3 below, not to a
claim here.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Tab numbering | Write the number into the name, `N:label` | The only mechanism. The tab bar renders nothing but the label. |
| Format | `1:dotfiles` | Matches tmux's default `#I:#W`, the convention the rest of this config mirrors. |
| Space numbering | `$n` metadata token, not a rename | Display-only. A rename would override herdr's repo-derived auto-naming, which is a real feature being paid for. |
| Trigger | herdr plugin event hooks | The sanctioned mechanism; no polling, no daemon of our own. |
| Auto-named tabs | Left alone | Their label already *is* their position, and herdr keeps it current. Touching one makes it custom-named forever — there is no API to un-name a tab. |
| Packaging | Inside the existing `herdr` stow package | Matches the convention; no new package for two files. |

## Mechanism

One plugin directory, `herdr/.config/herdr/plugins/numbering/`, holding a
manifest and one bash script. The manifest declares
`min_herdr_version = "0.9.1"` — the version every source citation here was
read from, and the floor herdr refuses to link below. `jq` is already a
Brewfile dependency for the pane-close popup.

**A run is a full reconciliation, not a delta.** It reads `herdr tab list` and
`herdr workspace list` once, then:

- For each workspace, walks its tabs in `herdr tab list` order. Position is
  1-based within that workspace. Desired label is `<position>:<name>`, where
  `<name>` is the current label with a leading `^[0-9]+:` stripped. It issues
  `herdr tab rename` **only** where the current label differs from the desired
  one.
- **Tabs whose label is entirely digits are skipped.** That is an auto-named
  tab, already displaying its own position, and herdr keeps it current for
  free; stamping one would produce `3:3` and cost it its auto-naming
  permanently. The test is a heuristic — `herdr tab list` returns no
  `custom_label` field, so "auto-named" is inferred from the label's shape.
  A tab a user deliberately names `42` is therefore skipped too.
- For each workspace, reports `--token n=<position>` with
  `--source numbering`.

Reconciling rather than reacting to the event payload means every hook is
interchangeable — the script never has to know *which* event woke it, and a
missed event self-heals on the next one.

### Events

Tabs: `tab.created`, `tab.closed`, `tab.moved`, `tab.renamed`.
Spaces: `workspace.created`, `workspace.closed`, `workspace.moved`,
`workspace.reordered`, `worktree.opened`, `worktree.removed`.
All ten are in `PLUGIN_HOOK_EVENT_KINDS` (`src/api/schema/events.rs:286-309`).

Plus a `[[startup]]` hook. Metadata tokens are runtime-only —
`WorkspaceSnapshot` has no tokens field (`src/persist/snapshot.rs:50`) — so
without it the sidebar numbers come back blank after a server restart. Tab names, being custom names,
do persist.

### Loop and race control

Two facts from the source shape this:

1. `handle_tab_rename` emits `tab.renamed` **unconditionally**, even when the
   label is unchanged (`src/app/api/tabs.rs:158-168`). So skipping
   already-correct renames is not an optimisation, it is the loop guard. With
   it, a change converges: the rename fires one more run, which finds nothing
   to do and stops. Without it, it never stops.
2. `run_plugin_event_hooks` spawns the command fire-and-forget with no
   debounce and no concurrency limit (`src/app/api/plugins/runtime.rs:218`).
   Overlapping runs are normal, not exceptional.

So runs serialize through a `mkdir` lock in `HERDR_PLUGIN_STATE_DIR`, with a
stale-lock timeout so a killed run cannot wedge the plugin. `mkdir`, not
`flock`: macOS ships no `flock` binary.

A run that cannot take the lock must **not** simply exit — that is a lost
update. The holder read its snapshot before the newer event happened, so
dropping the newer run leaves stale numbers on screen until some unrelated
event happens to fire. Instead a contending run touches a `dirty` marker
beside the lock and exits; the holder checks for `dirty` before releasing,
and if it is set, clears it and reconciles once more. That is the payoff for
reconciling instead of reacting to payloads: a burst of events collapses into
at most one extra pass, and nothing is dropped.

The spaces half needs no guard at all — `workspace.metadata_updated` is
deliberately excluded from hook-eligible events
(`src/api/schema/events.rs:351-357`), so reporting a token cannot wake the
plugin that reported it.

### Script interface

| Invocation | Behaviour |
|---|---|
| `renumber.sh` | Reconcile. What the hooks call. |
| `DRY_RUN=1 renumber.sh` | Print the renames and token reports it would issue; write nothing. |
| `renumber.sh --strip` | Remove every `^[0-9]+:` prefix and clear the `n` tokens. The undo. |
| `renumber_test.sh` | Table-driven check of the pure label transform. No server. |

`--strip` restores any name the plugin did not already corrupt. Two things it
cannot undo: a tab renamed once is custom-named for good (there is no API to
un-name one), which is the second reason auto-named tabs are left untouched;
and a name that was eaten on the way in stays eaten — `12:30 standup` stamps
to `1:30 standup` and strips to `30 standup`. Stripping is what destroys it,
and it is unrecoverable.

## Config changes

In `herdr/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "$n", "workspace"], ["branch", "git_status"]]
```

Renders as `● 1 · dotfiles`. The ` · ` is herdr's fixed token separator, not a
choice.

And, under `[keys]`:

```toml
switch_workspace = "prefix+shift+1..9"   # unset by default
```

Without it the space numbers are decoration nothing acts on. This is a
deliberate deviation from tmux, which has no jump-to-session-by-number binding
— recorded here rather than slipped in.

## Repo wiring

The plugin lives in the `herdr` stow package and is symlinked with everything
else. `plugins.json` — the registry — lives in the config dir
(`src/persist/plugin_registry.rs:11`) and is machine-local, like
`.plugins.lock` and `session.json`, so bootstrap must link it explicitly:

```sh
herdr plugin link "$HOME/.config/herdr/plugins/numbering"
```

next to the existing `herdr integration install` lines in step 9, which have
the same shape and the same reason for existing.

## Verification plan

Four layers, cheapest first. The first two carry no risk to the live session.

1. **`renumber_test.sh`** — the label transform over a table: `nvim` at 2 →
   `2:nvim`; `2:nvim` moved to 3 → `3:nvim`; already-correct → no rename (the
   loop guard); `3` auto-named → untouched; `12:30 standup` → asserts the
   known-eaten case so the limitation is pinned, not discovered.
2. **`DRY_RUN=1 renumber.sh`** against the real session — prints what it would
   do to the seven real tabs, writes nothing.
3. **An isolated live server.** `XDG_CONFIG_HOME=$(mktemp -d)`, copy
   `config.toml` in, link the plugin there, run `herdr`. Real hooks, real tab
   bar, live session untouched — necessary because the plugin registry lives in
   the config dir and is shared across named sessions, so linking into the
   normal config dir arms the running server immediately. Exercise: create a
   tab, close a middle tab, move one, rename one, restart the server for the
   `[[startup]]` hook, and read `$n` in the sidebar. `herdr plugin log list`
   shows each hook run with exit code and stderr when nothing appears to
   happen.
4. **`--strip`** — run it and confirm the tab bar returns to plain names.

## Known limits

- **Space numbers can disagree with `prefix+shift+N`.** The plugin numbers by
  the server's workspace order; the keybinding resolves against the client's
  *visible* list (`navigation_workspace_entries`,
  `src/client/shell/state.rs:1146-1159`), which differs when a worktree group
  is collapsed. Collapse state is client-side; a server-side plugin cannot see
  it. herdr's own two collapsed rails already disagree on this — one counts
  positions (`sidebar.rs:62-77`), the other prints the public `number`
  (`endpoint_sidebar.rs:134`).
- Tabs past 9 get numbered but are not reachable by `prefix+N`.
- A name deliberately starting with digits and a colon (`12:30 standup`) has
  its prefix eaten, irreversibly — see `--strip` above.
- Every tab the plugin touches becomes permanently custom-named in
  `session.json`. That also changes tab-bar styling (custom labels render
  bold when focused) and makes the agent sidebar show the tab token for
  single-tab workspaces (`src/client/shell/agent_sidebar.rs:273`).
- Renaming through `prefix+,` prefills the stamped name; the edit is
  re-stamped afterwards.

## Rejected alternatives

- **`ui.tab_bar_right` command entry** printing a numbered index. No renaming
  and no residue, but it spawns a process every second forever (minimum
  `interval_seconds` is 1), duplicates the tab row beside itself, and yields to
  the tabs on a narrow row. Considered seriously as the cheap option; rejected
  because the numbers belong next to the names, not in a second list.
- **Renaming workspaces** to carry their number. Would override herdr's
  repo-derived auto-naming, which updates as the root pane moves — a feature
  worth more than the number.
- **Upstream feature request.** Worth filing regardless; it does not help
  today, and the plugin is small enough to drop if upstream lands it.
