#!/usr/bin/env bash
# Unit test for scripts/gen-inventory.sh: the gateway is reached over its host
# port forward, the workstation only by hopping through the gateway. Runs against
# a throwaway lab.conf (LAB_CONF) and a temp inventory path, so it needs neither
# UTM nor the operator's real config.
set -euo pipefail
cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "${tmpdir}/lab.conf" <<EOF
LAB_PREFIX="anon"
LAB_USER="anon"
LAB_SSH_KEY="${tmpdir}/id_ed25519_anon.pub"
LAB_CPU=2
LAB_RAM=2048
LAB_DISK_GB=20
GATEWAY_INTERNAL_IP="10.20.0.1"
LAB_VMS=("gateway:gateway" "workstation:workstation")
EOF
: > "${tmpdir}/id_ed25519_anon.pub"

inv="${tmpdir}/hosts.yaml"
export LAB_CONF="${tmpdir}/lab.conf" INVENTORY_FILE_OVERRIDE="$inv" GATEWAY_PORT=2201

printf '%s\n' \
  "gateway gateway anon-gateway 2201 10.20.0.1 dual" \
  "workstation workstation anon-workstation 0 10.20.0.10 internal" \
  | scripts/gen-inventory.sh >/dev/null 2>&1

fail=0
sec=""
# Section labels are held back and only printed when something under them
# fails, so a green run is one line per file instead of a wall of headings.
section() { sec="$1"; }
_hdr() { [[ -n "$sec" ]] && { echo "$sec"; sec=""; }; return 0; }

# -- so a pattern starting with '-' (an ssh flag) is not read as a grep option.
want()    { grep -Eq -- "$1" "$inv" || { echo "  FAIL $2"; fail=1; }; }
want_no() { grep -Eq -- "$1" "$inv" && { echo "  FAIL $2"; fail=1; } || true; }

section "gen-inventory:"
want 'ansible_port: 2201'                    "gateway is reached on its host forward port"
want 'ansible_host: 10\.20\.0\.10'           "workstation is addressed by its internal IP"
want 'ProxyCommand'                          "workstation is reached through a ProxyCommand"
want '127\.0\.0\.1'                          "ProxyCommand hops via the gateway host forward"
want '-p 2201'                               "ProxyCommand uses the gateway port"
want 'role_gateway'                          "gateway role group exists"
want 'role_workstation'                      "workstation role group exists"
want 'internal_ip: 10\.20\.0\.1$'            "gateway internal_ip host var"
want 'ansible_user: anon'                    "connects as LAB_USER"
want 'ansible_ssh_private_key_file: .*id_ed25519_anon$' "key path comes from LAB_SSH_KEY"

# The workstation must never be given a host port forward: port 0 is 'none', and
# emitting it as an ansible_port would make Ansible dial 127.0.0.1:0.
want_no 'ansible_port: 0'                    "workstation must NOT get an ansible_port"

# Valid YAML, and the two hosts really are shaped differently.
ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$inv" 2>/dev/null \
  || { echo "  FAIL inventory is not valid YAML"; fail=1; }

if [[ "$fail" -eq 0 ]]; then
  echo "gen-inventory: OK"
else
  echo "gen-inventory: FAILED"; cat "$inv"
  exit 1
fi
