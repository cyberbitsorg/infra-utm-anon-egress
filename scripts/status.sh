#!/usr/bin/env bash
# Show the status of every lab VM.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

printf '%-28s %-10s\n' "VM" "STATUS"
printf '%-28s %-10s\n' "----------------------------" "----------"
for entry in "${LAB_VMS[@]}"; do
  parse_vm_entry "$entry"
  name="$(vm_name "$VM_SHORT")"
  status="$("$UTMCTL" status "$name" 2>/dev/null || echo "not created")"
  printf '%-28s %-10s\n' "$name" "$status"
done
