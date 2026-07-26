#!/usr/bin/env bash
# Render a cloud-init NoCloud seed ISO for one VM.
# Usage: make-seed.sh <short-name> <role> <mac-nat> <mac-lab> <lab-ip>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config
short="${1:?short name required}"
role="${2:?role required}"
mac_nat="${3:?nat mac required}"
mac_lab="${4:?lab mac required}"
lab_ip="${5:?lab ip required}"

mkdir -p "$GEN_DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

template="${CLOUDINIT_DIR}/${role}.user-data.yaml"
[[ -f "$template" ]] || template="${CLOUDINIT_DIR}/default.user-data.yaml"
[[ -f "$template" ]] || die "No cloud-init template for role '${role}' and no default"

pubkey="$(cat "$LAB_SSH_KEY")"
hostname="$(vm_name "$short")"

# user-data: substitute username, hostname and SSH public key.
sed \
  -e "s|@@LAB_USER@@|${LAB_USER}|g" \
  -e "s|@@HOSTNAME@@|${hostname}|g" \
  -e "s|@@SSH_KEY@@|${pubkey}|g" \
  "$template" > "${work}/user-data"

# meta-data: identity.
cat > "${work}/meta-data" <<EOF
instance-id: ${hostname}
local-hostname: ${hostname}
EOF

# network-config v2: NAT NIC via DHCP (internet), lab NIC static (isolated).
# Interfaces are matched by MAC so names (enp0sX) do not matter.
cat > "${work}/network-config" <<EOF
version: 2
ethernets:
  nat:
    match:
      macaddress: "${mac_nat}"
    dhcp4: true
  lab:
    match:
      macaddress: "${mac_lab}"
    dhcp4: false
    addresses:
      - ${lab_ip}/24
EOF

seed="${GEN_DIR}/${hostname}.seed.iso"
# hdiutil makehybrid refuses to overwrite an existing file, so make re-runs
# idempotent by clearing a stale seed first (also harmless for xorriso/mkisofs).
rm -f "$seed"

# Volume label MUST be "cidata" for the NoCloud datasource to be picked up.
if command -v xorriso >/dev/null 2>&1; then
  xorriso -as genisoimage -quiet -output "$seed" -volid cidata -joliet -rock \
    "${work}/user-data" "${work}/meta-data" "${work}/network-config"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -output "$seed" -volid cidata -joliet -rock \
    "${work}/user-data" "${work}/meta-data" "${work}/network-config"
else
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata \
    -o "$seed" "$work"
fi

echo "$seed"
