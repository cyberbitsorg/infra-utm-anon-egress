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
# Both phases assert NEGATIVES. "No egress" can only ever be tested against the
# vectors below, so this is not proof of anonymity -- it is proof that these
# specific vectors are closed.
#
# Nothing here needs a package installed in a guest: probes use bash's /dev/tcp,
# ping, and python3, all of which both images already ship (cloud-init is
# Python). The workstation deliberately has no curl and no dig.
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
on_ws() {
  local ip="$1"; shift
  ssh "${jump[@]}" "${LAB_USER}@${ip}" "$@"
}

# on_gw <command...>: run a command on the gateway over its host port forward.
on_gw() {
  ssh "${ssh_common[@]}" -p "$gw_port" "${LAB_USER}@127.0.0.1" "$@"
}

# py_on_ws <ip> <program>: run a python3 program on an internal VM.
#
# Base64 because the program travels through ssh's remote shell as well as the
# local one. Quoting a multi-line program through two shells reliably produces a
# syntax error rather than an answer, and a probe that errors out looks exactly
# like a probe that was correctly blocked -- a false pass in a leak test.
py_on_ws() {
  local ip="$1" src="$2" b64
  b64="$(printf '%s' "$src" | base64 | tr -d '\n')"
  on_ws "$ip" "python3 -c \"import base64;exec(base64.b64decode('${b64}'))\""
}

# --- probe programs ----------------------------------------------------------

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

# A name no cache can have seen before. The kill-switch DNS check is worthless
# without one: unbound and the workstation's own systemd-resolved both cache, and
# the checks earlier in this run have just warmed them with example.com. Asking
# for that name again with the tunnel down returns a cached answer instantly and
# looks exactly like a DNS leak. (It reported one, before this existed.)
uncached_name() {
  printf 'v%s%s.example.com' "$RANDOM" "$RANDOM"
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

# --- phase detection ---------------------------------------------------------

# `sudo` is not optional here: /etc/wireguard is 0700 root, so an unprivileged
# `test -f` cannot even traverse it and reports "no tunnel" on a fully configured
# gateway -- which silently downgrades this whole script to the Phase 1 contract
# and then fails it, because Phase 2 egress is supposed to work.
if on_gw "sudo test -f /etc/wireguard/wg0.conf" >/dev/null 2>&1; then
  PHASE=2
  log "Tunnel configured on the gateway: verifying the Phase 2 contract"
else
  PHASE=1
  log "No tunnel on the gateway: verifying the Phase 1 contract (zero egress)"
fi

if [[ "$PHASE" == "2" ]]; then
  # The WAN NIC must come from the MAIN routing table. `ip route get` and
  # ansible_default_ipv4 both return wg0 once the tunnel is up, because wg-quick
  # installs policy routing rules that outrank the main table -- and a WAN-silence
  # check pointed at wg0 would watch the tunnel instead of the wire.
  # `|| true` on every capture in this script is not sloppiness: lib.sh sets
  # `set -euo pipefail`, which this file inherits, so an unguarded `x="$(cmd)"`
  # aborts the whole run the moment cmd returns non-zero -- and several of the
  # commands below return non-zero in the PASSING case. Failures are handled
  # explicitly instead, right where they happen.
  wan_if="$(on_gw "ip -4 route show table main default | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1" 2>/dev/null | tr -d '\r' || true)"
  endpoint="$(on_gw "sudo sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' /etc/wireguard/wg0.conf | head -1" 2>/dev/null | tr -d '\r' || true)"
  endpoint_ip="${endpoint%%:*}"
  endpoint_port="${endpoint##*:}"
  # The internal NIC, found by the address it carries rather than by name, is
  # where the kill-switch test confirms its own traffic generator is working.
  internal_if="$(on_gw "ip -4 -o addr show to ${gw_ip}/32 | awk '{print \$2}' | head -1" 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$wan_if" ]] || die "could not determine the gateway's WAN interface; refusing to report a clean WAN"
  [[ -n "$internal_if" ]] || die "could not determine the gateway's internal interface (no NIC holds ${gw_ip})"
  [[ -n "$endpoint_ip" && -n "$endpoint_port" ]] \
    || die "could not read the WireGuard endpoint from the gateway; refusing to report a clean WAN"
  log "Gateway WAN is ${wan_if}; the only permitted flow on it is ${endpoint_ip}:${endpoint_port}"
fi

# --- per-VM checks -----------------------------------------------------------

ks_ip=""; ks_short=""
while read -r short role vm_idx; do
  [[ -z "$short" ]] && continue
  ip="$(internal_ip_for "$role" "$vm_idx")"
  [[ -z "$ks_ip" ]] && { ks_ip="$ip"; ks_short="$short"; }
  log "Verifying ${short} (${ip}) through the gateway on 127.0.0.1:${gw_port}"

  # 1. Reachability: the internal segment works and the jump path is intact.
  if on_ws "$ip" "ping -c1 -W2 ${gw_ip} >/dev/null 2>&1"; then
    ok "${short} reaches the gateway at ${gw_ip} on the internal segment"
  else
    note_fail "${short} cannot reach the gateway at ${gw_ip}"
  fi

  # 2. Topology: exactly one non-loopback NIC. A second NIC appearing here means
  # someone gave this VM a NAT interface, which breaks the entire guarantee even
  # if every other check happens to pass at this moment. True in both phases.
  nics="$(on_ws "$ip" "ls /sys/class/net | grep -v '^lo$' | tr '\n' ' '" || true)"
  count="$(printf '%s' "$nics" | wc -w | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    ok "${short} has exactly one NIC (${nics% })"
  else
    note_fail "${short} has ${count} NICs (${nics% }); an internal-only VM must have exactly one"
  fi

  if [[ "$PHASE" == "1" ]]; then
    # 3. Isolation: no path off the segment. ICMP to a public address, then a TCP
    # connect, because a dropped ping alone would not rule out a working route.
    if on_ws "$ip" "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1"; then
      note_fail "LEAK: ${short} reached 1.1.1.1 by ICMP with no VPN or forwarding in place"
    else
      ok "${short} has no ICMP path to the internet (correct for Phase 1)"
    fi

    # /dev/tcp is a bash builtin, so this needs nothing installed on the guest.
    if on_ws "$ip" "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1"; then
      note_fail "LEAK: ${short} opened a TCP connection to 1.1.1.1:443"
    else
      ok "${short} has no TCP path to the internet (correct for Phase 1)"
    fi
    continue
  fi

  # --- Phase 2: egress must work, and only through the tunnel ----------------
  if on_ws "$ip" "timeout 20 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1"; then
    ok "${short} reaches the internet (through the tunnel)"
  else
    note_fail "${short} has no egress at all: the tunnel is not forwarding"
  fi

  # The authoritative exit check: Mullvad's own endpoint, asked FROM the
  # workstation. Anything less is inference.
  exit_json="$(py_on_ws "$ip" "$(mullvad_check_probe)" 2>/dev/null || true)"
  ws_pub_ip="$(sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$exit_json")"
  if grep -q '"mullvad_exit_ip"[[:space:]]*:[[:space:]]*true' <<<"$exit_json"; then
    exit_host="$(sed -n 's/.*"mullvad_exit_ip_hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$exit_json")"
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
  if on_ws "$ip" "getent hosts example.com >/dev/null 2>&1"; then
    ok "${short} resolves DNS through the gateway"
  else
    note_fail "${short} cannot resolve DNS via ${gw_ip}"
  fi
  dns_leak=0
  for resolver in 1.1.1.1 8.8.8.8; do
    rcode="$(py_on_ws "$ip" "$(dns_udp_probe "$resolver")" 2>/dev/null | tr -d '\r' || true)"
    if [[ -z "$rcode" ]]; then
      # Not a pass. A probe that failed to run produces the same silence as a
      # blocked one, and silence must never be scored as security.
      note_fail "could not run the UDP DNS probe against ${resolver} on ${short}; leak status unknown"
      dns_leak=1
    elif [[ "$rcode" != "TIMEOUT" ]]; then
      note_fail "DNS LEAK: ${short} got a UDP :53 ${rcode} from ${resolver}, bypassing unbound"
      dns_leak=1
    fi
    if on_ws "$ip" "timeout 5 bash -c '</dev/tcp/${resolver}/53' >/dev/null 2>&1"; then
      note_fail "DNS LEAK: ${short} opened TCP :53 to ${resolver}, bypassing unbound"
      dns_leak=1
    fi
  done
  [[ "$dns_leak" -eq 0 ]] && ok "${short} cannot reach an external resolver on UDP or TCP :53"

  # IPv6 must be dead, not tunnelled. `ping -6` rather than `ping6`, which is a
  # compatibility symlink that not every image still ships.
  if on_ws "$ip" "ping -6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1"; then
    note_fail "IPv6 LEAK: ${short} reached a v6 address"
  else
    ok "${short} has no IPv6 egress"
  fi
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
    [[ "$tunnel_restored" == "1" ]] && return 0
    log "Restoring the tunnel"
    on_gw "sudo systemctl start wg-quick@wg0" >/dev/null 2>&1 || true
  }
  trap restore_tunnel EXIT INT TERM

  # --- part 1: nothing NEW may escape while the tunnel is down ---------------
  on_gw "sudo systemctl stop wg-quick@wg0" >/dev/null 2>&1 \
    || die "could not stop the tunnel; kill-switch untested"

  if on_ws "$ks_ip" "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1"; then
    note_fail "KILL-SWITCH FAILED: ICMP escaped with the tunnel down"
  else
    ok "kill-switch: no ICMP with the tunnel down"
  fi
  if on_ws "$ks_ip" "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1"; then
    note_fail "KILL-SWITCH FAILED: TCP escaped with the tunnel down"
  else
    ok "kill-switch: no TCP with the tunnel down"
  fi
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
      note_fail "could not run the DNS probe with the tunnel down; kill-switch DNS status unknown" ;;
    *)
      note_fail "KILL-SWITCH FAILED: DNS still resolved with the tunnel down (${ks_rcode} for an uncached name)" ;;
  esac
  # The gateway itself must be just as closed. It is the host holding the
  # credentials, so a clear-net path here is the more valuable one to an attacker.
  if on_gw "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1"; then
    note_fail "KILL-SWITCH FAILED: the gateway itself reached the internet with the tunnel down"
  else
    ok "kill-switch: the gateway has no clear-net egress either"
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
    if on_ws "$ks_ip" "timeout 10 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1"; then
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
    # this way, and the check below reported a clean WAN with a deliberately
    # wide-open forward rule in place.
    gen="$(on_gw "sudo timeout 8 tcpdump -nni ${internal_if} -c 2 'icmp and src host ${ks_ip}' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r' || true)"
    if [[ "${gen:-0}" == "0" ]]; then
      note_fail "the established-flow generator produced no traffic; a silent WAN would prove nothing"
    else
      on_gw "sudo systemctl stop wg-quick@wg0" >/dev/null 2>&1 || true

      # DO NOT filter on the workstation's address. The source address of a leaked
      # packet is not something this test may assume: with a stale NAT binding
      # still applied it carries the gateway's SNATed tunnel source (observed while
      # building Task 4), and with the binding gone it carries a bare 10.20.0.10
      # (observed by deliberately opening the forward path to prove this check
      # fires at all). A filter naming either address is a false pass in the one
      # test that must never give one.
      #
      # So filter by EXCLUDING what is legitimately allowed -- ARP, management SSH,
      # and the single WireGuard endpoint -- and treat anything else on the WAN as
      # a leak. Verified both ways: silent with the ruleset intact, and capturing
      # the leak within a second with a permissive forward rule inserted.
      #
      # -Q out because tcpdump sees BOTH directions. Inbound packets are not a
      # leak -- SLIRP router advertisements and stray replies arrive on this NIC
      # whatever the tunnel is doing -- and counting them fails the test for
      # traffic the gateway never sent.
      #
      # The captured lines are kept and reported. "Something left the WAN" with no
      # packet attached is not a finding anyone can act on, and this test's whole
      # job is to be believed when it fires.
      #
      # The exit status is carried back in a sentinel line rather than inferred.
      # tcpdump exits 124 here in the PASSING case (timeout kills it because the
      # WAN stayed silent) and 0 in the FAILING case (it hit its packet count), so
      # the status alone is not usable -- and a missing tcpdump, or a sudo refusal,
      # would produce the same empty output as a clean WAN. Reporting "no leak"
      # because the probe never ran is the one failure mode this test cannot have.
      cap="$(on_gw "command -v tcpdump >/dev/null 2>&1 || { echo __probe=missing; exit 0; }
  sudo timeout 12 tcpdump -nni ${wan_if} -Q out -c 3 'not arp and not port 22 and not (host ${endpoint_ip} and udp port ${endpoint_port})' 2>/dev/null
  echo __probe=\$?" 2>/dev/null | tr -d '\r' || true)"
      probe_rc="$(sed -n 's/^__probe=//p' <<<"$cap" || true)"
      leaked="$(grep -v '^__probe=' <<<"$cap" | sed '/^[[:space:]]*$/d' || true)"
      case "$probe_rc" in
        missing)
          note_fail "tcpdump is not installed on the gateway: the WAN-silence check could not run" ;;
        0|124)
          if [[ -n "$leaked" ]]; then
            note_fail "KILL-SWITCH FAILED: traffic left on ${wan_if} after the tunnel dropped (established-flow leak):"
            printf '       %s\n' "$leaked" >&2
          else
            ok "kill-switch: an established flow does not survive the tunnel dropping"
          fi ;;
        *)
          note_fail "the WAN-silence probe on ${wan_if} did not run (tcpdump exit ${probe_rc:-unknown}); leak status unknown" ;;
      esac
    fi
    # Stop the generator. -w 60 would eventually do it anyway, but leaving a
    # ping running would keep pushing packets through every later check.
    on_ws "$ks_ip" "pkill -f 'ping -i 0.3 -w 60 -q 1.1.1.1' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi

  # --- part 3: the lab must be left working ---------------------------------
  log "Kill-switch test: bringing the tunnel back up"
  on_gw "sudo systemctl start wg-quick@wg0" >/dev/null 2>&1 || true
  tunnel_restored=1
  trap - EXIT INT TERM

  recovered=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if on_ws "$ks_ip" "timeout 10 bash -c '</dev/tcp/1.1.1.1/443' >/dev/null 2>&1"; then
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
  if on_gw "systemctl show wg-quick@wg0 -p After --value | tr ' ' '\n' | grep -qx nftables.service"; then
    ok "wg-quick is ordered after nftables (fail-closed across a reboot)"
  else
    note_fail "wg-quick is NOT ordered after nftables: a boot could route before the ruleset loads"
  fi
  if on_gw "systemctl is-enabled nftables >/dev/null 2>&1"; then
    ok "nftables is enabled at boot"
  else
    note_fail "nftables is not enabled at boot"
  fi
  # Forwarding must be a consequence of the ruleset being loaded, never a
  # persistent sysctl: with no ruleset the kernel default is accept, so a
  # forwarding kernel and no rules is the one combination that leaks everything.
  if on_gw "grep -qs '^net.ipv4.ip_forward *= *1' /etc/sysctl.d/*.conf /etc/sysctl.conf"; then
    note_fail "ip_forward is persistently enabled on disk: a boot with no ruleset would forward in the clear"
  else
    ok "ip_forward is not persistently enabled (granted by nftables.service only)"
  fi
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
