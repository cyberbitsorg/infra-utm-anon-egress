#!/usr/bin/env bash
# Unit tests for parse_vm_entry in scripts/lib.sh. Run with: make test
# The parser is pure shell, so it runs without UTM, without lab.conf and
# without creating anything.
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

# Stand in for the lab-wide defaults that load_config would read from lab.conf.
LAB_CPU=2
LAB_RAM=2048
LAB_DISK_GB=20

fails=0
sec=""
# Section labels are held back and only printed when something under them
# fails, so a green run is one line per file instead of a wall of headings.
section() { sec="$1"; }
_hdr() { [[ -n "$sec" ]] && { echo "$sec"; sec=""; }; return 0; }


# check <label> <expected> <actual>
check() {
  if [[ "$2" != "$3" ]]; then
    printf '  FAIL %s: expected "%s", got "%s"\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# expect_reject <label> <entry>: the parser must refuse this entry.
# Runs in a subshell because die exits.
expect_reject() {
  if ( parse_vm_entry "$2" ) >/dev/null 2>&1; then
    printf '  FAIL %s: parser accepted "%s"\n' "$1" "$2"
    fails=$((fails + 1))
  fi
}

section "parse_vm_entry:"

parse_vm_entry "gateway:gateway"
check "bare entry keeps name"     "gateway" "$VM_SHORT"
check "bare entry keeps role"     "gateway" "$VM_ROLE"
check "bare entry inherits cpu"   "2"        "$VM_CPU"
check "bare entry inherits ram"   "2048"     "$VM_RAM"
check "bare entry inherits disk"  "20"       "$VM_DISK"

parse_vm_entry "workstation:workstation ram=4096"
check "one field overrides ram"        "4096" "$VM_RAM"
check "one field leaves cpu default"   "2"    "$VM_CPU"
check "one field leaves disk default"  "20"   "$VM_DISK"

parse_vm_entry "workstation:workstation cpu=4 ram=8192 disk=60"
check "all fields: name" "workstation" "$VM_SHORT"
check "all fields: role" "workstation" "$VM_ROLE"
check "all fields: cpu"  "4"        "$VM_CPU"
check "all fields: ram"  "8192"     "$VM_RAM"
check "all fields: disk" "60"       "$VM_DISK"

parse_vm_entry "box:role disk=60 cpu=4"
check "field order does not matter: cpu"  "4"  "$VM_CPU"
check "field order does not matter: disk" "60" "$VM_DISK"
check "unnamed field still defaults: ram" "2048" "$VM_RAM"

parse_vm_entry "solo"
check "name without a role: name" "solo" "$VM_SHORT"
check "name without a role: role" "solo" "$VM_ROLE"

parse_vm_entry "ws:workstation cpu=1"
check "name and role may differ: name" "ws"          "$VM_SHORT"
check "name and role may differ: role" "workstation" "$VM_ROLE"

parse_vm_entry "box:role:tag cpu=4"
check "head splits at the FIRST colon: name" "box"      "$VM_SHORT"
check "head splits at the FIRST colon: role" "role:tag" "$VM_ROLE"

expect_reject "unknown key"          "box:role mem=4096"
expect_reject "non-numeric value"    "box:role ram=8gb"
expect_reject "zero is not valid"    "box:role cpu=0"
expect_reject "negative value"       "box:role cpu=-2"
expect_reject "field without ="      "box:role bogus"
expect_reject "empty name"          ":role cpu=2"

section "require_lab_conf_vars:"

# A complete lab.conf, so each check below fails on exactly one missing var.
LAB_PREFIX="anon"
LAB_USER="operator"
LAB_SSH_KEY="/tmp/id_ed25519_anon.pub"
# LAB_CPU / LAB_RAM / LAB_DISK_GB are already set above, standing in for
# load_config's resource defaults.

# expect_config_reject <label> <var>: require_lab_conf_vars must die cleanly
# when <var> is unset, not fail with set -u's raw "unbound variable" (finding
# 3: parse_vm_entry hard-depends on LAB_CPU/LAB_RAM/LAB_DISK_GB, but
# load_config used to validate none of them). Runs in a subshell because die
# exits.
expect_config_reject() {
  local label="$1" var="$2" out
  if out="$( (unset "$var"; require_lab_conf_vars) 2>&1 )"; then
    printf '  FAIL %s: require_lab_conf_vars accepted a missing %s\n' "$label" "$var"
    fails=$((fails + 1))
    return
  fi
  if [[ "$out" == *"unbound variable"* ]]; then
    printf '  FAIL %s: died with "unbound variable" instead of a clean message: %s\n' "$label" "$out"
    fails=$((fails + 1))
  elif [[ "$out" != *"$var"* || "$out" != *"missing in lab.conf"* ]]; then
    printf '  FAIL %s: unexpected message: %s\n' "$label" "$out"
    fails=$((fails + 1))
  fi
}

expect_config_reject "missing LAB_CPU dies cleanly"      "LAB_CPU"
expect_config_reject "missing LAB_RAM dies cleanly"      "LAB_RAM"
expect_config_reject "missing LAB_DISK_GB dies cleanly"  "LAB_DISK_GB"

if ! ( require_lab_conf_vars ) >/dev/null 2>&1; then
  printf '  FAIL %s\n' "complete config passes: require_lab_conf_vars rejected a full set of vars"
  fails=$((fails + 1))
fi
if [[ "$fails" -eq 0 ]]; then
  echo "parse-vm-entry: OK"
else
  die "parse_vm_entry: ${fails} test(s) failed"
fi
