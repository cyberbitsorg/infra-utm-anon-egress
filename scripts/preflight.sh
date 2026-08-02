#!/usr/bin/env bash
# Verify the host can build the lab and generate an SSH key if needed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wg-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/mullvad-lib.sh"

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

# Generate what is missing, never touch what exists.
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
  # 0600 before any secret is written, so it is never briefly world-readable.
  ( umask 077; : > "$ENV_FILE" )
  chmod 600 "$ENV_FILE"
  # Copy the example verbatim, substituting a fresh password per empty
  # *_CONSOLE_PASSWORD="" line.
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

# Validate the WireGuard config early: a malformed one found here costs
# seconds, found after the ruleset is installed it costs a debugging session.
load_env

# Exactly one of the two mechanisms; a precedence rule would hide which exit
# you are actually on.
if [[ -n "${MULLVAD_WG_CONFIG:-}" && -n "${MULLVAD_EXIT:-}" ]]; then
  die "Both MULLVAD_WG_CONFIG and MULLVAD_EXIT are set in .env. They are mutually exclusive: clear one. MULLVAD_EXIT assembles a multihop config for you; MULLVAD_WG_CONFIG uses a file you assembled yourself."
fi

if [[ -n "${MULLVAD_EXIT:-}" ]]; then
  mullvad_load_relays "$MULLVAD_RELAY_CACHE" "$MULLVAD_CACHE_MAX_AGE_DAYS"
  log "Resolving exit '${MULLVAD_EXIT}'${MULLVAD_ENTRY:+ via entry '${MULLVAD_ENTRY}'}"
  pair="$(mullvad_resolve_pair "$MULLVAD_RELAY_CACHE" "${REPO_ROOT}/secrets" \
            "$MULLVAD_EXIT" "${MULLVAD_ENTRY:-}" "$MULLVAD_PIN_FILE")" \
    || die "Could not resolve an exit (reason above). Fix .env or secrets/ before 'make up'."
  entry_host="${pair%% *}"; exit_host="${pair##* }"
  # Multihop is not re-asserted here: every path out of mullvad_resolve_pair
  # already ran mullvad_assert_multihop.
  wg_derived="$(mktemp)"
  trap 'rm -f "${wg_derived:-}"' EXIT
  mullvad_render_to "$MULLVAD_RELAY_CACHE" "${REPO_ROOT}/secrets" \
      "$entry_host" "$exit_host" "$wg_derived" \
    || die "Could not assemble the multihop config (reason above)."
  validate_wg_config "$wg_derived" \
    || die "The assembled config is not usable (reason above)."
  ok "Exit ${exit_host} ($(mullvad_relay_field "$MULLVAD_RELAY_CACHE" "$exit_host" country_code)) via entry ${entry_host} ($(mullvad_relay_field "$MULLVAD_RELAY_CACHE" "$entry_host" country_code)), endpoint $(wg_endpoint_ip "$wg_derived"):$(wg_endpoint_port "$wg_derived")"
elif [[ -n "${MULLVAD_WG_CONFIG:-}" ]]; then
  wg_cfg="${MULLVAD_WG_CONFIG}"
  [[ "$wg_cfg" = /* ]] || wg_cfg="${REPO_ROOT}/${wg_cfg}"
  log "Checking WireGuard config: ${wg_cfg}"
  if validate_wg_config "$wg_cfg"; then
    ok "WireGuard config is usable (endpoint $(wg_endpoint_ip "$wg_cfg"):$(wg_endpoint_port "$wg_cfg"))"
    [[ "$(wg_endpoint_port "$wg_cfg")" != "$MULLVAD_SINGLEHOP_PORT" ]] \
      || warn "${wg_cfg} uses port ${MULLVAD_SINGLEHOP_PORT}: this is a SINGLE-hop config. Use MULLVAD_EXIT to get multihop assembled for you."
    cfg_perms="$(stat -f '%Lp' "$wg_cfg" 2>/dev/null || echo '')"
    case "$cfg_perms" in
      600|400) ;;
      *) warn "${wg_cfg} is mode ${cfg_perms}; it holds a private key. Fix with: chmod 600 ${wg_cfg}" ;;
    esac
  else
    die "The WireGuard config is not usable (reason above). Fix it before 'make up'."
  fi
else
  warn "Neither MULLVAD_EXIT nor MULLVAD_WG_CONFIG is set in .env: the gateway will have no tunnel and the workstation no egress."
fi

log "Checking Kali tool groups"
# parse_tool_groups dies on an invalid name: stop before a VM exists, not
# mid-apt over the tunnel.
tool_groups="$(parse_tool_groups)"
if [[ -n "$tool_groups" ]]; then
  ok "Tool groups: $(printf '%s' "$tool_groups" | tr '\n' ' ')"
else
  ok "No Kali tool groups selected: the workstation gets the desktop and browser only"
fi

# The vmnet host-only switch's own subnet is assigned by macOS, not by this
# repo. If a live route's gateway (typically a VPN's) falls inside it, macOS
# binds that route to UTM's bridge and the VPN silently breaks -- so refuse to
# build while that is the case. See README "Host-only subnet".
host_only="${HOST_ONLY_SUBNET:-192.168.128.0/24}"
log "Checking host-only subnet ${host_only} for route collisions"
collision=""
while read -r dest gw; do
  cidr_contains "$host_only" "$gw" && { collision="route ${dest} via ${gw}"; break; }
done < <(netstat -rn -f inet 2>/dev/null \
           | awk 'NR>1 && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1, $2}')
if [[ -n "$collision" ]]; then
  die "Host-only subnet ${host_only} collides: ${collision} sits inside it, so UTM's vmnet bridge would hijack that traffic. That is almost always a VPN that is currently up. Disconnect it and re-run: the bridge and the tunnel must never be up on the same range at once. (If the collision is not a VPN, the range itself is wrong -- see README 'Host-only subnet'.)"
fi

# Warn (not die) if a live vmnet bridge is up on a subnet other than the
# declared one: macOS and lab.conf disagree.
for brif in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep '^bridge'); do
  ifconfig "$brif" 2>/dev/null | grep -q 'member: vmenet' || continue
  braddr="$(ifconfig "$brif" 2>/dev/null | awk '/inet /{print $2; exit}')"
  [[ -n "$braddr" ]] || continue
  cidr_contains "$host_only" "$braddr" \
    || warn "vmnet bridge ${brif} is up on ${braddr}, outside declared ${host_only}: macOS Host_Net_Address and lab.conf disagree. See README 'Host-only subnet'."
done
ok "No existing route collides with ${host_only}"

ok "Preflight passed"
