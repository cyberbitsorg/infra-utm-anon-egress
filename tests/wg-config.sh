#!/usr/bin/env bash
# Unit tests for scripts/wg-lib.sh. Uses fixtures, so it runs with no Mullvad
# account and no network. These functions are the gate between an operator-supplied
# file and a ruleset that depends on its contents: if the endpoint is parsed wrong,
# the nftables output chain allows the wrong address and the tunnel never comes up.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
source scripts/wg-lib.sh

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
note() { echo "  FAIL $1"; fail=1; }

# A realistic Mullvad multihop config: endpoint is <ENTRY-IP>:<EXIT-MULTIHOP-PORT>,
# the PublicKey is the exit server's, and Mullvad ships both v4 and v6 addresses.
cat > "${tmp}/good.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32,fc00:bbbb:bbbb:bb01::1:2c21/128
DNS = 10.64.0.1

[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = 193.138.218.220:3004
EOF

cat > "${tmp}/hostname.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = se-mma-wg-001.relays.mullvad.net:3004
EOF

cat > "${tmp}/nokey.conf" <<'EOF'
[Interface]
Address = 10.66.12.34/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = 193.138.218.220:3004
EOF

echo "wg_endpoint_ip / wg_endpoint_port:"
[[ "$(wg_endpoint_ip "${tmp}/good.conf")" == "193.138.218.220" ]] || note "endpoint IP not parsed"
[[ "$(wg_endpoint_port "${tmp}/good.conf")" == "3004" ]] || note "endpoint port not parsed"

echo "validate_wg_config:"
validate_wg_config "${tmp}/good.conf" 2>/dev/null || note "a valid multihop config was rejected"
# A hostname endpoint must be refused: resolving it would need clear-net DNS
# before the tunnel exists, which is a leak by construction (design §2).
if validate_wg_config "${tmp}/hostname.conf" 2>/dev/null; then
  note "a hostname endpoint must be refused"
fi
if validate_wg_config "${tmp}/nokey.conf" 2>/dev/null; then
  note "a config with no PrivateKey must be refused"
fi
if validate_wg_config "${tmp}/does-not-exist.conf" 2>/dev/null; then
  note "a missing file must be refused"
fi

echo "sanitize_wg_config:"
san="$(sanitize_wg_config "${tmp}/good.conf")"
grep -q 'DNS' <<<"$san"        && note "the DNS line must be removed (unbound owns DNS)"
grep -q 'fc00:' <<<"$san"      && note "IPv6 must be stripped from Address"
grep -q '::/0' <<<"$san"       && note "IPv6 must be stripped from AllowedIPs"
grep -q '10\.66\.12\.34/32' <<<"$san" || note "the IPv4 address must survive"
grep -q '0\.0\.0\.0/0' <<<"$san"      || note "the IPv4 AllowedIPs must survive"
grep -q 'Endpoint = 193\.138\.218\.220:3004' <<<"$san" || note "the endpoint must survive"
grep -q 'PrivateKey' <<<"$san" || note "the private key must survive"
# The sanitised output must still be a config wg-quick accepts: both sections present.
grep -q '^\[Interface\]' <<<"$san" || note "[Interface] section lost"
grep -q '^\[Peer\]' <<<"$san"      || note "[Peer] section lost"

if [[ "$fail" -eq 0 ]]; then echo "wg-config: OK"; else echo "wg-config: FAILED"; exit 1; fi
