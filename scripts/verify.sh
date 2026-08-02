#!/usr/bin/env bash
# Assert the security property this repo exists for. Hard-fails on any leak.
#
# The phase is detected from the gateway itself, never from a flag:
#   Phase 1 (no tunnel configured): the workstation reaches the gateway and
#   nothing else. Phase 2 (a tunnel exists): the workstation has egress, and
#   ONLY through the tunnel -- including an active kill-switch test that drops
#   the tunnel and watches the WAN NIC directly.
#
# THE RULE THIS FILE IS BUILT AROUND: silence is never scored as security.
# Every probe must be able to say "I ran and the answer was no" separately
# from "I did not run"; anything ambiguous is reported as a FAILURE.
#
# Both phases assert NEGATIVES, so this is proof that these specific vectors
# are closed -- not proof of anonymity.
#
# No packages are needed in the guests: probes use bash's /dev/tcp, ping and
# python3, which both images ship. The gateway needs tcpdump, which its role
# installs for exactly this reason.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Sourced for MULLVAD_PIN_FILE and mullvad_spec_matches, so the pin's location
# and the matching rule live in exactly one place. Pure functions; sourcing
# runs nothing.
source "$(dirname "${BASH_SOURCE[0]}")/mullvad-lib.sh"
load_config
# .env is read for one fact: which mechanism built this lab (MULLVAD_EXIT vs
# MULLVAD_WG_CONFIG), which decides whether the exit-country assertion applies.
load_env

# Resolve the gateway's host port and the internal-only VMs from the fleet, the
# same way ssh.sh does, so a reordered fleet does not verify the wrong box.
idx=0; gw_idx=0; internal_rows=""
for entry in "${LAB_VMS[@]}"; do
  idx=$((idx + 1))
  parse_vm_entry "$entry"
  if [[ "$(nic_layout_for_role "$VM_ROLE")" == "dual" ]]; then
    [[ "$gw_idx" -eq 0 ]] && gw_idx="$idx"
  else
    internal_rows+="${VM_SHORT} ${VM_ROLE} ${idx}"$'\n'
  fi
done
[[ "$gw_idx" -ne 0 ]] || die "No dual-NIC gateway in LAB_VMS: nothing to verify through."
[[ -n "$internal_rows" ]] || die "No internal-only VM in LAB_VMS: nothing to verify."

gw_port="$(ssh_port_for "$gw_idx")"
gw_ip="${GATEWAY_INTERNAL_IP:-10.20.0.1}"
ssh_common=("${SSH_HOSTKEY_OPTS[@]}" -o ConnectTimeout=10 -o BatchMode=yes -i "$(priv_key)")
jump=(-o "ProxyCommand=$(ssh_jump_proxycommand "$gw_port")" "${ssh_common[@]}")

fails=0
note_fail() { printf '%s%s%s %s\n' "$(_c '1;31')" "FAIL" "$(_c 0)" "$*" >&2; fails=$((fails + 1)); }

# on_ws <ip> <command...>: run a command on an internal-only VM via the jump.
# on_gw <command...>:      run a command on the gateway over its host forward.
# `-n` is load-bearing: without it ssh drains the here-string feeding the
# per-VM loop, and every VM after the first is silently never verified.
on_ws() {
  local ip="$1"; shift
  ssh -n "${jump[@]}" "${LAB_USER}@${ip}" "$@"
}

on_gw() {
  ssh -n "${ssh_common[@]}" -p "$gw_port" "${LAB_USER}@127.0.0.1" "$@"
}

# ssh returns 255 when the hop itself fails -- the same non-zero a blocked
# probe returns. These helpers make the guest say which happened, so a failed
# connection is never scored as "the packet was blocked".
ws_probe() {
  local ip="$1" cmd="$2"
  on_ws "$ip" "if ${cmd}; then echo REACHED; else echo BLOCKED; fi" 2>/dev/null | tr -d '\r' || true
}

gw_probe() {
  on_gw "if ${1}; then echo REACHED; else echo BLOCKED; fi" 2>/dev/null | tr -d '\r' || true
}

# expect_blocked <result> <ok msg> <leak msg> <probe name>
expect_blocked() {
  case "$1" in
    BLOCKED) ok "$2" ;;
    REACHED) note_fail "$3" ;;
    *)       note_fail "the $4 probe did not run (transport failure); leak status UNKNOWN and deliberately not scored as a pass" ;;
  esac
}

# expect_reached <result> <ok msg> <fail msg> <probe name>
expect_reached() {
  case "$1" in
    REACHED) ok "$2" ;;
    BLOCKED) note_fail "$3" ;;
    *)       note_fail "the $4 probe did not run (transport failure); status UNKNOWN" ;;
  esac
}

# py_on_ws <ip> <program>: run a python3 program on an internal VM. Base64,
# because quoting a multi-line program through two shells reliably produces a
# syntax error that looks exactly like a correctly blocked probe.
py_on_ws() {
  local ip="$1" src="$2" b64
  b64="$(printf '%s' "$src" | base64 | tr -d '\n')"
  on_ws "$ip" "python3 -c \"import base64;exec(base64.b64decode('${b64}'))\""
}

# vpn_pkg_status <dump> <package>: the db:Status-Status field for <package> in
# a "Package Status" per-line dump, or empty if absent. Exact field equality,
# never a substring. Where dpkg holds several records for one name (one per
# arch, plus not-installed stanzas), a PRESENT record wins over a trailing
# not-installed one -- resolving ambiguity toward "pass" would defeat the check.
vpn_pkg_status() {
  awk -v p="$2" '
    $1 == p {
      if ($2 != "not-installed" && $2 != "config-files") { print $2; found = 1; exit }
      last = $2
    }
    END { if (!found && last != "") print last }
  ' <<<"$1"
}

# vpn_pkg_present <dump> <package>: true if anything of <package> is on disk.
# Inverted rather than matching "installed": a package interrupted mid-install
# (unpacked, half-configured) must fail safe by counting as present.
vpn_pkg_present() {
  local s
  s="$(vpn_pkg_status "$1" "$2")"
  [[ -n "$s" && "$s" != "not-installed" && "$s" != "config-files" ]]
}

# pkg_fully_installed <dump> <package>: true ONLY for the steady-state
# "installed". Opposite polarity from vpn_pkg_present on purpose: here the
# partial states are what a died-mid-tunnel apt run leaves behind, and
# accepting them would print green over a half-landed tool group.
pkg_fully_installed() {
  [[ "$(vpn_pkg_status "$1" "$2")" == "installed" ]]
}

# vpn_nm_plugins <dump>: every INSTALLED network-manager-* package that is not
# one of the four the desktop legitimately needs (applet/gnome front-ends,
# nmtui, translations -- none can dial a VPN). The pattern is the open-ended
# half of the VPN check: it catches plugins no hand-written list can know
# about, and failing loudly on a harmless new package is the cheap direction
# to be wrong in.
vpn_nm_plugins() {
  awk '$1 ~ /^network-manager-/ \
       && $1 != "network-manager-applet" && $1 != "network-manager-gnome" \
       && $1 != "network-manager-tui" && $1 != "network-manager-l10n" \
       && $2 != "not-installed" && $2 != "config-files" { print $1 }' <<<"$1" \
    | sort -u || true
}

# dns_udp_probe <resolver> [qname] [timeout]: send a real DNS query over UDP
# and print the response code, or TIMEOUT. UDP because a /dev/tcp test covers
# TCP only, and a real query because connect() on UDP always "succeeds". The
# response code matters: a resolver cut off from its upstream still replies,
# with SERVFAIL.
dns_udp_probe() {
  cat <<PY
import socket, struct, sys
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
for lab in b"${2:-example.com}".split(b"."):
    q += bytes([len(lab)]) + lab
q += b"\x00" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(${3:-4})
try:
    s.sendto(q, ("$1", 53))
    data = s.recv(512)
except Exception:
    print("TIMEOUT"); sys.exit(0)
codes = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 5: "REFUSED"}
print(codes.get(data[3] & 0x0F, "RCODE%d" % (data[3] & 0x0F)))
PY
}

# Prints Mullvad's verdict on where the caller egresses from.
mullvad_check_probe() {
  cat <<'PY'
import urllib.request, sys
try:
    print(urllib.request.urlopen("https://am.i.mullvad.net/json", timeout=25).read().decode())
except Exception as e:
    print("ERROR: %s" % e)
    sys.exit(1)
PY
}

# A name no cache can have seen: unbound and systemd-resolved both cache, and
# a cache hit looks exactly like a live resolver.
uncached_name() {
  printf 'v%s%s.example.com' "$RANDOM" "$RANDOM"
}

# --- phase detection ---------------------------------------------------------
# sudo is required (/etc/wireguard is 0700 root), and the three outcomes stay
# distinct: silently dropping to the Phase 1 contract on a broken hop would
# pass a Phase 2 gateway whose tunnel is dead.
phase_probe="$(on_gw "sudo -n true >/dev/null 2>&1 || { echo NOSUDO; exit 0; }
if sudo -n test -f /etc/wireguard/wg0.conf; then echo TUNNEL; else echo NOTUNNEL; fi" 2>/dev/null | tr -d '\r' || true)"
case "$phase_probe" in
  TUNNEL)
    PHASE=2
    log "Tunnel configured on the gateway: verifying the Phase 2 contract" ;;
  NOTUNNEL)
    PHASE=1
    log "No tunnel on the gateway: verifying the Phase 1 contract (zero egress)" ;;
  NOSUDO)
    die "passwordless sudo does not work on the gateway; cannot tell which contract applies" ;;
  *)
    die "could not reach the gateway on 127.0.0.1:${gw_port}; refusing to guess which contract applies" ;;
esac

if [[ "$PHASE" == "2" ]]; then
  # `|| true` on captures throughout: lib.sh sets `set -euo pipefail`, and
  # several commands below return non-zero in the PASSING case.
  #
  # The WAN NIC must come from the MAIN routing table: `ip route get` returns
  # wg0 once the tunnel's policy routing is up, and a WAN-silence check pointed
  # at wg0 would watch the tunnel instead of the wire.
  wan_if="$(on_gw "ip -4 route show table main default | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$wan_if" ]] || die "could not determine the gateway's WAN interface; refusing to report a clean WAN"

  wan_addr="$(on_gw "ip -4 -o addr show dev ${wan_if} | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$wan_addr" ]] || die "could not determine the gateway's WAN address; refusing to report a clean WAN"

  # The internal NIC, found by the address it carries, is where the kill-switch
  # test confirms its own traffic generator is working.
  internal_if="$(on_gw "ip -4 -o addr show to ${gw_ip}/32 | awk '{print \$2}' | head -1" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$internal_if" ]] || die "could not determine the gateway's internal interface (no NIC holds ${gw_ip})"

  endpoint="$(on_gw "sudo sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' /etc/wireguard/wg0.conf | head -1" 2>/dev/null | tr -d '\r' || true)"
  endpoint_ip="${endpoint%%:*}"
  endpoint_port="${endpoint##*:}"
  [[ -n "$endpoint_ip" && -n "$endpoint_port" ]] \
    || die "could not read the WireGuard endpoint from the gateway; refusing to report a clean WAN"

  # What may appear on the WAN and nothing else: ARP, management SSH (scoped to
  # tcp AND this NIC's own address), and the single WireGuard endpoint.
  # Exclusion, never inclusion: the source of a leaked packet is not something
  # this test may assume (SNATed or bare 10.20.0.10, both were seen).
  wan_filter="not arp and not (tcp port 22 and host ${wan_addr}) and not (host ${endpoint_ip} and udp port ${endpoint_port})"
  wan_cap_file="/tmp/anon-egress-wan-capture"

  log "Gateway WAN is ${wan_if} (${wan_addr}); the only permitted flow on it is ${endpoint_ip}:${endpoint_port}"
fi

# --- WAN capture -------------------------------------------------------------
# Watching the WAN NIC is the only authoritative answer to "did a packet leave
# in the clear": a leaked packet can leave un-SNATed, get no reply, and look
# "blocked" to every guest-side probe. Runs in the background so one capture
# judges a whole block of probes. -l keeps tcpdump line-buffered, so a
# few-packet leak cannot sit unflushed in a buffer and read as clean.
wan_capture_start() {
  local started
  started="$(on_gw "sudo rm -f ${wan_cap_file} 2>/dev/null
sudo nohup timeout 120 tcpdump -nnl -i ${wan_if} -Q out '${wan_filter}' >${wan_cap_file} 2>/dev/null </dev/null &
sleep 2
if pgrep -x tcpdump >/dev/null 2>&1; then echo STARTED; else echo NOTSTARTED; fi" 2>/dev/null | tr -d '\r' || true)"
  # A capture that never started would report a beautifully clean WAN.
  [[ "$started" == "STARTED" ]] || { note_fail "could not start the WAN capture on ${wan_if} (${started:-no response}); WAN silence CANNOT be asserted"; return 1; }
  return 0
}

# Prints whatever left the WAN, one packet per line. Empty means silent.
wan_capture_stop() {
  on_gw "sudo pkill -x tcpdump >/dev/null 2>&1 || true
sleep 1
cat ${wan_cap_file} 2>/dev/null || true
sudo rm -f ${wan_cap_file} 2>/dev/null || true" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' || true
}

# --- per-VM checks -----------------------------------------------------------

ks_ip=""; ks_short=""
while read -r short role vm_idx; do
  [[ -z "$short" ]] && continue
  ip="$(internal_ip_for "$role" "$vm_idx")"
  [[ -z "$ks_ip" ]] && { ks_ip="$ip"; ks_short="$short"; }
  log "Verifying ${short} (${ip}) through the gateway on 127.0.0.1:${gw_port}"

  # 1. Reachability: the internal segment works and the jump path is intact.
  expect_reached "$(ws_probe "$ip" "ping -c1 -W2 ${gw_ip} >/dev/null 2>&1")" \
    "${short} reaches the gateway at ${gw_ip} on the internal segment" \
    "${short} cannot reach the gateway at ${gw_ip}" \
    "gateway-reachability"

  # 2. Topology: exactly one non-loopback NIC. A second NIC means someone gave
  # this VM a NAT interface, which breaks the entire guarantee.
  nics="$(on_ws "$ip" "ls /sys/class/net | grep -v '^lo$' | tr '\n' ' '" 2>/dev/null || true)"
  count="$(printf '%s' "$nics" | wc -w | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    ok "${short} has exactly one NIC (${nics% })"
  else
    note_fail "${short} has ${count} NICs (${nics% }); an internal-only VM must have exactly one"
  fi

  # 3. No VPN client of any kind on an internal-only host: the machine-checkable
  # form of "credentials live only on the gateway". A client sitting installed
  # and unconfigured leaks nothing today, so no network probe can see it.
  #
  # The dump takes NO package arguments (so dpkg-query's exit status is
  # meaningful) and is filtered locally by exact field equality. Three faults
  # are kept distinct from a clean host: transport failure (the unconditional
  # `__vpnscan=done` sentinel), dpkg-query never ran (the base-files canary),
  # and dpkg-query died partway (`__rc` captured immediately after it).
  vpn_watch_list="mullvad-vpn \
      network-manager-openvpn network-manager-openvpn-gnome \
      network-manager-pptp network-manager-pptp-gnome \
      network-manager-l2tp network-manager-l2tp-gnome \
      network-manager-openconnect network-manager-openconnect-gnome \
      network-manager-vpnc network-manager-vpnc-gnome \
      network-manager-fortisslvpn network-manager-fortisslvpn-gnome \
      openvpn openconnect vpnc vpnc-scripts pptp-linux \
      wireguard wireguard-tools \
      strongswan strongswan-starter strongswan-charon strongswan-libcharon \
      libcharon-extauth-plugins libstrongswan libstrongswan-standard-plugins"

  vpn_scan="$(on_ws "$ip" "dpkg-query -W -f='\${Package} \${db:Status-Status}\n' 2>/dev/null; echo __rc=\$?; echo __vpnscan=done" \
      2>/dev/null | tr -d '\r' || true)"
  # The tool-group assertion (3b) reuses this dump, so every failure path here
  # also notes that the toolset could not be asserted -- silence is never
  # scored as security.
  if ! grep -q '__vpnscan=done' <<<"$vpn_scan"; then
    note_fail "the VPN-client scan did not run on ${short}; cannot assert credentials are gateway-only"
    [[ "$role" == "workstation" ]] && note_fail "the toolset on ${short} cannot be asserted either: it depends on the same scan"
  else
    vpn_rc="$(sed -n 's/^__rc=\([0-9][0-9]*\)$/\1/p' <<<"$vpn_scan" | tail -1 || true)"
    # grep -v exits 1 when every line matches the exclusion -- exactly the
    # fault case handled below, so it must not trip `set -e`.
    vpn_dump="$(grep -vE '^__rc=[0-9]+$|^__vpnscan=done$' <<<"$vpn_scan" || true)"
    if [[ "$vpn_rc" != "0" ]]; then
      note_fail "the VPN-client scan on ${short} did not complete (dpkg-query exited ${vpn_rc:-unknown} instead of 0); credential-isolation cannot be asserted"
      [[ "$role" == "workstation" ]] && note_fail "the toolset on ${short} cannot be asserted either: it depends on the same scan"
    elif ! vpn_pkg_present "$vpn_dump" "base-files"; then
      note_fail "the VPN-client scan on ${short} did not observe its own canary package (base-files) as installed; dpkg-query may not have actually read the status database, so credential-isolation cannot be asserted"
      [[ "$role" == "workstation" ]] && note_fail "the toolset on ${short} cannot be asserted either: it depends on the same scan"
    else
      vpn_found=""
      for pkg in $vpn_watch_list; do
        vpn_pkg_present "$vpn_dump" "$pkg" && vpn_found="${vpn_found}${pkg} "
      done
      # The same dump again, by pattern, for the plugins no list can know
      # about; deduped against the named finds.
      for pkg in $(vpn_nm_plugins "$vpn_dump"); do
        case " ${vpn_found}" in
          *" ${pkg} "*) continue ;;
        esac
        vpn_found="${vpn_found}${pkg} "
      done
      vpn_found="${vpn_found% }"
      if [[ -n "$vpn_found" ]]; then
        note_fail "${short} has VPN client package(s) installed, which an internal-only host must never have: ${vpn_found}"
      else
        ok "${short} has no VPN client installed: none of the named clients, and no network-manager-* plugin beyond the desktop's own (credentials stay on the gateway)"
      fi

      # 3b. Every tool group KALI_TOOL_GROUPS asked for actually finished
      # installing. Reuses the proven dump: a fresh query could come back empty
      # from a dead connection and read as "nothing installed".
      if [[ "$role" == "workstation" ]]; then
        # parse_tool_groups dies inside this command substitution's subshell;
        # the `if !` turns that into a scored FAIL the rest of the suite
        # survives (a bare `|| true` would abort the whole run under bash 3.2).
        if ! groups_list="$(parse_tool_groups)"; then
          note_fail "KALI_TOOL_GROUPS in lab.conf is invalid (see the error above); the toolset on ${short} cannot be asserted"
        else
          groups_missing=""; groups_seen=0
          while IFS= read -r grp; do
            [[ -n "$grp" ]] || continue
            groups_seen=$((groups_seen + 1))
            pkg_fully_installed "$vpn_dump" "kali-tools-${grp}" \
              || groups_missing="${groups_missing}kali-tools-${grp} "
          done <<<"$groups_list"
          if (( groups_seen == 0 )); then
            ok "${short} has no tool groups configured (KALI_TOOL_GROUPS is empty)"
          elif [[ -n "$groups_missing" ]]; then
            note_fail "${short} is missing tool group(s) that KALI_TOOL_GROUPS asked for: ${groups_missing% } (the apt run did not finish, or the selection changed without a re-run of 'make configure')"
          else
            ok "${short} has all ${groups_seen} configured tool group(s) installed"
          fi
        fi
      fi
    fi
  fi

  # 4. Positive controls for the tools the leak checks rely on: a bash without
  # /dev/tcp or a ping without IPv6 fails a probe exactly like a blocked packet,
  # making the corresponding leak check permanently, silently green.
  expect_reached "$(ws_probe "$ip" "timeout 5 bash -c '</dev/tcp/${gw_ip}/22' >/dev/null 2>&1")" \
    "${short} has working /dev/tcp (the TCP leak probes below are meaningful)" \
    "${short} cannot open /dev/tcp even to the gateway: the TCP leak probes prove nothing" \
    "dev-tcp control"
  expect_reached "$(ws_probe "$ip" "ping -6 -c1 -W2 ::1 >/dev/null 2>&1")" \
    "${short} has working IPv6 tooling (the v6 leak probe below is meaningful)" \
    "${short} cannot ping -6 even to ::1: the IPv6 leak probe proves nothing" \
    "ping6 control"

  if [[ "$PHASE" == "1" ]]; then
    # 5. Isolation: ICMP and TCP, because a dropped ping alone would not rule
    # out a working route.
    expect_blocked "$(ws_probe "$ip" "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1")" \
      "${short} has no ICMP path to the internet (correct for Phase 1)" \
      "LEAK: ${short} reached 1.1.1.1 by ICMP with no VPN or forwarding in place" \
      "phase-1 ICMP"
    expect_blocked "$(ws_probe "$ip" "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1")" \
      "${short} has no TCP path to the internet (correct for Phase 1)" \
      "LEAK: ${short} opened a TCP connection to 1.1.1.1:443" \
      "phase-1 TCP"
    continue
  fi

  # --- Phase 2: egress must work, and only through the tunnel ----------------
  expect_reached "$(ws_probe "$ip" "timeout 20 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1")" \
    "${short} reaches the internet (through the tunnel)" \
    "${short} has no egress at all: the tunnel is not forwarding" \
    "phase-2 egress"

  # The authoritative exit check: Mullvad's own endpoint, asked FROM the
  # workstation. Anything less is inference.
  exit_json="$(py_on_ws "$ip" "$(mullvad_check_probe)" 2>/dev/null || true)"
  ws_pub_ip="$(sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$exit_json" || true)"
  if grep -q '"mullvad_exit_ip"[[:space:]]*:[[:space:]]*true' <<<"$exit_json"; then
    exit_host="$(sed -n 's/.*"mullvad_exit_ip_hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$exit_json" || true)"
    ok "${short} egresses via a Mullvad exit (${ws_pub_ip}${exit_host:+, ${exit_host}})"
    # >>> exit-country assertion (extracted verbatim by tests/mullvad-select.sh) >>>
    # Egressing via SOME Mullvad exit is not the claim: the operator chose a
    # country, and intent and observation must be compared. Which mechanism
    # built the lab decides whether the comparison applies, and only .env says
    # which -- a stale pin left over after switching to MULLVAD_WG_CONFIG must
    # not fail a correct lab.
    if [[ -n "${MULLVAD_EXIT:-}" ]]; then
      pinned_exit=""
      if [[ -f "$MULLVAD_PIN_FILE" ]]; then
        # NR==1 matches how mullvad_resolve_pair reads the pin back.
        pinned_exit="$(awk 'NR==1{print $2}' "$MULLVAD_PIN_FILE" 2>/dev/null || true)"
      fi
      if [[ -z "$pinned_exit" ]]; then
        # Not a skip: with no readable pin nothing can confirm the operator got
        # the country they asked for, and "could not tell" is a failure here.
        note_fail "MULLVAD_EXIT='${MULLVAD_EXIT}' asked for a specific exit, but no hostname could be read from ${MULLVAD_PIN_FILE}: nothing can confirm ${short} egresses where you chose"
      elif ! mullvad_spec_matches "$MULLVAD_EXIT" "$pinned_exit"; then
        # The pin records what was SELECTED, not what .env asks for now; only
        # `make up` / `make configure` rewrite it. Same dash-boundary rule the
        # selection used, from the same function, so the two cannot drift.
        note_fail "MULLVAD_EXIT='${MULLVAD_EXIT}' but ${MULLVAD_PIN_FILE} pins ${pinned_exit}, and ${short} is on ${exit_host:-an exit whose hostname could not be read}: .env was edited after this lab was built. Run 'make configure' (or 'make up') so the selection catches up before trusting this check"
      elif [[ -z "$exit_host" ]]; then
        note_fail "${short} egresses via Mullvad but the exit hostname could not be read, so it cannot be compared with the pinned exit ${pinned_exit}"
      elif [[ "$exit_host" == "$pinned_exit" ]]; then
        ok "${short} egresses via the exit that was selected (${pinned_exit})"
      else
        note_fail "${short} egresses via ${exit_host} but ${pinned_exit} was selected: the tunnel is not in the country you chose"
      fi
    else
      # Said out loud rather than skipped in silence: "does not apply" and
      # "switched off" must never be indistinguishable.
      log "Exit-country assertion does not apply to ${short}: this lab is built from MULLVAD_WG_CONFIG, so no country was selected to compare against (any ${MULLVAD_PIN_FILE} left over from an earlier lab is ignored)"
    fi
    # <<< exit-country assertion <<<
  else
    note_fail "${short} is NOT exiting via Mullvad. Response: ${exit_json:-<none>}"
  fi

  # Secondary and non-fatal: the host is out of scope and may be behind its
  # own VPN.
  host_pub_ip="$(python3 -c "import urllib.request;print(urllib.request.urlopen('https://am.i.mullvad.net/json',timeout=20).read().decode())" 2>/dev/null \
                 | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
  if [[ -n "$ws_pub_ip" && -n "$host_pub_ip" && "$ws_pub_ip" == "$host_pub_ip" ]]; then
    warn "${short} and this host report the same public IP (${ws_pub_ip}). Expected if the host is on the same VPN; investigate if not."
  fi

  # DNS must work via the gateway's unbound and NOT via any external resolver.
  # A fresh random name every attempt, because a cached answer reads as a
  # working resolver over a completely dead gateway.
  #
  # Retried because this is a POSITIVE control, like the flow_up loop below.
  # NEVER retry a leak assertion: "failed three times, call it blocked" is how
  # an intermittent leak gets scored as security.
  up_rcode=""; up_tries=0
  for _ in 1 2 3; do
    up_tries=$((up_tries + 1))
    up_rcode="$(py_on_ws "$ip" "$(dns_udp_probe "$gw_ip" "$(uncached_name)" 10)" 2>/dev/null | tr -d '\r' || true)"
    case "$up_rcode" in
      NOERROR|NXDOMAIN) break ;;
    esac
    sleep 2
  done
  case "$up_rcode" in
    NOERROR|NXDOMAIN)
      if [[ "$up_tries" -eq 1 ]]; then
        ok "${short} resolves DNS through the gateway (uncached lookup, ${up_rcode})"
      else
        # Said out loud: it worked, but it did not work first time, and that is
        # worth knowing before it degrades into a hard failure.
        warn "${short} resolves DNS through the gateway (uncached lookup, ${up_rcode}), but only on attempt ${up_tries} of 3: the resolver is answering slowly or intermittently"
      fi ;;
    "") note_fail "the DNS probe against ${gw_ip} did not run on ${short} in ${up_tries} attempts; status UNKNOWN" ;;
    *)  note_fail "${short} cannot resolve via ${gw_ip}: ${up_tries} uncached lookups returned ${up_rcode}" ;;
  esac

  dns_leak=0
  for resolver in 1.1.1.1 8.8.8.8; do
    rcode="$(py_on_ws "$ip" "$(dns_udp_probe "$resolver")" 2>/dev/null | tr -d '\r' || true)"
    if [[ -z "$rcode" ]]; then
      note_fail "could not run the UDP DNS probe against ${resolver} on ${short}; leak status UNKNOWN"
      dns_leak=1
    elif [[ "$rcode" != "TIMEOUT" ]]; then
      note_fail "DNS LEAK: ${short} got a UDP :53 ${rcode} from ${resolver}, bypassing unbound"
      dns_leak=1
    fi
    tcp53="$(ws_probe "$ip" "timeout 5 bash -c '</dev/tcp/${resolver}/53' >/dev/null 2>&1")"
    case "$tcp53" in
      REACHED) note_fail "DNS LEAK: ${short} opened TCP :53 to ${resolver}, bypassing unbound"; dns_leak=1 ;;
      BLOCKED) ;;
      *)       note_fail "the TCP :53 probe against ${resolver} did not run on ${short}; leak status UNKNOWN"; dns_leak=1 ;;
    esac
  done
  [[ "$dns_leak" -eq 0 ]] && ok "${short} cannot reach an external resolver on UDP or TCP :53"

  # IPv6 must be dead, not tunnelled. `ping -6`, because the ping6 symlink is
  # not on every image.
  expect_blocked "$(ws_probe "$ip" "ping -6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1")" \
    "${short} has no IPv6 egress" \
    "IPv6 LEAK: ${short} reached a v6 address" \
    "IPv6"
done <<<"$internal_rows"

# --- the active kill-switch test ---------------------------------------------

if [[ "$PHASE" == "2" ]]; then
  echo
  log "Kill-switch test on ${ks_short} (${ks_ip})"

  # Restoration is a trap, not a final line: whatever aborts this section, the
  # tunnel must come back. A verify run that leaves the lab without egress is
  # worse than one that fails.
  tunnel_restored=0
  restore_tunnel() {
    if [[ "$tunnel_restored" == "1" ]]; then return 0; fi
    log "Restoring the tunnel"
    on_gw "sudo pkill -x tcpdump >/dev/null 2>&1 || true; sudo rm -f ${wan_cap_file} 2>/dev/null || true" >/dev/null 2>&1 || true
    on_ws "$ks_ip" "pkill -x ping >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    if ! on_gw "sudo systemctl start wg-quick@wg0" >/dev/null 2>&1; then
      warn "could not restart wg-quick@wg0; the lab may be left without egress. Run: make ssh gateway, then sudo systemctl start wg-quick@wg0"
    fi
  }
  # INT/TERM/HUP must EXIT after restoring: a bare handler would resume into
  # the tunnel-down assertions with the tunnel back up.
  trap restore_tunnel EXIT
  trap 'restore_tunnel; exit 130' INT TERM HUP

  # --- part 1: nothing NEW may escape while the tunnel is down ---------------
  # Judged by the WAN NIC as well as the guests: an un-SNATed leak produces no
  # reply, so guest-side evidence alone is compatible with traffic pouring out.
  wan_watching=0
  wan_capture_start && wan_watching=1

  on_gw "sudo systemctl stop wg-quick@wg0" >/dev/null 2>&1 \
    || die "could not stop the tunnel; kill-switch untested"

  expect_blocked "$(ws_probe "$ks_ip" "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1")" \
    "kill-switch: no ICMP with the tunnel down" \
    "KILL-SWITCH FAILED: ICMP escaped with the tunnel down" \
    "kill-switch ICMP"
  expect_blocked "$(ws_probe "$ks_ip" "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1")" \
    "kill-switch: no TCP with the tunnel down" \
    "KILL-SWITCH FAILED: TCP escaped with the tunnel down" \
    "kill-switch TCP"

  # With the tunnel down unbound cannot reach its upstream, so the only honest
  # answers are SERVFAIL or silence. Generous timeout: unbound retries first.
  ks_rcode="$(py_on_ws "$ks_ip" "$(dns_udp_probe "$gw_ip" "$(uncached_name)" 12)" 2>/dev/null | tr -d '\r' || true)"
  case "$ks_rcode" in
    SERVFAIL|TIMEOUT|REFUSED)
      ok "kill-switch: no DNS with the tunnel down (${ks_rcode})" ;;
    "")
      note_fail "could not run the DNS probe with the tunnel down; kill-switch DNS status UNKNOWN" ;;
    *)
      note_fail "KILL-SWITCH FAILED: DNS still resolved with the tunnel down (${ks_rcode} for an uncached name)" ;;
  esac

  # The gateway itself must be just as closed: it holds the credentials.
  expect_blocked "$(gw_probe "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1")" \
    "kill-switch: the gateway has no clear-net egress either" \
    "KILL-SWITCH FAILED: the gateway itself reached the internet with the tunnel down" \
    "gateway clear-net"

  if [[ "$wan_watching" == "1" ]]; then
    leaked="$(wan_capture_stop)"
    if [[ -n "$leaked" ]]; then
      note_fail "KILL-SWITCH FAILED: traffic left ${wan_if} while the tunnel was down:"
      printf '       %s\n' "$leaked" >&2
    else
      ok "kill-switch: ${wan_if} stayed silent throughout the tunnel-down probes"
    fi
  fi

  # --- part 2: nor may an ALREADY ESTABLISHED flow ---------------------------
  # The case a naive kill-switch test misses: conntrack keys on the 5-tuple,
  # not the output interface, so a flow established through the tunnel stays
  # ESTABLISHED for days after the tunnel dies, and an unqualified
  # `ct state established accept` re-admits it on the clear-net NIC. So: bring
  # the tunnel back, establish a flow through it, drop the tunnel underneath
  # it, and watch the WAN NIC itself.
  log "kill-switch: checking an ESTABLISHED flow cannot survive the tunnel dropping"
  on_gw "sudo systemctl start wg-quick@wg0" >/dev/null 2>&1 || true

  flow_up=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ "$(ws_probe "$ks_ip" "timeout 10 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1")" == "REACHED" ]]; then
      flow_up=1; break
    fi
    sleep 3
  done

  if [[ "$flow_up" != "1" ]]; then
    note_fail "could not re-establish egress, so the established-flow leak test could not run"
  else
    # ping, NOT a TCP connection: a raw socket to :443 gets reset after a few
    # packets and then emits nothing, making the WAN silent for the most boring
    # possible reason. conntrack tracks an ICMP echo flow as established
    # exactly like TCP, which is all that matters to the ruleset. -w 60 is a
    # self-destruct if this script dies before the cleanup.
    on_ws "$ks_ip" "nohup setsid ping -i 0.3 -w 60 -q 1.1.1.1 >/dev/null 2>&1 </dev/null &" >/dev/null 2>&1 || true
    sleep 2

    # Prove the generator is generating BEFORE drawing any conclusion from a
    # silent WAN: "nothing leaked" and "nothing was sent" look identical.
    gen="$(on_gw "sudo timeout 8 tcpdump -nnl -i ${internal_if} -c 1 'icmp and src host ${ks_ip}' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r' || true)"
    if [[ "${gen:-0}" == "0" ]]; then
      note_fail "the established-flow generator produced no traffic; a silent WAN would prove nothing"
    else
      if wan_capture_start; then
        on_gw "sudo systemctl stop wg-quick@wg0" >/dev/null 2>&1 || true
        # Long enough for several retransmits and ~30 pings to try to escape.
        sleep 10
        leaked="$(wan_capture_stop)"
        if [[ -n "$leaked" ]]; then
          note_fail "KILL-SWITCH FAILED: traffic left ${wan_if} after the tunnel dropped (established-flow leak):"
          printf '       %s\n' "$leaked" >&2
        else
          ok "kill-switch: an established flow does not survive the tunnel dropping"
        fi
      fi
    fi
    # `-x ping` matches the process name exactly; `-f` would also match the
    # remote `bash -c` and could kill the shell while leaving the ping alive.
    on_ws "$ks_ip" "pkill -x ping >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi

  # --- part 3: the lab must be left working ---------------------------------
  log "Kill-switch test: bringing the tunnel back up"
  if ! on_gw "sudo systemctl start wg-quick@wg0" >/dev/null 2>&1; then
    note_fail "could not restart wg-quick@wg0 after the kill-switch test"
  fi
  tunnel_restored=1
  trap - EXIT INT TERM HUP

  recovered=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ "$(ws_probe "$ks_ip" "timeout 10 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1")" == "REACHED" ]]; then
      recovered=1; break
    fi
    sleep 3
  done
  if [[ "$recovered" == "1" ]]; then
    ok "kill-switch: egress returned after the tunnel came back"
  else
    note_fail "egress did NOT return after restarting the tunnel; the lab is left without egress"
  fi

  # --- part 4: fail-closed across a reboot, proved by ordering ---------------
  # Rebooting inside verify would cut the SSH path this script needs, so assert
  # the ordering that makes a boot safe instead.
  expect_reached "$(gw_probe "systemctl show wg-quick@wg0 -p After --value | tr ' ' '\n' | grep -qx nftables.service")" \
    "wg-quick is ordered after nftables (fail-closed across a reboot)" \
    "wg-quick is NOT ordered after nftables: a boot could route before the ruleset loads" \
    "unit ordering"
  expect_reached "$(gw_probe "systemctl is-enabled nftables >/dev/null 2>&1")" \
    "nftables is enabled at boot" \
    "nftables is not enabled at boot" \
    "nftables enablement"

  # Forwarding must be a consequence of the ruleset being loaded, never a
  # persistent sysctl: a forwarding kernel with no rules is the one combination
  # that leaks everything. All of systemd's sysctl search paths, not just /etc.
  expect_blocked "$(gw_probe "grep -qs '^[[:space:]]*net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf")" \
    "ip_forward is not persistently enabled (granted by nftables.service only)" \
    "ip_forward is persistently enabled on disk: a boot with no ruleset would forward in the clear" \
    "persistent ip_forward"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  if [[ "$PHASE" == "1" ]]; then
    ok "verify: all checks passed. The workstation is provably isolated."
  else
    ok "verify: all checks passed. The workstation egresses only through the tunnel, and nothing escapes when it drops."
  fi
else
  die "verify: ${fails} check(s) failed. Do NOT treat this build as isolated."
fi
