#!/usr/bin/env bash
# The cloud-init network-config renderer, split out of make-seed.sh so it can be
# unit tested (tests/seed-network.sh) without building an ISO. Sourced, not run.

# render_network_config <role> <mac_nat> <mac_internal> <internal_ip> <nic_layout>
#
# Prints a cloud-init network-config v2 document on stdout. Interfaces are
# matched by MAC, so guest interface names (enp0sX) never matter.
#
# Two shapes, decided by the NIC layout (nic_layout_for_role in lib.sh):
#
#   dual      the gateway: a DHCP NAT NIC for internet plus a static address on
#             the internal segment. It is the router, so it takes no default
#             route from the internal side.
#   internal  everything else: ONE NIC, static, with both the default route and
#             DNS pointing at the gateway. No NAT NIC is described at all,
#             because the VM does not have one -- see create-vm.applescript.
#
# The default route uses the `routes:` form rather than the `gateway4:` key:
# gateway4 is deprecated in current netplan/cloud-init and logs a deprecation
# warning on every boot, while `routes:` is supported by every renderer these
# images use.
render_network_config() {
  local role="$1" mac_nat="$2" mac_internal="$3" internal_ip="$4" nic_layout="$5"
  if [[ "$nic_layout" == "dual" ]]; then
    cat <<EOF
version: 2
ethernets:
  nat:
    match:
      macaddress: "${mac_nat}"
    dhcp4: true
  internal:
    match:
      macaddress: "${mac_internal}"
    dhcp4: false
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
