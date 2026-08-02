#!/usr/bin/env bash
# Unit test for render_bool_var in scripts/lib.sh: the bridge from a yes/no
# switch in lab.conf to an Ansible bool in the 0600 vars file.
#
# Mutation: drop the `*)` die branch and the four rejection cases below fail;
# make the empty case emit `false` and the "unset defers to group_vars" case
# fails, which is what keeps lab.conf from overriding a default it never set.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

fail=0
check() { [[ "$1" == "$2" ]] || { echo "  FAIL $3 (got '$1', want '$2')"; fail=1; }; }
checkfails() { if ( "$@" ) >/dev/null 2>&1; then echo "  FAIL $* should have been rejected"; fail=1; fi; }

echo "render_bool_var:"
check "$(render_bool_var workstation_clipboard yes)"  "workstation_clipboard: true"  "yes -> true"
check "$(render_bool_var workstation_clipboard no)"   "workstation_clipboard: false" "no -> false"
check "$(render_bool_var workstation_clipboard TRUE)" "workstation_clipboard: true"  "case-insensitive"
check "$(render_bool_var workstation_clipboard On)"   "workstation_clipboard: true"  "on -> true"
check "$(render_bool_var workstation_clipboard 1)"    "workstation_clipboard: true"  "1 -> true"
check "$(render_bool_var workstation_clipboard 0)"    "workstation_clipboard: false" "0 -> false"

# Unset must emit NOTHING, not a blank line and not false: the tracked
# group_vars default is what decides when lab.conf is silent.
check "$(render_bool_var workstation_clipboard '')"   "" "unset defers to group_vars"
check "$(render_bool_var workstation_clipboard)"      "" "missing argument defers too"

# A typo must stop the build rather than be read as "no": silently disabling a
# feature the operator asked for is the same class of bug as silently enabling one.
checkfails render_bool_var workstation_clipboard maybe
checkfails render_bool_var workstation_clipboard y
checkfails render_bool_var workstation_clipboard "true "
checkfails render_bool_var workstation_clipboard 2

[[ "$fail" == 0 ]] && echo "  bool-var OK" || { echo "  bool-var FAILED"; exit 1; }
