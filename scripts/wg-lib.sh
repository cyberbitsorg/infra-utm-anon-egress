#!/usr/bin/env bash
# WireGuard config parsing and sanitising. Sourced, not run; pure functions,
# unit tested by tests/wg-config.sh.
#
# These functions are a gate, not a convenience: the nftables output chain
# allows exactly one destination -- the endpoint parsed here -- so a misparse
# produces a ruleset that looks correct and a tunnel that never comes up.

# Print the value of a bare `Key = Value` line, first match wins. Tolerates any
# spacing around '=' and strips a trailing `# comment` (wg-quick tolerates
# those, and a comment glued to the port would fail "not numeric").
_wg_field() {
  local file="${1:?config path required}" key="${2:?key required}" val
  val="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$file" | head -1)"
  val="${val%%#*}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# Print a comma-separated Address/AllowedIPs value with every IPv6 entry
# removed, in any position, with no stray commas left behind. An entry is IPv6
# iff it contains ':'.
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

# Endpoint host portion. In a Mullvad multihop config this is the ENTRY
# server's IP, while the port selects the EXIT.
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

# Return 0 if the config can drive this design, else print ONE specific reason
# to stderr and return 1. This runs in preflight; "invalid config" would send
# the operator back to a website with no clue why.
validate_wg_config() {
  local file="${1:?config path required}" ip port addr allowed peers
  [[ -f "$file" ]] || { echo "WireGuard config not found: ${file}" >&2; return 1; }
  # Exactly one [Peer]: the kill-switch allows a single endpoint, so a second
  # peer would be configured by wg-quick and silently blackholed.
  peers="$(grep -c -i '^[[:space:]]*\[Peer\]' "$file" || true)"
  [[ "${peers:-0}" -eq 1 ]] \
    || { echo "${file}: found ${peers:-0} [Peer] sections, expected exactly 1. This design allows one endpoint through the kill-switch; extra peers would be blocked." >&2; return 1; }
  [[ -n "$(_wg_field "$file" PrivateKey)" ]] \
    || { echo "${file}: no PrivateKey. Generate a config (not just a key) on Mullvad's site." >&2; return 1; }
  [[ -n "$(_wg_field "$file" PublicKey)" ]] \
    || { echo "${file}: no PublicKey for the peer." >&2; return 1; }
  addr="$(_wg_field "$file" Address)"
  [[ -n "$addr" ]] \
    || { echo "${file}: no Address for the interface." >&2; return 1; }
  # Sanitising strips IPv6; an IPv6-only Address would leave no address at all.
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
  # A bracketed host is an IPv6 endpoint; caught separately so the operator
  # gets the actual reason rather than "not a hostname".
  [[ "$ip" == \[* ]] \
    && { echo "${file}: endpoint '${ip}' is IPv6. This design drops IPv6 outright; pick a server by its IPv4 address on Mullvad's servers page." >&2; return 1; }
  # An IPv4 literal only: a hostname would need clear-net DNS before the
  # tunnel exists, a leak by construction.
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "${file}: endpoint '${ip}' must be an IPv4 address, not a hostname. Use the IP shown on Mullvad's servers page." >&2; return 1; }
  return 0
}

# Print the config with the modifications this design requires:
#   - `DNS =` removed: unbound owns DNS, wg-quick must not touch resolv.conf.
#   - `MTU =` removed: the gateway role's wg_mtu is the ONLY place that sets it
#     (wg-quick applies the LAST assignment it sees, so an operator MTU line
#     would silently outrank the role's).
#   - PostUp/PostDown/PreUp/PreDown removed: nftables owns firewalling, and
#     Mullvad's "local network sharing" option injects exactly these hooks.
#   - IPv6 stripped from Address/AllowedIPs, entry by entry (a regex anchored
#     on a leading comma misses a v6 entry in first position).
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
