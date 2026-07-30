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

echo "mullvad_spec_matches:"
# The rule itself, as a predicate. verify.sh checks the pinned exit against
# MULLVAD_EXIT with this same function, so the cases below are the ones that
# decide both which country gets selected and which country counts as verified.
mullvad_spec_matches se se-sto-wg-001 || note "'se' must match se-sto-wg-001"
mullvad_spec_matches se se2-sto-wg-001 && note "'se' must NOT match se2-sto-wg-001"
mullvad_spec_matches bg-sof bg-sofia-wg-001 && note "'bg-sof' must NOT match bg-sofia-wg-001"
mullvad_spec_matches bg-sof-wg-001 bg-sof-wg-001 || note "an exact hostname must match itself"
mullvad_spec_matches "" nl-ams-wg-001 || note "an empty spec means anywhere"
mullvad_spec_matches nl bg-sof-wg-001 && note "'nl' must not match another country"

# And it must be the SAME rule mullvad_relay_match applies -- one implementation
# is the whole point, so this compares the two on every spec/hostname pair the
# fixture offers. A second matcher that drifted (say, a bare startswith in one
# of them) shows up here rather than as a lab in the wrong country.
for h in bg-sof-wg-001 bg-sof-wg-002 bg-sofia-wg-001 se-got-wg-001 se-sto-wg-001 se2-sto-wg-001 nl-ams-wg-001; do
  for spec in "" se bg bg-sof nl zz; do
    if mullvad_spec_matches "$spec" "$h"; then want=1; else want=0; fi
    if mullvad_relay_match "$J" "$spec" | grep -qxF "$h"; then got=1; else got=0; fi
    [[ "$want" == "$got" ]] \
      || note "mullvad_relay_match and mullvad_spec_matches disagree on spec '${spec}' vs ${h} (match=${got}, predicate=${want})"
  done
done

echo "mullvad_relay_field:"
[[ "$(mullvad_relay_field "$J" bg-sof-wg-001 multihop_port)" == "3225" ]] \
  || note "multihop_port lookup"
[[ "$(mullvad_relay_field "$J" se-got-wg-001 ipv4_addr_in)" == "185.213.154.66" ]] \
  || note "ipv4_addr_in lookup"
[[ "$(mullvad_relay_field "$J" bg-sof-wg-001 country_code)" == "bg" ]] \
  || note "country_code lookup"
[[ -z "$(mullvad_relay_field "$J" does-not-exist country_code)" ]] \
  || note "an unknown hostname must yield nothing"

echo "relay table cache:"
# mullvad_relay_match / mullvad_relay_field answer from a table derived from the
# JSON once, instead of parsing it per call. A cache that can answer for a file
# it was not built from is worse than the 26 s it saves: mullvad_load_relays
# replaces the relay list mid-run whenever a refetch succeeds, and the answers
# after that must be about the new file. (The stamp is size + mtime, so the two
# writes below differ in size as well as content -- a same-size rewrite inside
# one mtime tick is the case this does not cover.)
cp "$J" "${tmp}/mutable.json"
[[ "$(mullvad_relay_field "${tmp}/mutable.json" bg-sof-wg-001 country_code)" == "bg" ]] \
  || note "the first lookup against a relay list must be correct"
cat > "${tmp}/mutable.json" <<'EOF'
[{"hostname":"bg-sof-wg-001","active":true,"ipv4_addr_in":"146.70.188.130","multihop_port":3225,"country_code":"xx","city_code":"sof"}]
EOF
[[ "$(mullvad_relay_field "${tmp}/mutable.json" bg-sof-wg-001 country_code)" == "xx" ]] \
  || note "a replaced relay list must rebuild the derived table, not keep answering for the file it replaced"
got="$(mullvad_relay_match "${tmp}/mutable.json" "" | tr '\n' ' ')"
[[ "$got" == "bg-sof-wg-001 " ]] \
  || note "a replaced relay list must rebuild the hostname table too (got '${got}')"

# A duplicated hostname answers from the FIRST record, which is what the
# per-relay scan this table replaced did (it stopped at the first match). Not a
# shape Mullvad publishes, but "which of the two do I get" must be decided by
# the code rather than by which one the table happened to keep.
cat > "${tmp}/dupe.json" <<'EOF'
[
 {"hostname":"bg-sof-wg-001","active":true,"ipv4_addr_in":"146.70.188.130","multihop_port":3225,"country_code":"bg","city_code":"sof"},
 {"hostname":"bg-sof-wg-001","active":true,"ipv4_addr_in":"10.9.9.9","multihop_port":3999,"country_code":"xx","city_code":"sof"}
]
EOF
got="$(mullvad_relay_field "${tmp}/dupe.json" bg-sof-wg-001 country_code)"
[[ "$got" == "bg" ]] \
  || note "a duplicated hostname must answer from the first record, as the scan this replaced did (got '${got}')"
got="$(mullvad_relay_field "${tmp}/dupe.json" bg-sof-wg-001 multihop_port)"
[[ "$got" == "3225" ]] \
  || note "every field of a duplicated hostname must come from that same first record (got '${got}')"

echo "the derived table's format version:"
# A table written by an OLDER build of mullvad-lib.sh must be discarded, not
# read. The size/mtime half of the stamp cannot do that on its own: it only
# notices a changed relay list, so a table built before (say) the separator
# filter below existed keeps answering from forged records for as long as the
# JSON beneath it is untouched -- up to the full 7-day cache life.
#
# So the fixture below is a hostile table carrying the CORRECT size/mtime stamp
# and the wrong format version. That is the only shape that tells the version
# apart from the rest of the stamp: give it a wrong mtime too and the test passes
# whether the version exists or not.
VJ="${tmp}/version.json"
cp "$J" "$VJ"
mullvad_relay_field "$VJ" bg-sof-wg-001 country_code >/dev/null
{ printf '# %s\n' "$(_mullvad_stamp "$VJ")"; printf 'H\tforged-host-001\n'; } > "${VJ}.tbl"
got="$(mullvad_relay_match "$VJ" forged | tr '\n' ' ')"
[[ -z "$got" ]] \
  || note "a derived table stamped with a different format version must be rebuilt, not trusted (got '${got}')"
got="$(mullvad_relay_match "$VJ" bg-sof | tr '\n' ' ')"
[[ "$got" == "bg-sof-wg-001 bg-sof-wg-002 " ]] \
  || note "...and the rebuild must produce the real table (got '${got}')"

echo "the derived table's separators:"
# The table is line- and tab-separated, so anything that can carry either
# separator must be dropped before it is written -- otherwise a relay list can
# forge records this repo has no way to tell from real ones. Both hostnames
# below were verified to do exactly that before the hostname filter existed:
# "inj\nH\tza-jnb-wg-999" put za-jnb-wg-999 into the hostname stream as a
# selectable candidate that is in no relay list, and "vic\tcountry_code" made
# `mullvad_relay_field <json> vic country_code` answer
# "hostname<TAB>vic<TAB>country_code". The per-relay scan this table replaced
# answered nothing for either, and "nothing" is what every caller already
# treats as fatal.
#
# Not a privilege boundary -- whoever can hand this repo a relay list can choose
# the exit country with ordinary-looking JSON -- but an answer about a server
# that does not exist is a different class of wrong from a refusal to answer.
# ok-bbb-wg-001 carries the same attack in a VALUE instead of a hostname, which
# is the case the writer already filtered; it is here so both filters are pinned
# by the same fixture.
python3 - "${tmp}/hostile.json" <<'PY'
import json, sys
json.dump([
    {"hostname": "inj\nH\tza-jnb-wg-999", "active": True, "country_code": "bg",
     "multihop_port": 3225, "ipv4_addr_in": "10.0.0.1"},
    {"hostname": "vic\tcountry_code", "active": True, "country_code": "nl",
     "multihop_port": 3226, "ipv4_addr_in": "10.0.0.2"},
    {"hostname": "ok-aaa-wg-001", "active": True, "country_code": "se",
     "multihop_port": 3227, "ipv4_addr_in": "10.0.0.3"},
    {"hostname": "ok-bbb-wg-001", "active": True, "country_code": "se",
     "multihop_port": 3228, "ipv4_addr_in": "10.0.0.4",
     "city_code": "x\nH\tfake-host-001"},
], open(sys.argv[1], "w"))
PY
HJ="${tmp}/hostile.json"
got="$(mullvad_relay_match "$HJ" "" | tr '\n' ' ')"
[[ "$got" == "ok-aaa-wg-001 ok-bbb-wg-001 " ]] \
  || note "a hostname or value carrying a newline or a tab must not reach the hostname table (got '${got}')"
got="$(mullvad_relay_match "$HJ" za | tr '\n' ' ')"
[[ -z "$got" ]] \
  || note "a forged hostname must never be selectable as a candidate (got '${got}')"
got="$(mullvad_relay_match "$HJ" fake | tr '\n' ' ')"
[[ -z "$got" ]] \
  || note "a forged hostname smuggled through a field VALUE must never be selectable (got '${got}')"
got="$(mullvad_relay_field "$HJ" za-jnb-wg-999 country_code)"
[[ -z "$got" ]] \
  || note "a relay that is not in the list must have no fields (got '${got}')"
got="$(mullvad_relay_field "$HJ" 'vic' country_code)"
[[ -z "$got" ]] \
  || note "a tab in a hostname must not let one relay answer for another's key (got '${got}')"
mullvad_assert_multihop "$HJ" ok-aaa-wg-001 za-jnb-wg-999 2>/dev/null \
  && note "a forged exit hostname must be rejected as not in the relay list"

echo "the derived table's mode:"
# 0600 for consistency with the pin, not for secrecy: the table holds only the
# public Mullvad relay list, no secret and no record of the operator's choice.
# The pin is 0600 on the reasoning that a file created at the ambient umask is
# readable by every local user for as long as it exists, and a table at 0644
# sitting next to it only raises the question of which of the two rules is real.
# Checked under a deliberately loose umask so a pass cannot be an accident of
# the ambient one.
TBLJ="${tmp}/tblmode.json"
cp "$J" "$TBLJ"
rm -f "${TBLJ}.tbl"
( umask 022; mullvad_relay_field "$TBLJ" bg-sof-wg-001 country_code >/dev/null )
[[ "$(stat -f '%Lp' "${TBLJ}.tbl")" == "600" ]] \
  || note "the derived table must be mode 600 regardless of umask (got '$(stat -f '%Lp' "${TBLJ}.tbl")')"

echo "_mullvad_list_has:"
# The candidate list is matched as literal strings. A corrupted pin read as a
# basic regular expression could otherwise claim to be a candidate it does not
# name.
_mullvad_list_has "$(printf 'bg-sof-wg-001\nbg-sof-wg-002\n')" 'bg-sof-wg-00.' \
  && note "a pin must be compared literally, never as a pattern"
_mullvad_list_has "$(printf 'bg-sof-wg-001\nbg-sof-wg-002\n')" '.*' \
  && note "a pin of '.*' must match nothing"
_mullvad_list_has "$(printf 'bg-sof-wg-001\nbg-sof-wg-002\n')" bg-sof-wg-002 \
  || note "an exact hostname must be found"
_mullvad_list_has "$(printf 'bg-sof-wg-001\nbg-sof-wg-002\n')" bg-sof-wg-001 \
  || note "the FIRST line must be found too"
_mullvad_list_has "" bg-sof-wg-001 && note "an empty list contains nothing"

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

# A fake secrets dir: only some relays have a config on disk, which is the real
# world (the operator downloads a subset).
mkdir -p "${tmp}/secrets"
for h in bg-sof-wg-001 bg-sof-wg-002 nl-ams-wg-001; do
  cp "${tmp}/exit.conf" "${tmp}/secrets/${h}.conf"
done
S="${tmp}/secrets"
PIN="${tmp}/chosen"

echo "mullvad_exit_candidates:"
got="$(mullvad_exit_candidates "$J" "$S" bg | tr '\n' ' ')"
[[ "$got" == "bg-sof-wg-001 bg-sof-wg-002 " ]] \
  || note "only relays with a config on disk are exit candidates (got '${got}')"
got="$(mullvad_exit_candidates "$J" "$S" se | tr '\n' ' ')"
[[ -z "$got" ]] || note "se has no config on disk, so no candidates (got '${got}')"

echo "mullvad_resolve_pair (entry-country pre-filter, repeated):"
# A single resolve below only proves the filter fired ONCE, and that is nearly
# no evidence: with entry_spec "" the default-spec pool is the 7 active
# relays, 3 of which are bg (the exit's country here). Delete the pre-filter
# and the loop still lands outside bg by pure luck on 4-of-7 draws -- a coin
# flip that a mutation-tester found catches its own removal only ~half the
# time. Resolve fresh 25 times, each with its OWN pin (a reused pin would
# just replay one draw, defeating the whole point), and check the invariant
# ourselves on every draw. Each iteration is wrapped in an `if`, so a mutated
# failure is caught by our own note rather than aborting the whole suite
# under `set -e` and pointing at the backstop instead of the missing filter.
# This runs BEFORE the single-shot checks below for the same reason: those
# are unguarded, and if a mutation makes one of them fail, `set -e` would kill
# the script before ever reaching this block. If the pre-filter is gone,
# either some iteration draws a same-country entry (caught below by name) or
# mullvad_assert_multihop rejects it and the resolve call fails (also caught
# below by name). With 4 of 7 candidates legal, the chance all 25 iterations
# luck into a legal draw despite a missing filter is (4/7)^25, on the order
# of 1 in a million -- decisive rather than a coin flip.
for i in $(seq 1 25); do
  mpin="${tmp}/chosen_mut_${i}"
  rm -f "$mpin"
  if out="$(mullvad_resolve_pair "$J" "$S" bg "" "$mpin" 2>/dev/null)"; then
    e="${out%% *}"; x="${out##* }"
    ec="$(mullvad_relay_field "$J" "$e" country_code)"
    xc="$(mullvad_relay_field "$J" "$x" country_code)"
    [[ "$ec" != "$xc" ]] \
      || note "iteration ${i}: entry ${e} (${ec}) shares the exit ${x}'s country '${xc}' -- the entry-country pre-filter did not fire"
  else
    note "iteration ${i}: mullvad_resolve_pair failed to find a legal entry, though 4 of 7 default candidates are outside bg -- the entry-country pre-filter regressed"
  fi
done

echo "mullvad_resolve_pair (the exit's country sorts LAST):"
# A second fixture, and the reason for it is one line of arithmetic: a `while`
# loop reports the status of its LAST iteration. The entry pre-filter walks the
# candidate list in sorted order, so when the alphabetically last active relay
# happens to be in the exit's own country, the loop's final `[[ ... ]] && printf`
# is false, the loop returns 1, and under `set -o pipefail` the whole command
# substitution fails -- even though a legal entry was already chosen and
# printed. The operator is then told no entry exists, which is the opposite of
# true, and which relay sorts last is pure alphabetical luck: against the live
# relay list this made every South African exit unbuildable while 537 legal
# entries sat in the list.
#
# So: exactly two relays, the exit's own country last, one legal entry.
cat > "${tmp}/tail.json" <<'EOF'
[
 {"hostname":"aa-xxx-wg-001","active":true,"ipv4_addr_in":"10.9.0.1","multihop_port":3001,"country_code":"aa","city_code":"xxx"},
 {"hostname":"zz-yyy-wg-001","active":true,"ipv4_addr_in":"10.9.0.2","multihop_port":3002,"country_code":"zz","city_code":"yyy"}
]
EOF
mkdir -p "${tmp}/secrets-tail"
cp "${tmp}/exit.conf" "${tmp}/secrets-tail/zz-yyy-wg-001.conf"
rm -f "${tmp}/chosen-tail"
if got="$(mullvad_resolve_pair "${tmp}/tail.json" "${tmp}/secrets-tail" zz "" "${tmp}/chosen-tail" 2>/dev/null)"; then
  [[ "$got" == "aa-xxx-wg-001 zz-yyy-wg-001" ]] \
    || note "the only legal entry must be chosen (got '${got}')"
else
  note "an exit whose country sorts last must still resolve: aa-xxx-wg-001 is a legal entry, but the pre-filter loop returned the status of its last iteration (zz-yyy-wg-001, the exit's own country) and pipefail turned that into 'no entry matches'"
fi

echo "mullvad_resolve_pair:"
rm -f "$PIN"
got="$(mullvad_resolve_pair "$J" "$S" bg "" "$PIN")"
entry="${got%% *}"; exit_h="${got##* }"
[[ "$exit_h" == bg-sof-wg-00[12] ]] || note "exit must be a bg server with a config (got '${exit_h}')"
[[ "$(mullvad_relay_field "$J" "$entry" country_code)" != "bg" ]] \
  || note "a default entry must not be in the exit's country (got '${entry}')"
[[ -f "$PIN" ]] || note "the pin file must be written"
[[ "$(cat "$PIN")" == "$got" ]] || note "the pin must contain the resolved pair"

# Stability: a second call with the same .env must reuse the pin, or the tunnel
# would move country on every `make configure`.
again="$(mullvad_resolve_pair "$J" "$S" bg "" "$PIN")"
[[ "$again" == "$got" ]] || note "an unchanged .env must reuse the pin ('${got}' -> '${again}')"

# Invalidation: changing the exit spec must discard the pin.
changed="$(mullvad_resolve_pair "$J" "$S" nl "" "$PIN")"
[[ "${changed##* }" == "nl-ams-wg-001" ]] \
  || note "changing MULLVAD_EXIT must re-resolve (got '${changed}')"

# An explicit entry spec is honoured.
got="$(mullvad_resolve_pair "$J" "$S" bg se "$PIN")"
[[ "${got%% *}" == se-*-wg-* ]] || note "an explicit entry spec must be used (got '${got}')"

# An impossible ask fails loudly rather than silently picking something else.
mullvad_resolve_pair "$J" "$S" zz "" "$PIN" >/dev/null 2>&1 \
  && note "an exit spec matching nothing must fail"
mullvad_resolve_pair "$J" "$S" bg bg "$PIN" >/dev/null 2>&1 \
  && note "an entry spec confined to the exit's own country must fail"

echo "mullvad_resolve_pair (a pin that was legal and no longer is):"
# Both pins below survive BOTH of mullvad_pair_ok's candidate checks -- the
# pinned exit still matches MULLVAD_EXIT and still has a config on disk, the
# pinned entry still matches MULLVAD_ENTRY -- so the only thing that can reject
# them is the mullvad_assert_multihop call on the reuse path.
#
# That call is load-bearing beyond this function: preflight.sh deliberately does
# NOT re-assert multihop, on the stated grounds that every return path out of
# mullvad_resolve_pair already has. Drop it and an illegal pin passes preflight
# and is caught only by up.sh's backstop -- i.e. after the VMs exist, which is
# precisely what "single-hop must fail before any VM is created" forbids. These
# two cases are what keeps that comment true.
PIN_SAME="${tmp}/chosen-same-country"
printf 'bg-sof-wg-002 bg-sof-wg-001\n' > "$PIN_SAME"
mullvad_resolve_pair "$J" "$S" bg bg "$PIN_SAME" >/dev/null 2>&1 \
  && note "a pinned pair whose entry and exit are both in 'bg' must be discarded on reuse: matching the specs is not the same as being multihop"

# The relay list moved under an old pin: the pinned exit's multihop_port is now
# 51820, which is Mullvad's single-hop port. Its own secrets dir so the fixture
# secrets/ used everywhere else keeps having no se config at all.
S_SINGLE="${tmp}/secrets-singlehop"
mkdir -p "$S_SINGLE"
cp "${tmp}/exit.conf" "${S_SINGLE}/se-got-wg-001.conf"
PIN_SINGLE="${tmp}/chosen-singlehop"
printf 'nl-ams-wg-001 se-got-wg-001\n' > "$PIN_SINGLE"
mullvad_resolve_pair "$J" "$S_SINGLE" se-got "" "$PIN_SINGLE" >/dev/null 2>&1 \
  && note "a pinned exit that now resolves to port ${MULLVAD_SINGLEHOP_PORT} must be discarded on reuse, not kept because the hostnames still match"

echo "mullvad_pair_ok (where the pin sits in the list must not matter):"
# mullvad_pair_ok captures each candidate list and searches the string. The
# obvious spelling -- `mullvad_entry_candidates ... | grep -qxF "$entry"` -- is
# wrong, and this is where that costs the operator something: grep exits at the
# first match, mullvad_relay_match's printf takes SIGPIPE on its next stdio
# flush, pipefail turns that into "this pin is no longer legal", and the tunnel
# moves to another country on a run where nothing changed. That is the bug commit
# c2e4520 fixed.
#
# SIZE IS WHAT GIVES THIS CASE TEETH. The ten-relay fixture cannot catch it: its
# whole candidate list is about 100 bytes, one stdio flush, so nothing is ever
# written to a closed pipe and the wrong spelling passes. Measured: with both
# list checks restored to `| grep -qxF`, the case below on "$J" passed 10 of 10
# runs. The second fixture is therefore 400 relays, whose candidate lists span
# several 1 KB flushes; the same mutation fails it 10 of 10.
#
# It is the ENTRY check the mutation dies on, and deliberately so:
# mullvad_relay_match is the only producer here with nothing between it and the
# pipe. mullvad_exit_candidates ends in `return 0`, which swallows the SIGPIPE
# death of its own while-loop -- so the exit half of that mutation survives, and
# for the same reason no early-exit consumer of THAT function is at risk.
mullvad_pair_ok "$J" "$S" nl "" bg-sof-wg-001 nl-ams-wg-001 \
  || note "a legal pin whose entry is the first candidate in the list must still be reused"

# 200 bg entries and 200 nl exits, so the pinned entry (bg-sof-wg-001) and the
# pinned exit (nl-ams-wg-001) are each FIRST in their own sorted list and an
# early-exiting consumer stops as early as it possibly can. The exit configs are
# empty files on purpose: candidacy is an `-r` test and nothing here reads them.
BIGJ="${tmp}/big.json"
BIGS="${tmp}/big-secrets"
mkdir -p "$BIGS"
{
  printf '['
  sep=""
  i=1
  while [[ "$i" -le 200 ]]; do
    n="$(printf '%03d' "$i")"
    printf '%s\n {"hostname":"bg-sof-wg-%s","active":true,"ipv4_addr_in":"10.1.0.1","multihop_port":%d,"country_code":"bg","city_code":"sof"}' \
      "$sep" "$n" "$((3000 + i))"
    sep=","
    i=$((i + 1))
  done
  i=1
  while [[ "$i" -le 200 ]]; do
    n="$(printf '%03d' "$i")"
    printf '%s\n {"hostname":"nl-ams-wg-%s","active":true,"ipv4_addr_in":"10.2.0.1","multihop_port":%d,"country_code":"nl","city_code":"ams"}' \
      "$sep" "$n" "$((4000 + i))"
    : > "${BIGS}/nl-ams-wg-${n}.conf"
    i=$((i + 1))
  done
  printf '\n]\n'
} > "$BIGJ"

# Assert the fixture's two load-bearing properties before using it, or this case
# silently degrades into the small one it exists to replace. Both lists are
# CAPTURED rather than piped into `head`: piping them into an early-exit consumer
# is the very thing under test, and doing it here would abort the suite under
# pipefail instead of testing anything.
bigentries="$(mullvad_entry_candidates "$BIGJ" "")"
bigexits="$(mullvad_exit_candidates "$BIGJ" "$BIGS" nl)"
[[ "${#bigentries}" -gt 1024 ]] \
  || note "the entry candidate list must exceed one stdio flush (1 KB) or the SIGPIPE this case exists for cannot happen (got ${#bigentries} bytes)"
[[ "${bigentries%%$'\n'*}" == "bg-sof-wg-001" ]] \
  || note "the pinned entry must be the FIRST sorted entry candidate (got '${bigentries%%$'\n'*}')"
[[ "${bigexits%%$'\n'*}" == "nl-ams-wg-001" ]] \
  || note "the pinned exit must be the FIRST sorted exit candidate (got '${bigexits%%$'\n'*}')"

mullvad_pair_ok "$BIGJ" "$BIGS" nl "" bg-sof-wg-001 nl-ams-wg-001 \
  || note "a legal pin must be reused against a 400-relay list too: piping the candidate list into an early-exit consumer kills the producer with SIGPIPE and pipefail reports a still-legal pin as illegal, which moves the tunnel's country on a run where nothing changed"

echo "the pin's mode:"
# No key material in it, but it names the country the operator chose. Written
# create-chmod-write like mullvad_render_to, and checked under a deliberately
# loose umask so a missing chmod cannot pass by accident of the ambient one.
PIN_MODE="${tmp}/chosen-umask"
rm -f "$PIN_MODE"
( umask 022; mullvad_resolve_pair "$J" "$S" bg "" "$PIN_MODE" >/dev/null )
[[ "$(stat -f '%Lp' "$PIN_MODE")" == "600" ]] \
  || note "the pin must be mode 600 regardless of umask (got '$(stat -f '%Lp' "$PIN_MODE")')"

echo "mullvad_cache_fresh:"
# A relay cache is never 0 bytes on a real machine (mullvad_load_relays only
# ever mv's a JSON-validated file into place), but the check itself must not
# rely on that: it has to say "not fresh" for a 0-byte file on its own, since
# that is exactly the shape an interrupted mv or a full disk leaves behind.
# So the fixtures here are valid JSON, not `touch`ed placeholders -- a fixture
# that cannot occur in reality would let a content-blind check (-e) pass this
# test for the wrong reason.
cat > "${tmp}/fresh.json" <<'EOF'
[{"hostname":"se-sto-wg-001","active":true,"ipv4_addr_in":"185.213.154.70","multihop_port":3301,"country_code":"se","city_code":"sto"}]
EOF
mullvad_cache_fresh "${tmp}/fresh.json" 7 || note "a just-written cache must be fresh"
mullvad_cache_fresh "${tmp}/missing.json" 7 && note "a missing cache must not be fresh"
# 8 days old against a 7-day limit.
cp "${tmp}/fresh.json" "${tmp}/old.json"
touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" "${tmp}/old.json"
mullvad_cache_fresh "${tmp}/old.json" 7 && note "an 8-day-old cache must not be fresh against a 7-day limit"
# A 0-byte file must never read as fresh, whatever its mtime: this is the
# exact shape an interrupted mv or ENOSPC leaves behind, and a stale-but-
# nonempty cache must still self-heal via mullvad_load_relays' own validity
# check rather than this mtime-only predicate silently vouching for content.
: > "${tmp}/empty.json"
mullvad_cache_fresh "${tmp}/empty.json" 7 && note "a 0-byte cache must never read as fresh"

echo "mullvad_load_relays:"
# Stub the network fetch so these tests never touch the real API.
# _mullvad_fetch_relays is the seam mullvad-lib.sh provides for exactly this:
# production always calls it unmodified, tests redefine it after sourcing.
#
# The call counter is a FILE, not a shell variable: the "expect die" cases
# below must run inside a `$(...)` command substitution (die calls `exit`,
# which would kill this whole test script if invoked as a bare statement in
# the current shell), and a command substitution is a subshell -- any plain
# variable a stub increments there is gone the moment it exits. A file write
# is real I/O and survives across that boundary.
calls="${tmp}/fetch-calls"
fetch_call_count() { wc -l < "$calls" 2>/dev/null | tr -d ' '; }

echo "  no cache, fetch fails -> fatal:"
rm -f "$calls"
_mullvad_fetch_relays() { echo x >> "$calls"; return 1; }
if out="$(mullvad_load_relays "${tmp}/no-cache.json" 7 2>&1)"; then
  note "no cache + a failing fetch must be fatal, but mullvad_load_relays returned 0"
else
  [[ "$out" == *"Could not fetch"* ]] \
    || note "the fatal message must say the fetch failed (got '${out}')"
fi
[[ "$(fetch_call_count)" -eq 1 ]] \
  || note "a missing cache must trigger exactly one fetch attempt (got $(fetch_call_count))"
[[ -e "${tmp}/no-cache.json" ]] \
  && note "a failed fetch with no prior cache must not leave a cache file behind"

echo "  stale but valid cache, fetch fails -> warns and continues:"
cat > "${tmp}/stale-valid.json" <<'EOF'
[{"hostname":"se-sto-wg-001","active":true,"ipv4_addr_in":"185.213.154.70","multihop_port":3301,"country_code":"se","city_code":"sto"}]
EOF
touch -t "$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)" "${tmp}/stale-valid.json"
rm -f "$calls"
_mullvad_fetch_relays() { echo x >> "$calls"; return 1; }
if out="$(mullvad_load_relays "${tmp}/stale-valid.json" 7 2>&1)"; then
  [[ "$out" == *"Could not refresh"* ]] \
    || note "a stale cache with a failing refetch must warn that it could not refresh (got '${out}')"
else
  note "a stale-but-valid cache must let the build continue when the refetch fails (mullvad_load_relays died instead)"
fi
[[ "$(fetch_call_count)" -eq 1 ]] \
  || note "a stale cache must still attempt exactly one refetch (got $(fetch_call_count))"
[[ "$(mullvad_relay_field "${tmp}/stale-valid.json" se-sto-wg-001 country_code)" == "se" ]] \
  || note "the stale cache's own content must survive on disk when the refetch fails"

echo "  corrupt cache (fresh by mtime), fetch succeeds -> refetch attempted and used:"
echo 'not json' > "${tmp}/corrupt-fresh.json"
rm -f "$calls"
_mullvad_fetch_relays() {
  echo x >> "$calls"
  cat > "${1:?}" <<'EOF'
[{"hostname":"nl-ams-wg-001","active":true,"ipv4_addr_in":"92.60.40.10","multihop_port":3401,"country_code":"nl","city_code":"ams"}]
EOF
}
mullvad_load_relays "${tmp}/corrupt-fresh.json" 7 >/dev/null 2>&1 \
  || note "a corrupt-but-fresh cache must self-heal via refetch when the fetch succeeds, not fail"
[[ "$(fetch_call_count)" -eq 1 ]] \
  || note "a corrupt cache must trigger exactly one refetch even though it is 'fresh' by mtime (got $(fetch_call_count))"
[[ "$(mullvad_relay_field "${tmp}/corrupt-fresh.json" nl-ams-wg-001 country_code)" == "nl" ]] \
  || note "the refetched content must actually replace the corrupt cache on disk"

echo "  corrupt cache (fresh by mtime), fetch also fails -> fatal:"
echo 'not json' > "${tmp}/corrupt-fresh-2.json"
rm -f "$calls"
_mullvad_fetch_relays() { echo x >> "$calls"; return 1; }
if out="$(mullvad_load_relays "${tmp}/corrupt-fresh-2.json" 7 2>&1)"; then
  note "a corrupt cache must never be trusted just because its mtime is new, even when the refetch also fails"
fi
[[ "$(fetch_call_count)" -eq 1 ]] \
  || note "a corrupt fresh cache must still attempt exactly one fetch before giving up (got $(fetch_call_count))"

echo "mullvad_render_to:"
mullvad_render_to "$J" "$S" se-sto-wg-001 bg-sof-wg-001 "${tmp}/derived.conf"
[[ "$(grep -c '^Endpoint = 185.213.154.70:3225$' "${tmp}/derived.conf")" -eq 1 ]] \
  || note "the derived config must point at the entry ip and the exit multihop port"
# The mode check must not pass by accident of the ambient umask: force a loose
# one around a second render so a missing `chmod 600` in the implementation
# would actually be caught rather than masked by a restrictive umask already
# in effect (e.g. 077, which would leave the file at 600 with no chmod at all).
( umask 022; mullvad_render_to "$J" "$S" se-sto-wg-001 bg-sof-wg-001 "${tmp}/derived-umask.conf" )
[[ "$(stat -f '%Lp' "${tmp}/derived-umask.conf")" == "600" ]] \
  || note "the derived config holds a private key and must be mode 600 regardless of umask"
diff <(grep -v '^Endpoint' "${S}/bg-sof-wg-001.conf") <(grep -v '^Endpoint' "${tmp}/derived.conf") >/dev/null \
  || note "the derived config must differ from the exit's config only in Endpoint"

echo "verify.sh exit-country assertion:"
# This is verify.sh's decision logic, not mullvad-lib.sh's, but it lives here
# because it is the same feature and this is the suite that already has the
# vocabulary for it.
#
# The block is EXTRACTED from scripts/verify.sh between its markers rather than
# copied into this file. A copy would drift: someone weakens the production
# assertion, the copy here still passes, and the suite reports green on exactly
# the check that stopped working. Extracting means a change to the production
# text is a change to what these cases run.
BLOCK="${tmp}/exit-assertion.sh"
awk '/# >>> exit-country assertion/{f=1;next} /# <<< exit-country assertion/{f=0} f' \
  scripts/verify.sh > "$BLOCK"
[[ -s "$BLOCK" ]] \
  || note "could not extract the exit-country assertion from scripts/verify.sh -- did the >>> / <<< markers move?"
grep -q 'MULLVAD_PIN_FILE' "$BLOCK" \
  || note "the assertion must locate the pin via \$MULLVAD_PIN_FILE; a second hardcoded path would let a rename switch the whole check off unnoticed"

# Run the extracted block with the four inputs it actually branches on, under
# the same `set -euo pipefail` verify.sh runs with (so a block that aborts on a
# missing pin is caught here rather than in production). ok/note_fail/log are
# stubbed to a flat transcript; the last line is the failure count.
#
# MULLVAD_PIN_FILE is repointed into $tmp: this test must never read or write
# the operator's real generated/mullvad-exit.chosen.
run_exit_assertion() {
  local host="$1" mx="$2" pin="$3"
  (
    fails=0
    short="workstation"
    exit_host="$host"
    MULLVAD_EXIT="$mx"
    MULLVAD_PIN_FILE="${tmp}/verify-pin"
    rm -f "$MULLVAD_PIN_FILE"
    if [[ "$pin" != "__nopin__" ]]; then printf '%s' "$pin" > "$MULLVAD_PIN_FILE"; fi
    ok()        { printf 'OK %s\n' "$*"; }
    note_fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
    log()       { printf 'LOG %s\n' "$*"; }
    # shellcheck disable=SC1090
    source "$BLOCK"
    printf 'fails=%d\n' "$fails"
  )
}

GOODPIN=$'jp-osa-wg-103 bg-sof-wg-001\n'

# 1. The observed exit is the pinned one: the only case that may pass.
out="$(run_exit_assertion bg-sof-wg-001 bg "$GOODPIN")"
[[ "$out" == *"fails=0"* ]] || note "a matching exit must not fail (got '${out}')"
[[ "$out" == *"exit that was selected (bg-sof-wg-001)"* ]] \
  || note "a matching exit must say so explicitly (got '${out}')"

# 2. The tunnel is in a country the operator did not choose. This is the whole
# reason the assertion exists, and it must name BOTH hostnames so the message
# says what happened rather than that something is wrong.
out="$(run_exit_assertion nl-ams-wg-001 bg "$GOODPIN")"
[[ "$out" == *"fails=1"* ]] \
  || note "an exit that differs from the pinned one MUST fail (got '${out}')"
[[ "$out" == *"nl-ams-wg-001"* && "$out" == *"bg-sof-wg-001"* ]] \
  || note "the mismatch message must name both the observed and the selected exit (got '${out}')"

# 3-5. MULLVAD_EXIT is set, so a country WAS chosen, but the pin cannot answer
# whether it was honoured. Missing, empty and truncated pins are all "could not
# tell", and this suite's rule is that could-not-tell is a failure. A silent
# skip here is the failure mode that matters: delete the pin and an otherwise
# green run would stop checking the country without saying a word.
for case_name in missing empty truncated; do
  case "$case_name" in
    missing)   pin="__nopin__" ;;
    empty)     pin="" ;;
    truncated) pin=$'jp-osa-wg-103\n' ;;
  esac
  out="$(run_exit_assertion bg-sof-wg-001 bg "$pin")"
  [[ "$out" == *"fails=1"* ]] \
    || note "a ${case_name} pin with MULLVAD_EXIT set must FAIL, not silently skip the country check (got '${out}')"
  [[ "$out" == *"MULLVAD_EXIT="* ]] \
    || note "the ${case_name}-pin failure must say the operator asked for a specific exit (got '${out}')"
done

# 6. Mullvad confirmed an exit but named no hostname: comparable to nothing.
out="$(run_exit_assertion "" bg "$GOODPIN")"
[[ "$out" == *"fails=1"* ]] \
  || note "an unreadable exit hostname must fail rather than pass by omission (got '${out}')"

# 7. Not applicable, and said out loud. A MULLVAD_WG_CONFIG lab is correct even
# with a pin left behind by an earlier MULLVAD_EXIT lab -- only `make destroy`
# clears it -- so applying that pin would fail a good lab while naming a country
# nobody asked for. It must be ignored, and the transcript must still show the
# check was considered: an absent line and a disabled check look identical.
out="$(run_exit_assertion nl-ams-wg-001 "" "$GOODPIN")"
[[ "$out" == *"fails=0"* ]] \
  || note "a stale pin must not fail a MULLVAD_WG_CONFIG lab (got '${out}')"
[[ "$out" == *"does not apply"* ]] \
  || note "a lab with no MULLVAD_EXIT must SAY the country check does not apply, not skip in silence (got '${out}')"

# 8. Same, with no pin at all: the ordinary MULLVAD_WG_CONFIG case.
out="$(run_exit_assertion nl-ams-wg-001 "" "__nopin__")"
[[ "$out" == *"fails=0"* && "$out" == *"does not apply"* ]] \
  || note "a MULLVAD_WG_CONFIG lab with no pin must pass and say the check does not apply (got '${out}')"

# 9. The tunnel matches the PIN exactly, and the pin no longer matches .env.
# This is what "edit MULLVAD_EXIT, then run make verify to see where I am"
# produces, and it is the one case where every hostname comparison agrees while
# the lab is not in the country .env names. Nothing here re-resolves, so the
# spec has to be checked against the pin explicitly or it is never checked at
# all.
out="$(run_exit_assertion bg-sof-wg-001 nl "$GOODPIN")"
[[ "$out" == *"fails=1"* ]] \
  || note "a pin that no longer satisfies MULLVAD_EXIT must FAIL even when the tunnel matches it exactly (got '${out}')"
[[ "$out" == *"MULLVAD_EXIT='nl'"* && "$out" == *"bg-sof-wg-001"* ]] \
  || note "the stale-pin failure must name the spec asked for AND what is actually pinned/observed (got '${out}')"

# 10. Same rule as the selection, so a prefix on a dash boundary is honoured:
# 'bg-sof' chose bg-sof-wg-001 and must still verify it.
out="$(run_exit_assertion bg-sof-wg-001 bg-sof "$GOODPIN")"
[[ "$out" == *"fails=0"* ]] \
  || note "a pin that satisfies a city-level MULLVAD_EXIT must still pass (got '${out}')"

# 11. ...and a prefix that is NOT on a dash boundary is a different place:
# 'bg-sof' never selected bg-sofia-wg-001, so verifying it as if it had is the
# same wrong-jurisdiction bug the selection rule exists to prevent. A bare
# startswith matcher passes this; the shared one does not.
out="$(run_exit_assertion bg-sofia-wg-001 bg-sof $'x bg-sofia-wg-001\n')"
[[ "$out" == *"fails=1"* ]] \
  || note "MULLVAD_EXIT='bg-sof' must not accept a pinned bg-sofia-* exit (got '${out}')"

[[ "$fail" -eq 0 ]] && echo "mullvad-select: OK"
exit "$fail"
