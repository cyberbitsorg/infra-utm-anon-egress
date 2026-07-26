#!/usr/bin/env bash
# Orchestrator: preflight -> fetch image -> create VMs -> wait SSH ->
# generate inventory -> Ansible. Fully hands-off.
# Flags: --provision-only (no Ansible), --configure-only (Ansible only)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"

require_macos
load_config

MODE="all"
case "${1:-}" in
  --provision-only) MODE="provision" ;;
  --configure-only) MODE="configure" ;;
  "") MODE="all" ;;
  *) die "Unknown flag: $1" ;;
esac

run_ansible() {
  log "Installing Ansible Galaxy requirements"
  ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yaml" >/dev/null
  log "Running Ansible playbook"
  # No -e vars in Phase 1: everything the plays need comes from the generated
  # inventory and ansible/group_vars. Phase 2 adds the VPN provider selection;
  # any secret must go through a 0600 vars file, never -e on the command line
  # (that would put it in the host process list, ps auxww).
  ( cd "$REPO_ROOT" && ansible-playbook "${ANSIBLE_DIR}/playbook.yaml" )
  ok "Configuration complete"
}

if [[ "$MODE" == "configure" ]]; then
  [[ -f "$INVENTORY_FILE" ]] || die "No inventory. Run a full 'make up' first."
  run_ansible
  exit 0
fi

"${SCRIPTS}/preflight.sh"
"${SCRIPTS}/fetch-images.sh"

log "Provisioning ${#LAB_VMS[@]} VMs"
provisioned=""   # lines: short role name port internal_ip nic_layout
GATEWAY_PORT=""
idx=0
for entry in "${LAB_VMS[@]}"; do
  idx=$((idx + 1))
  parse_vm_entry "$entry"
  result="$("${SCRIPTS}/create-vm.sh" "$idx" "$VM_SHORT" "$VM_ROLE" \
    "$VM_CPU" "$VM_RAM" "$VM_DISK" | tail -1)"
  read -r name port internal_ip nic_layout <<<"$result"
  provisioned+="${VM_SHORT} ${VM_ROLE} ${name} ${port} ${internal_ip} ${nic_layout}"$'\n'
  # The gateway's host forward is the jump host for every internal-only VM, so
  # gen-inventory.sh, ssh.sh and the readiness wait below all need its port.
  [[ "$nic_layout" == "dual" ]] && GATEWAY_PORT="$port"
done
[[ -n "$GATEWAY_PORT" ]] \
  || die "No dual-NIC gateway in LAB_VMS. Every other VM is internal-only and unreachable without it."
export GATEWAY_PORT LAB_USER

# The gateway is waited on over its host forward. Internal-only VMs have no
# forward, so they are probed through the gateway -- which is only possible once
# the gateway itself answers, hence the two passes rather than one loop.
log "Waiting for the gateway to accept SSH"
while read -r short role name port internal_ip nic_layout; do
  [[ "$nic_layout" == "dual" ]] || continue
  "${SCRIPTS}/wait-ssh.sh" 127.0.0.1 "$port" 420
done <<<"$provisioned"

log "Waiting for internal-only VMs to accept SSH through the gateway"
while read -r short role name port internal_ip nic_layout; do
  [[ "$nic_layout" == "internal" ]] || continue
  deadline=$(( $(date +%s) + 420 ))
  until ssh -o ProxyJump="${LAB_USER}@127.0.0.1:${GATEWAY_PORT}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -o BatchMode=yes -i "$(priv_key)" \
            "${LAB_USER}@${internal_ip}" true 2>/dev/null; do
    [[ $(date +%s) -lt $deadline ]] \
      || die "Timed out waiting for ${name} at ${internal_ip} through the gateway"
    sleep 5
  done
  ok "SSH is up on ${name} (${internal_ip}, via the gateway)"
done <<<"$provisioned"

printf '%s' "$provisioned" | "${SCRIPTS}/gen-inventory.sh"

if [[ "$MODE" == "provision" ]]; then
  ok "Provisioning done. Run 'make configure' to apply Ansible."
  exit 0
fi

run_ansible

echo
ok "Both VMs are up. Try: make ssh gateway, or make ssh workstation (via the gateway)"
log "Internal segment: gateway ${GATEWAY_INTERNAL_IP:-10.20.0.1}, workstation 10.20.0.10"
log "Now run 'make verify' to assert the workstation has no path to the internet."
