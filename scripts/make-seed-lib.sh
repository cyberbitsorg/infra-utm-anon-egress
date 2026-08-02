#!/usr/bin/env bash
# The cloud-init network-config renderer, split out of make-seed.sh so it can be
# unit tested (tests/seed-network.sh) without building an ISO. Sourced, not run.

# render_network_config <role> <mac_nat> <mac_internal> <internal_ip> <nic_layout>
#
# Prints a cloud-init network-config v2 document. Interfaces are matched by
# MAC, so guest interface names never matter. dual = the gateway (static WAN +
# internal); internal = one NIC with default route and DNS via the gateway.
#
# `routes:` instead of the deprecated `gateway4:`. The WAN NIC is STATIC, not
# DHCP: SLIRP's lease is deterministic (10.0.2.15/24 via 10.0.2.2) and a DHCP
# allow rule has no place in an output chain that must emit only WireGuard.
# The 10.0.2.3 nameserver is bootstrap-only; the kill-switch drops :53 off the
# WAN and the gateway role repoints resolution at unbound.
render_network_config() {
  local role="$1" mac_nat="$2" mac_internal="$3" internal_ip="$4" nic_layout="$5"
  if [[ "$nic_layout" == "dual" ]]; then
    cat <<EOF
version: 2
ethernets:
  nat:
    match:
      macaddress: "${mac_nat}"
    dhcp4: false
    dhcp6: false
    addresses:
      - 10.0.2.15/24
    routes:
      - to: default
        via: 10.0.2.2
    nameservers:
      addresses:
        - 10.0.2.3
  internal:
    match:
      macaddress: "${mac_internal}"
    dhcp4: false
    dhcp6: false
    addresses:
      - ${internal_ip}/24
EOF
  else
    cat <<EOF
version: 2
ethernets:
  internal:
    match:
      macaddress: "${mac_internal}"
    dhcp4: false
    dhcp6: false
    addresses:
      - ${internal_ip}/24
    routes:
      - to: default
        via: ${GATEWAY_INTERNAL_IP:-10.20.0.1}
    nameservers:
      addresses:
        - ${GATEWAY_INTERNAL_IP:-10.20.0.1}
EOF
  fi
}
