#!/usr/bin/env bash
# Stop and delete all lab VMs and remove generated artifacts.
# Prompts once before deleting. Base images in images/ are kept.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

echo "This will DELETE these UTM VMs and all their data:"
for entry in "${LAB_VMS[@]}"; do parse_vm_entry "$entry"; echo "  - $(vm_name "$VM_SHORT")"; done
read -r -p "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { warn "Aborted"; exit 1; }

for entry in "${LAB_VMS[@]}"; do
  parse_vm_entry "$entry"
  name="$(vm_name "$VM_SHORT")"
  log "Stopping and deleting ${name}"
  # A running VM cannot be deleted, so wait for it to actually stop.
  stop_vm_and_wait "$name" 30 || warn "${name} did not stop in time, trying to delete anyway"
  "$UTMCTL" delete "$name" 2>/dev/null \
    || osascript -e "tell application \"UTM\" to delete virtual machine named \"${name}\"" 2>/dev/null \
    || warn "Could not delete ${name} (already gone?)"
done

log "Removing generated artifacts"
rm -rf "$GEN_DIR"
rm -f "$INVENTORY_FILE"
ok "Lab destroyed. Base images kept in images/."
