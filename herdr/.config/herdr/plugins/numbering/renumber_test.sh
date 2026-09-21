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
