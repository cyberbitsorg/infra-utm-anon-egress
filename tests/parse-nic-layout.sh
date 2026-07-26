#!/usr/bin/env bash
# Unit test for nic_layout_for_role and internal_ip_for in scripts/lib.sh.
# These two helpers decide the whole security property of this repo -- who gets a
# NAT NIC and who does not -- so they are tested in isolation, without UTM and
# without a real lab.conf.
set -euo pipefail
cd "$(dirname "$0")/.."
# Stand in for the lab.conf vars the helpers read.
LAB_SEGMENT="10.20.0.0/24"; GATEWAY_INTERNAL_IP="10.20.0.1"
source scripts/lib.sh

fail=0
check() { [[ "$1" == "$2" ]] || { echo "  FAIL $3 (got '$1', want '$2')"; fail=1; }; }

echo "nic_layout_for_role / internal_ip_for:"

check "$(nic_layout_for_role gateway)"     "dual"       "gateway is dual-NIC"
check "$(nic_layout_for_role workstation)" "internal"   "workstation is internal-only"
# Anything not explicitly the gateway must default to internal-only: a new role
# added later must never silently get a NAT NIC.
check "$(nic_layout_for_role something-new)" "internal" "unknown role defaults to internal-only"

check "$(internal_ip_for gateway 1)"        "10.20.0.1"  "gateway internal IP is .1"
check "$(internal_ip_for workstation 2)"    "10.20.0.10" "workstation internal IP is fixed .10"
check "$(internal_ip_for workstation 7)"    "10.20.0.10" "workstation IP does not depend on index"
check "$(internal_ip_for extra 3)"          "10.20.0.13" "extra internal VM falls back to 10.20.0.(10+idx)"

# GATEWAY_INTERNAL_IP from lab.conf wins for the gateway.
check "$(GATEWAY_INTERNAL_IP=10.20.0.254 internal_ip_for gateway 1)" "10.20.0.254" \
  "gateway IP honours GATEWAY_INTERNAL_IP"

echo "role_image:"
IMAGES_DIR="/img"
DEBIAN_IMG_URL="https://example.invalid/debian-12-genericcloud-arm64.qcow2"
KALI_IMG_FILE="kali-genericcloud-arm64.raw"
check "$(role_image gateway)"     "/img/debian-12-genericcloud-arm64.qcow2" "gateway runs Debian"
check "$(role_image workstation)" "/img/kali-genericcloud-arm64.raw"       "workstation runs Kali"

if [[ "$fail" -eq 0 ]]; then
  echo "parse-nic-layout: OK"
else
  echo "parse-nic-layout: FAILED"
  exit 1
fi
