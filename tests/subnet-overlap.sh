#!/usr/bin/env bash
# Unit test for ip_to_int and cidr_contains in scripts/lib.sh -- the IPv4 math
# behind preflight's host-only-subnet collision guard. No UTM, no lab.conf.
#
# The guard exists because a VPN whose tunnel gateway lands inside the vmnet
# host-only subnet gets silently hijacked by UTM's bridge. The load-bearing case
# is therefore "is this gateway IP inside that /24", exercised both ways below,
# including the exact 192.168.128.1-in-192.168.128.0/24 collision that motivated it.
set -euo pipefail
cd "$(dirname "$0")/.."
# lib.sh's config helpers are not used here, but require_lab_conf_vars is only
# called from load_config, which we never invoke -- so no fake vars are needed.
source scripts/lib.sh

fail=0
check() { [[ "$1" == "$2" ]] || { echo "  FAIL $3 (got '$1', want '$2')"; fail=1; }; }
# Run a command and check its exit status (0/1/2). The if/else keeps a non-zero
# return -- which is the whole point of half these cases -- from tripping set -e.
checkrc() { local want="$1" rc; shift; if "$@" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  [[ "$rc" == "$want" ]] || { echo "  FAIL $* (rc $rc, want $want)"; fail=1; }; }

echo "ip_to_int:"
check "$(ip_to_int 0.0.0.0)"         "0"          "0.0.0.0 is 0"
check "$(ip_to_int 255.255.255.255)" "4294967295" "broadcast is 2^32-1"
check "$(ip_to_int 192.168.128.1)"   "3232268289" "192.168.128.1"
check "$(ip_to_int 10.20.0.10)"      "169082890"  "10.20.0.10"
# A leading-zero octet must be read base-10, never octal (010 != 8), and must
# not blow up under set -e.
check "$(ip_to_int 010.0.0.1)"       "167772161"  "010 is decimal 10, not octal"
# Malformed inputs return 1 and print nothing -- this is what rejects a
# MAC-formatted gateway (fe.b2.14.5b.c8.64) or a link#N row in the route table.
checkrc 1 ip_to_int 256.0.0.1        # octet out of range
checkrc 1 ip_to_int 1.2.3            # too few octets
checkrc 1 ip_to_int 1.2.3.4.5        # too many octets
checkrc 1 ip_to_int fe.b2.14.5b.c8.64
checkrc 1 ip_to_int ""

echo "cidr_contains:"
# The collision that started all this: the VPN gateway inside the vmnet default,
# i.e. exactly what preflight refuses to build on when HOST_ONLY_SUBNET is that
# /24 and a VPN pushes a gateway into it.
checkrc 0 cidr_contains 192.168.128.0/24 192.168.128.1
# A different /24 does NOT contain that gateway (so preflight would NOT fire).
checkrc 1 cidr_contains 172.16.20.0/24   192.168.128.1
# Boundaries of a /24.
checkrc 0 cidr_contains 172.16.20.0/24   172.16.20.0
checkrc 0 cidr_contains 172.16.20.0/24   172.16.20.255
checkrc 1 cidr_contains 172.16.20.0/24   172.16.21.0
checkrc 1 cidr_contains 172.16.20.0/24   172.16.19.255
# The wide tunnel range that overlapped the /24 vmnet net (Squawker's /18).
checkrc 0 cidr_contains 192.168.128.0/18 192.168.191.255  # last address in /18
checkrc 1 cidr_contains 192.168.128.0/18 192.168.192.0    # first address past it
# A host route (/32) matches only itself.
checkrc 0 cidr_contains 10.20.0.10/32    10.20.0.10
checkrc 1 cidr_contains 10.20.0.10/32    10.20.0.11
# /0 contains everything.
checkrc 0 cidr_contains 0.0.0.0/0        8.8.8.8
# Malformed CIDR or IP returns 2 (cannot tell), never a false match.
checkrc 2 cidr_contains 172.16.20.0/33   172.16.20.1
checkrc 2 cidr_contains 172.16.20.0/24   not-an-ip
checkrc 2 cidr_contains garbage          172.16.20.1

[[ "$fail" == 0 ]] && echo "OK" || { echo "FAILED"; exit 1; }
