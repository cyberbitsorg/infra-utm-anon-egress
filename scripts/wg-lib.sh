#!/usr/bin/env bash
# WireGuard config parsing for the Mullvad multihop config the operator generates.
# Sourced, not run. Pure functions: they read a file and print to stdout, so they
# are unit testable (tests/wg-config.sh) without an account.
#
# These functions are a gate, not a convenience. The nftables output chain allows
# exactly one destination -- the endpoint parsed here -- so a misparse produces a
# ruleset that looks correct and a tunnel that never comes up.

# Print the value of a bare `Key = Value` line, first match wins. Tolerates any
# spacing around '=' because operators hand-edit these files.
_wg_field() {
  local file="${1:?config path required}" key="${2:?key required}"
  sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$file" | head -1
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
  local file="${1:?config path required}" ip port
  [[ -f "$file" ]] || { echo "WireGuard config not found: ${file}" >&2; return 1; }
  [[ -n "$(_wg_field "$file" PrivateKey)" ]] \
    || { echo "${file}: no PrivateKey. Generate a config (not just a key) on Mullvad's site." >&2; return 1; }
  [[ -n "$(_wg_field "$file" PublicKey)" ]] \
    || { echo "${file}: no PublicKey for the peer." >&2; return 1; }
  [[ -n "$(_wg_field "$file" Address)" ]] \
    || { echo "${file}: no Address for the interface." >&2; return 1; }
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

# Print the config with two modifications this design requires:
#   - the `DNS =` line removed, so wg-quick does not touch resolv.conf; unbound
#     owns DNS and wg-quick fighting it would break the gateway's resolution.
#   - IPv6 removed from Address and AllowedIPs, because IPv6 is dropped outright
#     (design §3.4) and carrying a v6 default route into the tunnel is pure
#     leak surface for a repo that needs no v6.
sanitize_wg_config() {
  local file="${1:?config path required}"
  sed -E \
    -e '/^[[:space:]]*DNS[[:space:]]*=/d' \
    -e '/^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=/{
          s/[[:space:]]*,[[:space:]]*[0-9a-fA-F:]*:[0-9a-fA-F:]*[^,]*//g
          s/[[:space:]]*,[[:space:]]*::\/0//g
        }' \
    "$file"
}
