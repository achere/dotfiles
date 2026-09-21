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
