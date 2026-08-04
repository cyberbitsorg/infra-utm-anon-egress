#!/usr/bin/env bash
# Unit test for render_network_config in scripts/make-seed-lib.sh: the
# cloud-init network-config each role boots with. This is where the "no NAT NIC"
# property is actually spelled out for the guest, so it is asserted directly, and
# without needing UTM or building an ISO.
set -euo pipefail
cd "$(dirname "$0")/.."
LAB_SEGMENT="10.20.0.0/24"; GATEWAY_INTERNAL_IP="10.20.0.1"
source scripts/lib.sh
source scripts/make-seed-lib.sh

fail=0
sec=""
# Section labels are held back and only printed when something under them
# fails, so a green run is one line per file instead of a wall of headings.
section() { sec="$1"; }
_hdr() { [[ -n "$sec" ]] && { echo "$sec"; sec=""; }; return 0; }

want()    { grep -Eq "$2" <<<"$1" || { echo "  FAIL $3"; fail=1; }; }
want_no() { grep -Eq "$2" <<<"$1" && { echo "  FAIL $3"; fail=1; } || true; }

gw="$(render_network_config gateway 52:54:00:AA:00:01 52:54:00:10:20:01 10.20.0.1 dual)"
ws="$(render_network_config workstation "" 52:54:00:10:20:02 10.20.0.10 internal)"

section "gateway (dual):"
want "$gw" '52:54:00:AA:00:01'            "gateway matches the NAT NIC by MAC"
want "$gw" '10\.0\.2\.15/24'              "gateway WAN NIC is statically addressed"
want "$gw" 'via: 10\.0\.2\.2'             "gateway WAN default route is the SLIRP gateway"
want "$gw" '10\.0\.2\.3'                  "gateway has a bootstrap nameserver (dropped by nftables later)"
want "$gw" '10\.20\.0\.1/24'              "gateway has its internal segment address"
want "$gw" '52:54:00:10:20:01'            "gateway matches the internal NIC by MAC"
# No DHCP anywhere: a lease would need a DHCP allow rule in the nftables output
# chain, and the whole point of Phase 2 is that the WAN NIC emits nothing but
# WireGuard.
want_no "$gw" 'dhcp4: true'               "gateway must NOT use DHCP on the WAN NIC"

section "workstation (internal-only):"
want "$ws" '10\.20\.0\.10/24'             "workstation has its internal segment address"
want "$ws" '52:54:00:10:20:02'            "workstation matches the internal NIC by MAC"
# The default route may be written either as the modern routes: form or the
# deprecated gateway4:; what must hold is that it points at the gateway.
want "$ws" 'via: 10\.20\.0\.1|gateway4: 10\.20\.0\.1' \
                                          "workstation default route is the gateway"
want "$ws" 'nameservers'                  "workstation resolves via the gateway"
# The whole point of Phase 1: an internal-only VM must have exactly one NIC and
# no DHCP/NAT interface of any kind.
want_no "$ws" 'dhcp4: true'               "workstation must NOT have a NAT/DHCP NIC"
want_no "$ws" '52:54:00:AA'               "workstation must NOT reference a NAT MAC"
[[ "$(grep -c 'macaddress' <<<"$ws")" == "1" ]] \
  || { echo "  FAIL workstation must have exactly one NIC"; fail=1; }

if [[ "$fail" -eq 0 ]]; then
  echo "seed-network: OK"
else
  echo "seed-network: FAILED"
  exit 1
fi
