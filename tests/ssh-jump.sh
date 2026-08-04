#!/usr/bin/env bash
# Regression test for the jump into an internal-only VM.
#
# Guards a failure that cost a full 'make up': the readiness wait used
# `-o ProxyJump=...` with `-o StrictHostKeyChecking=no -o
# UserKnownHostsFile=/dev/null` on the command line. Per ssh_config(5) those
# directives apply to the DESTINATION and not to a jump host, so the hop fell
# back to StrictHostKeyChecking=ask; with no tty (BatchMode, Ansible, verify.sh)
# it died with "Host key verification failed" while the guest was in fact up and
# answering. The host-key options must therefore live INSIDE the ProxyCommand.
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
export LAB_CONF="${tmpdir}/lab.conf"
source scripts/lib.sh
load_config

fail=0
sec=""
# Section labels are held back and only printed when something under them
# fails, so a green run is one line per file instead of a wall of headings.
section() { sec="$1"; }
_hdr() { [[ -n "$sec" ]] && { echo "$sec"; sec=""; }; return 0; }

want() { grep -Eq -- "$2" <<<"$1" || { echo "  FAIL $3"; fail=1; }; }

section "ssh_jump_proxycommand:"
pc="$(ssh_jump_proxycommand 2301)"
want "$pc" '^ssh -W %h:%p'                     "is a -W stdio forward"
want "$pc" '-p 2301'                           "targets the gateway's host port"
want "$pc" 'anon@127\.0\.0\.1'                 "hops via the gateway on localhost"
want "$pc" "${tmpdir}/id_ed25519_anon"         "uses the private key, not the .pub"
# The two that actually caused the outage: the hop must not consult -- or
# pollute -- the operator's known_hosts, because these VMs are disposable and
# get a new host key on every rebuild.
want "$pc" 'StrictHostKeyChecking=no'          "hop does not fall back to ask (the outage)"
want "$pc" 'UserKnownHostsFile=/dev/null'      "hop ignores the operator's known_hosts"

section "gen-inventory uses the same definition:"
# Any second, hand-rolled copy of the ProxyCommand can drift back into the bug,
# so the generated inventory must contain this exact string.
inv="${tmpdir}/hosts.yaml"
INVENTORY_FILE_OVERRIDE="$inv" GATEWAY_PORT=2301 \
  scripts/gen-inventory.sh >/dev/null 2>&1 <<'ROWS'
gateway gateway anon-gateway 2301 10.20.0.1 dual
workstation workstation anon-workstation 0 10.20.0.10 internal
ROWS
grep -Fq -- "$pc" "$inv" \
  || { echo "  FAIL inventory ProxyCommand differs from ssh_jump_proxycommand"; fail=1; }

if [[ "$fail" -eq 0 ]]; then
  echo "ssh-jump: OK"
else
  echo "ssh-jump: FAILED"
  exit 1
fi
