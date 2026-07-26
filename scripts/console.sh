#!/usr/bin/env bash
# Attach to a VM's serial console. Usage: console.sh <short-name>
#
# WHY this exists: both base images run the distro's '-cloud' kernel flavour,
# which ships NO DRM drivers at all (no virtio-gpu, no framebuffer). The guest
# sees UTM's virtio-gpu-pci device but nothing ever binds to it, so UTM's display
# view correctly reports "Display output is not active" and always will. The
# guests put their kernel console and a getty on ttyAMA0 instead, and UTM exposes
# that serial device to the host as a pseudo-tty. This attaches to it.
#
# The pty path (/dev/ttysNNN) is assigned by UTM at VM start and CHANGES on every
# boot, so it is queried live rather than remembered.
#
# NOTE: with cloud-init's lock_passwd this console shows boot output and a login
# prompt you cannot get past -- it is a diagnostic channel, not a way in. Set a
# console password deliberately if you want it to be a recovery path too.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

short="${1:?Usage: make console <short-name> (e.g. gateway or workstation)}"

# Validate against the fleet so a typo names the known VMs instead of failing
# inside AppleScript.
found=0; known=""
for entry in "${LAB_VMS[@]}"; do
  parse_vm_entry "$entry"
  known+="${VM_SHORT} "
  [[ "$VM_SHORT" == "$short" ]] && found=1
done
[[ "$found" == "1" ]] || die "Unknown VM '${short}'. Known: ${known}"

name="$(vm_name "$short")"
[[ "$(vm_status "$name")" == "started" ]] \
  || die "${name} is not running (status: $(vm_status "$name" || echo 'not created')). Run 'make up' first."

# Ask UTM for the first serial port's host pty. UTM reports interface
# 'unavailable' when its own GUI holds the port (the built-in terminal), in which
# case use that window instead of fighting it for the device.
read -r iface dev <<<"$(osascript -e "tell application \"UTM\"
  set vm to virtual machine named \"${name}\"
  set sps to serial ports of vm
  if (count of sps) is 0 then return \"none -\"
  set sp to item 1 of sps
  return (interface of sp as text) & \" \" & (address of sp as text)
end tell" 2>/dev/null)"

case "${iface:-}" in
  ptty) ;;
  none) die "${name} has no serial port in UTM. Add one in UTM (Edit -> new device -> Serial) or rebuild the VM." ;;
  unavailable) die "${name}'s serial port is held by the UTM GUI. Open the VM's serial/terminal view in the UTM window instead." ;;
  "") die "Could not read ${name}'s serial port from UTM. Is UTM running and is automation permitted?" ;;
  *) die "${name}'s serial port uses the '${iface}' interface, which this script does not handle (expected ptty)." ;;
esac
[[ -e "$dev" ]] || die "UTM reports ${name}'s console at ${dev}, but that device does not exist."

log "Console for ${name} at ${dev}"
log "Press Enter for a login prompt. Detach with: Ctrl-a then k (then y)"
# screen is the only terminal emulator guaranteed present on macOS. Exec it so
# Ctrl-C and window resizes go to the console, not to this script.
exec screen "$dev" 115200
