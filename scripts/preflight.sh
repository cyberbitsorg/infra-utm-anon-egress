#!/usr/bin/env bash
# Verify the host can build the lab and generate an SSH key if needed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wg-lib.sh"

require_macos
load_config

log "Checking Apple Silicon"
[[ "$(uname -m)" == "arm64" ]] || warn "Not arm64. ARM64 cloud images will not boot on Intel."

log "Checking UTM"
[[ -d /Applications/UTM.app ]] || die "UTM not found. Install from https://mac.getutm.app/"
command -v utmctl >/dev/null 2>&1 \
  || warn "utmctl not on PATH. It ships inside UTM.app; scripts fall back to that path."

log "Checking qemu-img (disk resize)"
if QEMU_IMG="$(find_qemu_img)"; then
  ok "qemu-img: ${QEMU_IMG}"
else
  die "qemu-img not found. Install with: brew install qemu"
fi

log "Checking ISO tooling (cloud-init seed)"
if command -v xorriso >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1 \
   || command -v hdiutil >/dev/null 2>&1; then
  ok "ISO builder available"
else
  die "No ISO builder found. Install with: brew install xorriso"
fi

log "Checking Ansible"
command -v ansible-playbook >/dev/null 2>&1 \
  || die "Ansible not found. Install with: brew install ansible"

log "Checking SSH key: ${LAB_SSH_KEY}"
if [[ -f "$LAB_SSH_KEY" ]]; then
  ok "Public key present"
else
  local_priv="$(priv_key)"
  warn "Key missing, generating ${local_priv}"
  ssh-keygen -t ed25519 -N "" -C "anon-egress" -f "$local_priv"
  ok "Generated ${local_priv} and ${local_priv}.pub"
fi

# Secrets. Same treatment as the SSH key: generate what is missing rather than
# make the operator hand-roll it, and never touch what already exists.
log "Checking secrets: ${ENV_FILE}"
if [[ -f "$ENV_FILE" ]]; then
  # Only the mode is enforced here; contents are the operator's business.
  env_perms="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '')"
  case "$env_perms" in
    600|400) ok ".env present (mode ${env_perms})" ;;
    *) warn ".env is mode ${env_perms}, tightening to 600"; chmod 600 "$ENV_FILE"; ok ".env is now mode 600" ;;
  esac
else
  [[ -f "${REPO_ROOT}/.env.example" ]] || die ".env.example is missing; cannot create .env"
  warn ".env missing, generating it with fresh console passwords"
  # Create it 0600 BEFORE writing anything, so the secrets are never briefly
  # world-readable on disk.
  ( umask 077; : > "$ENV_FILE" )
  chmod 600 "$ENV_FILE"
  # Substitute a generated password into each empty *_CONSOLE_PASSWORD="" line and
  # copy the rest of the example (comments included) verbatim, so the generated
  # file still documents itself. A fresh password per line, not one reused.
  while IFS= read -r line; do
    case "$line" in
      GATEWAY_CONSOLE_PASSWORD=\"\"|WORKSTATION_CONSOLE_PASSWORD=\"\")
        printf '%s"%s"\n' "${line%\"\"}" "$(gen_password)" >> "$ENV_FILE"
        ;;
      *) printf '%s\n' "$line" >> "$ENV_FILE" ;;
    esac
  done < "${REPO_ROOT}/.env.example"
  ok "Generated ${ENV_FILE} (mode 600) with console passwords for both VMs"
  log "Read them with: grep CONSOLE_PASSWORD .env"
fi

# Validate the WireGuard config early. Finding out it is malformed here costs
# seconds; finding out after the ruleset is installed costs a debugging session
# with no egress.
load_env
if [[ -n "${MULLVAD_WG_CONFIG:-}" ]]; then
  wg_cfg="${MULLVAD_WG_CONFIG}"
  [[ "$wg_cfg" = /* ]] || wg_cfg="${REPO_ROOT}/${wg_cfg}"
  log "Checking WireGuard config: ${wg_cfg}"
  if validate_wg_config "$wg_cfg"; then
    ok "WireGuard config is usable (endpoint $(wg_endpoint_ip "$wg_cfg"):$(wg_endpoint_port "$wg_cfg"))"
    cfg_perms="$(stat -f '%Lp' "$wg_cfg" 2>/dev/null || echo '')"
    case "$cfg_perms" in
      600|400) ;;
      *) warn "${wg_cfg} is mode ${cfg_perms}; it holds a private key. Fix with: chmod 600 ${wg_cfg}" ;;
    esac
  else
    die "The WireGuard config is not usable (reason above). Fix it before 'make up'."
  fi
else
  warn "MULLVAD_WG_CONFIG is not set in .env: the gateway will have no tunnel and the workstation no egress."
fi

ok "Preflight passed"
