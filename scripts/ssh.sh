#!/usr/bin/env bash
# SSH into a lab VM by short name. Usage: ssh.sh <short-name>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

short="${1:?Usage: make ssh <short-name> (e.g. attacker)}"

# Find the VM index to compute its host SSH port.
idx=0; found=0; known=""
for entry in "${LAB_VMS[@]}"; do
  idx=$((idx + 1))
  parse_vm_entry "$entry"
  known+="${VM_SHORT} "
  [[ "$VM_SHORT" == "$short" ]] && { found=1; break; }
done
[[ "$found" == "1" ]] || die "Unknown VM '${short}'. Known: ${known}"

port="$((2200 + idx))"
key="$(priv_key)"
log "Connecting to ${short} (127.0.0.1:${port})"
exec ssh -i "$key" -p "$port" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${LAB_USER}@127.0.0.1"
