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

[[ "$fail" -eq 0 ]] && echo "mullvad-select: OK"
exit "$fail"
