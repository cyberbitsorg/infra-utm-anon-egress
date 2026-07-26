#!/usr/bin/env bash
# Verify the host can build the lab and generate an SSH key if needed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

ok "Preflight passed"
