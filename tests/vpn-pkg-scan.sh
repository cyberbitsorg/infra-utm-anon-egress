#!/usr/bin/env bash
# Unit tests for the VPN-client scan helpers in scripts/verify.sh.
#
# These three are the only machine-checkable form of "credentials live only on
# the gateway", and they fail silently in one direction: green over an
# installed VPN client. Pure text over a dpkg dump, so no UTM or guest needed.
#
# The regression that prompted this file: vpn_pkg_status kept the LAST record
# per package, so a trailing not-installed stanza (dpkg keeps one per package
# it has ever known, one line per architecture) masked an installed one.
set -euo pipefail
cd "$(dirname "$0")/.."

# verify.sh runs the whole verification suite the moment it is sourced -- it
# needs a lab.conf, a running gateway and an ssh path -- so the helpers are
# lifted out of it by name instead. Extracted from the real file, never copied
# into this one: a copy would keep passing after verify.sh regressed, which is
# the exact class of bug this test exists to catch.
eval "$(awk '/^vpn_pkg_status\(\)/,/^}$/' scripts/verify.sh)"
eval "$(awk '/^vpn_pkg_present\(\)/,/^}$/' scripts/verify.sh)"
eval "$(awk '/^vpn_nm_plugins\(\)/,/^}$/' scripts/verify.sh)"
eval "$(awk '/^pkg_fully_installed\(\)/,/^}$/' scripts/verify.sh)"

fail=0
sec=""
# Section labels are held back and only printed when something under them
# fails, so a green run is one line per file instead of a wall of headings.
section() { sec="$1"; }
_hdr() { [[ -n "$sec" ]] && { echo "$sec"; sec=""; }; return 0; }

note() { _hdr; echo "  FAIL $1"; fail=1; }

# If a rename ever makes the extraction above find nothing, every assertion
# below would error rather than pass -- but say so plainly instead.
for fn in vpn_pkg_status vpn_pkg_present vpn_nm_plugins pkg_fully_installed; do
  declare -f "$fn" >/dev/null 2>&1 \
    || { echo "  FAIL ${fn} was not extracted from scripts/verify.sh"; exit 1; }
done

present() { vpn_pkg_present "$1" "$2"; }

section "vpn_pkg_present, single record:"
dump_clean="base-files installed
network-manager installed
mullvad-vpn not-installed"
present "$dump_clean" "mullvad-vpn" && note "a lone not-installed record must not count as present"
present "$dump_clean" "base-files"  || note "an installed package must count as present"
present "$dump_clean" "openvpn"     && note "a package absent from the dump must not count as present"

section "vpn_pkg_present, config-files:"
# Purged-but-configured: the binaries are gone, so this is genuinely absent.
present "mullvad-vpn config-files" "mullvad-vpn" \
  && note "config-files must not count as present"

section "vpn_pkg_present, an interrupted install:"
# A status nobody enumerated must fail SAFE. `unpacked` means the files are on
# disk with the package half-configured -- a working binary by any useful
# measure.
present "openvpn unpacked" "openvpn" \
  || note "an unrecognised status (unpacked) must fail safe and count as present"

section "vpn_pkg_present, two records for one name (the M2 regression):"
# THE case this file exists for. dpkg emits one record per architecture and
# keeps a not-installed stanza for packages it has previously known, so the same
# name legitimately appears twice -- and which one sorts last is an arbitrary
# tiebreak in a function whose whole job is to fail safe.
present "mullvad-vpn installed
mullvad-vpn not-installed" "mullvad-vpn" \
  || note "installed-then-not-installed must be reported PRESENT, not masked by the later record"
present "mullvad-vpn not-installed
mullvad-vpn installed" "mullvad-vpn" \
  || note "not-installed-then-installed must be reported PRESENT"
present "openvpn config-files
openvpn not-installed" "openvpn" \
  && note "two genuinely-absent records must stay absent"

section "vpn_pkg_present matches whole names only:"
# Substring matching would let one package name vouch for another in either
# direction: an installed network-manager-openvpn must not answer for openvpn,
# and it must not be reported under a name nobody asked about.
present "network-manager-openvpn installed" "openvpn" \
  && note "a longer package name must not satisfy a shorter one"
present "openvpn installed" "network-manager-openvpn" \
  && note "a shorter package name must not satisfy a longer one"

section "vpn_nm_plugins:"
# Exactly what a cold `make up` leaves on the workstation. -l10n and -tui are in
# here because the first cold build after this check was widened failed on them:
# both match network-manager-*, neither is a VPN client.
dump_desktop="base-files installed
network-manager installed
network-manager-applet installed
network-manager-gnome installed
network-manager-l10n installed
network-manager-tui installed"
[[ -z "$(vpn_nm_plugins "$dump_desktop")" ]] \
  || note "a stock desktop (nm + applet + gnome + l10n + tui) must report no plugins"

# The open-ended half: a plugin no list names, which is the whole point.
got="$(vpn_nm_plugins "${dump_desktop}
network-manager-sstp-gnome installed")"
[[ "$got" == "network-manager-sstp-gnome" ]] \
  || note "an unlisted plugin must be caught by pattern (got '${got}')"

# ...and not on the strength of a stanza for a package that is gone.
[[ -z "$(vpn_nm_plugins "${dump_desktop}
network-manager-sstp-gnome not-installed
network-manager-l2tp config-files")" ]] \
  || note "not-installed / config-files plugins must not be reported"

# Multiple hits, deduplicated and stable, so the failure message is readable.
got="$(vpn_nm_plugins "network-manager-l2tp installed
network-manager-openvpn installed
network-manager-l2tp installed" | tr '\n' ' ')"
[[ "$got" == "network-manager-l2tp network-manager-openvpn " ]] \
  || note "multiple plugins must come back sorted and deduplicated (got '${got}')"

# An empty dump must produce nothing and must not trip the inherited `set -e`;
# the caller treats "no output" as clean, and a non-zero exit here would abort
# the whole verify run instead.
[[ -z "$(vpn_nm_plugins "")" ]] || note "an empty dump must yield no plugins"

section "pkg_fully_installed vs vpn_pkg_present, opposite polarity:"
# The contrast this test exists for. verify.sh's tool-group assertion asks
# "did this finish installing", not "did something of it land on disk" -- an
# apt run that died halfway through the tunnel leaves a group in exactly
# half-configured, and that must read as MISSING, not present.
#
# Mutation: widen pkg_fully_installed to accept half-configured as well. The
# first assertion below fails by name ("half-configured must not count as fully
# installed"), not through a generic abort. Reverted after measuring.
dump_half="kali-tools-web half-configured"
pkg_fully_installed "$dump_half" "kali-tools-web" \
  && note "half-configured must not count as fully installed"
vpn_pkg_present "$dump_half" "kali-tools-web" \
  || note "half-configured must still count as present (vpn_pkg_present's fail-safe direction)"

dump_full="kali-tools-web installed"
pkg_fully_installed "$dump_full" "kali-tools-web" \
  || note "a package reported installed must count as fully installed"
vpn_pkg_present "$dump_full" "kali-tools-web" \
  || note "a package reported installed must also count as present"

if [[ "$fail" -eq 0 ]]; then
  echo "vpn-pkg-scan: OK"
else
  echo "vpn-pkg-scan: FAILED"
  exit 1
fi
