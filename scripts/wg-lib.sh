#!/usr/bin/env bash
# WireGuard config parsing for the Mullvad multihop config the operator generates.
# Sourced, not run. Pure functions: they read a file and print to stdout, so they
# are unit testable (tests/wg-config.sh) without an account.
#
# These functions are a gate, not a convenience. The nftables output chain allows
# exactly one destination -- the endpoint parsed here -- so a misparse produces a
# ruleset that looks correct and a tunnel that never comes up.

# Print the value of a bare `Key = Value` line, first match wins. Tolerates any
# spacing around '=' because operators hand-edit these files. Also strips a
# trailing `# comment` (and the whitespace before it): wg-quick tolerates those,
# and without this an `Endpoint = 1.2.3.4:3004 # note` line hands the comment to
# wg_endpoint_port as part of the port, which then fails "not numeric" on an
# otherwise-valid config.
_wg_field() {
  local file="${1:?config path required}" key="${2:?key required}" val
  val="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$file" | head -1)"
  val="${val%%#*}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# Print a comma-separated Address/AllowedIPs value with every IPv6 entry
# removed, regardless of position (first, middle, last, or the only entry), and
# with no leading/trailing/doubled comma left behind. An entry is IPv6 iff it
# contains a ':' -- IPv4 literals and CIDR suffixes never do, so this needs no
# address-family parsing. Bash 3.2 compatible: plain word-splitting, no arrays
# needed beyond what `read -ra` gives us.
_wg_strip_v6_csv() {
  local csv="${1:-}" IFS=',' parts p out=""
  read -ra parts <<<"$csv"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -z "$p" ]] && continue
    [[ "$p" == *:* ]] && continue
    out="${out:+${out},}${p}"
  done
  printf '%s' "$out"
}

# Endpoint host portion. For a Mullvad multihop config this is the ENTRY server's
# IP, while the port selects the EXIT server.
wg_endpoint_ip() {
  local ep; ep="$(_wg_field "${1:?}" Endpoint)"
  [[ -n "$ep" ]] || return 0
  printf '%s' "${ep%:*}"
}

wg_endpoint_port() {
  local ep; ep="$(_wg_field "${1:?}" Endpoint)"
  [[ -n "$ep" ]] || return 0
  printf '%s' "${ep##*:}"
}

# Return 0 if the config can drive this design, else print ONE specific reason to
# stderr and return 1. Specific messages matter: this runs in preflight, and
# "invalid config" would send the operator back to a website with no clue why.
validate_wg_config() {
  local file="${1:?config path required}" ip port addr allowed
  [[ -f "$file" ]] || { echo "WireGuard config not found: ${file}" >&2; return 1; }
  [[ -n "$(_wg_field "$file" PrivateKey)" ]] \
    || { echo "${file}: no PrivateKey. Generate a config (not just a key) on Mullvad's site." >&2; return 1; }
  [[ -n "$(_wg_field "$file" PublicKey)" ]] \
    || { echo "${file}: no PublicKey for the peer." >&2; return 1; }
  addr="$(_wg_field "$file" Address)"
  [[ -n "$addr" ]] \
    || { echo "${file}: no Address for the interface." >&2; return 1; }
  # Phase 2 drops IPv6 outright (sanitize_wg_config strips it). If Address is
  # IPv6-only, stripping would leave the interface with no address at all --
  # catch that here with a specific reason rather than let wg-quick fail later.
  [[ -n "$(_wg_strip_v6_csv "$addr")" ]] \
    || { echo "${file}: Address '${addr}' is IPv6-only; Phase 2 drops IPv6 and no IPv4 address would remain." >&2; return 1; }
  allowed="$(_wg_field "$file" AllowedIPs)"
  if [[ -n "$allowed" ]]; then
    [[ -n "$(_wg_strip_v6_csv "$allowed")" ]] \
      || { echo "${file}: AllowedIPs '${allowed}' is IPv6-only; Phase 2 drops IPv6 and no IPv4 route would remain." >&2; return 1; }
  fi
  ip="$(wg_endpoint_ip "$file")"
  port="$(wg_endpoint_port "$file")"
  [[ -n "$ip" && -n "$port" ]] \
    || { echo "${file}: no Endpoint = <host>:<port> line." >&2; return 1; }
  [[ "$port" =~ ^[0-9]+$ ]] \
    || { echo "${file}: endpoint port '${port}' is not numeric." >&2; return 1; }
  # An IPv4 literal only. A hostname would have to be resolved over clear-net DNS
  # before the tunnel exists -- a leak by construction, and a chicken-and-egg
  # dependency (design §2). Mullvad's generator emits IPs.
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "${file}: endpoint '${ip}' must be an IPv4 address, not a hostname. Use the IP shown on Mullvad's servers page." >&2; return 1; }
  return 0
}

# Print the config with the modifications this design requires:
#   - the `DNS =` line removed, so wg-quick does not touch resolv.conf; unbound
#     owns DNS and wg-quick fighting it would break the gateway's resolution.
#   - the `MTU =` line removed, so the Ansible role's wg_mtu default is the
#     ONLY place that sets it. wg-quick applies the LAST assignment of a given
#     key it sees in the file, so leaving the operator's MTU line in place
#     would let it silently outrank the value the gateway role writes below
#     `[Interface]` -- the role would report success while the tunnel actually
#     ran at whatever MTU Mullvad's generator happened to emit.
#   - `PostUp`/`PostDown`/`PreUp`/`PreDown` lines removed, so wg-quick never
#     manages firewalling either: nftables owns egress, and Mullvad's "local
#     network sharing" option injects exactly these hooks with rules that would
#     fight our ruleset.
#   - IPv6 removed from Address and AllowedIPs, in ANY position (first, middle,
#     last, or the only entry), because IPv6 is dropped outright (design §3.4)
#     and carrying a v6 address or default route into the tunnel is pure leak
#     surface for a repo that needs no v6.
#
# Address/AllowedIPs are rebuilt entry-by-entry via _wg_strip_v6_csv rather than
# pattern-deleted in place: a regex anchored on "comma before the v6 token"
# (the original approach here) silently does nothing when the v6 entry is
# first, since there is no leading comma to match. Splitting on commas and
# rejoining only the survivors also guarantees no stray leading/trailing/double
# comma, whatever position the v6 entry was in.
sanitize_wg_config() {
  local file="${1:?config path required}" line key val stripped
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(DNS|MTU|PostUp|PostDown|PreUp|PreDown)[[:space:]]*= ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*(Address|AllowedIPs)[[:space:]]*= ]]; then
      key="${line%%=*}"
      val="${line#*=}"
      stripped="$(_wg_strip_v6_csv "$val")"
      printf '%s= %s\n' "$key" "$stripped"
      continue
    fi
    printf '%s\n' "$line"
  done < "$file"
}
