#!/usr/bin/env bash
# The VPN watch list exists in two places on purpose: the workstation role
# PURGES it, and scripts/verify.sh independently ASSERTS it stayed gone. That
# duplication is the point -- an assertion that reads the same variable the
# removal used would pass by construction.
#
# What is not acceptable is the two drifting apart. A package added to the
# role's purge list but not to verify's watch list is a package nobody asserts;
# one added to verify but not the role is a FAIL nothing removes. This test
# pins them to each other without merging them.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { echo "  FAIL $1"; fail=1; }

# The list in verify.sh, lifted out by name rather than copied: a copy here
# would keep passing after verify.sh regressed.
eval "$(awk '/vpn_watch_list="/,/[^\\]"$/' scripts/verify.sh)"
[[ -n "${vpn_watch_list:-}" ]] \
  || { echo "  FAIL vpn_watch_list was not extracted from scripts/verify.sh"; exit 1; }

# The list in group_vars, read with a real YAML parser.
ansible_list="$(ruby -ryaml -e '
  d = YAML.safe_load(File.read("ansible/group_vars/role_workstation.yaml")) || {}
  l = d["workstation_vpn_watch_list"]
  abort("missing") unless l.is_a?(Array)
  print l.join("\n")
')" || { echo "  FAIL workstation_vpn_watch_list is missing or not a list in group_vars"; exit 1; }

verify_sorted="$(printf '%s\n' $vpn_watch_list | sort -u)"
ansible_sorted="$(printf '%s\n' "$ansible_list" | sort -u)"

if [[ "$verify_sorted" != "$ansible_sorted" ]]; then
  note "the watch lists have drifted apart:"
  diff <(printf '%s\n' "$verify_sorted") <(printf '%s\n' "$ansible_sorted") \
    | sed 's/^/    /' || true
fi

# A list that shrank to nothing would make the diff above pass trivially in the
# one case that matters least and hide the case that matters most.
count="$(printf '%s\n' "$ansible_sorted" | wc -l | tr -d ' ')"
[[ "$count" -ge 25 ]] || note "the watch list has only ${count} entries; it had 27 when this was written (verified by extraction from verify.sh)"

# The four packages the kali-linux-* umbrellas were measured to pull must be on
# it, because they are the reason the list exists.
for pkg in openvpn vpnc vpnc-scripts wireguard-tools mullvad-vpn; do
  grep -qx "$pkg" <<<"$ansible_sorted" || note "${pkg} is missing from the watch list"
done

if [[ "$fail" == "0" ]]; then echo "  vpn-watch-list OK"; else echo "  vpn-watch-list FAILED"; exit 1; fi
