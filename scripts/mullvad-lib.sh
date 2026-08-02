#!/usr/bin/env bash
# Mullvad relay selection: turn a country code in .env into a concrete
# entry/exit server pair and a WireGuard config that uses them.
# Sourced, not run.
#
# A Mullvad multihop config is the EXIT server's own config with exactly one
# line changed: `Endpoint = <entry ipv4_addr_in>:<exit multihop_port>`. Keys,
# Address, AllowedIPs and PublicKey all stay the exit's. Every config Mullvad's
# generator emits is SINGLE-hop (port 51820), so building on one unchanged
# silently downgrades the design -- mullvad_assert_multihop treats that as a
# hard failure.

MULLVAD_RELAY_URL="https://api.mullvad.net/www/relays/wireguard/"
MULLVAD_SINGLEHOP_PORT="51820"

# Does <hostname> belong to <spec>? Prefix-on-a-dash-boundary, never a bare
# substring: "se" must not match "se2-...", "bg-sof" must not match
# "bg-sofia-...". An EMPTY spec means "every relay" (unset MULLVAD_ENTRY).
# THE definition of the rule: selection and verify.sh both use it, so the two
# can never drift.
mullvad_spec_matches() {
  local spec="${1-}" host="${2-}"
  [[ -n "$spec" ]] || return 0
  case "$host" in
    "$spec"|"$spec"-*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Derived lookup table (<json>.tbl): the relay JSON parsed once into a flat
# file awk and the shell read directly, instead of a python3 spawn per lookup
# (~540 spawns and ~26 s per resolution against the live list).
#
# Line 1 stamps format version + size/mtime of the JSON; any difference
# rebuilds, so the table can never answer for a list it was not built from.
# Format, tab-separated:
#   H<TAB><hostname>                       every ACTIVE relay, sorted
#   F<TAB><hostname><TAB><key><TAB><value> fields of the FIRST relay per hostname
# Hostnames/keys carrying a separator (and values carrying a newline) are
# dropped rather than written, so a crafted relay list cannot forge records.
# Written 0600 like everything else under generated/.
# ---------------------------------------------------------------------------

# Bump whenever the writer's output changes meaning; discards existing tables.
MULLVAD_TABLE_FORMAT=2

_mullvad_stamp() {
  stat -f '%z %Fm' "${1:?}" 2>/dev/null || stat -c '%s %.9Y' "${1:?}" 2>/dev/null
}

_mullvad_build_table() {
  python3 - "${1:?}" "${2:?}" "${3:?}" <<'PY'
import json, os, sys
src, dest, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as fh:
    relays = json.load(fh)
hosts, seen, fields = [], set(), []
for r in relays:
    h = r.get("hostname")
    if not isinstance(h, str):
        continue
    if "\n" in h or "\t" in h:
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
fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write(stamp + "\n")
    for h in sorted(hosts):
        fh.write("H\t%s\n" % h)
    fh.writelines(fields)
PY
}

# Print the path of an up-to-date table for <json>, building it if needed.
# Returns 1 (printing nothing) when the JSON cannot be parsed.
_mullvad_table() {
  local json="${1:?relay json required}" tbl stamp hdr tmp
  tbl="${json}.tbl"
  stamp="# v${MULLVAD_TABLE_FORMAT} $(_mullvad_stamp "$json" || true)"
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

# Print every ACTIVE hostname matching <spec>, one per line, sorted. Nothing
# (not a blank line) when nothing matches.
#
# NOT SAFE FOR A CONSUMER THAT STOPS EARLY: bash's printf flushes in ~1 KB
# chunks, so `| grep -q` / `| head -1` can close the pipe mid-write and kill
# this function with SIGPIPE, which pipefail hands to the caller as "no match".
# Capture the list and search the string (_mullvad_list_has), or fully drain it.
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

# Print one field of one relay, or nothing if absent. Callers MUST treat empty
# as "unknown" and fail: a defaulted multihop_port would be a silently wrong
# tunnel. host/field go via the environment: `-v` would run escape processing.
mullvad_relay_field() {
  local json="${1:?relay json required}" host="${2:?hostname required}" field="${3:?field required}" tbl
  tbl="$(_mullvad_table "$json")" || return 1
  _MV_HOST="$host" _MV_FIELD="$field" awk '
    BEGIN { pfx = "F\t" ENVIRON["_MV_HOST"] "\t" ENVIRON["_MV_FIELD"] "\t"; n = length(pfx) }
    substr($0, 1, n) == pfx { print substr($0, n + 1); exit }
  ' "$tbl"
}

# Read lines on stdin, print exactly one at random. Returns 1 on empty input.
# $RANDOM's modulo bias is irrelevant at a few hundred candidates.
mullvad_pick_random() {
  local lines n idx
  lines="$(cat)"
  [[ -n "$lines" ]] || return 1
  n="$(printf '%s\n' "$lines" | grep -c . || true)"
  [[ "${n:-0}" -ge 1 ]] || return 1
  idx=$(( (RANDOM % n) + 1 ))
  printf '%s\n' "$lines" | grep . | sed -n "${idx}p"
}

# Print the exit server's config with ONLY the Endpoint line replaced. The
# count is checked BEFORE anything is printed, so a caller that forgets to
# check can never be left with a plausible-looking partial config.
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

# The exit server's multihop_port IS the endpoint port.
mullvad_endpoint_port_for() {
  mullvad_relay_field "${1:?relay json required}" "${2:?exit hostname required}" multihop_port
}

# Return 0 if <entry>/<exit> is genuine multihop, else print ONE specific
# reason to stderr and return 1. Single-hop must be unreachable, not
# discouraged.
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

# Exit candidates match the spec AND have a config on disk: the rewrite needs
# the exit's own keys.
mullvad_exit_candidates() {
  local json="${1:?}" secrets_dir="${2:?}" spec="${3:?}" h
  mullvad_relay_match "$json" "$spec" | while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    [[ -r "${secrets_dir}/${h}.conf" ]] && printf '%s\n' "$h"
  done
  return 0
}

# Entry candidates need NO config: only the entry's ipv4_addr_in is used.
mullvad_entry_candidates() {
  mullvad_relay_match "${1:?relay json required}" "${2-}"
}

# Entry candidates NOT in <country_code>: the second hop only buys anything in
# another jurisdiction. A candidate whose country_code cannot be read is
# skipped (ineligible), not passed through.
#
# The explicit `return 0` matters: a `while` loop reports its LAST iteration's
# status, and under pipefail a final non-matching candidate would fail the
# whole command substitution even with legal entries already printed.
mullvad_entries_outside_country() {
  local json="${1:?}" spec="${2-}" exclude_cc="${3:?}" h cc
  mullvad_entry_candidates "$json" "$spec" | while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    cc="$(mullvad_relay_field "$json" "$h" country_code)"
    [[ -n "$cc" && "$cc" != "$exclude_cc" ]] && printf '%s\n' "$h"
  done
  return 0
}

# Is <needle> one of the newline-separated lines of <haystack>? Exact equality
# (a pin is data, never a pattern), and deliberately not `producer | grep -q`,
# which exits at the first match and SIGPIPEs the producer under pipefail.
_mullvad_list_has() {
  local haystack="${1-}" needle="${2-}" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<MULLVAD_LIST
${haystack}
MULLVAD_LIST
  return 1
}

# Is this exact pair still legal under the current .env? Silent predicate,
# used to decide whether to keep a pin.
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

# Resolve an entry/exit pair, reusing a previous choice when still legal.
# The pin keeps `make configure` from silently moving the tunnel to another
# country; `make destroy` removes it. Hostnames only, never key material.
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

  entry="$(mullvad_entries_outside_country "$json" "$entry_spec" "$exit_cc" \
           | mullvad_pick_random)" || {
    echo "No entry server matches MULLVAD_ENTRY='${entry_spec}' outside the exit's country '${exit_cc}'. Leave MULLVAD_ENTRY empty for any country, or name a different one." >&2
    return 1
  }

  mullvad_assert_multihop "$json" "$entry" "$exit_h" || return 1

  # Created empty and chmodded BEFORE the hostnames are written: the pin names
  # the chosen country, and a file at the ambient umask is world-readable for
  # as long as the write takes.
  : > "$pin"
  chmod 600 "$pin" 2>/dev/null || true
  printf '%s %s\n' "$entry" "$exit_h" > "$pin"
  printf '%s %s\n' "$entry" "$exit_h"
}

MULLVAD_RELAY_CACHE="${GEN_DIR}/mullvad-relays.json"
MULLVAD_PIN_FILE="${GEN_DIR}/mullvad-exit.chosen"
MULLVAD_CACHE_MAX_AGE_DAYS=7

# True if <cache> exists, is NON-EMPTY (-s, not -e: a 0-byte file from an
# interrupted write must never read as fresh) and is younger than <days>.
mullvad_cache_fresh() {
  local cache="${1:?}" days="${2:?}"
  [[ -s "$cache" ]] || return 1
  [[ -z "$(find "$cache" -mtime +"$days" -print 2>/dev/null)" ]]
}

# True if <file> parses as Mullvad's relay list shape: a non-empty JSON array.
# One check for every path a cache can reach, so "corrupt" means one thing.
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

# Fetch the raw relay list into <dest>. Split out so tests can override it and
# drive every path without a network request. curl's stderr is NOT redirected:
# its error line is the only clue whether it was a portal, a proxy or DNS.
_mullvad_fetch_relays() {
  curl -fsS --max-time 30 "$MULLVAD_RELAY_URL" -o "${1:?}"
}

# Make sure the relay cache is present and parseable. The fetch happens on the
# HOST, over the real IP (there is no tunnel yet); the 7-day cache keeps it
# rare and the README says so. A cache is only trusted after it parses;
# a failed refetch with no usable cache is fatal, because the multihop port
# must never be guessed.
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

# Write the derived multihop config to <dest> at mode 0600, chmodded BEFORE
# any content is written: it holds the exit server's private key.
mullvad_render_to() {
  local json="${1:?}" secrets_dir="${2:?}" entry="${3:?}" exit_h="${4:?}" dest="${5:?}"
  local entry_ip exit_port src
  src="${secrets_dir}/${exit_h}.conf"
  [[ -r "$src" ]] || { echo "no config for exit ${exit_h} at ${src}" >&2; return 1; }
  # Warn, never fail, on a loose mode: unpacking Mullvad's bundle leaves the
  # whole directory world-readable. Only the mode is inspected.
  local src_perms
  src_perms="$(stat -f '%Lp' "$src" 2>/dev/null || echo '')"
  case "$src_perms" in
    600|400|"") ;;
    *) warn "${src} is mode ${src_perms}; it holds a private key. Fix the whole directory with: chmod 600 ${secrets_dir}/*.conf" ;;
  esac
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
