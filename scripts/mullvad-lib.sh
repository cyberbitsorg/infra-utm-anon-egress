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

# Exit candidates are relays that match the spec AND have a config on disk: the
# rewrite needs the exit's own keys, so a relay we have no config for cannot be
# an exit no matter how well its name matches.
mullvad_exit_candidates() {
  local json="${1:?}" secrets_dir="${2:?}" spec="${3:?}" h
  mullvad_relay_match "$json" "$spec" | while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    [[ -r "${secrets_dir}/${h}.conf" ]] && printf '%s\n' "$h"
  done
  return 0
}

# Entry candidates need NO config on disk: only the entry's ipv4_addr_in is used,
# and that comes from the relay table. An empty spec means "anywhere", which
# mullvad_relay_match handles directly.
mullvad_entry_candidates() {
  mullvad_relay_match "${1:?relay json required}" "${2-}"
}

# Is this exact pair still legal under the current .env? Silent by design: it is
# a predicate used to decide whether to keep a pin, not a validator whose reasons
# the operator needs to read.
mullvad_pair_ok() {
  local json="${1:?}" secrets_dir="${2:?}" exit_spec="${3:?}" entry_spec="${4:-}" entry="${5:?}" exit_h="${6:?}"
  mullvad_exit_candidates "$json" "$secrets_dir" "$exit_spec" | grep -qx "$exit_h" || return 1
  mullvad_entry_candidates "$json" "$entry_spec" | grep -qx "$entry" || return 1
  mullvad_assert_multihop "$json" "$entry" "$exit_h" >/dev/null 2>&1 || return 1
  return 0
}

# Resolve an entry/exit pair, reusing a previous choice when it is still legal.
#
# The pin exists so `make configure` cannot silently move the tunnel to another
# country between runs, while `make destroy` (which removes generated/) still
# gives a fresh pair per lab lifecycle. It stores hostnames only -- never key
# material -- so it is safe to leave on disk.
mullvad_resolve_pair() {
  local json="${1:?}" secrets_dir="${2:?}" exit_spec="${3:?}" entry_spec="${4:-}" pin="${5:?}"
  local entry exit_h exit_cc n_exit

  if [[ -f "$pin" ]]; then
    entry=""; exit_h=""
    read -r entry exit_h < "$pin" || true
    if [[ -n "$entry" && -n "$exit_h" ]] \
       && mullvad_pair_ok "$json" "$secrets_dir" "$exit_spec" "$entry_spec" "$entry" "$exit_h"; then
      printf '%s %s\n' "$entry" "$exit_h"
      return 0
    fi
  fi

  exit_h="$(mullvad_exit_candidates "$json" "$secrets_dir" "$exit_spec" | mullvad_pick_random)" || {
    n_exit="$(mullvad_relay_match "$json" "$exit_spec" | grep -c . || true)"
    echo "No exit server matches MULLVAD_EXIT='${exit_spec}' with a config in ${secrets_dir}. The relay list has ${n_exit:-0} active server(s) matching that name; download their configs from Mullvad, or pick a country you have." >&2
    return 1
  }

  exit_cc="$(mullvad_relay_field "$json" "$exit_h" country_code)"
  [[ -n "$exit_cc" ]] || { echo "exit ${exit_h} has no country_code in the relay list." >&2; return 1; }

  # The entry must be in a different country: that is the whole point of the
  # second hop, so it is filtered here rather than checked afterwards.
  entry="$(mullvad_entry_candidates "$json" "$entry_spec" \
           | while IFS= read -r h; do
               [[ -n "$h" ]] || continue
               [[ "$(mullvad_relay_field "$json" "$h" country_code)" != "$exit_cc" ]] && printf '%s\n' "$h"
             done \
           | mullvad_pick_random)" || {
    echo "No entry server matches MULLVAD_ENTRY='${entry_spec}' outside the exit's country '${exit_cc}'. Leave MULLVAD_ENTRY empty for any country, or name a different one." >&2
    return 1
  }

  mullvad_assert_multihop "$json" "$entry" "$exit_h" || return 1

  printf '%s %s\n' "$entry" "$exit_h" > "$pin"
  chmod 600 "$pin" 2>/dev/null || true
  printf '%s %s\n' "$entry" "$exit_h"
}

MULLVAD_RELAY_CACHE="${GEN_DIR}/mullvad-relays.json"
MULLVAD_PIN_FILE="${GEN_DIR}/mullvad-exit.chosen"
MULLVAD_CACHE_MAX_AGE_DAYS=7

# True if <cache> exists and is younger than <days>. `find -mtime +N` counts
# whole 24-hour periods, which is exactly the granularity wanted here.
mullvad_cache_fresh() {
  local cache="${1:?}" days="${2:?}"
  # -e, not -s: this is an mtime freshness check, not a content check. A cache
  # only ever reaches disk via mullvad_load_relays' own mv below, which already
  # requires the JSON to parse as a non-empty list -- an empty file cannot occur
  # there. Using -s here would make a just-created (0-byte) cache read as
  # "not fresh", which is only reachable in a test fixture, but wrong all the same.
  [[ -e "$cache" ]] || return 1
  [[ -z "$(find "$cache" -mtime +"$days" -print 2>/dev/null)" ]]
}

# Make sure the relay cache is present and parseable.
#
# The fetch happens on the HOST, over the operator's real connection, before the
# lab exists -- there is no tunnel to use yet. It is a public unauthenticated
# endpoint every Mullvad user queries, and the 7-day cache keeps it rare, but it
# is real-IP traffic and the README says so.
#
# A stale cache is used with a visible warning; NO cache and no network is fatal.
# Guessing a multihop port would produce a tunnel that silently exits somewhere
# the operator did not choose, which is worse than not building.
mullvad_load_relays() {
  local cache="${1:-$MULLVAD_RELAY_CACHE}" days="${2:-$MULLVAD_CACHE_MAX_AGE_DAYS}" tmpf
  if mullvad_cache_fresh "$cache" "$days"; then
    log "Using cached Mullvad relay list ($(basename "$cache"))"
    return 0
  fi
  mkdir -p "$(dirname "$cache")"
  tmpf="$(mktemp)"
  log "Fetching the Mullvad relay list (public API, over your real IP)"
  if curl -fsS --max-time 30 "$MULLVAD_RELAY_URL" -o "$tmpf" 2>/dev/null \
     && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d,list) and d else 1)' "$tmpf"; then
    mv "$tmpf" "$cache"
    ok "Relay list cached ($(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$cache") relays)"
    return 0
  fi
  rm -f "$tmpf"
  [[ -s "$cache" ]] \
    || die "Could not fetch ${MULLVAD_RELAY_URL} and no cached relay list exists at ${cache}. The exit's multihop port comes from that list and must not be guessed."
  warn "Could not refresh the relay list; using the cached copy from $(date -r "$cache" '+%Y-%m-%d %H:%M')."
}

# Write the derived multihop config to <dest> at mode 0600.
#
# Created empty and chmodded BEFORE any content is written: the file holds the
# exit server's private key, and a window where it exists at the default umask
# is a window where another local user can read it.
mullvad_render_to() {
  local json="${1:?}" secrets_dir="${2:?}" entry="${3:?}" exit_h="${4:?}" dest="${5:?}"
  local entry_ip exit_port src
  src="${secrets_dir}/${exit_h}.conf"
  [[ -r "$src" ]] || { echo "no config for exit ${exit_h} at ${src}" >&2; return 1; }
  entry_ip="$(mullvad_relay_field "$json" "$entry" ipv4_addr_in)"
  [[ "$entry_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "entry ${entry} has no IPv4 address in the relay list (got '${entry_ip}'). The endpoint must be an IP: resolving a name would need clear-net DNS before the tunnel exists." >&2; return 1; }
  exit_port="$(mullvad_endpoint_port_for "$json" "$exit_h")"
  [[ "$exit_port" =~ ^[0-9]+$ ]] \
    || { echo "exit ${exit_h} has no numeric multihop_port." >&2; return 1; }
  : > "$dest"
  chmod 600 "$dest"
  mullvad_rewrite_endpoint "$src" "$entry_ip" "$exit_port" > "$dest"
}
