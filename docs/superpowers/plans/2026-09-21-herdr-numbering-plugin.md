# herdr numbering plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a tab's number visible whatever its name is (`2:nvim`), and put
the same number on spaces in herdr's expanded sidebar.

**Architecture:** A local herdr plugin whose event hooks all run one bash
script. The script is a full reconciler, not a delta handler: every run reads
the whole tab and workspace list and fixes whatever is wrong, so no hook needs
to know which event woke it. Tabs get their number written into the name
(herdr's tab bar renders nothing else); spaces get a display-only `$n`
metadata token.

**Tech Stack:** bash, jq (already a Brewfile dependency), herdr 0.9.1 CLI,
GNU stow, herdr plugin manifest format.

**Spec:** `docs/superpowers/specs/2026-09-21-herdr-numbering-plugin-design.md`

## Global Constraints

- **herdr floor:** `min_herdr_version = "0.9.1"`. Every source citation in the
  spec was read at tag `v0.9.1`.
- **Platform:** macOS only (`platforms = ["macos"]`). The lock uses
  `stat -f %m`, which is BSD `stat`; macOS ships no `flock` binary.
- **Dependencies:** bash and `jq` only. `jq` is already in the Brewfile for the
  pane-close popup. Add nothing else.
- **Metadata source id:** `numbering`. Token name: `n`.
- **Tab label format:** `<position>:<name>`, e.g. `2:nvim`. Position is 1-based
  within its workspace.
- **Never touch auto-named tabs** — labels matching `^[0-9]+$`.
- **Never issue a rename that is already correct.** `handle_tab_rename` emits
  `tab.renamed` even when the label is unchanged, so this is the loop guard,
  not an optimisation.
- **Commits:** end every commit message with
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Commit on `main`;
  this repo is linear and has no branches.
- **Stow:** files live in the existing `herdr` package under
  `herdr/.config/herdr/`, and reach `~/.config/herdr/` through
  `bootstrap.sh`'s `stow -R`.

## File Structure

| File | Responsibility |
|---|---|
| `herdr/.config/herdr/plugins/numbering/renumber.sh` | Everything: pure label transform, planner, strip, apply, lock. One file because the transform must be sourceable by the test without a second library file to keep in sync. |
| `herdr/.config/herdr/plugins/numbering/renumber_test.sh` | Table-driven test of the pure transform. No server, no network. |
| `herdr/.config/herdr/plugins/numbering/herdr-plugin.toml` | Manifest: startup hook plus ten event hooks, all running `renumber.sh`. |
| `herdr/.config/herdr/config.toml` | Modify: `$n` in the spaces sidebar rows, `switch_workspace` binding. |
| `bootstrap.sh` | Modify: `herdr plugin link` step, because the plugin registry is machine-local. |
| `docs/superpowers/specs/2026-09-21-herdr-numbering-plugin-design.md` | Modify: status line at the end. |

**Task order note:** `--strip` (Task 3) is built *before* the apply path
(Task 4) on purpose. Task 4 is the first task that writes to the live session,
and it should not be the first task that needs an undo that does not exist yet.

---

### Task 1: The label transform

The pure functions every later task builds on, and the only part that can be
tested without a running herdr.

**Files:**
- Create: `herdr/.config/herdr/plugins/numbering/renumber.sh`
- Test: `herdr/.config/herdr/plugins/numbering/renumber_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `strip_number_prefix <label>` → label with a leading `<digits>:`
  removed, printed without a trailing newline. `is_auto_named <label>` → exit
  0 when the label is all digits. `desired_label <position> <label>` → the
  label the tab should have, printed without a trailing newline; equal to the
  input when nothing should change. Sourcing `renumber.sh` with
  `RENUMBER_LIB_ONLY=1` defines these and runs nothing.

- [ ] **Step 1: Write the failing test**

Create `herdr/.config/herdr/plugins/numbering/renumber_test.sh`:

```bash
#!/usr/bin/env bash
# Table-driven check of renumber.sh's pure label transform. No herdr server
# involved - this is the layer that can be run anywhere, any time.
set -uo pipefail

RENUMBER_LIB_ONLY=1 source "$(dirname "$0")/renumber.sh"

failures=0
check() { # check <description> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: expected %q, got %q\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

check "plain name gets stamped"          "2:nvim"          "$(desired_label 2 'nvim')"
check "stale prefix is replaced"         "3:nvim"          "$(desired_label 3 '2:nvim')"
check "correct label is left identical"  "2:nvim"          "$(desired_label 2 '2:nvim')"
check "name containing a colon"          "2:feat:auth"     "$(desired_label 2 'feat:auth')"
check "name with spaces"                 "4:contro poc"    "$(desired_label 4 'contro poc')"
# An auto-named tab's label already IS its position and herdr keeps it current.
check "auto-named tab is untouched"      "3"               "$(desired_label 3 '3')"
# Deliberate digits-and-colon names are collateral damage. Pinned here so the
# limitation is a decision on record, not a surprise.
check "digits-and-colon name is eaten"   "1:30 standup"    "$(desired_label 1 '12:30 standup')"
check "strip removes a prefix"           "nvim"            "$(strip_number_prefix '2:nvim')"
check "strip leaves a bare name"         "nvim"            "$(strip_number_prefix 'nvim')"
check "strip is not greedy"              "2:nvim"          "$(strip_number_prefix '3:2:nvim')"

if ((failures > 0)); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod +x herdr/.config/herdr/plugins/numbering/renumber_test.sh
herdr/.config/herdr/plugins/numbering/renumber_test.sh
```

Expected: FAIL — `renumber.sh` does not exist, so `source` errors with
"No such file or directory".

- [ ] **Step 3: Write the minimal implementation**

Create `herdr/.config/herdr/plugins/numbering/renumber.sh`:

```bash
#!/usr/bin/env bash
# herdr numbering plugin - keeps each tab's number in its name (2:nvim) and
# reports each space's number as an $n metadata token for the sidebar.
#
# herdr 0.9.1 shows a tab's number only while the tab is auto-named, because
# the number IS the auto-name (src/workspace.rs:442) and the tab bar renders
# nothing but the label (src/client/shell/tabs.rs:374). Writing the number
# into the name is the only mechanism there is. Spaces are different: the
# sidebar takes custom tokens, so they need no rename.
#
# See docs/superpowers/specs/2026-09-21-herdr-numbering-plugin-design.md
set -euo pipefail

# --- pure label transform -------------------------------------------------

# Remove one leading "<digits>:" from a label. Not greedy: "3:2:nvim" loses
# only the "3:", because the rest is the user's name.
strip_number_prefix() {
  local label=$1
  if [[ $label =~ ^[0-9]+:(.*)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$label"
  fi
}

# A label of nothing but digits is herdr's own auto-name for the tab, which it
# keeps equal to the tab's position for free. Stamping one would produce "3:3"
# and cost the tab its auto-naming permanently - there is no API to un-name a
# tab. `herdr tab list` exposes no custom_label field, so the label's shape is
# the only available test; a tab a user deliberately names "42" is skipped too.
is_auto_named() {
  [[ $1 =~ ^[0-9]+$ ]]
}

# The label a tab at <position> should carry. Returns the input unchanged when
# nothing should change - callers rely on that to skip no-op renames.
desired_label() {
  local position=$1 label=$2
  if is_auto_named "$label"; then
    printf '%s' "$label"
    return
  fi
  printf '%s:%s' "$position" "$(strip_number_prefix "$label")"
}

# Sourced by renumber_test.sh, which wants the functions and nothing else.
if [[ ${RENUMBER_LIB_ONLY:-0} == 1 ]]; then
  return 0
fi
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
herdr/.config/herdr/plugins/numbering/renumber_test.sh
```

Expected: ten `ok` lines and `all checks passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x herdr/.config/herdr/plugins/numbering/renumber.sh
git add herdr/.config/herdr/plugins/numbering/
git commit -m "$(cat <<'MSG'
Add the herdr numbering plugin's label transform

The pure half: strip a stale prefix, skip auto-named tabs, stamp
<position>:<name>. Tested by a table that also pins the known-eaten
case (12:30 standup) so the limitation stays a decision on record.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: The planner and dry run

Reads herdr and decides what should change, without changing anything. This is
the task that can be exercised against the real session at zero risk.

**Files:**
- Modify: `herdr/.config/herdr/plugins/numbering/renumber.sh` (append after the
  `RENUMBER_LIB_ONLY` guard)

**Interfaces:**
- Consumes: `desired_label` from Task 1.
- Produces: `$HERDR` → the herdr binary to call. `$SOURCE_ID` → `numbering`.
  `plan_actions` → prints zero or more tab-separated action lines on stdout:
  `rename<TAB><tab_id><TAB><desired label>` and
  `token<TAB><workspace_id><TAB><position>`. `main "$@"` → dispatches on
  `DRY_RUN`. Running the script with `DRY_RUN=1` prints the plan and exits 0
  without writing; running it with neither `DRY_RUN` nor arguments does
  nothing yet.

- [ ] **Step 1: Append the planner**

Append to `herdr/.config/herdr/plugins/numbering/renumber.sh`:

```bash
# --- talking to herdr -----------------------------------------------------

# Plugin commands get HERDR_BIN_PATH injected; a hand-run does not.
HERDR="${HERDR_BIN_PATH:-herdr}"
SOURCE_ID="numbering"

# Tab renames. Position is counted here rather than taken from the API's
# `number` field on purpose: prefix+N resolves by POSITION in the
# workspace-filtered list (src/client/shell/actions.rs:924), while `number` is
# a monotonic public id that diverges from position after closes and moves.
# `herdr tab list` returns tabs in position order - both list paths walk
# ws.tabs by index and neither sorts (src/app/api/tabs.rs:23-29, 290-300).
plan_tab_renames() {
  local workspace tab_id label prev_workspace="" position=0 desired
  while IFS=$'\t' read -r workspace tab_id label; do
    if [[ $workspace != "$prev_workspace" ]]; then
      position=0
      prev_workspace=$workspace
    fi
    position=$((position + 1))
    desired=$(desired_label "$position" "$label")
    [[ $desired == "$label" ]] && continue
    printf 'rename\t%s\t%s\n' "$tab_id" "$desired"
  done < <("$HERDR" tab list | jq -r '.result.tabs[] | [.workspace_id, .tab_id, .label] | @tsv')
}

# Space numbers. The array index is the server's workspace order, which is what
# the sidebar draws. Reported every run rather than diffed: metadata tokens are
# runtime-only (src/persist/snapshot.rs:50 has no tokens field), so there is no
# stored value to compare against, and reporting one cannot wake this plugin -
# workspace.metadata_updated is excluded from hook events
# (src/api/schema/events.rs:351-357).
plan_space_tokens() {
  "$HERDR" workspace list |
    jq -r '.result.workspaces | to_entries[] | ["token", .value.workspace_id, (.key + 1)] | @tsv'
}

plan_actions() {
  plan_tab_renames
  plan_space_tokens
}

main() {
  local actions
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    actions=$(plan_actions)
    [[ -n $actions ]] && printf '%s\n' "$actions"
    return 0
  fi
}

main "$@"
```

- [ ] **Step 2: Run the dry run against the live session**

```bash
DRY_RUN=1 herdr/.config/herdr/plugins/numbering/renumber.sh
```

Expected: one `rename` line per named tab, with positions counted per
workspace and restarting at 1 for each — e.g. `rename	w1:t1	1:dotfiles` and
`rename	w2:t1	1:code`. One `token` line per workspace numbered `1`, `2`, `3`.
No auto-named tab appears.

- [ ] **Step 3: Confirm nothing was written**

```bash
herdr tab list | jq -r '.result.tabs[].label'
herdr api snapshot | jq -c '.result.snapshot.workspaces[] | {label, tokens}'
```

Expected: labels unchanged from before Step 2, and every `tokens` field still
`null`.

- [ ] **Step 4: Verify the loop guard by hand**

Rename one tab to its desired label, then re-run the dry run:

```bash
herdr tab rename w1:t1 "1:dotfiles"
DRY_RUN=1 herdr/.config/herdr/plugins/numbering/renumber.sh | grep -c '^rename	w1:t1' || true
herdr tab rename w1:t1 "dotfiles"
```

Expected: `0` — an already-correct tab produces no rename. This is the
property that stops the `tab.renamed` hook re-triggering itself forever. The
third command restores the original name.

- [ ] **Step 5: Commit**

```bash
git add herdr/.config/herdr/plugins/numbering/renumber.sh
git commit -m "$(cat <<'MSG'
Plan herdr renames and space tokens, with a dry run

Reads the whole tab and workspace list and prints what should change.
Counts positions itself rather than trusting the API's `number` field,
which is a monotonic id that diverges from position after closes.

Verified against the live session: correct tabs produce no rename,
which is what stops the tab.renamed hook re-triggering itself.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: `--strip`, the undo

Built before anything writes, so the first task that stamps the live session
has a way back.

**Files:**
- Modify: `herdr/.config/herdr/plugins/numbering/renumber.sh`
- Modify: `herdr/.config/herdr/plugins/numbering/renumber_test.sh`

**Interfaces:**
- Consumes: `strip_number_prefix` (Task 1), `$HERDR`, `$SOURCE_ID` (Task 2).
- Produces: `safe_stripped_label <label>` → the label `--strip` should apply,
  equal to the input when stripping would leave nothing. `strip_all` → removes
  every `<digits>:` prefix from tab labels and clears the `n` token from every
  workspace. `main` gains a `--strip` branch.

- [ ] **Step 1: Write the failing test**

Append to `renumber_test.sh`, immediately before the `if ((failures > 0))`
block:

```bash
# A tab labelled exactly "3:" would strip to nothing. herdr accepts an empty
# name, and a nameless tab is worse than a stamped one, so it is left alone.
check "strip refuses to empty a label"   "3:"              "$(safe_stripped_label '3:')"
check "strip returns the stripped name"  "nvim"            "$(safe_stripped_label '2:nvim')"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
herdr/.config/herdr/plugins/numbering/renumber_test.sh
```

Expected: FAIL — `safe_stripped_label: command not found`, so both new checks
report an empty actual value.

- [ ] **Step 3: Implement the guard and the strip pass**

In `renumber.sh`, add `safe_stripped_label` immediately after `desired_label`
— it is pure, so it belongs above the `RENUMBER_LIB_ONLY` guard where the test
can reach it:

```bash
# What --strip should rename a tab to. Returns the label unchanged when
# stripping would leave nothing: herdr has no objection to an empty tab name,
# and an unnamed tab is worse than a stamped one.
safe_stripped_label() {
  local label=$1 stripped
  stripped=$(strip_number_prefix "$label")
  if [[ -z $stripped ]]; then
    printf '%s' "$label"
  else
    printf '%s' "$stripped"
  fi
}
```

Add `strip_all` after `plan_actions`:

```bash
# The undo. Restores any name this plugin did not already corrupt: a name that
# was eaten on the way in (12:30 standup -> 1:30 standup) strips to
# "30 standup" and is unrecoverable, and a tab renamed once is custom-named
# for good - there is no API to un-name one.
strip_all() {
  local tab_id label stripped workspace_id
  while IFS=$'\t' read -r tab_id label; do
    stripped=$(safe_stripped_label "$label")
    [[ $stripped == "$label" ]] && continue
    "$HERDR" tab rename "$tab_id" "$stripped" >/dev/null
  done < <("$HERDR" tab list | jq -r '.result.tabs[] | [.tab_id, .label] | @tsv')

  while read -r workspace_id; do
    "$HERDR" workspace report-metadata "$workspace_id" \
      --source "$SOURCE_ID" --clear-token n >/dev/null
  done < <("$HERDR" workspace list | jq -r '.result.workspaces[].workspace_id')
}
```

And replace `main` with:

```bash
main() {
  local actions
  if [[ ${1:-} == "--strip" ]]; then
    strip_all
    return 0
  fi
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    actions=$(plan_actions)
    [[ -n $actions ]] && printf '%s\n' "$actions"
    return 0
  fi
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
herdr/.config/herdr/plugins/numbering/renumber_test.sh
```

Expected: twelve `ok` lines and `all checks passed`.

- [ ] **Step 5: Verify strip is a no-op on an unstamped session**

Nothing has stamped the live session yet, so strip should change nothing.

```bash
herdr tab list | jq -r '.result.tabs[].label' > /tmp/labels-before
herdr/.config/herdr/plugins/numbering/renumber.sh --strip
herdr tab list | jq -r '.result.tabs[].label' > /tmp/labels-after
diff /tmp/labels-before /tmp/labels-after && echo "unchanged"
```

Expected: `unchanged`. A strip that mangles names with no prefix would show up
here rather than after the session is stamped.

- [ ] **Step 6: Commit**

```bash
git add herdr/.config/herdr/plugins/numbering/
git commit -m "$(cat <<'MSG'
Add --strip to the herdr numbering plugin

Built before the apply path on purpose: the first task that stamps the
live session should not be the first task that needs an undo. Refuses
to strip a label to nothing, since herdr would accept an empty name.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: Apply, with the lock and the dirty marker

Turns the plan into writes, and makes concurrent runs safe. Hooks spawn
fire-and-forget with no debounce (`src/app/api/plugins/runtime.rs:218`), so
overlapping runs are the normal case, not an edge case.

**Files:**
- Modify: `herdr/.config/herdr/plugins/numbering/renumber.sh`

**Interfaces:**
- Consumes: `plan_actions`, `strip_all`, `$HERDR`, `$SOURCE_ID`.
- Produces: `apply_actions <actions>` → executes the action lines.
  `reconcile` → one plan-then-apply pass. `take_lock` → exit 0 when this run
  holds the lock. Running the script with no arguments and no `DRY_RUN`
  reconciles under the lock.

- [ ] **Step 1: Add the apply path and the lock**

In `renumber.sh`, add after `strip_all`:

```bash
# --- applying -------------------------------------------------------------

apply_actions() {
  local actions=$1 kind target value
  [[ -z $actions ]] && return 0
  while IFS=$'\t' read -r kind target value; do
    case $kind in
      rename)
        "$HERDR" tab rename "$target" "$value" >/dev/null
        ;;
      token)
        "$HERDR" workspace report-metadata "$target" \
          --source "$SOURCE_ID" --token "n=$value" >/dev/null
        ;;
    esac
  done <<<"$actions"
}

reconcile() {
  apply_actions "$(plan_actions)"
}

# --- serialising runs -----------------------------------------------------

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-numbering}"
LOCK_DIR="$STATE_DIR/lock"
DIRTY_FILE="$STATE_DIR/dirty"
LOCK_STALE_SECONDS=60
MAX_PASSES=5

# mkdir, not flock: macOS ships no flock binary. `stat -f %m` is BSD stat.
take_lock() {
  mkdir -p "$STATE_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null && return 0
  local now mtime
  now=$(date +%s)
  mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || printf '%s' "$now")
  if ((now - mtime > LOCK_STALE_SECONDS)); then
    # A run was killed mid-flight. Do not let it wedge the plugin forever.
    rmdir "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null && return 0
  fi
  return 1
}
```

Then replace `main` with:

```bash
main() {
  local actions pass=0
  if [[ ${1:-} == "--strip" ]]; then
    strip_all
    return 0
  fi
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    actions=$(plan_actions)
    [[ -n $actions ]] && printf '%s\n' "$actions"
    return 0
  fi

  if ! take_lock; then
    # Losing the race must not drop this run's work: the holder read its
    # snapshot before whatever just happened. Leave a marker it will see.
    mkdir -p "$STATE_DIR"
    : >"$DIRTY_FILE"
    return 0
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

  # Cleared before reconciling, so an event arriving mid-pass sets it again.
  rm -f "$DIRTY_FILE"
  reconcile
  while [[ -f $DIRTY_FILE ]] && ((pass < MAX_PASSES)); do
    rm -f "$DIRTY_FILE"
    reconcile
    pass=$((pass + 1))
  done
}
```

- [ ] **Step 2: Verify a contending run records rather than drops**

```bash
cd herdr/.config/herdr/plugins/numbering
rm -rf /tmp/numbering-state && mkdir -p /tmp/numbering-state/lock
HERDR_PLUGIN_STATE_DIR=/tmp/numbering-state ./renumber.sh
ls /tmp/numbering-state
```

Expected: the run exits 0 immediately, and `ls` shows both `lock` and `dirty`
— the contending run recorded work instead of dropping it. Confirm it wrote
nothing: `herdr tab list | jq -r '.result.tabs[].label'` is unchanged.

- [ ] **Step 3: Verify a stale lock is broken**

```bash
rm -rf /tmp/numbering-state && mkdir -p /tmp/numbering-state/lock
touch -t 202001010000 /tmp/numbering-state/lock
HERDR_PLUGIN_STATE_DIR=/tmp/numbering-state ./renumber.sh && echo "ran"
herdr tab list | jq -r '.result.tabs[].label'
```

Expected: `ran`, and the labels are now stamped (`1:dotfiles`, `2:nvim`, …) —
a lock older than 60 seconds does not wedge the plugin. The live session is
now stamped; Task 3's undo is available if anything looks wrong.

- [ ] **Step 4: Verify convergence**

```bash
./renumber.sh
DRY_RUN=1 ./renumber.sh | grep -c '^rename' || true
```

Expected: `0` — a second run finds nothing to rename. Anything other than `0`
means the loop guard is broken: stop, and fix it before the hooks are ever
wired, because a broken guard makes `tab.renamed` self-trigger forever.

- [ ] **Step 5: Restore the session and commit**

```bash
./renumber.sh --strip
herdr tab list | jq -r '.result.tabs[].label'
rm -rf /tmp/numbering-state
cd - >/dev/null
git add herdr/.config/herdr/plugins/numbering/renumber.sh
git commit -m "$(cat <<'MSG'
Apply herdr numbering under a coalescing lock

Hooks spawn with no debounce, so overlapping runs are normal. A run
that loses the lock sets a dirty marker instead of exiting empty-handed,
and the holder re-checks it before releasing - otherwise the holder's
older snapshot would win and leave stale numbers on screen.

mkdir rather than flock: macOS ships no flock binary.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: The manifest, tested in an isolated server

Wires the script to herdr's events, and exercises those events without arming
the live session.

**Files:**
- Create: `herdr/.config/herdr/plugins/numbering/herdr-plugin.toml`

**Interfaces:**
- Consumes: `renumber.sh`.
- Produces: a linkable plugin with id `dotfiles.numbering`.

- [ ] **Step 1: Write the manifest**

Create `herdr/.config/herdr/plugins/numbering/herdr-plugin.toml`:

```toml
# herdr numbering plugin. Every hook runs the same script, because a run is a
# full reconciliation rather than a reaction to a payload - so no hook needs
# to know which event woke it, and a missed event self-heals on the next one.
#
# Commands are argv arrays run without a shell, and their working directory is
# this plugin directory, so "renumber.sh" resolves without a path.
id = "dotfiles.numbering"
name = "Numbering"
version = "0.1.0"
min_herdr_version = "0.9.1"
description = "Keep tab numbers in tab names and space numbers in the sidebar"
platforms = ["macos"]

# Metadata tokens are runtime-only - WorkspaceSnapshot has no tokens field -
# so without this the sidebar numbers come back blank after a server restart.
# Tab names persist on their own, being custom names.
[[startup]]
command = ["bash", "renumber.sh"]

# Tabs: the four events that change a tab's position or name.
[[events]]
on = "tab.created"
command = ["bash", "renumber.sh"]

[[events]]
on = "tab.closed"
command = ["bash", "renumber.sh"]

[[events]]
on = "tab.moved"
command = ["bash", "renumber.sh"]

# Fires even when a rename changed nothing (src/app/api/tabs.rs:158-168), so
# this hook re-triggers itself unless the script skips correct labels. It does.
[[events]]
on = "tab.renamed"
command = ["bash", "renumber.sh"]

# Spaces: the events that change workspace order.
[[events]]
on = "workspace.created"
command = ["bash", "renumber.sh"]

[[events]]
on = "workspace.closed"
command = ["bash", "renumber.sh"]

[[events]]
on = "workspace.moved"
command = ["bash", "renumber.sh"]

[[events]]
on = "workspace.reordered"
command = ["bash", "renumber.sh"]

[[events]]
on = "worktree.opened"
command = ["bash", "renumber.sh"]

[[events]]
on = "worktree.removed"
command = ["bash", "renumber.sh"]
```

- [ ] **Step 2: Link it into a scratch config dir**

Linking into the normal config dir would arm the running server immediately,
because the plugin registry lives in the config dir
(`src/persist/plugin_registry.rs:11`) and is shared across sessions. So use a
scratch one:

```bash
export SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/herdr"
cp herdr/.config/herdr/config.toml "$SCRATCH/herdr/config.toml"
XDG_CONFIG_HOME="$SCRATCH" herdr plugin link "$PWD/herdr/.config/herdr/plugins/numbering"
XDG_CONFIG_HOME="$SCRATCH" herdr plugin list
```

Expected: the plugin lists as `dotfiles.numbering`, enabled, with no warning
about unknown event names. An `unknown event` warning means a hook name is
wrong — fix it before continuing.

- [ ] **Step 3: Hand to the user — exercise the hooks in the scratch server**

This needs a human at an interactive TUI. Ask the user to run, in a terminal
that is not inside the live herdr session:

```bash
XDG_CONFIG_HOME="$SCRATCH" herdr
```

That starts a second herdr server with its own session state and its own
plugin registry; the live session is untouched. In it, ask them to confirm:

- creating a tab (`prefix+c`) renumbers the bar within a second;
- closing a middle tab (`prefix+&`) closes the gap in the numbering;
- renaming `2:nvim` to `notes` (`prefix+,`) comes back as `2:notes`;
- quitting and restarting that server leaves the numbers correct, which is the
  `[[startup]]` hook doing its job.

If nothing happens, the diagnosis is here:

```bash
XDG_CONFIG_HOME="$SCRATCH" herdr plugin log list | tail -20
```

which shows each hook run with its exit code and stderr.

- [ ] **Step 4: Tear down the scratch server and commit**

```bash
XDG_CONFIG_HOME="$SCRATCH" herdr server stop || true
rm -rf "$SCRATCH"
git add herdr/.config/herdr/plugins/numbering/herdr-plugin.toml
git commit -m "$(cat <<'MSG'
Add the herdr numbering plugin manifest

Ten event hooks and a startup hook, all running the same reconciler.
The startup hook exists because metadata tokens are runtime-only, so
sidebar numbers would come back blank after a server restart.

Exercised in a scratch XDG_CONFIG_HOME rather than the live session:
the plugin registry lives in the config dir and is shared across
sessions, so linking into the normal one arms the running server.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: Config changes

Makes the space numbers visible and reachable. Until this task the `$n` token
is reported into a sidebar that does not draw it.

**Files:**
- Modify: `herdr/.config/herdr/config.toml`

**Interfaces:**
- Consumes: the `n` token reported by `renumber.sh`.
- Produces: a sidebar row containing `$n`, and `prefix+shift+1..9` bound to
  `switch_workspace`.

- [ ] **Step 1: Add the sidebar row and the binding**

In `herdr/.config/herdr/config.toml`, add directly after the
`agent_panel_sort = "priority"` block:

```toml
# Space numbers in the expanded sidebar. herdr draws no number there - the
# collapsed rail does (src/client/shell/sidebar.rs:62-77), while the expanded
# rows take only state_icon, state_text, workspace, branch, git_status and
# $custom tokens (src/config/sidebar.rs:380-390). So the numbering plugin
# reports the position as an $n token and this row draws it. The second row is
# herdr's default, repeated because setting `rows` replaces the whole layout.
# Renders as "● 1 · dotfiles": the " · " is herdr's fixed token separator, not
# a choice made here. Before the plugin reports anything the token and its
# separator simply disappear, so this is safe to have set on its own.
[ui.sidebar.spaces]
rows = [["state_icon", "$n", "workspace"], ["branch", "git_status"]]
```

And in the `[keys]` section, directly after the `workspace_picker` /
`settings` pair:

```toml
# Jump to space 1-9, matching the numbers the numbering plugin puts in the
# sidebar. Unset in herdr by default, and a deliberate deviation from tmux,
# which has no jump-to-session-by-number binding - without it the space
# numbers would be decoration nothing acts on.
switch_workspace = "prefix+shift+1..9"
```

- [ ] **Step 2: Validate and reload**

```bash
herdr config check && herdr server reload-config
```

Expected: `config: ok`, then a reload result with `"status":"applied"` and an
empty `diagnostics` array.

- [ ] **Step 3: Hand to the user — eyes on the sidebar**

This is the one claim no command can settle, and the spec deliberately records
it as unverified. Run the reconciler, then ask the user to look:

```bash
herdr/.config/herdr/plugins/numbering/renumber.sh
```

Ask them to confirm:

- each space row now reads `● 1 · dotfiles`, `● 2 · Code`, `● 3 · wiki`;
- `prefix+shift+2` jumps to the space numbered 2;
- the numbers survive collapsing the sidebar (`prefix+b`) and expanding it.

Then restore, since nothing is armed until Task 7:

```bash
herdr/.config/herdr/plugins/numbering/renumber.sh --strip
```

- [ ] **Step 4: Commit**

```bash
git add herdr/.config/herdr/config.toml
git commit -m "$(cat <<'MSG'
Draw space numbers in the sidebar and bind switch_workspace

The expanded sidebar takes only a fixed token set plus $custom tokens,
so the numbering plugin reports the position as $n and this row draws
it. Binding prefix+shift+1..9 is what makes those numbers actionable -
a deliberate deviation from tmux, which has no equivalent.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 7: Bootstrap wiring and spec status

Arms the plugin on this machine and on any future one.

**Files:**
- Modify: `bootstrap.sh` (step 9, beside the `herdr integration install` lines)
- Modify: `docs/superpowers/specs/2026-09-21-herdr-numbering-plugin-design.md`

**Interfaces:**
- Consumes: the linked plugin directory at `~/.config/herdr/plugins/numbering`.
- Produces: nothing later depends on.

- [ ] **Step 1: Add the link step to bootstrap**

In `bootstrap.sh`, directly after the two `herdr integration install` lines,
add:

```sh
# 10. the numbering plugin keeps each tab's number in its name and reports
#     each space's number to the sidebar. Like the integrations above, stow
#     alone does not arm it: herdr's plugin registry lives at
#     ~/.config/herdr/plugins.json, which is machine-local and gitignored
#     alongside the sockets and session.json, so a fresh machine has to be
#     told about the plugin explicitly. The plugin's files themselves DO
#     arrive by stow, under herdr/.config/herdr/plugins/numbering. Linking is
#     idempotent, so this doubles as the update path, like the restow above.
herdr plugin link "$HOME/.config/herdr/plugins/numbering"
```

- [ ] **Step 2: Run bootstrap and confirm the plugin is live**

```bash
bash bootstrap.sh 2>&1 | tail -8
herdr plugin list
```

Expected: the stow step reports the new `plugins` path, and the plugin lists
as `dotfiles.numbering`, enabled.

- [ ] **Step 3: Hand to the user — exercise the hooks on the live session**

Everything is armed now. Ask the user to confirm, by keypress, in their real
session:

- `prefix+c` — a new tab appears numbered, and its neighbours stay correct;
- `prefix+&` on a middle tab — the numbering closes the gap;
- `prefix+,` renaming `2:nvim` to `notes` — it returns as `2:notes`;
- the sidebar shows `● 1 · dotfiles` and `prefix+shift+2` jumps to space 2.

If any of that is silent, `herdr plugin log list | tail -20` shows each hook
run with its exit code and stderr.

- [ ] **Step 4: Record what was actually verified in the spec**

Replace the `**Status:**` paragraph of
`docs/superpowers/specs/2026-09-21-herdr-numbering-plugin-design.md` with what
the run actually established, following the keybindings spec's convention —
the distinction between "confirmed by keypress", "verified at the CLI level",
and "implemented but not individually exercised" is the part worth recording.
Use this shape, filled in with what really happened:

```markdown
**Status:** implemented YYYY-MM-DD — plugin, config, and bootstrap wiring are
committed.

CONFIRMED by the user pressing keys: <the operations they actually tried>.

Verified at the CLI level, without keypresses: <dry run, convergence, lock
contention, stale-lock recovery, strip>.

Implemented but NOT individually exercised: <hooks nothing happened to fire,
e.g. worktree.opened / workspace.reordered if no worktree or reorder occurred>.
```

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh docs/superpowers/specs/2026-09-21-herdr-numbering-plugin-design.md
git commit -m "$(cat <<'MSG'
Link the numbering plugin from bootstrap; record what was verified

herdr's plugin registry is machine-local, so stow alone does not arm
the plugin - a fresh machine has to be told about it, the same reason
the agent integrations have their own bootstrap step.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```
