#!/usr/bin/env bash
# Orchestrator: preflight -> fetch image -> create VMs -> wait SSH ->
# generate inventory -> Ansible. Fully hands-off.
# Flags: --provision-only (no Ansible), --configure-only (Ansible only)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"

require_macos
load_config
# Secrets are loaded here rather than inside load_config on purpose: only this
# script needs them, and the unit tests call load_config with a throwaway
# lab.conf -- they must never pull in the operator's real .env as a side effect.
load_env

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

  # Secrets from .env go to Ansible through a 0600 file, never through
  # -e key=value: command-line arguments are visible to every user on the host in
  # `ps auxww`, so a password passed that way is public for the length of the run.
  # Non-secret configuration stays in group_vars and the generated inventory.
  local vars_file="" secrets
  secrets="$(render_secret_vars)"
  if [[ -n "$secrets" ]]; then
    vars_file="$(mktemp)"
    chmod 600 "$vars_file"
    # Bake the path into the trap so the file is removed even if ansible-playbook
    # fails under set -e.
    trap "rm -f '${vars_file}'" EXIT
    printf '%s\n' "$secrets" > "$vars_file"
    log "Passing $(grep -c ':' "$vars_file") secret(s) from .env via a 0600 vars file"
  fi

  log "Running Ansible playbook"
  if [[ -n "$vars_file" ]]; then
    ( cd "$REPO_ROOT" && ansible-playbook "${ANSIBLE_DIR}/playbook.yaml" -e "@${vars_file}" )
  else
    ( cd "$REPO_ROOT" && ansible-playbook "${ANSIBLE_DIR}/playbook.yaml" )
  fi
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
jump_pc="$(ssh_jump_proxycommand "$GATEWAY_PORT")"
while read -r short role name port internal_ip nic_layout; do
  [[ "$nic_layout" == "internal" ]] || continue
  deadline=$(( $(date +%s) + 420 ))
  # The last error is kept and reported on timeout. Swallowing it makes a
  # client-side failure (a bad ProxyCommand, a missing key) look exactly like a
  # guest that has not booted yet, and you burn the full timeout before finding
  # out the guest was up all along.
  while :; do
    last_err="$(ssh -o ProxyCommand="$jump_pc" "${SSH_HOSTKEY_OPTS[@]}" \
                    -o ConnectTimeout=5 -o BatchMode=yes -i "$(priv_key)" \
                    "${LAB_USER}@${internal_ip}" true 2>&1)" && break
    [[ $(date +%s) -lt $deadline ]] || die "Timed out waiting for ${name} at ${internal_ip} through the gateway. Last SSH error: ${last_err}"
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
