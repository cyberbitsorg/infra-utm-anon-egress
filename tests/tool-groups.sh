#!/usr/bin/env bash
# Unit tests for parse_tool_groups and render_tool_groups_var in scripts/lib.sh:
# the bridge from KALI_TOOL_GROUPS in lab.conf to the Ansible variable the
# workstation role installs from.
#
# Two things here are load-bearing: a group name ends up on an apt command line
# inside the guest (the charset rule is what keeps that from being an injection
# path), and the kali-tools- prefix is prepended by the code, never typed,
# which is what makes the kali-linux-* umbrellas inexpressible.
#
# Mutation: weaken the charset test to `[[ -n "$g" ]]` (every injection case
# fails), delete the `kali-*` case (all four umbrella cases fail), or drop the
# `set -f` handling (the glob cases fail showing an expanded directory name --
# they only bite from the repo root, where those names exist).
set -euo pipefail
cd "$(dirname "$0")/.."
# load_config is never called here, so no lab.conf and no fake vars are needed.
source scripts/lib.sh

fail=0
check() { [[ "$1" == "$2" ]] || { echo "  FAIL $3 (got '$1', want '$2')"; fail=1; }; }
# Run a command and check it fails. The if/else keeps the non-zero return --
# which is the point of half these cases -- from tripping set -e.
checkfails() { if ( "$@" ) >/dev/null 2>&1; then echo "  FAIL $* should have been rejected"; fail=1; fi; }

echo "parse_tool_groups, accepting:"
check "$(parse_tool_groups 'web passwords')"      "web
passwords"  "two groups, one per line, in order"
check "$(parse_tool_groups '  web   passwords ')" "web
passwords"  "extra whitespace is irrelevant"
check "$(parse_tool_groups 'web web passwords web')" "web
passwords"  "duplicates collapse, first-seen order kept"
check "$(parse_tool_groups 'top10')"              "top10"      "digits are legal in a group name"
check "$(parse_tool_groups '802-11')"             "802-11"     "a group may start with a digit"
check "$(parse_tool_groups 'information-gathering')" "information-gathering" "dashes are legal"

echo "parse_tool_groups, empty:"
# NOTHING, not a blank line. A helper in this repo has already shipped that bug:
# a bare newline on zero matches made "nothing matched" indistinguishable from
# one empty result, and every `while read` consumer looped once on an empty
# value. This is that regression, pinned.
check "$(parse_tool_groups '' | wc -l | tr -d ' ')"    "0" "an empty selection prints no lines at all"
check "$(parse_tool_groups '   ' | wc -l | tr -d ' ')" "0" "a whitespace-only selection prints no lines at all"
check "$(KALI_TOOL_GROUPS='' parse_tool_groups | wc -l | tr -d ' ')" "0" "an unset KALI_TOOL_GROUPS prints no lines at all"

echo "parse_tool_groups, reading the environment:"
check "$(KALI_TOOL_GROUPS='web' parse_tool_groups)" "web" "falls back to KALI_TOOL_GROUPS with no argument"

echo "parse_tool_groups, rejecting:"
# The four umbrella metapackages are the ones measured to pull openvpn, vpnc,
# vpnc-scripts (and wireguard-tools, for -everything). They pass the charset
# rule, so the charset alone is not enough: a name that already carries a kali-
# prefix is refused outright, which also catches the likelier typo of writing
# the full package name.
checkfails parse_tool_groups 'kali-linux-large'
checkfails parse_tool_groups 'kali-linux-everything'
checkfails parse_tool_groups 'web kali-linux-headless'
checkfails parse_tool_groups 'kali-tools-web'
# Charset: anything that could change the meaning of an apt command line.
checkfails parse_tool_groups 'web; rm -rf /'
checkfails parse_tool_groups 'web&&reboot'
checkfails parse_tool_groups '$(id)'
checkfails parse_tool_groups 'web/../../etc'
checkfails parse_tool_groups 'Web'
checkfails parse_tool_groups '-web'
checkfails parse_tool_groups 'web.passwords'
checkfails parse_tool_groups 'web_passwords'
# Pathname expansion: * ? and [...] must be rejected before glob expansion happens.
# The function is called from repo root (ansible docs scripts tests exist here),
# so unquoted expansion would accept directory names. These must be caught by the
# charset guard, not silently accepted as glob tokens.
# Before the fix, * expands to ansible, docs, ... and parse_tool_groups would
# print "ansible" before dying on "ansible.cfg". That means the glob-expanded
# name was accepted. The test must reject these patterns directly, not allow them
# to partially match before failing on later expansions.
output=$(parse_tool_groups '*' 2>&1) || true
if echo "$output" | grep -q '^[a-z0-9-]'; then
  echo "  FAIL parse_tool_groups * should not accept directory names (got: $(echo "$output" | head -1))"
  fail=1
fi
output=$(parse_tool_groups '?' 2>&1) || true
if echo "$output" | grep -q '^[a-z0-9-]'; then
  echo "  FAIL parse_tool_groups ? should not accept directory names"
  fail=1
fi
output=$(parse_tool_groups '[a-z]*' 2>&1) || true
if echo "$output" | grep -q '^[a-z0-9-]'; then
  echo "  FAIL parse_tool_groups '[a-z]*' should not accept directory names"
  fail=1
fi
checkfails parse_tool_groups 'web *'

echo "render_tool_groups_var:"
check "$(render_tool_groups_var 'web passwords')" "workstation_tools_groups: [web, passwords]" "renders a flow list"
check "$(render_tool_groups_var 'web web')"       "workstation_tools_groups: [web]"            "renders the deduplicated set"
# An empty selection emits NOTHING, so the tracked group_vars default keeps
# deciding what "no groups" means. Same rule as an unset secret.
check "$(render_tool_groups_var '' | wc -c | tr -d ' ')" "0" "an empty selection emits no variable at all"
checkfails render_tool_groups_var 'kali-linux-large'

# Read it back with a real YAML parser, so the test proves what Ansible will
# actually see rather than what the string looks like.
yaml_list() {
  ruby -ryaml -e '
    d = YAML.safe_load(STDIN.read) || {}
    print (d["workstation_tools_groups"] || []).join(",")
  ' <<<"$1"
}
check "$(yaml_list "$(render_tool_groups_var 'web passwords top10')")" "web,passwords,top10" \
  "the rendered variable survives a real YAML parser as a list of three"

if [[ "$fail" == "0" ]]; then echo "  tool-groups OK"; else echo "  tool-groups FAILED"; exit 1; fi
