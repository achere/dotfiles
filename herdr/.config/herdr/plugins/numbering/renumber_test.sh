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

# A tab labelled exactly "3:" would strip to nothing. herdr accepts an empty
# name, and a nameless tab is worse than a stamped one, so it is left alone.
check "strip refuses to empty a label"   "3:"              "$(safe_stripped_label '3:')"
check "strip returns the stripped name"  "nvim"            "$(safe_stripped_label '2:nvim')"
# A second empty-refusal case, distinct label shape from the one above -
# pins that the refusal is general, not a fluke of "3:" specifically.
check "strip refuses to empty a label 2" "10:"             "$(safe_stripped_label '10:')"
# A label that strips to something starting with "-". `herdr tab rename`
# was suspected of parsing this as a flag; verified against a live isolated
# herdr 0.9.1 server that it does not (see the comment above plan_strip in
# renumber.sh). Pinned here so a dash-leading result is a supported,
# intentional outcome, not a surprise the next time this is touched.
check "strip result may start with -"    "-foo"            "$(safe_stripped_label '1:-foo')"

if ((failures > 0)); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
