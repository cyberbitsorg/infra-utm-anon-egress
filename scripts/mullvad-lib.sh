#!/usr/bin/env bash
# Mullvad relay selection: turn a country code in .env into a concrete
# entry/exit server pair and a WireGuard config that uses them.
# Sourced, not run.
#
# WHY THIS EXISTS. A Mullvad multihop config is the EXIT server's own config
# with exactly one line changed:
#
#   Endpoint = <ENTRY server ipv4_addr_in>:<EXIT server multihop_port>
#
# Keys, Address, AllowedIPs and PublicKey all stay the exit's. The gateway
# connects to the entry; the port selects the exit. Verified against a working
# hand-made config: bg-sof-wg-001 (multihop_port 3225) reached through
# se-got-wg-001 (185.213.154.66) produced Endpoint 185.213.154.66:3225.
#
# Every config Mullvad's generator emits is SINGLE-hop (port 51820). Building on
# one unchanged silently downgrades the design, which is why
# mullvad_assert_multihop treats port 51820 as a hard failure rather than a note.

MULLVAD_RELAY_URL="https://api.mullvad.net/www/relays/wireguard/"
MULLVAD_SINGLEHOP_PORT="51820"

# Print every ACTIVE hostname matching <spec>, one per line, sorted.
#
# Matching is prefix-on-a-dash-boundary, never a bare substring: "se" must not
# match "se2-sto-wg-001" (a different country's numbering) and "bg-sof" must not
# match "bg-sofia-wg-001". A plain `startswith(spec)` gets both wrong and would
# put the operator in a country they did not choose.
#
# An EMPTY spec means "every active relay", which is what an unset MULLVAD_ENTRY
# asks for. Note this is a real special case, not a fallthrough: the dash-boundary
# rule applied to "" would test `startswith("-")` and match nothing at all, so an
# operator who left MULLVAD_ENTRY blank would get "no entry server matches ''"
# instead of a free choice.
mullvad_relay_match() {
  local json="${1:?relay json required}" spec="${2-}"
  python3 - "$json" "$spec" <<'PY'
import json, sys
path, spec = sys.argv[1], sys.argv[2]
with open(path) as fh:
    relays = json.load(fh)
out = [r["hostname"] for r in relays
       if r.get("active")
       and isinstance(r.get("hostname"), str)
       and (spec == ""
            or r["hostname"] == spec
            or r["hostname"].startswith(spec + "-"))]
# Guard against printing a bare blank line when nothing matches: print("")
# still emits a trailing newline, and a caller piping through `tr '\n' ' '`
# (as the test harness does) would see a single space instead of empty
# output, breaking the "-z" check for "no match".
if out:
    print("\n".join(sorted(out)))
PY
}

# Print one field of one relay, or nothing if the relay or field is absent.
# Callers MUST treat empty as "unknown" and fail; a missing multihop_port that
# defaulted to something would be a silently wrong tunnel.
mullvad_relay_field() {
  local json="${1:?relay json required}" host="${2:?hostname required}" field="${3:?field required}"
  python3 - "$json" "$host" "$field" <<'PY'
import json, sys
path, host, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh:
    relays = json.load(fh)
for r in relays:
    if r.get("hostname") == host:
        v = r.get(field)
        if v is not None:
            print(v)
        break
PY
}

# Read lines on stdin, print exactly one at random. Returns 1 on empty input so
# callers can distinguish "nothing matched" from "picked an empty string".
#
# $RANDOM is 0..32767 against at most a few hundred candidates, so the modulo
# bias is real but irrelevant here: this picks a server for unlinkability across
# builds, not a cryptographic secret.
mullvad_pick_random() {
  local lines n idx
  lines="$(cat)"
  [[ -n "$lines" ]] || return 1
  n="$(printf '%s\n' "$lines" | grep -c . || true)"
  [[ "${n:-0}" -ge 1 ]] || return 1
  idx=$(( (RANDOM % n) + 1 ))
  printf '%s\n' "$lines" | grep . | sed -n "${idx}p"
}
