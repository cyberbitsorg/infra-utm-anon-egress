#!/usr/bin/env bash
# Unit tests for scripts/mullvad-lib.sh. Fixtures only: no network, no Mullvad
# account, no secrets/. These functions decide which server the gateway talks to
# and which country the internet sees, so a wrong match is a wrong jurisdiction.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
source scripts/mullvad-lib.sh

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
note() { echo "  FAIL $1"; fail=1; }

# A fixture relay table. Deliberately contains the traps that matter:
#   se2-... exists so a "se" prefix must not match it
#   bg-sofia-... exists so a "bg-sof" prefix must not match it
#   nl-ams-wg-002 is INACTIVE and must never be selected
#   se-got-wg-001 has multihop_port 51820, the single-hop port, to drive Task 2
#   bg-sof-wg-003 has NO multihop_port key at all, and bg-sof-wg-004 has one
#   that is JSON null -- both are realistic shapes of "this relay has no
#   usable multihop endpoint" and both must drive the same rejection in
#   mullvad_assert_multihop. Marked INACTIVE so the empty-spec "7 active
#   relays" count below does not have to change to accommodate them.
cat > "${tmp}/relays.json" <<'EOF'
[
 {"hostname":"bg-sof-wg-001","active":true,"ipv4_addr_in":"146.70.188.130","multihop_port":3225,"country_code":"bg","city_code":"sof"},
 {"hostname":"bg-sof-wg-002","active":true,"ipv4_addr_in":"146.70.188.194","multihop_port":3226,"country_code":"bg","city_code":"sof"},
 {"hostname":"bg-sofia-wg-001","active":true,"ipv4_addr_in":"146.70.188.200","multihop_port":3227,"country_code":"bg","city_code":"sfa"},
 {"hostname":"bg-sof-wg-003","active":false,"ipv4_addr_in":"146.70.188.201","country_code":"bg","city_code":"sof"},
 {"hostname":"bg-sof-wg-004","active":false,"ipv4_addr_in":"146.70.188.202","multihop_port":null,"country_code":"bg","city_code":"sof"},
 {"hostname":"se-got-wg-001","active":true,"ipv4_addr_in":"185.213.154.66","multihop_port":51820,"country_code":"se","city_code":"got"},
 {"hostname":"se-sto-wg-001","active":true,"ipv4_addr_in":"185.213.154.70","multihop_port":3301,"country_code":"se","city_code":"sto"},
 {"hostname":"se2-sto-wg-001","active":true,"ipv4_addr_in":"185.213.154.71","multihop_port":3302,"country_code":"se","city_code":"sto"},
 {"hostname":"nl-ams-wg-001","active":true,"ipv4_addr_in":"92.60.40.10","multihop_port":3401,"country_code":"nl","city_code":"ams"},
 {"hostname":"nl-ams-wg-002","active":false,"ipv4_addr_in":"92.60.40.11","multihop_port":3402,"country_code":"nl","city_code":"ams"}
]
EOF
J="${tmp}/relays.json"

echo "mullvad_relay_match:"
got="$(mullvad_relay_match "$J" se | tr '\n' ' ')"
[[ "$got" == "se-got-wg-001 se-sto-wg-001 " ]] \
  || note "'se' must match only se-* and never se2-* (got '${got}')"

got="$(mullvad_relay_match "$J" bg-sof | tr '\n' ' ')"
[[ "$got" == "bg-sof-wg-001 bg-sof-wg-002 " ]] \
  || note "'bg-sof' must not match bg-sofia-* (got '${got}')"

got="$(mullvad_relay_match "$J" bg-sof-wg-001 | tr '\n' ' ')"
[[ "$got" == "bg-sof-wg-001 " ]] \
  || note "an exact hostname must match exactly itself (got '${got}')"

got="$(mullvad_relay_match "$J" nl | tr '\n' ' ')"
[[ "$got" == "nl-ams-wg-001 " ]] \
  || note "an inactive relay must never be selectable (got '${got}')"

got="$(mullvad_relay_match "$J" zz | tr '\n' ' ')"
[[ -z "$got" ]] || note "an unknown spec must match nothing (got '${got}')"

# An empty spec means "anywhere" -- this is what an unset MULLVAD_ENTRY passes.
# The seven ACTIVE relays, not all eight.
got="$(mullvad_relay_match "$J" "" | grep -c . || true)"
[[ "$got" == "7" ]] \
  || note "an empty spec must match every active relay, not none (got '${got}')"

echo "mullvad_relay_field:"
[[ "$(mullvad_relay_field "$J" bg-sof-wg-001 multihop_port)" == "3225" ]] \
  || note "multihop_port lookup"
[[ "$(mullvad_relay_field "$J" se-got-wg-001 ipv4_addr_in)" == "185.213.154.66" ]] \
  || note "ipv4_addr_in lookup"
[[ "$(mullvad_relay_field "$J" bg-sof-wg-001 country_code)" == "bg" ]] \
  || note "country_code lookup"
[[ -z "$(mullvad_relay_field "$J" does-not-exist country_code)" ]] \
  || note "an unknown hostname must yield nothing"

echo "mullvad_pick_random:"
got="$(printf 'a\nb\nc\n' | mullvad_pick_random)"
case "$got" in a|b|c) ;; *) note "must pick one of the input lines (got '${got}')" ;; esac
printf '' | mullvad_pick_random >/dev/null 2>&1 \
  && note "empty input must return non-zero"

# A fixture exit config. Realistic shape, obviously fake key material.
cat > "${tmp}/exit.conf" <<'EOF'
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSByZWFsIGtleQo=
Address = 10.66.12.34/32,fc00:bbbb:bbbb:bb01::1:2c21/128
DNS = 10.64.0.1

[Peer]
PublicKey = UrQiI9ISdPPzd4ARw1NHOPKKvKvxUhjwRjaI0JpJFgM=
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = 146.70.188.130:51820
EOF

echo "mullvad_rewrite_endpoint:"
out="$(mullvad_rewrite_endpoint "${tmp}/exit.conf" 185.213.154.66 3225)"
[[ "$(grep -c '^Endpoint = 185.213.154.66:3225$' <<<"$out")" -eq 1 ]] \
  || note "the endpoint must be rewritten to entry-ip:exit-port"
[[ "$(grep -c '^Endpoint' <<<"$out")" -eq 1 ]] \
  || note "there must be exactly one Endpoint line afterwards"

# The whole safety of this transformation is that it changes NOTHING else: the
# keys, Address and AllowedIPs must stay the exit server's, byte for byte.
diff <(grep -v '^Endpoint' "${tmp}/exit.conf") <(grep -v '^Endpoint' <<<"$out") >/dev/null \
  || note "every line except Endpoint must be untouched"

# Two Endpoint lines is a malformed config, not something to guess at. The
# rejection must be silent on stdout, not just non-zero: a caller that forgot
# to check the return value must never be handed a plausible partial config.
cp "${tmp}/exit.conf" "${tmp}/two.conf"
echo 'Endpoint = 1.2.3.4:51820' >> "${tmp}/two.conf"
out2="$(mullvad_rewrite_endpoint "${tmp}/two.conf" 1.1.1.1 3225 2>/dev/null)" \
  && note "two Endpoint lines must be rejected"
[[ -z "$out2" ]] \
  || note "rejection must print nothing on stdout, not a partial config (got '${out2}')"

echo "mullvad_assert_multihop:"
mullvad_assert_multihop "$J" se-sto-wg-001 bg-sof-wg-001 2>/dev/null \
  || note "a different-country pair with a real multihop port must pass"
mullvad_assert_multihop "$J" bg-sof-wg-001 bg-sof-wg-001 2>/dev/null \
  && note "the same server as entry and exit must be rejected"
mullvad_assert_multihop "$J" bg-sof-wg-002 bg-sof-wg-001 2>/dev/null \
  && note "entry and exit in the same country must be rejected"
mullvad_assert_multihop "$J" bg-sof-wg-001 se-got-wg-001 2>/dev/null \
  && note "an exit whose multihop_port is 51820 must be rejected"
mullvad_assert_multihop "$J" bg-sof-wg-001 does-not-exist 2>/dev/null \
  && note "an unknown exit must be rejected"
mullvad_assert_multihop "$J" does-not-exist bg-sof-wg-001 2>/dev/null \
  && note "an unknown entry must be rejected"
mullvad_assert_multihop "$J" se-sto-wg-001 bg-sof-wg-003 2>/dev/null \
  && note "an exit with no multihop_port key at all must be rejected"
mullvad_assert_multihop "$J" se-sto-wg-001 bg-sof-wg-004 2>/dev/null \
  && note "an exit whose multihop_port is null must be rejected"

echo "mullvad_endpoint_port_for:"
[[ "$(mullvad_endpoint_port_for "$J" bg-sof-wg-001)" == "3225" ]] \
  || note "the exit's multihop_port is the endpoint port"

[[ "$fail" -eq 0 ]] && echo "mullvad-select: OK"
exit "$fail"
