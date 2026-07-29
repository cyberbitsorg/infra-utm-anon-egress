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

# Does <hostname> belong to <spec>?
#
# Matching is prefix-on-a-dash-boundary, never a bare substring: "se" must not
# match "se2-sto-wg-001" (a different country's numbering) and "bg-sof" must not
# match "bg-sofia-wg-001". A plain `startswith(spec)` gets both wrong and would
# put the operator in a country they did not choose.
#
# An EMPTY spec means "every relay", which is what an unset MULLVAD_ENTRY asks
# for. Note this is a real special case, not a fallthrough: the dash-boundary
# rule applied to "" would test `startswith("-")` and match nothing at all, so an
# operator who left MULLVAD_ENTRY blank would get "no entry server matches ''"
# instead of a free choice.
#
# THE definition of the rule, deliberately in one place. mullvad_relay_match
# filters the relay list with it and verify.sh checks the pinned exit against
# .env with it: selection and verification asking the same question two
# different ways is how a lab ends up green in a country nobody chose.
mullvad_spec_matches() {
  local spec="${1-}" host="${2-}"
  [[ -n "$spec" ]] || return 0
  case "$host" in
    "$spec"|"$spec"-*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The derived lookup table.
#
# mullvad_relay_match and mullvad_relay_field used to parse the relay JSON in a
# fresh python3 each time they were called. The entry pre-filter asks for one
# country_code per candidate, so with MULLVAD_ENTRY empty a single resolution
# against the live 539-relay list cost 540 interpreter spawns and ~26 s inside
# `make up`. The JSON is therefore parsed ONCE into a flat table that awk and
# the shell can read directly.
#
# The table is a cache and must never be able to answer for a relay list it was
# not built from: its first line stamps the size and mtime (sub-second where
# stat provides it) of the JSON, and any difference rebuilds. That covers the
# case that actually happens -- mullvad_load_relays mv'ing a refetched list over
# the cache mid-run -- without hashing 500 KB on every lookup.
#
# It is written next to the JSON (`<json>.tbl`), which needs no fallback: the
# only relay list this repo reads is the one mullvad_load_relays put there, so a
# directory it cannot write is a build that already died. `make destroy` removes
# GEN_DIR wholesale, table included, and `generated/` is gitignored.
#
# Format, one record per line, tab-separated:
#   H<TAB><hostname>                     every ACTIVE relay, sorted
#   F<TAB><hostname><TAB><key><TAB><value>   fields of the FIRST relay with
#                                            that hostname
# "First" matches the `break` the per-call parse did, so a duplicated hostname
# still answers from the same record it always did. A value containing a newline
# is omitted rather than written, because it would forge a record; that reads
# back as "unknown", which every caller already treats as fatal.
# ---------------------------------------------------------------------------

_mullvad_stamp() {
  stat -f '%z %Fm' "${1:?}" 2>/dev/null || stat -c '%s %.9Y' "${1:?}" 2>/dev/null
}

_mullvad_build_table() {
  python3 - "${1:?}" "${2:?}" "${3:?}" <<'PY'
import json, sys
src, dest, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh:
    relays = json.load(fh)
hosts, seen, fields = [], set(), []
for r in relays:
    h = r.get("hostname")
    if not isinstance(h, str):
        continue
    if r.get("active"):
        hosts.append(h)
    if h in seen:
        continue
    seen.add(h)
    for k, v in r.items():
        if v is None:
            continue
        s = str(v)
        if "\n" in s or "\n" in k or "\t" in k:
            continue
        fields.append("F\t%s\t%s\t%s\n" % (h, k, s))
with open(dest, "w") as fh:
    fh.write(stamp + "\n")
    for h in sorted(hosts):
        fh.write("H\t%s\n" % h)
    fh.writelines(fields)
PY
}

# Print the path of an up-to-date table for <json>, building it if needed.
# Returns 1 (having printed nothing) when the JSON cannot be parsed, exactly as
# the per-call parse did, so callers keep seeing empty output for a list they
# cannot trust.
_mullvad_table() {
  local json="${1:?relay json required}" tbl stamp hdr tmp
  tbl="${json}.tbl"
  stamp="# $(_mullvad_stamp "$json" || true)"
  if [[ -s "$tbl" ]]; then
    hdr=""
    IFS= read -r hdr < "$tbl" || true
    if [[ "$hdr" == "$stamp" ]]; then
      printf '%s\n' "$tbl"
      return 0
    fi
  fi
  tmp="${tbl}.$$.${RANDOM}"
  if _mullvad_build_table "$json" "$tmp" "$stamp" && mv -f "$tmp" "$tbl"; then
    printf '%s\n' "$tbl"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Print every ACTIVE hostname matching <spec>, one per line, sorted.
#
# Nothing is printed when nothing matches -- not a blank line. A caller piping
# through `tr '\n' ' '` (as the test harness does) would see a single space
# instead of empty output and its "-z" check for "no match" would stop working.
#
# The matches are collected and written ONCE, as the python this replaced did.
# A line-at-a-time loop would take SIGPIPE from any consumer that stops early
# (`grep -q`, `head`) and, under `set -o pipefail`, hand that failure to the
# caller as "no match".
mullvad_relay_match() {
  local json="${1:?relay json required}" spec="${2-}" tbl h out=""
  tbl="$(_mullvad_table "$json")" || return 1
  while IFS= read -r h; do
    mullvad_spec_matches "$spec" "$h" && out="${out}${h}
"
  done < <(awk 'substr($0,1,2)=="H\t"{print substr($0,3)}' "$tbl")
  [[ -z "$out" ]] || printf '%s' "$out"
  return 0
}

# Print one field of one relay, or nothing if the relay or field is absent.
# Callers MUST treat empty as "unknown" and fail; a missing multihop_port that
# defaulted to something would be a silently wrong tunnel.
#
# The lookup is prefix-anchored on the whole record rather than split into awk
# fields, so a value that itself contains a tab comes back whole.
# host/field arrive through the environment, not `-v`, which would run backslash
# escape processing over them.
mullvad_relay_field() {
  local json="${1:?relay json required}" host="${2:?hostname required}" field="${3:?field required}" tbl
  tbl="$(_mullvad_table "$json")" || return 1
  _MV_HOST="$host" _MV_FIELD="$field" awk '
    BEGIN { pfx = "F\t" ENVIRON["_MV_HOST"] "\t" ENVIRON["_MV_FIELD"] "\t"; n = length(pfx) }
    substr($0, 1, n) == pfx { print substr($0, n + 1); exit }
  ' "$tbl"
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

# Entry candidates that are NOT in <country_code>. The second hop only buys
# anything in another jurisdiction, so the pool is filtered here rather than the
# draw checked afterwards.
#
# A function ending in an explicit `return 0`, exactly like
# mullvad_exit_candidates and for exactly the same reason: a `while` loop
# reports the status of its LAST iteration, so a final candidate that IS in the
# exit's country makes the loop return 1. Inline in a pipeline under
# `set -o pipefail` that failed the whole command substitution even though a
# legal entry had already been chosen and printed, and told the operator no
# entry existed -- for every exit whose country sorts last in the relay list
# (`za` against the live list, while 537 legal entries sat in it). The status of
# this filter is a property of the filter, never of whichever relay happened to
# be examined last.
mullvad_entries_outside_country() {
  local json="${1:?}" spec="${2-}" exclude_cc="${3:?}" h
  mullvad_entry_candidates "$json" "$spec" | while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    [[ "$(mullvad_relay_field "$json" "$h" country_code)" != "$exclude_cc" ]] && printf '%s\n' "$h"
  done
  return 0
}

# Is <needle> one of the newline-separated lines of <haystack>? Exact string
# equality, because a pin is data and never a pattern: `grep -qx` would read a
# corrupted pin as a basic regular expression and could match a candidate it
# does not name.
#
# Deliberately NOT `producer | grep -qxF "$needle"`, which is the obvious
# spelling and is wrong here for a second reason: `grep -q` exits at the FIRST
# match, the producer takes SIGPIPE on its next write, and under
# `set -o pipefail` that becomes the pipeline's status -- so whether a
# still-legal pin was reused came down to where in the candidate list it
# happened to sort and whether grep had drained the pipe first. Nothing
# streams, nothing exits early, nothing depends on timing.
_mullvad_list_has() {
  local haystack="${1-}" needle="${2-}" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<MULLVAD_LIST
${haystack}
MULLVAD_LIST
  return 1
}

# Is this exact pair still legal under the current .env? Silent by design: it is
# a predicate used to decide whether to keep a pin, not a validator whose reasons
# the operator needs to read.
mullvad_pair_ok() {
  local json="${1:?}" secrets_dir="${2:?}" exit_spec="${3:?}" entry_spec="${4:-}" entry="${5:?}" exit_h="${6:?}"
  local exits entries
  exits="$(mullvad_exit_candidates "$json" "$secrets_dir" "$exit_spec")" || return 1
  _mullvad_list_has "$exits" "$exit_h" || return 1
  entries="$(mullvad_entry_candidates "$json" "$entry_spec")" || return 1
  _mullvad_list_has "$entries" "$entry" || return 1
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
  entry="$(mullvad_entries_outside_country "$json" "$entry_spec" "$exit_cc" \
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

# True if <cache> exists, is non-empty, and is younger than <days>. `find
# -mtime +N` counts whole 24-hour periods, which is exactly the granularity
# wanted here.
#
# -s, not -e: this is reachable with a 0-byte file whenever something failed
# partway through writing it -- an interrupted `mv`, ENOSPC, a `mv` across
# filesystems when TMPDIR and the cache live on different volumes. A 0-byte
# file must never read as "fresh"; the whole point of this check is deciding
# whether the content on disk can be trusted, and mtime alone says nothing
# about that.
mullvad_cache_fresh() {
  local cache="${1:?}" days="${2:?}"
  [[ -s "$cache" ]] || return 1
  [[ -z "$(find "$cache" -mtime +"$days" -print 2>/dev/null)" ]]
}

# True if <file> parses as Mullvad's relay list shape: a non-empty JSON array.
# Every path a relay cache can reach -- a fresh fetch, a cache we're about to
# reuse, a stale cache we're about to fall back to -- runs through the same
# check, so "corrupt" means the same thing everywhere: a truncated copy, a
# 0-byte file, or content carried over from another machine all fail the same
# way instead of three different ones. Exceptions are caught rather than left
# to propagate, so a bad file produces a clean 1, not a Python traceback on
# the operator's terminal.
_mullvad_relays_valid() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, list) and d else 1)
' "${1:?}" 2>/dev/null
}

# Fetch the raw relay list into <dest>. Split out from mullvad_load_relays so
# tests can redefine this one function after sourcing the library and drive
# every path -- fetch succeeds, fails, times out -- without a real network
# request; production never overrides it, so `make preflight` always hits the
# real API here.
#
# curl's own stderr is NOT redirected: -fsS still prints curl's error line
# (a captive portal, a TLS-intercepting proxy, DNS failure) on failure, and
# throwing that away would leave the operator with only "could not fetch",
# no clue which of those it was.
_mullvad_fetch_relays() {
  curl -fsS --max-time 30 "$MULLVAD_RELAY_URL" -o "${1:?}"
}

# Make sure the relay cache is present and parseable.
#
# The fetch happens on the HOST, over the operator's real connection, before the
# lab exists -- there is no tunnel to use yet. It is a public unauthenticated
# endpoint every Mullvad user queries, and the 7-day cache keeps it rare, but it
# is real-IP traffic and the README says so.
#
# A cache is only ever trusted after it parses -- fresh or stale, on disk or
# just fetched. A cache that fails that check is treated exactly like a
# missing one: refetch, and if the refetch also fails, that's fatal. Guessing
# a multihop port, or silently building against a corrupt relay list, would
# produce a tunnel that exits somewhere the operator did not choose, which is
# worse than not building.
mullvad_load_relays() {
  local cache="${1:-$MULLVAD_RELAY_CACHE}" days="${2:-$MULLVAD_CACHE_MAX_AGE_DAYS}" tmpf
  if mullvad_cache_fresh "$cache" "$days"; then
    if _mullvad_relays_valid "$cache"; then
      log "Using cached Mullvad relay list ($(basename "$cache"))"
      return 0
    fi
    warn "Cached relay list at ${cache} is fresh but does not parse as a relay list; refetching."
  fi
  mkdir -p "$(dirname "$cache")"
  tmpf="$(mktemp)"
  log "Fetching the Mullvad relay list (public API, over your real IP)"
  if _mullvad_fetch_relays "$tmpf" && _mullvad_relays_valid "$tmpf"; then
    mv "$tmpf" "$cache"
    ok "Relay list cached ($(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$cache") relays)"
    return 0
  fi
  rm -f "$tmpf"
  if _mullvad_relays_valid "$cache"; then
    warn "Could not refresh the relay list; using the cached copy from $(date -r "$cache" '+%Y-%m-%d %H:%M')."
    return 0
  fi
  die "Could not fetch ${MULLVAD_RELAY_URL} and no usable cached relay list exists at ${cache}. The exit's multihop port comes from that list and must not be guessed."
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
