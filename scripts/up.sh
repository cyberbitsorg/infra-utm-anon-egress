#!/usr/bin/env bash
# Orchestrator: preflight -> fetch image -> create VMs -> wait SSH ->
# generate inventory -> Ansible. Fully hands-off.
# Flags: --provision-only (no Ansible), --configure-only (Ansible only)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wg-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/mullvad-lib.sh"
SCRIPTS="$(dirname "${BASH_SOURCE[0]}")"

require_macos
load_config
# Loaded here, not inside load_config: the unit tests call load_config and
# must never pull in the operator's real .env as a side effect.
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

  # Secrets go to Ansible through a 0600 file, never `-e key=value` (visible in
  # `ps auxww`). Content is accumulated and written ONCE via vars_or_empty_mapping,
  # because ansible-playbook rejects a blank `-e @file` outright.
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

  # The config is sanitised HERE, in bash, where the transformation is unit
  # tested (tests/wg-config.sh). The sanitised copy is staged under its own key
  # (mullvad_wg_sanitized). Resolved here as well as in preflight, because
  # `make configure` never runs preflight.
  local wg_src wg_tmp="" wg_built="" pair entry_host exit_host
  if [[ -n "${MULLVAD_EXIT:-}" ]]; then
    mullvad_load_relays "$MULLVAD_RELAY_CACHE" "$MULLVAD_CACHE_MAX_AGE_DAYS"
    pair="$(mullvad_resolve_pair "$MULLVAD_RELAY_CACHE" "${REPO_ROOT}/secrets" \
              "$MULLVAD_EXIT" "${MULLVAD_ENTRY:-}" "$MULLVAD_PIN_FILE")" \
      || die "Could not resolve an exit (reason above)."
    entry_host="${pair%% *}"; exit_host="${pair##* }"
    mullvad_assert_multihop "$MULLVAD_RELAY_CACHE" "$entry_host" "$exit_host" \
      || die "The resolved pair is not multihop (reason above)."
    wg_built="$(mktemp)"
    # Registered the moment the file exists: it is about to hold a private key.
    trap "rm -f '${vars_file}' '${wg_built}'" EXIT
    mullvad_render_to "$MULLVAD_RELAY_CACHE" "${REPO_ROOT}/secrets" \
        "$entry_host" "$exit_host" "$wg_built" \
      || die "Could not assemble the multihop config (reason above)."
    wg_src="$wg_built"
    log "Multihop: exit ${exit_host} via entry ${entry_host}"
  fi
  if [[ -n "${wg_src:-}" ]]; then
    validate_wg_config "$wg_src" || die "The WireGuard config is not usable (reason above)."
    wg_tmp="$(mktemp)"
    chmod 600 "$wg_tmp"
    # Trap updated BEFORE anything is written, so no failure path can leave a
    # file containing the private key behind.
    trap "rm -f '${vars_file}' '${wg_tmp}' '${wg_built}'" EXIT
    sanitize_wg_config "$wg_src" > "$wg_tmp"
    vars_content="${vars_content}
mullvad_wg_sanitized: '${wg_tmp}'
mullvad_endpoint_ip: '$(wg_endpoint_ip "$wg_src")'
mullvad_endpoint_port: '$(wg_endpoint_port "$wg_src")'"
    log "Sanitised WireGuard config staged (endpoint $(wg_endpoint_ip "$wg_src"):$(wg_endpoint_port "$wg_src"))"
  fi

  # Not a secret, but the 0600 vars file is the only channel to
  # ansible-playbook. Validation repeated: `make configure` skips preflight.
  local tool_groups_var
  tool_groups_var="$(render_tool_groups_var)"
  if [[ -n "$tool_groups_var" ]]; then
    vars_content="${vars_content}
${tool_groups_var}"
    log "Kali tool groups: $(parse_tool_groups | tr '\n' ' ')"
  fi

  local clipboard_var
  clipboard_var="$(render_bool_var workstation_clipboard "${WORKSTATION_CLIPBOARD:-}")"
  [[ -z "$clipboard_var" ]] || vars_content="${vars_content}
${clipboard_var}"

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

# Two passes: internal-only VMs can only be probed through the gateway, so the
# gateway must answer first.
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
  # The last ssh error is reported on timeout, so a client-side failure does
  # not read as "the guest never booted".
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
