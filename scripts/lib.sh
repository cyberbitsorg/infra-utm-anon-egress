#!/usr/bin/env bash
# Shared helpers, sourced by every script. Not meant to be run directly.

set -euo pipefail

# --- Paths ------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/images"
GEN_DIR="${REPO_ROOT}/generated"
CLOUDINIT_DIR="${REPO_ROOT}/cloud-init"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_FILE="${ANSIBLE_DIR}/inventory/hosts.generated.yaml"

# --- Logging ----------------------------------------------------------------
# All four write to stderr so stdout carries only data; callers capture it
# with $(...).
_c() { printf '\033[%sm' "$1"; }
log()  { printf '%s%s%s %s\n' "$(_c '1;34')" "==>" "$(_c 0)" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$(_c '1;32')" " ok" "$(_c 0)" "$*" >&2; }
warn() { printf '%s%s%s %s\n' "$(_c '1;33')" " ! " "$(_c 0)" "$*" >&2; }
die()  { printf '%s%s%s %s\n' "$(_c '1;31')" "err" "$(_c 0)" "$*" >&2; exit 1; }

# --- Config -----------------------------------------------------------------
# Split out of load_config so tests can validate fake values directly.
require_lab_conf_vars() {
  : "${LAB_PREFIX:?LAB_PREFIX missing in lab.conf}"
  : "${LAB_USER:?LAB_USER missing in lab.conf}"
  : "${LAB_SSH_KEY:?LAB_SSH_KEY missing in lab.conf}"
  : "${LAB_CPU:?LAB_CPU missing in lab.conf}"
  : "${LAB_RAM:?LAB_RAM missing in lab.conf}"
  : "${LAB_DISK_GB:?LAB_DISK_GB missing in lab.conf}"
}

load_config() {
  # LAB_CONF is set only by the unit tests, to point at a throwaway config.
  local cfg="${LAB_CONF:-${REPO_ROOT}/lab.conf}"
  [[ -f "$cfg" ]] || die "lab.conf not found. Run: cp lab.conf.example lab.conf"
  # shellcheck disable=SC1090
  source "$cfg"
  require_lab_conf_vars
  # Expand ~ in the key path.
  LAB_SSH_KEY="${LAB_SSH_KEY/#\~/$HOME}"
  LAB_SSH_KEY="${LAB_SSH_KEY/#\$\{HOME\}/$HOME}"
}

# --- Secrets ----------------------------------------------------------------
# Secrets live in .env (gitignored, 0600), never in lab.conf.
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

# Source .env if it exists. Absent is fine: every secret is optional.
load_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local perms
  perms="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '')"
  case "$perms" in
    600|400) ;;
    "") ;;
    *) warn "${ENV_FILE} is mode ${perms}; secrets should be 600. Fix with: chmod 600 ${ENV_FILE}" ;;
  esac
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# Emit the secrets from .env as an Ansible vars document on stdout.
# Ansible gets these via `-e @file` with the file at 0600, never `-e key=value`:
# command-line arguments are visible to every user in `ps auxww`.
# Values are single-quoted YAML with every ' doubled; an unset secret is
# OMITTED so the tracked group_vars defaults decide what "unset" means.
render_secret_vars() {
  local name val esc
  for name in GATEWAY_CONSOLE_PASSWORD WORKSTATION_CONSOLE_PASSWORD; do
    eval "val=\${${name}:-}"
    [[ -n "$val" ]] || continue
    # UNQUOTED on purpose: quoting this assignment emits backslash-escaped
    # quotes, which YAML rejects (pinned by tests/secret-vars.sh).
    # shellcheck disable=SC2086
    esc=${val//\'/\'\'}
    printf "%s: '%s'\n" "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" "$esc"
  done
}

# ansible-playbook rejects a blank `-e @file` outright, but an all-secrets-unset
# build legitimately produces one: substitute an explicit empty mapping then.
vars_or_empty_mapping() {
  local content="${1:-}"
  if [[ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]]; then
    printf '{}\n'
  else
    printf '%s\n' "$content"
  fi
}

# 24 chars from [A-Za-z0-9] (~142 bits): strong, and can never trip a shell,
# YAML parser or chpasswd on its way to the guest.
gen_password() {
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24
}

# Full UTM VM name for a short name (e.g. gateway -> anon-gateway).
vm_name() { echo "${LAB_PREFIX}-$1"; }

# Private key path derived from the public key in lab.conf.
priv_key() { echo "${LAB_SSH_KEY%.pub}"; }

# Base disk image for a role: the gateway runs Debian, everything else Kali.
role_image() {
  case "$1" in
    gateway) echo "${IMAGES_DIR}/$(basename "$DEBIAN_IMG_URL")" ;;
    *)       echo "${IMAGES_DIR}/${KALI_IMG_FILE}" ;;
  esac
}

# Host SSH forward port for a VM index; only a dual-NIC VM ever gets one.
# Base 2300 keeps clear of other UTM fleets that may bind 22xx on this host.
SSH_PORT_BASE=2300
ssh_port_for() { echo "$(( SSH_PORT_BASE + ${1:?index required} ))"; }

# NIC layout per role: the single source of truth for the security property.
# The default is the safe one -- an unknown role gets 'internal', never NAT.
nic_layout_for_role() {
  case "$1" in
    gateway) echo "dual" ;;
    *)       echo "internal" ;;
  esac
}

# Internal-segment IP per role. Keyed on role, not index, so the workstation
# keeps its address whatever order the fleet is written in.
internal_ip_for() {
  local role="${1:?role required}" idx="${2:?index required}"
  case "$role" in
    gateway)     echo "${GATEWAY_INTERNAL_IP:-10.20.0.1}" ;;
    workstation) echo "${WORKSTATION_INTERNAL_IP:-10.20.0.10}" ;;
    *)           echo "10.20.0.$((10 + idx))" ;;
  esac
}

# --- Network math -----------------------------------------------------------
# bash 3.2 safe; every octet forced base-10 (10#) so 010 is never read as octal.

# Dotted-quad -> unsigned 32-bit integer. Prints nothing and returns 1 for
# anything that is not a.b.c.d with each octet 0-255.
ip_to_int() {
  local o IFS=.
  # shellcheck disable=SC2086
  set -- ${1:-}
  [[ $# -eq 4 ]] || return 1
  for o in "$@"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$o <= 255 )) || return 1
  done
  echo "$(( (10#$1 << 24) | (10#$2 << 16) | (10#$3 << 8) | 10#$4 ))"
}

# cidr_contains <a.b.c.d/prefix> <a.b.c.d>: 0 inside, 1 outside, 2 malformed
# (callers treat 2 as "cannot tell", never as a match).
cidr_contains() {
  local cidr="${1:-}" ip="${2:-}" net prefix mask netint ipint
  net="${cidr%/*}"; prefix="${cidr#*/}"
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( prefix <= 32 )) || return 2
  netint="$(ip_to_int "$net")" || return 2
  ipint="$(ip_to_int "$ip")"   || return 2
  (( prefix == 0 )) && return 0
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (netint & mask) == (ipint & mask) ))
}

# --- Kali tool groups -------------------------------------------------------
# KALI_TOOL_GROUPS names groups WITHOUT the kali-tools- prefix; the workstation
# role prepends it. That makes the kali-linux-* umbrellas inexpressible, which
# is deliberate: they pull VPN clients onto the one host that must never hold
# one, while no kali-tools-* group does.
#
# Prints one validated, deduplicated group per line, and NOTHING AT ALL for an
# empty selection (not a blank line). Dies on an invalid name: it ends up on an
# apt command line inside the guest.
parse_tool_groups() {
  local raw="${1-${KALI_TOOL_GROUPS:-}}" g seen=" " noglob_was_on
  # Unquoted expansion is the word splitting that reads the list; noglob keeps
  # * ? [ ] from expanding to filenames before the charset guard sees them.
  # Commas separate too, because that is how the docs print the group list and
  # a comma can never be part of a valid name -- accepting it guesses nothing.
  local IFS=$' \t\n,'
  noglob_was_on=$(set -o | grep -c "^noglob.*on" || true)
  set -f
  # shellcheck disable=SC2086
  for g in $raw; do
    # Two adjacent commas yield an empty field; that is sloppy, not wrong.
    [[ -n "$g" ]] || continue
    [[ "$g" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
      || die "KALI_TOOL_GROUPS contains an invalid group name: '${g}'. Use lowercase Kali group names, digits and dashes only."
    case "$g" in
      kali-*) die "KALI_TOOL_GROUPS contains '${g}': group names are written WITHOUT the kali- prefix (write 'web', not 'kali-tools-web'). This also means kali-linux-large and its siblings cannot be selected here, which is deliberate: they pull VPN clients onto a host that must never hold one." ;;
    esac
    case "$seen" in *" ${g} "*) continue ;; esac
    seen="${seen}${g} "
    printf '%s\n' "$g"
  done
  if (( ! noglob_was_on )); then set +f; fi
}

# Render the validated selection as the Ansible variable the workstation role
# consumes. Rides the same 0600 vars file as the secrets (`-e key=value` is
# banned repo-wide); an empty selection emits nothing so the tracked
# group_vars default keeps deciding what "no groups" means.
render_tool_groups_var() {
  local groups line out=""
  groups="$(parse_tool_groups "$@")" || return 1
  [[ -n "$groups" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    out="${out}${out:+, }${line}"
  done <<<"$groups"
  printf 'workstation_tools_groups: [%s]\n' "$out"
}

# Render a lab.conf yes/no switch as an Ansible bool. Empty emits NOTHING, so
# the tracked group_vars default decides; anything unrecognised dies.
render_bool_var() {
  local name="${1:?var name required}" raw="${2-}"
  case "$(printf '%s' "$raw" | tr 'A-Z' 'a-z')" in
    "")               return 0 ;;
    yes|true|1|on)    printf '%s: true\n'  "$name" ;;
    no|false|0|off)   printf '%s: false\n' "$name" ;;
    *) die "${name}: expected yes or no in lab.conf, got '${raw}'." ;;
  esac
}

# --- SSH --------------------------------------------------------------------
# The VMs are disposable, so host keys are not pinned and known_hosts is
# /dev/null. LogLevel=ERROR suppresses the "Permanently added" warning that
# would otherwise print on every one of verify.sh's dozens of hops.
SSH_HOSTKEY_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# The ProxyCommand that reaches an internal-only VM through the gateway.
# MUST be a ProxyCommand with the options spelled out inside it, never a bare
# ProxyJump: command-line ssh options do not apply to a jump hop, so the hop
# would fall back to StrictHostKeyChecking=ask and die wherever there is no
# tty (Ansible, verify.sh, the readiness wait). Pinned by tests/ssh-jump.sh.
ssh_jump_proxycommand() {
  local gw_port="${1:?gateway port required}"
  echo "ssh -W %h:%p -i $(priv_key) ${SSH_HOSTKEY_OPTS[*]} -o ConnectTimeout=10 -p ${gw_port} ${LAB_USER}@127.0.0.1"
}

# Parse one LAB_VMS entry ("name:role [cpu=N] [ram=MiB] [disk=GB]") into
# VM_SHORT / VM_ROLE / VM_CPU / VM_RAM / VM_DISK globals (bash 3.2: no
# associative arrays). The only place that knows the fleet syntax.
parse_vm_entry() {
  local entry="${1:?entry required}"
  local spec fields field key val

  # Split off the "name:role" head at the first space; the rest are fields.
  spec="${entry%% *}"
  if [[ "$entry" == *" "* ]]; then
    fields="${entry#* }"
  else
    fields=""
  fi

  # Split the head at the FIRST colon, so a colon in a field can never be
  # mistaken for the role separator.
  VM_SHORT="${spec%%:*}"
  VM_ROLE="${spec#*:}"
  [[ -n "$VM_SHORT" ]] || die "LAB_VMS entry '${entry}' has no VM name."
  [[ -n "$VM_ROLE" ]] || die "LAB_VMS entry '${entry}' has an empty role."

  VM_CPU="$LAB_CPU"
  VM_RAM="$LAB_RAM"
  VM_DISK="$LAB_DISK_GB"

  # Deliberate word splitting: the fields are space separated.
  # shellcheck disable=SC2086
  for field in $fields; do
    [[ "$field" == *=* ]] \
      || die "LAB_VMS entry '${entry}': '${field}' is not key=value. Valid keys: cpu, ram, disk."
    key="${field%%=*}"
    val="${field#*=}"
    case "$key" in
      cpu|ram|disk) ;;
      *) die "LAB_VMS entry '${entry}': unknown field '${key}'. Valid keys: cpu, ram, disk." ;;
    esac
    [[ "$val" =~ ^[1-9][0-9]*$ ]] \
      || die "LAB_VMS entry '${entry}': ${key} must be a positive whole number, got '${val}'."
    case "$key" in
      cpu)  VM_CPU="$val" ;;
      ram)  VM_RAM="$val" ;;
      disk) VM_DISK="$val" ;;
    esac
  done
}

# --- Platform guard ---------------------------------------------------------
require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This provisions UTM VMs and must run on macOS."
}

# Locate a qemu-img binary: prefer Homebrew, fall back to the one bundled in UTM.
find_qemu_img() {
  if command -v qemu-img >/dev/null 2>&1; then
    command -v qemu-img; return 0
  fi
  local bundled
  bundled="$(ls /Applications/UTM.app/Contents/Frameworks/qemu-*/bin/qemu-img 2>/dev/null | head -1 || true)"
  [[ -n "$bundled" ]] && { echo "$bundled"; return 0; }
  return 1
}

# Virtual size of a disk image in bytes. Prints nothing if it cannot be read,
# so callers must handle an empty result.
disk_bytes() {
  local img="${1:?image path required}" qi
  qi="$(find_qemu_img)" || return 0
  # `|| true`: under pipefail a failing qemu-img would kill the caller.
  "$qi" info "$img" 2>/dev/null | sed -n 's/.*(\([0-9][0-9]*\) bytes).*/\1/p' | head -1 || true
}

# --- utmctl -----------------------------------------------------------------
# utmctl ships inside UTM.app and is usually not on PATH.
if command -v utmctl >/dev/null 2>&1; then
  UTMCTL="$(command -v utmctl)"
else
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
fi

# True if UTM already has a VM with this exact name.
vm_exists() {
  "$UTMCTL" list 2>/dev/null | grep -q " ${1}\$"
}

# Stop a VM and wait until its status is really "stopped" (utmctl stop asks the
# guest and passes through "stopping" first). Empty status = VM gone = success.
# Returns 1 on timeout so callers decide whether that is fatal.
# Usage: stop_vm_and_wait <name> [timeout_seconds, default 60]
stop_vm_and_wait() {
  local name="${1:?vm name required}" timeout="${2:-60}" waited=0 status
  "$UTMCTL" stop "$name" >/dev/null 2>&1 \
    || osascript -e "tell application \"UTM\" to stop virtual machine named \"${name}\"" >/dev/null 2>&1 \
    || true
  while [[ "$waited" -lt "$timeout" ]]; do
    status="$("$UTMCTL" status "$name" 2>/dev/null || true)"
    if [[ -z "$status" || "$status" == "stopped" ]]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# UTM's status for a VM ("started", "stopped", ...), or empty if it does not exist.
vm_status() {
  "$UTMCTL" status "${1:?vm name required}" 2>/dev/null || true
}

# Start a VM, falling back to AppleScript on UTM builds where utmctl is unhappy.
start_vm() {
  local name="${1:?vm name required}"
  "$UTMCTL" start "$name" >/dev/null 2>&1 \
    || osascript -e "tell application \"UTM\" to start virtual machine named \"${name}\"" >/dev/null 2>&1
}
