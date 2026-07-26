#!/usr/bin/env bash
# Unit test for render_secret_vars in scripts/lib.sh: the bridge from .env to
# Ansible. Secrets go to Ansible through a 0600 vars FILE, never through
# `-e key=value`, because command-line args are visible to every user on the host
# in `ps auxww`. This test pins the file's shape and, mostly, its quoting: a
# password is arbitrary user input and must survive the YAML parser intact.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

fail=0
note() { echo "  FAIL $1"; fail=1; }

# yaml_value <yaml> <key>: read a key back with a real YAML parser, so the test
# proves what Ansible will actually see rather than what the string looks like.
yaml_value() {
  ruby -ryaml -e '
    d = YAML.safe_load(STDIN.read) || {}
    print d.fetch(ARGV[0], "<<MISSING>>")
  ' "$2" <<<"$1"
}

echo "render_secret_vars:"

# A password with every character that breaks naive quoting: single quotes,
# double quotes, a backslash, a #, a $, a colon-space, and leading/trailing space.
nasty="a'b''c\"d\\e#f\$g: h "
got="$(GATEWAY_CONSOLE_PASSWORD="$nasty" WORKSTATION_CONSOLE_PASSWORD="simple123" render_secret_vars)"

[[ "$(yaml_value "$got" gateway_console_password)" == "$nasty" ]] \
  || note "a password with quotes/backslash/\$/# does not survive the YAML round-trip"
[[ "$(yaml_value "$got" workstation_console_password)" == "simple123" ]] \
  || note "plain password does not round-trip"

# Unset secrets must be OMITTED, not emitted empty: the roles treat an empty
# password as "leave the account locked", and that decision belongs to the
# group_vars default, not to a stray empty extra-var.
got_empty="$(GATEWAY_CONSOLE_PASSWORD="" WORKSTATION_CONSOLE_PASSWORD="" render_secret_vars)"
[[ "$(yaml_value "$got_empty" gateway_console_password)" == "<<MISSING>>" ]] \
  || note "an empty GATEWAY_CONSOLE_PASSWORD must not be emitted"
[[ "$(yaml_value "$got_empty" workstation_console_password)" == "<<MISSING>>" ]] \
  || note "an empty WORKSTATION_CONSOLE_PASSWORD must not be emitted"

# With nothing set at all the output must still be valid YAML (an empty mapping),
# so `-e @file` never hands ansible-playbook a malformed file.
ruby -ryaml -e 'd = YAML.safe_load(STDIN.read); exit(d.nil? || d.is_a?(Hash) ? 0 : 1)' <<<"$got_empty" \
  || note "output with no secrets set is not valid YAML"

# The rendered file must not leak a secret into a comment or a key name.
[[ "$(grep -c "simple123" <<<"$got")" == "1" ]] \
  || note "a secret appears more than once (a comment or echo is leaking it)"

# MULLVAD_WG_CONFIG is a path, not a secret, but it travels the same channel so
# there is one way in and one way out for everything .env carries.
got_cfg="$(MULLVAD_WG_CONFIG="secrets/mullvad-wg.conf" render_secret_vars)"
[[ "$(yaml_value "$got_cfg" mullvad_wg_config)" == "secrets/mullvad-wg.conf" ]] \
  || note "MULLVAD_WG_CONFIG does not round-trip"
got_nocfg="$(MULLVAD_WG_CONFIG="" render_secret_vars)"
[[ "$(yaml_value "$got_nocfg" mullvad_wg_config)" == "<<MISSING>>" ]] \
  || note "an empty MULLVAD_WG_CONFIG must not be emitted"

echo "vars_or_empty_mapping:"

# The actual regression: ansible-playbook must ACCEPT the file produced for a
# fully-empty render, not merely "is valid YAML" -- a blank/whitespace-only
# file is rejected outright even though it parses fine as empty YAML.
got_blank="$(vars_or_empty_mapping "$got_empty")"
[[ "$(printf '%s' "$got_blank" | tr -d '[:space:]')" == "{}" ]] \
  || note "a fully empty render must become an explicit empty mapping ('{}'), not blank output"

# Non-blank content must pass through untouched -- this must not turn a real
# vars document into '{}'.
got_passthrough="$(vars_or_empty_mapping "$got")"
[[ "$got_passthrough" == "$(printf '%s\n' "$got")" ]] \
  || note "non-empty content must pass through vars_or_empty_mapping unchanged"

if command -v ansible-playbook >/dev/null 2>&1; then
  tmp_pb="$(mktemp)"
  tmp_vars="$(mktemp)"
  printf '%s\n' '---' '- hosts: localhost' '  gather_facts: false' '  connection: local' '  tasks: []' > "$tmp_pb"
  vars_or_empty_mapping "$got_empty" > "$tmp_vars"
  ansible_err="$(ansible-playbook "$tmp_pb" -e "@${tmp_vars}" 2>&1)" \
    || note "ansible-playbook rejected the vars file produced for a fully-empty render: ${ansible_err}"
  rm -f "$tmp_pb" "$tmp_vars"
else
  echo "  (ansible-playbook not on PATH; skipped the real-parser check)"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "secret-vars: OK"
else
  echo "secret-vars: FAILED"
  exit 1
fi
