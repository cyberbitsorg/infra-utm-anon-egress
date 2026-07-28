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
cat > "${tmp}/relays.json" <<'EOF'
[
 {"hostname":"bg-sof-wg-001","active":true,"ipv4_addr_in":"146.70.188.130","multihop_port":3225,"country_code":"bg","city_code":"sof"},
 {"hostname":"bg-sof-wg-002","active":true,"ipv4_addr_in":"146.70.188.194","multihop_port":3226,"country_code":"bg","city_code":"sof"},
 {"hostname":"bg-sofia-wg-001","active":true,"ipv4_addr_in":"146.70.188.200","multihop_port":3227,"country_code":"bg","city_code":"sfa"},
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

[[ "$fail" -eq 0 ]] && echo "mullvad-select: OK"
exit "$fail"
