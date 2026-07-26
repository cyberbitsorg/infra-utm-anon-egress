#!/usr/bin/env bash
# Orchestrator: preflight -> fetch image -> create VMs -> wait SSH ->
# generate inventory -> Ansible. Fully hands-off.
# Flags: --provision-only (no Ansible), --configure-only (Ansible only)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wg-lib.sh"
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
  #
  # The file is now created unconditionally (not just when secrets is non-empty):
  # it also carries the sanitised WireGuard config path and endpoint below.
  # Content is accumulated in $vars_content and written ONCE at the bottom
  # (via vars_or_empty_mapping), rather than streamed straight to disk as each
  # piece becomes available: ansible-playbook's `-e @file` rejects a blank or
  # whitespace-only file outright ("could not be made into a dictionary"),
  # even though it is valid (if empty) YAML, and the only way to know whether
  # the file will end up truly empty is to have gathered everything first.
  local vars_file vars_content secrets
  secrets="$(render_secret_vars)"
  vars_file="$(mktemp)"
  chmod 600 "$vars_file"
  # Bake the path into the trap so the file is removed even if ansible-playbook
  # fails under set -e.
  trap "rm -f '${vars_file}'" EXIT
  vars_content="$secrets"
  [[ -n "$secrets" ]] \
    && log "Passing $(grep -c ':' <<<"$secrets") secret(s) from .env via a 0600 vars file"

  # The config is sanitised HERE, in bash, because that transformation is unit
  # tested (tests/wg-config.sh) and because Ansible should receive a file that is
  # already exactly what belongs on the gateway. The temp copy is 0600 and removed
  # by the same trap as the vars file.
  #
  # mullvad_wg_config (emitted into $vars_content above by render_secret_vars)
  # keeps meaning the operator's original .env path. The gateway role never
  # reads that path directly -- it consumes the sanitised copy below, staged
  # under a DIFFERENT key (mullvad_wg_sanitized) so the two never collide as
  # duplicate YAML keys in the same vars file.
  local wg_src wg_tmp=""
  if [[ -n "${MULLVAD_WG_CONFIG:-}" ]]; then
    wg_src="${MULLVAD_WG_CONFIG}"
    [[ "$wg_src" = /* ]] || wg_src="${REPO_ROOT}/${wg_src}"
    validate_wg_config "$wg_src" || die "The WireGuard config is not usable (reason above)."
    wg_tmp="$(mktemp)"
    chmod 600 "$wg_tmp"
    # Trap updated the moment wg_tmp exists, BEFORE anything is written into
    # it: a failure between creation and this point (a write error, a signal)
    # would otherwise exit under `set -e` with only the vars_file half of the
    # cleanup registered, leaving a file containing the private key behind.
    trap "rm -f '${vars_file}' '${wg_tmp}'" EXIT
    sanitize_wg_config "$wg_src" > "$wg_tmp"
    vars_content="${vars_content}
mullvad_wg_sanitized: '${wg_tmp}'
mullvad_endpoint_ip: '$(wg_endpoint_ip "$wg_src")'
mullvad_endpoint_port: '$(wg_endpoint_port "$wg_src")'"
    log "Sanitised WireGuard config staged (endpoint $(wg_endpoint_ip "$wg_src"):$(wg_endpoint_port "$wg_src"))"
  fi

  vars_or_empty_mapping "$vars_content" > "$vars_file"

  log "Running Ansible playbook"
  ( cd "$REPO_ROOT" && ansible-playbook "${ANSIBLE_DIR}/playbook.yaml" -e "@${vars_file}" )
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
