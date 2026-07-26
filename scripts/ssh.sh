#!/usr/bin/env bash
# SSH into a VM by short name. Usage: ssh.sh <short-name>
#
# The gateway is reached directly over its host port forward. Everything else is
# internal-only -- no NAT NIC, no forward -- so it is reached by ProxyJump
# through the gateway. That is not a convenience: it is the same single path the
# inventory and verify.sh use, and there is deliberately no other way in.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

short="${1:?Usage: make ssh <short-name> (e.g. gateway or workstation)}"

# Walk the fleet once to resolve the target's role and index, and to find the
# gateway's index (its host port comes from ssh_port_for).
idx=0; found=0; known=""
target_role=""; target_idx=0; gw_idx=0
for entry in "${LAB_VMS[@]}"; do
  idx=$((idx + 1))
  parse_vm_entry "$entry"
  known+="${VM_SHORT} "
  if [[ "$(nic_layout_for_role "$VM_ROLE")" == "dual" && "$gw_idx" -eq 0 ]]; then
    gw_idx="$idx"
  fi
  if [[ "$VM_SHORT" == "$short" ]]; then
    found=1; target_role="$VM_ROLE"; target_idx="$idx"
  fi
done
[[ "$found" == "1" ]] || die "Unknown VM '${short}'. Known: ${known}"
[[ "$gw_idx" -ne 0 ]] || die "No dual-NIC gateway in LAB_VMS: nothing can be reached."

key="$(priv_key)"
gw_port="$(ssh_port_for "$gw_idx")"
common=(-i "$key" "${SSH_HOSTKEY_OPTS[@]}")

if [[ "$(nic_layout_for_role "$target_role")" == "dual" ]]; then
  port="$(ssh_port_for "$target_idx")"
  log "Connecting to ${short} (127.0.0.1:${port})"
  exec ssh "${common[@]}" -p "$port" "${LAB_USER}@127.0.0.1"
fi

internal_ip="$(internal_ip_for "$target_role" "$target_idx")"
log "Connecting to ${short} (${internal_ip}) via the gateway on 127.0.0.1:${gw_port}"
exec ssh "${common[@]}" \
  -o ProxyCommand="$(ssh_jump_proxycommand "$gw_port")" \
  "${LAB_USER}@${internal_ip}"
