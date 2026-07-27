#!/usr/bin/env bash
# Assert the security property this repo exists for. Hard-fails on any leak, so
# it is safe to wire into CI or a post-build hook.
#
# The contract depends on how far the build has got, so this script detects the
# phase from the gateway itself rather than from a flag. A flag would eventually
# disagree with reality, and this check must never pass because someone forgot to
# flip it.
#
#   Phase 1 (no tunnel configured): the workstation reaches the gateway, and
#   nothing else. Zero egress is the correct state.
#
#   Phase 2 (a tunnel exists): the workstation has egress, and ONLY through the
#   tunnel -- verified by Mullvad's own exit check, a DNS-leak test, an IPv6
#   test, and an active kill-switch test that drops the tunnel and watches the
#   WAN NIC directly.
#
# THE RULE THIS FILE IS BUILT AROUND: silence is never scored as security. Every
# probe must be able to say "I ran and the answer was no" separately from "I did
# not run". An ssh hop that fails, a tool that is missing, a cached DNS answer or
# a traffic generator that emits nothing all produce the same quiet output as a
# perfectly closed gateway -- and each one of those has, at some point during
# development, turned this suite green while something was actually open. So:
# probes return explicit tokens, captures carry their own liveness proof, and
# anything ambiguous is reported as a FAILURE, never as a pass.
#
# Both phases assert NEGATIVES. "No egress" can only ever be tested against the
# vectors below, so this is not proof of anonymity -- it is proof that these
# specific vectors are closed.
#
# Nothing here needs a package installed in a guest: probes use bash's /dev/tcp,
# ping, and python3, all of which both images already ship (cloud-init is
# Python). The workstation deliberately has no curl and no dig. The gateway needs
# tcpdump, which the gateway role installs for exactly this reason.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

# Resolve the gateway's host port and the internal-only VMs from the fleet, the
# same way ssh.sh does, so a reordered or renamed fleet does not silently verify
# the wrong box.
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

# on_ws <ip> <command...>: run a command on an internal-only VM through the jump.
# on_gw <command...>:      run a command on the gateway over its host port forward.
#
# `-n` on both is load-bearing, not tidiness. Without it ssh inherits the caller's
# stdin, and the per-VM loop below is fed by a here-string: the first ssh drains
# it, the next `read` hits EOF, and every internal VM after the first is silently
# never verified. The suite then reports all checks passed on a fleet it only
# partly looked at.
on_ws() {
  local ip="$1"; shift
  ssh -n "${jump[@]}" "${LAB_USER}@${ip}" "$@"
}

on_gw() {
  ssh -n "${ssh_common[@]}" -p "$gw_port" "${LAB_USER}@127.0.0.1" "$@"
}

# --- probes that cannot be confused with a broken transport ------------------
#
# ssh returns 255 when the hop itself fails (a ProxyCommand race, a
# ConnectTimeout under load, sshd's MaxStartups) -- and non-zero is exactly what
# a blocked probe returns too. Testing `if on_ws ...` therefore scores a failed
# connection as "the packet was blocked": a green kill-switch result for a check
# that never ran. These helpers make the guest say which happened, so the
# ambiguous case is distinguishable and can be failed loudly.
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

# py_on_ws <ip> <program>: run a python3 program on an internal VM.
#
# Base64 because the program travels through ssh's remote shell as well as the
# local one. Quoting a multi-line program through two shells reliably produces a
# syntax error rather than an answer, and a probe that errors out looks exactly
# like a probe that was correctly blocked.
py_on_ws() {
  local ip="$1" src="$2" b64
  b64="$(printf '%s' "$src" | base64 | tr -d '\n')"
  on_ws "$ip" "python3 -c \"import base64;exec(base64.b64decode('${b64}'))\""
}

# dns_udp_probe <resolver> [qname] [timeout]
#
# Sends a real DNS query over UDP and prints the response code, or TIMEOUT.
#
# UDP, because a `</dev/tcp/<resolver>/53` test covers TCP only and DNS is
# overwhelmingly UDP: the leak that matters most would sail straight past it. A
# UDP socket cannot be tested by connecting either -- connect() on UDP always
# "succeeds" -- so this sends a real query and reads a real answer.
#
# The response code, not merely "did something reply", because a resolver that
# cannot reach its upstream still REPLIES: with SERVFAIL. Treating any reply as
# success would score a completely severed resolver as working.
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

# A name no cache can have seen before. Any DNS check that must distinguish
# "resolution works" from "resolution is severed" needs one: unbound on the
# gateway and systemd-resolved on the workstation both cache, so re-asking for a
# name an earlier check just warmed returns instantly from cache and looks
# exactly like a live resolver. (It did: the kill-switch DNS check reported a
# leak that was nothing but a cache hit.)
uncached_name() {
  printf 'v%s%s.example.com' "$RANDOM" "$RANDOM"
}

# --- phase detection ---------------------------------------------------------
#
# sudo is required: /etc/wireguard is 0700 root, so an unprivileged `test -f`
# cannot even traverse it and reports "no tunnel" on a fully configured gateway.
#
# And the three outcomes are kept distinct. A bare `if on_gw "sudo test -f ..."`
# treats a broken sudo, a failed ssh and a genuinely absent config identically:
# it quietly drops to the Phase 1 contract, which a Phase 2 gateway whose tunnel
# is DEAD passes with flying colours -- ending in "all checks passed. The
# workstation is provably isolated." on a lab with no working anonymity layer.
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
  # `|| true` on every capture in this script is not sloppiness: lib.sh sets
  # `set -euo pipefail`, which this file inherits, so an unguarded `x="$(cmd)"`
  # aborts the whole run the moment cmd returns non-zero -- and several of the
  # commands below return non-zero in the PASSING case (`timeout` exits 124 when
  # the WAN stays silent). Failures are handled explicitly instead.
  #
  # The WAN NIC must come from the MAIN routing table. `ip route get` and
  # ansible_default_ipv4 both return wg0 once the tunnel is up, because wg-quick
  # installs policy routing rules that outrank the main table -- and a WAN-silence
  # check pointed at wg0 would watch the tunnel instead of the wire.
  wan_if="$(on_gw "ip -4 route show table main default | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$wan_if" ]] || die "could not determine the gateway's WAN interface; refusing to report a clean WAN"

  wan_addr="$(on_gw "ip -4 -o addr show dev ${wan_if} | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$wan_addr" ]] || die "could not determine the gateway's WAN address; refusing to report a clean WAN"

  # The internal NIC, found by the address it carries rather than by name, is
  # where the kill-switch test confirms its own traffic generator is working.
  internal_if="$(on_gw "ip -4 -o addr show to ${gw_ip}/32 | awk '{print \$2}' | head -1" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$internal_if" ]] || die "could not determine the gateway's internal interface (no NIC holds ${gw_ip})"

  endpoint="$(on_gw "sudo sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' /etc/wireguard/wg0.conf | head -1" 2>/dev/null | tr -d '\r' || true)"
  endpoint_ip="${endpoint%%:*}"
  endpoint_port="${endpoint##*:}"
  [[ -n "$endpoint_ip" && -n "$endpoint_port" ]] \
    || die "could not read the WireGuard endpoint from the gateway; refusing to report a clean WAN"

  # What is allowed to appear on the WAN, and nothing else:
  #   - ARP, which is link-local and carries nothing.
  #   - management SSH, scoped to tcp AND to this NIC's own address, so a leak
  #     that merely happens to involve port 22 elsewhere is still caught.
  #   - the single WireGuard endpoint.
  #
  # Exclusion, never inclusion. Filtering FOR the workstation's address is a false
  # pass: the source of a leaked packet is not something this test may assume. A
  # stale NAT binding makes it the gateway's SNATed tunnel address (seen while
  # building Task 4); with the binding gone it is a bare 10.20.0.10 (seen by
  # deliberately opening the forward path to prove this check fires at all).
  wan_filter="not arp and not (tcp port 22 and host ${wan_addr}) and not (host ${endpoint_ip} and udp port ${endpoint_port})"
  wan_cap_file="/tmp/anon-egress-wan-capture"

  log "Gateway WAN is ${wan_if} (${wan_addr}); the only permitted flow on it is ${endpoint_ip}:${endpoint_port}"
fi

# --- WAN capture -------------------------------------------------------------
#
# Watching the WAN NIC is the only authoritative answer to "did a packet leave in
# the clear". Asking the guest whether it got a reply is NOT equivalent, and the
# difference is not academic: a forward-chain regression sends the workstation's
# packets out the WAN un-SNATed, with source 10.20.0.10, for which SLIRP has no
# return path -- so no reply ever comes back, the guest's probe fails, and a
# reply-based check calls that "blocked" while traffic is leaving the machine.
#
# Runs in the background so a whole block of probes can be judged by one capture.
# -l keeps tcpdump line-buffered; without it output to a pipe or file is block
# buffered and a leak of a few packets can sit in the buffer, unflushed, until
# after the capture is read -- silently becoming a clean result.
wan_capture_start() {
  local started
  started="$(on_gw "sudo rm -f ${wan_cap_file} 2>/dev/null
sudo nohup timeout 120 tcpdump -nnl -i ${wan_if} -Q out '${wan_filter}' >${wan_cap_file} 2>/dev/null </dev/null &
sleep 2
if pgrep -x tcpdump >/dev/null 2>&1; then echo STARTED; else echo NOTSTARTED; fi" 2>/dev/null | tr -d '\r' || true)"
  # A capture that never started would report a beautifully clean WAN. Say so.
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

  # 2. Topology: exactly one non-loopback NIC. A second NIC appearing here means
  # someone gave this VM a NAT interface, which breaks the entire guarantee even
  # if every other check happens to pass at this moment. True in both phases.
  nics="$(on_ws "$ip" "ls /sys/class/net | grep -v '^lo$' | tr '\n' ' '" 2>/dev/null || true)"
  count="$(printf '%s' "$nics" | wc -w | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    ok "${short} has exactly one NIC (${nics% })"
  else
    note_fail "${short} has ${count} NICs (${nics% }); an internal-only VM must have exactly one"
  fi

  # 3. No VPN client, of any kind, on an internal-only host.
  #
  # This is the machine-checkable form of "credentials live only on the gateway".
  # Nothing else in this suite can see it: a VPN client sitting installed and
  # unconfigured leaks nothing today, so every network probe stays green while the
  # box acquires exactly the capability the design forbids.
  #
  # It guards two real drift paths. The Mullvad repo added for the browser also
  # carries `mullvad-vpn` for arm64 (an apt pin blocks it, and this catches the
  # pin being removed). And the Kali desktop RECOMMENDS ten NetworkManager VPN
  # plugins, which are purged at install time -- but a later dist-upgrade can
  # re-satisfy a Recommends and quietly put an OpenVPN GUI back on the machine
  # months after anyone last looked.
  #
  # The trailing sentinel distinguishes "scanned, found nothing" from "the scan
  # never ran": an ssh failure prints nothing at all, which would otherwise be
  # indistinguishable from a clean host and would score as a pass.
  #
  # The sentinel alone is not enough, though: it is written with `;`, not `&&`,
  # so it fires even if dpkg-query itself is missing from PATH or the package
  # database is unreadable -- the pipeline emits nothing, the echo still runs,
  # and that reads exactly like a clean host. `base-files` is added to the same
  # dpkg-query invocation as a canary: it is present on every Debian/Kali
  # install, so its absence from the output proves the query never really ran,
  # not that the box happens to be clean. It is stripped out of the "found"
  # list below before anything is reported.
  #
  # The awk filter is inverted rather than matching "installed" literally: a
  # package interrupted mid-install sits in `unpacked` or `half-configured`
  # with its files already on disk, and a filter that only recognizes the one
  # steady-state string would wave that through. Only `not-installed` and
  # `config-files` (purged, conffiles only) mean the package is genuinely not
  # present; every other status means something landed on disk, including
  # statuses nobody has thought to enumerate here.
  vpn_scan="$(on_ws "$ip" "dpkg-query -W -f='\${Package} \${db:Status-Status}\n' \
      base-files \
      mullvad-vpn \
      network-manager-openvpn network-manager-openvpn-gnome \
      network-manager-pptp network-manager-pptp-gnome \
      network-manager-l2tp network-manager-l2tp-gnome \
      network-manager-openconnect network-manager-openconnect-gnome \
      network-manager-vpnc network-manager-vpnc-gnome \
      network-manager-fortisslvpn network-manager-fortisslvpn-gnome \
      2>/dev/null | awk '\$2 != \"not-installed\" && \$2 != \"config-files\" { printf \"%s \", \$1 }'; echo __vpnscan=done" \
      2>/dev/null | tr -d '\r' || true)"
  if ! grep -q '__vpnscan=done' <<<"$vpn_scan"; then
    note_fail "the VPN-client scan did not run on ${short}; cannot assert credentials are gateway-only"
  else
    vpn_present="$(sed 's/__vpnscan=done//' <<<"$vpn_scan" | tr -s ' ' | sed 's/^ *//;s/ *$//')"
    canary_seen=0
    vpn_found=""
    for pkg in $vpn_present; do
      if [[ "$pkg" == "base-files" ]]; then
        canary_seen=1
      else
        vpn_found="${vpn_found}${pkg} "
      fi
    done
    vpn_found="${vpn_found% }"
    if [[ "$canary_seen" -ne 1 ]]; then
      note_fail "the VPN-client scan on ${short} did not observe its own canary package (base-files); dpkg-query may be missing or the package database unreadable, so credential-isolation cannot be asserted"
    elif [[ -n "$vpn_found" ]]; then
      note_fail "${short} has VPN client package(s) installed, which an internal-only host must never have: ${vpn_found}"
    else
      ok "${short} has no VPN client installed (credentials stay on the gateway)"
    fi
  fi

  # 4. Positive controls for the tools the leak checks rely on. A bash built
  # without /dev/tcp, or a ping that cannot do IPv6, fails a probe in exactly the
  # same way a blocked packet does -- which would make the corresponding leak
  # check permanently, silently green.
  expect_reached "$(ws_probe "$ip" "timeout 5 bash -c '</dev/tcp/${gw_ip}/22' >/dev/null 2>&1")" \
    "${short} has working /dev/tcp (the TCP leak probes below are meaningful)" \
    "${short} cannot open /dev/tcp even to the gateway: the TCP leak probes prove nothing" \
    "dev-tcp control"
  expect_reached "$(ws_probe "$ip" "ping -6 -c1 -W2 ::1 >/dev/null 2>&1")" \
    "${short} has working IPv6 tooling (the v6 leak probe below is meaningful)" \
    "${short} cannot ping -6 even to ::1: the IPv6 leak probe proves nothing" \
    "ping6 control"

  if [[ "$PHASE" == "1" ]]; then
    # 5. Isolation: no path off the segment. ICMP to a public address, then a TCP
    # connect, because a dropped ping alone would not rule out a working route.
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
  else
    note_fail "${short} is NOT exiting via Mullvad. Response: ${exit_json:-<none>}"
  fi

  # Secondary and deliberately non-fatal: this host is out of scope and may be
  # behind its own VPN, which would make an equality test noisy, not meaningful.
  host_pub_ip="$(python3 -c "import urllib.request;print(urllib.request.urlopen('https://am.i.mullvad.net/json',timeout=20).read().decode())" 2>/dev/null \
                 | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
  if [[ -n "$ws_pub_ip" && -n "$host_pub_ip" && "$ws_pub_ip" == "$host_pub_ip" ]]; then
    warn "${short} and this host report the same public IP (${ws_pub_ip}). Expected if the host is on the same VPN; investigate if not."
  fi

  # DNS must work via the gateway's unbound, and NOT via any external resolver.
  # The name is a fresh random one: `getent hosts example.com` would be answered
  # from the workstation's own stub cache and would report a working resolver
  # over a completely dead gateway.
  up_rcode="$(py_on_ws "$ip" "$(dns_udp_probe "$gw_ip" "$(uncached_name)" 10)" 2>/dev/null | tr -d '\r' || true)"
  case "$up_rcode" in
    NOERROR|NXDOMAIN) ok "${short} resolves DNS through the gateway (uncached lookup, ${up_rcode})" ;;
    "")               note_fail "the DNS probe against ${gw_ip} did not run on ${short}; status UNKNOWN" ;;
    *)                note_fail "${short} cannot resolve via ${gw_ip}: an uncached lookup returned ${up_rcode}" ;;
  esac

  dns_leak=0
  for resolver in 1.1.1.1 8.8.8.8; do
    rcode="$(py_on_ws "$ip" "$(dns_udp_probe "$resolver")" 2>/dev/null | tr -d '\r' || true)"
    if [[ -z "$rcode" ]]; then
      # Not a pass. A probe that failed to run produces the same silence as a
      # blocked one, and silence must never be scored as security.
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

  # IPv6 must be dead, not tunnelled. `ping -6` rather than `ping6`, which is a
  # compatibility symlink that not every image still ships.
  expect_blocked "$(ws_probe "$ip" "ping -6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1")" \
    "${short} has no IPv6 egress" \
    "IPv6 LEAK: ${short} reached a v6 address" \
    "IPv6"
done <<<"$internal_rows"

# --- the active kill-switch test ---------------------------------------------

if [[ "$PHASE" == "2" ]]; then
  echo
  log "Kill-switch test on ${ks_short} (${ks_ip})"

  # Restoration is a trap, not a final line: if an assertion below exits, or the
  # operator interrupts, the tunnel must still come back. A verify run that
  # leaves the lab without egress is worse than one that fails.
  tunnel_restored=0
  restore_tunnel() {
    if [[ "$tunnel_restored" == "1" ]]; then return 0; fi
    log "Restoring the tunnel"
    on_gw "sudo pkill -x tcpdump >/dev/null 2>&1 || true; sudo rm -f ${wan_cap_file} 2>/dev/null || true" >/dev/null 2>&1 || true
    on_ws "$ks_ip" "pkill -x ping >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    # Do not swallow a failed restart: an operator who is told "Restoring the
    # tunnel" and nothing else will assume the lab is usable again.
    if ! on_gw "sudo systemctl start wg-quick@wg0" >/dev/null 2>&1; then
      warn "could not restart wg-quick@wg0; the lab may be left without egress. Run: make ssh gateway, then sudo systemctl start wg-quick@wg0"
    fi
  }
  # INT/TERM/HUP must EXIT after restoring. A bare handler returns and bash
  # resumes the script -- straight into the tunnel-down assertions with the
  # tunnel back up, reporting leaks that are nothing but the interrupt.
  trap restore_tunnel EXIT
  trap 'restore_tunnel; exit 130' INT TERM HUP

  # --- part 1: nothing NEW may escape while the tunnel is down ---------------
  #
  # Judged by the WAN NIC as well as by the guests' own results. The guests can
  # only report whether a reply came back, and the un-SNATed leak described above
  # produces no reply at all -- so on its own that evidence is compatible with
  # traffic pouring out the WAN.
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

  # Ask the gateway's own resolver for a name nothing can have cached, and read
  # the response code. With the tunnel down unbound cannot reach its upstream, so
  # the only honest answers are SERVFAIL or silence; anything resolvable means a
  # clear-net DNS path exists. Timeout is generous because unbound retries its
  # upstream a few times before giving up.
  ks_rcode="$(py_on_ws "$ks_ip" "$(dns_udp_probe "$gw_ip" "$(uncached_name)" 12)" 2>/dev/null | tr -d '\r' || true)"
  case "$ks_rcode" in
    SERVFAIL|TIMEOUT|REFUSED)
      ok "kill-switch: no DNS with the tunnel down (${ks_rcode})" ;;
    "")
      note_fail "could not run the DNS probe with the tunnel down; kill-switch DNS status UNKNOWN" ;;
    *)
      note_fail "KILL-SWITCH FAILED: DNS still resolved with the tunnel down (${ks_rcode} for an uncached name)" ;;
  esac

  # The gateway itself must be just as closed. It is the host holding the
  # credentials, so a clear-net path here is the more valuable one to an attacker.
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
  #
  # This is the case a naive kill-switch test misses, and the reason this section
  # exists. conntrack keys on the IP 5-tuple, NOT on the output interface, so a
  # flow established through the tunnel stays ESTABLISHED for days after the
  # tunnel goes away; an unqualified `ct state established accept` then re-admits
  # it on the clear-net NIC. Only opening NEW connections after tunnel-down passes
  # cleanly while that hole is wide open -- this repo shipped exactly that bug and
  # part 1 above did not notice.
  #
  # So: bring the tunnel back, establish a flow through it, drop the tunnel
  # underneath the flow, and watch the WAN NIC itself.
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
    # Generate the flow with ping, NOT a TCP connection. The obvious approach --
    # open a socket to 1.1.1.1:443 and keep writing to it -- silently does not
    # work: the peer resets the malformed TLS after a handful of packets and every
    # later send raises BrokenPipeError. Measured on this lab: 5 sends, then
    # broken pipe. The flow then emits nothing at all, the WAN is silent for the
    # most boring possible reason, and this test passes without having tested
    # anything. ping keeps emitting for as long as it is told to, whatever the
    # peer does, and conntrack tracks an ICMP echo flow as established exactly as
    # it does a TCP one -- which is all that matters here, because no rule in the
    # ruleset distinguishes the two.
    #
    # -w 60 is a self-destruct: should this script die before the cleanup below,
    # the ping stops on its own instead of running forever on an isolated VM.
    on_ws "$ks_ip" "nohup setsid ping -i 0.3 -w 60 -q 1.1.1.1 >/dev/null 2>&1 </dev/null &" >/dev/null 2>&1 || true
    sleep 2

    # Prove the generator is generating BEFORE drawing any conclusion from a
    # silent WAN. Without this the test cannot tell "nothing leaked" from
    # "nothing was sent" -- and the second one looks identical and always passes.
    # That is not hypothetical: the TCP generator described above failed exactly
    # this way, and the WAN check reported silence with a deliberately wide-open
    # forward rule in place.
    gen="$(on_gw "sudo timeout 8 tcpdump -nnl -i ${internal_if} -c 1 'icmp and src host ${ks_ip}' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r' || true)"
    if [[ "${gen:-0}" == "0" ]]; then
      note_fail "the established-flow generator produced no traffic; a silent WAN would prove nothing"
    else
      if wan_capture_start; then
        on_gw "sudo systemctl stop wg-quick@wg0" >/dev/null 2>&1 || true
        # Long enough for several retransmits and ~30 ping packets to have had
        # every opportunity to escape.
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
    # Stop the generator. `-x ping` matches the process name exactly; `-f` with a
    # command-line pattern would also match the remote `bash -c` running it, since
    # ssh puts the whole command string in that process's argv -- killing the
    # shell first can leave the ping alive to pollute every later check.
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
  # Rebooting the gateway inside verify would be slow and would cut the very SSH
  # path the rest of this script needs, so assert the ordering that makes a boot
  # safe instead.
  expect_reached "$(gw_probe "systemctl show wg-quick@wg0 -p After --value | tr ' ' '\n' | grep -qx nftables.service")" \
    "wg-quick is ordered after nftables (fail-closed across a reboot)" \
    "wg-quick is NOT ordered after nftables: a boot could route before the ruleset loads" \
    "unit ordering"
  expect_reached "$(gw_probe "systemctl is-enabled nftables >/dev/null 2>&1")" \
    "nftables is enabled at boot" \
    "nftables is not enabled at boot" \
    "nftables enablement"

  # Forwarding must be a consequence of the ruleset being loaded, never a
  # persistent sysctl: with no ruleset the kernel default is accept, so a
  # forwarding kernel and no rules is the one combination that leaks everything.
  # All of systemd's sysctl search paths, not just /etc -- a drop-in under
  # /usr/lib or /run enables forwarding just as effectively.
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
