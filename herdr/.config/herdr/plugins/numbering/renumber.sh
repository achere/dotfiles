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

# Sourced by renumber_test.sh, which wants the functions and nothing else.
if [[ ${RENUMBER_LIB_ONLY:-0} == 1 ]]; then
  return 0
fi

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
  local tabs_json=$1
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
  done < <(jq -r '.result.tabs[] | [.workspace_id, .tab_id, .label] | @tsv' <<<"$tabs_json")
}

# Space numbers. The array index is the server's workspace order, which is what
# the sidebar draws. Reported every run rather than diffed: metadata tokens are
# runtime-only (src/persist/snapshot.rs:50 has no tokens field), so there is no
# stored value to compare against, and reporting one cannot wake this plugin -
# workspace.metadata_updated is excluded from hook events
# (src/api/schema/events.rs:351-357).
plan_space_tokens() {
  local workspaces_json=$1
  jq -r '.result.workspaces | to_entries[] | ["token", .value.workspace_id, (.key + 1)] | @tsv' <<<"$workspaces_json"
}

# Fetches both payloads up front and validates each before any position is
# counted. `set -e` does not propagate out of a process substitution feeding
# a while loop, so a truncated-but-valid list would otherwise go unnoticed
# and positions would be computed from a partial tab set - not an empty plan
# (safe), but a WRONG one written to the user's real tabs. Fail closed:
# return 1 rather than plan from an incomplete or malformed payload.
plan_actions() {
  local tabs_json workspaces_json
  tabs_json=$("$HERDR" tab list) || return 1
  jq -e '.result.tabs | type == "array"' <<<"$tabs_json" >/dev/null || return 1
  workspaces_json=$("$HERDR" workspace list) || return 1
  jq -e '.result.workspaces | type == "array"' <<<"$workspaces_json" >/dev/null || return 1
  # Tokens first, renames second: a failing `herdr tab rename` trips `set -e`
  # partway through apply_actions. Metadata tokens are runtime-only and
  # restored only by the startup hook, so a rename failure during a startup
  # reconcile would otherwise leave the sidebar numbers blank until some
  # unrelated event fired - emitting the tokens first means they are already
  # applied by the time a rename can abort the run.
  plan_space_tokens "$workspaces_json"
  plan_tab_renames "$tabs_json"
}

# The undo. Restores any name this plugin did not already corrupt: a name that
# was eaten on the way in (12:30 standup -> 1:30 standup) strips to
# "30 standup" and is unrecoverable, and a tab renamed once is custom-named
# for good - there is no API to un-name one.
#
# A label whose stripped form starts with "-" (a tab named "1:-foo") was
# suspected of tripping `herdr tab rename`'s flag parsing and aborting this
# loop mid-list under `set -e`. Verified against a live herdr 0.9.1 server
# (isolated, not the user's): `herdr tab rename <id> -foo` renames cleanly,
# exit 0 - LABEL... is a variadic positional and the CLI accepts a leading
# "-" in it. No guard is needed, and none is applied: prepending `--` was
# tried too and is actively wrong here, since this LABEL arg treats `--` as
# a literal token rather than an end-of-flags marker ("1:-foo" would strip to
# "-- -foo", not "-foo"). If a future herdr version tightens this parsing,
# `renumber_test.sh`'s dash-leading case plus this comment are the trail back
# to why.
plan_strip() {
  local tab_id label stripped workspace_id
  while IFS=$'\t' read -r tab_id label; do
    stripped=$(safe_stripped_label "$label")
    [[ $stripped == "$label" ]] && continue
    printf 'rename\t%s\t%s\n' "$tab_id" "$stripped"
  done < <("$HERDR" tab list | jq -r '.result.tabs[] | [.tab_id, .label] | @tsv')

  while read -r workspace_id; do
    printf 'clear\t%s\n' "$workspace_id"
  done < <("$HERDR" workspace list | jq -r '.result.workspaces[].workspace_id')
}

strip_all() {
  apply_actions "$(plan_strip)"
}

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
      clear)
        "$HERDR" workspace report-metadata "$target" \
          --source "$SOURCE_ID" --clear-token n >/dev/null
        ;;
    esac
  done <<<"$actions"
}

reconcile() {
  local actions
  # A failed plan is not a reason to apply a partial one - do nothing instead.
  actions=$(plan_actions) || return 0
  apply_actions "$actions"
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
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" >"$LOCK_DIR/pid"
    return 0
  fi
  local now mtime
  now=$(date +%s)
  mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || printf '%s' "$now")
  if ((now - mtime > LOCK_STALE_SECONDS)); then
    # A run was killed mid-flight. Do not let it wedge the plugin forever.
    # Breaks regardless of whose pid is inside - staleness alone is the test.
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s' "$$" >"$LOCK_DIR/pid"
      return 0
    fi
  fi
  return 1
}

# After a stale break, two runs can believe they hold the lock. Release only
# the lock this run actually owns, or the first to finish would rmdir the
# other's lock out from under it.
release_lock() {
  local owner_pid
  owner_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [[ $owner_pid == "$$" ]]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

main() {
  local actions pass=0
  # DRY_RUN must win over every other switch, --strip included: it is the
  # no-write promise, and a mode check that runs after it (as --strip used
  # to) makes `DRY_RUN=1 renumber.sh --strip` write for real.
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    # A failed fetch prints nothing and exits 0, same as a real empty plan -
    # never a partial plan.
    if [[ ${1:-} == "--strip" ]]; then
      actions=$(plan_strip) || return 0
    else
      actions=$(plan_actions) || return 0
    fi
    [[ -n $actions ]] && printf '%s\n' "$actions"
    return 0
  fi
  if [[ ${1:-} == "--strip" ]]; then
    strip_all
    return 0
  fi

  if ! take_lock; then
    # Losing the race must not drop this run's work: the holder read its
    # snapshot before whatever just happened. Leave a marker it will see.
    mkdir -p "$STATE_DIR"
    : >"$DIRTY_FILE"
    return 0
  fi
  trap release_lock EXIT

  # Cleared before reconciling, so an event arriving mid-pass sets it again.
  rm -f "$DIRTY_FILE"
  reconcile
  while [[ -f $DIRTY_FILE ]] && ((pass < MAX_PASSES)); do
    rm -f "$DIRTY_FILE"
    reconcile
    pass=$((pass + 1))
  done
}

main "$@"
