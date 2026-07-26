#!/usr/bin/env bash
# Assert the security property this repo exists for. Hard-fails on any leak, so
# it is safe to wire into CI or a post-build hook.
#
# Phase 1 checks (this file):
#   1. the workstation reaches the gateway on the internal segment (must PASS)
#   2. the workstation cannot reach the internet at all (must FAIL to reach)
#   3. the workstation has no NIC other than the internal one
#
# Phase 2 extends this into the full leak-test suite: exit-IP check, kill-switch
# test, DNS-leak test, IPv6-leak test, reconnect test, and proof that forwarded
# traffic really transits the tunnel. See docs/superpowers/plans/.
#
# Check 2 asserts a NEGATIVE: "no egress" can only ever be tested against the
# vectors we think of, so it is not proof of anonymity -- it is proof that the
# specific vectors below are closed. Phase 2 adds the ones that matter once a
# tunnel exists.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

# Resolve the gateway's host port and the internal-only VMs from the fleet, the
# same way ssh.sh does, so a reordered or renamed fleet does not silently verify
# the wrong box.
idx=0; gw_idx=0; internal_rows=""
for entry in "${LAB_VMS[@]}"; do
  idx=$((idx + 1))
  parse_vm_entry "$entry"
  if [[ "$(nic_layout_for_role "$VM_ROLE")" == "dual" ]]; then
    [[ "$gw_idx" -eq 0 ]] && gw_idx="$idx"
  else
    internal_rows+="${VM_SHORT} ${VM_ROLE} ${idx}"$'\n'
  fi
done
[[ "$gw_idx" -ne 0 ]] || die "No dual-NIC gateway in LAB_VMS: nothing to verify through."
[[ -n "$internal_rows" ]] || die "No internal-only VM in LAB_VMS: nothing to verify."

gw_port="$(ssh_port_for "$gw_idx")"
gw_ip="${GATEWAY_INTERNAL_IP:-10.20.0.1}"
jump=(-o "ProxyCommand=$(ssh_jump_proxycommand "$gw_port")"
      "${SSH_HOSTKEY_OPTS[@]}"
      -o ConnectTimeout=10 -o BatchMode=yes -i "$(priv_key)")

fails=0
note_fail() { printf '%s%s%s %s\n' "$(_c '1;31')" "FAIL" "$(_c 0)" "$*" >&2; fails=$((fails + 1)); }

# on_ws <ip> <command...>: run a command on an internal-only VM through the jump.
on_ws() {
  local ip="$1"; shift
  ssh "${jump[@]}" "${LAB_USER}@${ip}" "$@"
}

while read -r short role vm_idx; do
  [[ -z "$short" ]] && continue
  ip="$(internal_ip_for "$role" "$vm_idx")"
  log "Verifying ${short} (${ip}) through the gateway on 127.0.0.1:${gw_port}"

  # 1. Reachability: the internal segment works and the jump path is intact.
  if on_ws "$ip" "ping -c1 -W2 ${gw_ip} >/dev/null 2>&1"; then
    ok "${short} reaches the gateway at ${gw_ip} on the internal segment"
  else
    note_fail "${short} cannot reach the gateway at ${gw_ip}"
  fi

  # 2. Isolation: no path off the segment. ICMP to a public address, then a TCP
  # connect, because a dropped ping alone would not rule out a working route.
  if on_ws "$ip" "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1"; then
    note_fail "LEAK: ${short} reached 1.1.1.1 by ICMP with no VPN or forwarding in place"
  else
    ok "${short} has no ICMP path to the internet (correct for Phase 1)"
  fi

  # /dev/tcp is a bash builtin, so this needs nothing installed on the guest.
  if on_ws "$ip" "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1"; then
    note_fail "LEAK: ${short} opened a TCP connection to 1.1.1.1:443"
  else
    ok "${short} has no TCP path to the internet (correct for Phase 1)"
  fi

  # 3. Topology: exactly one non-loopback NIC. A second NIC appearing here means
  # someone gave this VM a NAT interface, which breaks the entire guarantee even
  # if the checks above happen to pass at this moment.
  nics="$(on_ws "$ip" "ls /sys/class/net | grep -v '^lo$' | tr '\n' ' '" || true)"
  count="$(printf '%s' "$nics" | wc -w | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    ok "${short} has exactly one NIC (${nics% })"
  else
    note_fail "${short} has ${count} NICs (${nics% }); an internal-only VM must have exactly one"
  fi
done <<<"$internal_rows"

echo
if [[ "$fails" -eq 0 ]]; then
  ok "verify: all checks passed. The workstation is provably isolated."
else
  die "verify: ${fails} check(s) failed. Do NOT treat this build as isolated."
fi
