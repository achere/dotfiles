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

main "$@"
