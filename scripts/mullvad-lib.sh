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

# Print the exit server's config with ONLY the Endpoint line replaced.
#
# The count is checked BEFORE anything is printed. Emitting a partial config and
# then returning non-zero would leave a caller that forgot to check with a file
# that looks plausible and points at the wrong server.
mullvad_rewrite_endpoint() {
  local conf="${1:?config path required}" ip="${2:?entry ip required}" port="${3:?exit port required}" n line
  n="$(grep -c -E '^[[:space:]]*Endpoint[[:space:]]*=' "$conf" || true)"
  [[ "${n:-0}" -eq 1 ]] \
    || { echo "${conf}: expected exactly 1 Endpoint line, found ${n:-0}." >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*Endpoint[[:space:]]*= ]]; then
      printf 'Endpoint = %s:%s\n' "$ip" "$port"
    else
      printf '%s\n' "$line"
    fi
  done < "$conf"
}

# The exit server's multihop_port IS the endpoint port. Separate function so the
# name says why a port from the relay table ends up in an Endpoint line.
mullvad_endpoint_port_for() {
  mullvad_relay_field "${1:?relay json required}" "${2:?exit hostname required}" multihop_port
}

# Return 0 if <entry>/<exit> is genuine multihop, else print ONE specific reason
# to stderr and return 1.
#
# The operator's requirement is "always multihop", so single-hop has to be
# unreachable rather than discouraged -- the same reasoning that keeps
# net.ipv4.ip_forward at 0 on disk. Each message names both servers so it says
# what to change instead of that something is invalid.
mullvad_assert_multihop() {
  local json="${1:?relay json required}" entry="${2:?entry hostname required}" exit_h="${3:?exit hostname required}"
  local ec xc port
  [[ "$entry" != "$exit_h" ]] \
    || { echo "entry and exit are both ${entry}: that is a single hop, not multihop." >&2; return 1; }
  ec="$(mullvad_relay_field "$json" "$entry" country_code)"
  xc="$(mullvad_relay_field "$json" "$exit_h" country_code)"
  [[ -n "$ec" ]] || { echo "entry ${entry} is not in the relay list." >&2; return 1; }
  [[ -n "$xc" ]] || { echo "exit ${exit_h} is not in the relay list." >&2; return 1; }
  [[ "$ec" != "$xc" ]] \
    || { echo "entry ${entry} and exit ${exit_h} are both in '${ec}'. Multihop through one jurisdiction buys nothing; set MULLVAD_ENTRY to another country." >&2; return 1; }
  port="$(mullvad_endpoint_port_for "$json" "$exit_h")"
  [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] \
    || { echo "exit ${exit_h} has no usable multihop_port in the relay list." >&2; return 1; }
  [[ "$port" != "$MULLVAD_SINGLEHOP_PORT" ]] \
    || { echo "exit ${exit_h} resolves to port ${MULLVAD_SINGLEHOP_PORT}, which is single-hop. Refusing to build." >&2; return 1; }
  return 0
}
