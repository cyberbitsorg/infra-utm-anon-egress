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
# All four write to stderr, so a script's stdout carries only its data. That
# matters because callers capture that data: up.sh does
# result="$(create-vm.sh ... | tail -1)" and create-vm.sh does
# seed="$(make-seed.sh ... | tail -1)". When log/ok wrote to stdout, every
# message from those scripts was swallowed by the command substitution and
# never reached the terminal, including the reconcile telling you it was about
# to restart a VM.
_c() { printf '\033[%sm' "$1"; }
log()  { printf '%s%s%s %s\n' "$(_c '1;34')" "==>" "$(_c 0)" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$(_c '1;32')" " ok" "$(_c 0)" "$*" >&2; }
warn() { printf '%s%s%s %s\n' "$(_c '1;33')" " ! " "$(_c 0)" "$*" >&2; }
die()  { printf '%s%s%s %s\n' "$(_c '1;31')" "err" "$(_c 0)" "$*" >&2; exit 1; }

# --- Config -----------------------------------------------------------------
# Validate the lab.conf variables every script depends on. Split out from
# load_config so tests can exercise it directly against fake values, without
# needing a real lab.conf on disk.
require_lab_conf_vars() {
  : "${LAB_PREFIX:?LAB_PREFIX missing in lab.conf}"
  : "${LAB_USER:?LAB_USER missing in lab.conf}"
  : "${LAB_SSH_KEY:?LAB_SSH_KEY missing in lab.conf}"
  # parse_vm_entry falls back to these for any fleet entry that omits
  # cpu=/ram=/disk=, so every script that touches the fleet needs them, not
  # just create-vm.sh.
  : "${LAB_CPU:?LAB_CPU missing in lab.conf}"
  : "${LAB_RAM:?LAB_RAM missing in lab.conf}"
  : "${LAB_DISK_GB:?LAB_DISK_GB missing in lab.conf}"
}

load_config() {
  # LAB_CONF overrides the config path. Only the unit tests set it, so they can
  # exercise scripts that call load_config against a throwaway config instead of
  # requiring (or worse, reading) the operator's real lab.conf.
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
# Secrets live in .env, NOT in lab.conf. The split is deliberate: lab.conf is
# build configuration you might paste into an issue (fleet, image URLs, sizes),
# while .env holds only things that must never leave this machine -- console
# passwords now, VPN credentials in Phase 2. Both are gitignored; only the
# .example files are tracked.
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

# Source .env if it exists. Absent is fine: every secret is optional, and an
# unset one means "do not configure that feature" rather than a broken build.
load_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  local perms
  # Secrets must not be world- or group-readable. Warn rather than die: refusing
  # to build over a file mode would be worse than telling the operator.
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
#
# Ansible gets these through `-e @file` with the file at 0600, never through
# `-e key=value`: command-line arguments are visible to every user on the host in
# `ps auxww`, so a password passed that way is effectively public while the
# playbook runs.
#
# Values are written as single-quoted YAML scalars with every ' doubled, which is
# how YAML escapes a quote inside one. That keeps a password containing quotes,
# backslashes, '#', '$' or a leading space completely literal -- tests/secret-vars.sh
# round-trips a deliberately hostile one through a real YAML parser.
#
# An unset or empty secret is OMITTED rather than emitted empty, so the roles'
# group_vars defaults keep deciding what "no password" means.
render_secret_vars() {
  local name val esc
  for name in GATEWAY_CONSOLE_PASSWORD WORKSTATION_CONSOLE_PASSWORD; do
    eval "val=\${${name}:-}"
    [[ -n "$val" ]] || continue
    # UNQUOTED assignment on purpose: it makes \' a literal ' in both pattern and
    # replacement, doubling each quote. Wrapping this in double quotes instead
    # (esc="${val//\'/\'\'}") emits backslash-escaped quotes -- which YAML does
    # not accept inside a single-quoted scalar -- and produces a file
    # ansible-playbook rejects. tests/secret-vars.sh catches that regression.
    # shellcheck disable=SC2086
    esc=${val//\'/\'\'}
    # Lowercase the env var name to get the Ansible var name.
    printf "%s: '%s'\n" "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" "$esc"
  done
}

# Generate a password: 24 chars from [A-Za-z0-9] (~142 bits). The charset is
# restricted on purpose -- it is wide enough to be strong, and narrow enough that
# the value can never trip a shell, a YAML parser or chpasswd on its way to the
# guest.
gen_password() {
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-24
}

# Full UTM VM name for a short name (e.g. gateway -> anon-gateway).
vm_name() { echo "${LAB_PREFIX}-$1"; }

# Private key path derived from the public key in lab.conf.
priv_key() { echo "${LAB_SSH_KEY%.pub}"; }

# Absolute path to the base disk image for a role. The gateway runs Debian (a
# small, stable router); every other role runs Kali. Both live in IMAGES_DIR
# after scripts/fetch-images.sh.
role_image() {
  case "$1" in
    gateway) echo "${IMAGES_DIR}/$(basename "$DEBIAN_IMG_URL")" ;;
    *)       echo "${IMAGES_DIR}/${KALI_IMG_FILE}" ;;
  esac
}

# Host SSH forward port for a VM index. Only a dual-NIC VM ever gets one.
#
# The base is 2300, NOT the sibling lab's 2200: infra-utm-redteam-lab hands its
# index-1 VM 127.0.0.1:2201, and if both fleets are up at once QEMU cannot bind
# the same host port twice. The failure is nasty rather than loud -- whichever
# forward wins, 'make ssh gateway' can land you on the lab's Kali attacker
# instead of this gateway. Different base, no overlap, and an anonymous
# engagement box never shares a socket with a deliberately vulnerable VM.
SSH_PORT_BASE=2300
ssh_port_for() { echo "$(( SSH_PORT_BASE + ${1:?index required} ))"; }

# NIC layout per role. The gateway keeps the two-NIC layout (NAT for internet +
# the host SSH forward, plus the internal segment). Every other VM is
# internal-only: a single host-mode NIC on the isolated segment, no NAT NIC at
# all, so it has no path to the internet except through the gateway.
#
# This is the single source of truth for the repo's security property, and the
# default is deliberately the safe one: a role nobody thought about gets
# 'internal', never a NAT NIC.
nic_layout_for_role() {
  case "$1" in
    gateway) echo "dual" ;;
    *)       echo "internal" ;;
  esac
}

# Internal-segment IP for a role. The two named roles get fixed, memorable
# addresses (gateway .1 = the router everything else routes through, workstation
# .10); any additional internal-only VM falls back to 10.20.0.(10+idx). Keyed on
# role rather than index so the workstation keeps the same address whatever
# order the fleet is written in -- verify.sh and the ProxyJump both hardcode it.
internal_ip_for() {
  local role="${1:?role required}" idx="${2:?index required}"
  case "$role" in
    gateway)     echo "${GATEWAY_INTERNAL_IP:-10.20.0.1}" ;;
    workstation) echo "10.20.0.10" ;;
    *)           echo "10.20.0.$((10 + idx))" ;;
  esac
}

# --- SSH --------------------------------------------------------------------
# Host-key options every connection in this repo uses. These VMs are disposable
# by design -- 'make destroy && make up' hands the workstation a brand new host
# key -- so pinning them would break on the next rebuild, and /dev/null keeps
# that churn out of the operator's real known_hosts.
SSH_HOSTKEY_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# The ProxyCommand that reaches an internal-only VM through the gateway.
# Usage: ssh -o ProxyCommand="$(ssh_jump_proxycommand "$gw_port")" ...
#
# It MUST be a ProxyCommand with the options spelled out INSIDE it, never a bare
# '-o ProxyJump=user@host:port'. Per ssh_config(5), directives given on the
# command line apply to the destination and NOT to a jump host: a ProxyJump hop
# therefore silently falls back to StrictHostKeyChecking=ask, and anywhere there
# is no tty (BatchMode, Ansible, verify.sh, up.sh's readiness wait) it dies with
# "Host key verification failed" while the guest is up and answering fine. That
# cost a whole 420s build timeout once; tests/ssh-jump.sh pins it.
ssh_jump_proxycommand() {
  local gw_port="${1:?gateway port required}"
  echo "ssh -W %h:%p -i $(priv_key) ${SSH_HOSTKEY_OPTS[*]} -o ConnectTimeout=10 -p ${gw_port} ${LAB_USER}@127.0.0.1"
}

# Parse one LAB_VMS entry into VM_SHORT / VM_ROLE / VM_CPU / VM_RAM / VM_DISK.
#
# Entry syntax: "name:role [cpu=N] [ram=MiB] [disk=GB]"
# The resource fields are optional and order-free; each one falls back to the
# lab-wide LAB_CPU / LAB_RAM / LAB_DISK_GB. Omitting ":role" makes the role the
# same as the name.
#
# This is the ONLY place that knows the fleet syntax. Bash 3.2 has no
# associative arrays, so the result comes back as globals.
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
    # Check the key before the value, so 'mem=abc' complains about 'mem'
    # rather than about the number.
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

# Virtual size of a disk image in bytes, per qemu-img. Prints nothing if the
# size cannot be read, so callers must handle an empty result.
disk_bytes() {
  local img="${1:?image path required}" qi
  qi="$(find_qemu_img)" || return 0
  # qemu-img can fail (missing, unreadable or corrupt image) while sed and
  # head still succeed on empty input; under pipefail that failure becomes
  # the pipeline's status and would otherwise kill the caller under set -e.
  "$qi" info "$img" 2>/dev/null | sed -n 's/.*(\([0-9][0-9]*\) bytes).*/\1/p' | head -1 || true
}

# --- utmctl -----------------------------------------------------------------
# utmctl ships inside UTM.app and is usually NOT on PATH. Resolve it once so
# every script can call "$UTMCTL" and work whether or not you added it to PATH.
if command -v utmctl >/dev/null 2>&1; then
  UTMCTL="$(command -v utmctl)"
else
  UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
fi

# True if UTM already has a VM with this exact name.
vm_exists() {
  "$UTMCTL" list 2>/dev/null | grep -q " ${1}\$"
}

# Stop a VM and wait for it to really be stopped. utmctl stop asks the guest to
# shut down, which is not instant, and passes through intermediate statuses
# (e.g. "stopping") before landing on "stopped". Waits for exactly "stopped",
# not merely "not started", so a caller that immediately reconfigures the VM
# never races a UTM that is still mid-shutdown. Returns early (success) if the
# status is empty, meaning the VM does not exist, so a caller like destroy.sh
# does not burn the full timeout on a VM that is already gone. Returns 1 if it
# is still not stopped after the timeout, so callers can decide whether that
# is fatal.
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

# UTM's status for a VM ("started", "stopped", "paused", ...), or empty if the
# VM does not exist.
vm_status() {
  "$UTMCTL" status "${1:?vm name required}" 2>/dev/null || true
}

# Start a VM through utmctl, falling back to AppleScript on the odd UTM build
# where utmctl is unhappy. Both create-vm.sh paths (new VM, reconciled VM) route
# through here so the start command lives in exactly one place.
start_vm() {
  local name="${1:?vm name required}"
  "$UTMCTL" start "$name" >/dev/null 2>&1 \
    || osascript -e "tell application \"UTM\" to start virtual machine named \"${name}\"" >/dev/null 2>&1
}
