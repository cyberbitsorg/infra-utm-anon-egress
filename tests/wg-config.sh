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

# Two peers. wg-quick would happily configure both, but the kill-switch allows
# exactly ONE endpoint through, so the second is silently blackholed -- it fails
# closed, and presents as a tunnel that mysteriously does not work.
cat > "${tmp}/twopeers.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = 193.138.218.220:3004
[Peer]
PublicKey = J8KysHmHZWqtrVKKOppneDXSks/PDsB1XTlRHpwiABA=
AllowedIPs = 0.0.0.0/0
Endpoint = 185.213.154.66:3225
EOF

# A bracketed IPv6 endpoint. Refused like any non-IPv4 endpoint, but it must say
# WHY: the generic message claims "not a hostname", which is untrue here and
# sends the operator hunting for the wrong problem.
cat > "${tmp}/v6endpoint.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = [2a03:1b20:5:f011::a01f]:3004
EOF

cat > "${tmp}/nokey.conf" <<'EOF'
[Interface]
Address = 10.66.12.34/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = 193.138.218.220:3004
EOF

# IPv6 entries FIRST in a three-entry Address list, and first-of-two in
# AllowedIPs. The original sed-based stripper only matched a v6 entry preceded
# by a comma, so a leading v6 entry (no comma before it) survived untouched.
cat > "${tmp}/v6first.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = fc00::1/128,10.66.1.2/32,10.77.3.4/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = ::/0,0.0.0.0/0
Endpoint = 193.138.218.220:3004
EOF

# Address is IPv6-only: stripping it must leave nothing, and validate_wg_config
# must refuse rather than hand sanitize_wg_config a now-addressless interface.
cat > "${tmp}/v6only-address.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = fc00::1/128
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = 193.138.218.220:3004
EOF

# AllowedIPs is IPv6-only: same refusal, different field.
cat > "${tmp}/v6only-allowedips.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = ::/0
Endpoint = 193.138.218.220:3004
EOF

# A trailing comment on the Endpoint line. Without stripping it, the port
# parses as "3004 # note" and validate_wg_config rejects a perfectly valid
# config with a confusing "not numeric" message.
cat > "${tmp}/comment-endpoint.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:3004 # note
EOF

# An operator-supplied MTU. wg-quick applies the LAST assignment of a repeated
# key, so if this line survived sanitising, the gateway role's own MTU write
# (below [Interface]) would come first and this one would silently win instead
# -- the role would report the MTU it set, but the tunnel would run at
# whatever Mullvad's generator emitted here.
cat > "${tmp}/mtu.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32
MTU = 1420
[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0
Endpoint = 193.138.218.220:3004
EOF

# Mullvad's "local network sharing" option injects PostUp/PostDown/PreUp/PreDown
# hooks that run firewall rules. wg-quick must never manage firewalling --
# nftables owns egress -- so sanitize_wg_config must strip all four.
cat > "${tmp}/hooks.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PreUp = echo pre-up
PreDown = echo pre-down
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
# The ruleset permits exactly one endpoint, so more than one [Peer] must be
# caught here rather than turning into a tunnel that silently will not come up.
if validate_wg_config "${tmp}/twopeers.conf" 2>/dev/null; then
  note "a config with two [Peer] sections must be refused"
fi
if validate_wg_config "${tmp}/v6endpoint.conf" 2>/dev/null; then
  note "a bracketed IPv6 endpoint must be refused"
fi
# ...and the reason must name IPv6, not send the operator looking for a hostname.
grep -qi 'IPv6' <<<"$(validate_wg_config "${tmp}/v6endpoint.conf" 2>&1 || true)" \
  || note "the IPv6-endpoint rejection must say IPv6, not 'not a hostname'"
if validate_wg_config "${tmp}/does-not-exist.conf" 2>/dev/null; then
  note "a missing file must be refused"
fi
if validate_wg_config "${tmp}/v6only-address.conf" 2>/dev/null; then
  note "an IPv6-only Address must be refused (no IPv4 address would remain)"
fi
if validate_wg_config "${tmp}/v6only-allowedips.conf" 2>/dev/null; then
  note "an IPv6-only AllowedIPs must be refused (no IPv4 route would remain)"
fi

echo "Endpoint with a trailing comment:"
[[ "$(wg_endpoint_port "${tmp}/comment-endpoint.conf")" == "3004" ]] \
  || note "a trailing comment on Endpoint corrupts the parsed port"
validate_wg_config "${tmp}/comment-endpoint.conf" 2>/dev/null \
  || note "a valid config with a trailing Endpoint comment must still be accepted"

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

echo "sanitize_wg_config (IPv6 in any position):"
san_first="$(sanitize_wg_config "${tmp}/v6first.conf")"
grep -q 'fc00:' <<<"$san_first" && note "a leading IPv6 Address entry must be stripped"
grep -q '::/0'  <<<"$san_first" && note "a leading IPv6 AllowedIPs entry must be stripped"
grep -q '10\.66\.1\.2/32' <<<"$san_first" || note "first surviving IPv4 Address entry lost"
grep -q '10\.77\.3\.4/32' <<<"$san_first" || note "second surviving IPv4 Address entry lost"
# Exact-line checks: the two survivors must be joined by a single comma, with
# no leading, trailing, or doubled comma left where the v6 entry used to be.
grep -qE '^Address = 10\.66\.1\.2/32,10\.77\.3\.4/32$' <<<"$san_first" \
  || note "Address not cleanly rejoined after stripping a leading IPv6 entry"
grep -qE '^AllowedIPs = 0\.0\.0\.0/0$' <<<"$san_first" \
  || note "AllowedIPs not cleanly rejoined after stripping a leading IPv6 entry"
grep -qE ',,|= ,|,$' <<<"$san_first" && note "stray comma left in sanitized output"

echo "sanitize_wg_config (operator MTU):"
san_mtu="$(sanitize_wg_config "${tmp}/mtu.conf")"
grep -qE '^MTU[[:space:]]*=' <<<"$san_mtu" \
  && note "an operator-supplied MTU line must be stripped (the gateway role's wg_mtu must be the only source)"

echo "sanitize_wg_config (Post/Pre hooks):"
san_hooks="$(sanitize_wg_config "${tmp}/hooks.conf")"
grep -qE '^(PostUp|PostDown|PreUp|PreDown)' <<<"$san_hooks" \
  && note "PostUp/PostDown/PreUp/PreDown must be stripped (wg-quick must not manage firewalling)"

if [[ "$fail" -eq 0 ]]; then echo "wg-config: OK"; else echo "wg-config: FAILED"; exit 1; fi
