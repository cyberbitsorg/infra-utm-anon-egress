#!/usr/bin/env bash
# Poll until SSH answers on a host:port, or time out.
# Usage: wait-ssh.sh <host> <port> [timeout-seconds]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

host="${1:?host required}"
port="${2:?port required}"
timeout="${3:-300}"
deadline=$(( $(date +%s) + timeout ))

log "Waiting for SSH on ${host}:${port} (up to ${timeout}s, first boot installs packages)"
# Wait for a real SSH banner, not just an open TCP port. With QEMU user-mode
# (SLIRP) hostfwd the host socket accepts connections before the guest sshd is
# reachable, so a bare `nc -z` gives a false positive and Ansible then fails on
# "banner exchange". Requiring the "SSH-..." banner confirms sshd actually answers.
until nc -w 4 "$host" "$port" </dev/null 2>/dev/null | grep -q '^SSH-'; do
  [[ $(date +%s) -lt $deadline ]] || die "Timed out waiting for ${host}:${port}"
  sleep 5
done
ok "SSH is up on ${host}:${port}"
