# UTM anonymous egress

A **gateway VM plus an isolated Kali workstation** on UTM for Apple Silicon. The
gateway is the single anonymity layer; the workstation has **no independent path
to the internet at all**. The macOS host is treated as untrusted transport and is
out of scope by design: nothing about the guarantee depends on host state.

Sibling to `infra-utm-redteam-lab`, sharing its machinery (UTM AppleScript
provisioning, cloud-init bootstrap, Ansible, `lab.conf` fleet) but not its
purpose or lifecycle. An anonymous engagement box must not share footing with
intentionally vulnerable VMs.

> **Phase 2 (this milestone) is live.** The gateway runs a Mullvad multihop
> WireGuard tunnel behind a fail-closed nftables kill-switch, resolves DNS only
> through that tunnel, and drops IPv6 outright. The only clear-net traffic
> anywhere is UDP to one WireGuard endpoint. `make verify` proves it, including
> an active test that drops the tunnel and watches the WAN NIC. Phase 1 built the
> isolation underneath; Phase 3 adds the Kali toolset and Mullvad Browser. See
> `docs/superpowers/`.

## Architecture

```
   macOS host (untrusted transport — out of scope)
        | UTM SLIRP NAT (gateway only)
        v
   +-------------------+        internal-only vmnet-host segment
   |  gateway VM       |        (NO route to internet/host)
   |  (Debian ARM64)   |<==============================+
   |  - wan NIC (NAT)  |                               |
   |    WireGuard ONLY |        +----------------------+------+
   |  - internal NIC   |        |  workstation                |
   |    10.20.0.1      |        |  (Kali ARM64)               |
   |  - nftables       |        |  - ONLY NIC: internal       |
   |    kill-switch    |        |    10.20.0.10               |
   |  - unbound (DNS)  |        |  - default route = gateway  |
   +-------------------+        |  - DNS = 10.20.0.1          |
                                |  - no VPN creds, no NAT NIC |
                                +-----------------------------+
```

The gateway is the only VM with a NAT NIC. The workstation's single NIC sits on
a host-only Apple vmnet switch with no gateway of its own, so even a fully
compromised workstation has no route out except through the gateway. That is the
"cannot physically leak" property, and `make verify` asserts it.

Because the workstation has no host port forward, the host reaches it by SSH
**ProxyJump through the gateway** — including Ansible, which uses the same hop
from the generated inventory.

## Requirements

- Apple Silicon Mac (ARM64) with an internet connection
- Xcode Command Line Tools (`xcode-select --install`) for `make` and `git`
- [UTM](https://mac.getutm.app/): `brew install --cask utm` or drag the app to
  `/Applications`. No PATH setup needed; `utmctl` is called from inside the bundle
- `qemu` for `qemu-img`: `brew install qemu`
- An ISO builder for cloud-init seeds: `xorriso` (`brew install xorriso`), or the
  built-in `hdiutil` (used automatically if `xorriso` is absent)
- `ansible`: `brew install ansible`
- Free disk space: roughly **~35 GB** (the Kali raw image alone is ~25 GiB)

`make preflight` checks the tools and generates an SSH key if you do not have one.

> **First run:** macOS asks for permission the first time your terminal controls
> UTM (a prompt, then System Settings → Privacy & Security → Automation).
> Approve it, otherwise provisioning cannot create VMs.

## Quick start

```bash
cp lab.conf.example lab.conf   # adjust if you want other names/sizes
make preflight                 # checks tools; generates the SSH key and .env
make up                        # images, VMs, cloud-init, Ansible
make verify                    # assert the isolation property
make ssh gateway               # direct, over the host port forward
make ssh workstation           # via ProxyJump through the gateway
```

`make up` is idempotent: re-running it reconciles cpu/ram of existing VMs and
starts anything that is stopped. `make destroy` deletes both VMs and
`generated/`, keeping the base images — that is also the disposable-workstation
mechanism: destroy, then `make up` clones a fresh Kali from the base image.

## Commands

```bash
make up          # full hands-off build
make provision   # create and boot VMs only (no Ansible)
make configure   # run Ansible against running VMs
make status      # VM status via utmctl
make ssh <name>  # gateway (direct) or workstation (via the gateway)
make console <n> # serial console over UTM's pty (works on any kernel)
make verify      # the security property: see "What make verify proves" below
make test        # shell unit tests, no UTM needed
make lint        # bash -n on scripts, ansible-lint if present
make down        # stop VMs
make destroy     # delete VMs and generated artifacts
```

## Configuration and secrets

Two files, both gitignored, each with a tracked `.example`. It is the same split
as `*.tf` versus `terraform.tfvars` in the sibling Hetzner repos:

| File | Holds | Why separate |
|------|-------|--------------|
| `lab.conf` | fleet, image URLs, sizes, segment | build configuration you could paste into an issue to reproduce a fleet |
| `.env` | console passwords and the path to the WireGuard config | the one file that must never leave this machine; kept at mode `0600` |

`make preflight` creates both a fresh SSH key and a `.env` if they are missing,
generating a **distinct 24-character password per VM** and writing the file `0600`
before any secret goes into it. Nothing is overwritten if it already exists, so
your own values are safe. Read them back with `grep CONSOLE_PASSWORD .env`.

Everything in `.env` is optional: an unset value means "do not configure that
feature", never a broken build. Secrets reach Ansible through a `0600` temp vars
file, never `-e key=value` — command-line arguments are visible to every user on
the host in `ps auxww`. The `group_vars` defaults stay empty strings on purpose,
since those files *are* tracked.

## The anonymity layer

The gateway runs a **Mullvad multihop WireGuard tunnel**, and an nftables ruleset
whose three chains are all `policy drop`. The only clear-net egress permitted
anywhere is **UDP to one endpoint IP and port**. Everything else — the
workstation's traffic, the gateway's own `apt`, unbound's upstream queries — goes
through the tunnel or nowhere.

### Getting an account and a config

The subscription is an external prerequisite, not a build step, and how you buy
it decides whether any of this means anything:

- Pay with **Monero or cash**. Not iDEAL, not a card — a bank-linked payment ties
  the account to your identity and defeats the entire exercise.
- Generate a **multihop** WireGuard config on Mullvad's site (entry server in one
  country, exit in another), save it somewhere outside this repo, `chmod 600` it.
- Point `MULLVAD_WG_CONFIG` in `.env` at that file. The whole config is the
  artifact, so no keys are ever transcribed by hand.

The endpoint **must be an IP address, not a hostname**. Resolving a hostname to
bring the tunnel up would need clear-net DNS before the tunnel exists — a leak by
construction. `make preflight` validates the file and tells you exactly what is
wrong if it is not usable.

The config is sanitised before it ever reaches the gateway: the `DNS =` line is
stripped (unbound owns DNS), IPv6 addresses are removed, and any `PostUp` /
`PreDown` hooks are dropped (nftables owns egress). It is installed **on the
gateway only**, mode `0600`, and never touches the workstation.

### When the tunnel is down, nothing moves

This is a feature and it will surprise you at least once. With `wg0` down the
gateway cannot `apt update`, cannot resolve a name, and cannot reach anything at
all except the one WireGuard endpoint. The workstation gets no ICMP, no TCP and
no DNS. Management SSH from the host keeps working — that is the repair path, it
arrives on the port forward and cannot carry traffic outward.

Forwarding follows the same rule: `net.ipv4.ip_forward` is **0 on disk** and is
switched on by `nftables.service` only once the ruleset has actually loaded. A
kernel that forwards while no rules exist is the one combination that leaks
everything, so it is made impossible rather than merely unlikely.

### DNS

`unbound` on the gateway listens on `10.20.0.1` and loopback — never the WAN NIC
— and forwards only to Mullvad's in-tunnel resolver. There is no second, clear-net
forwarder: a fallback resolver *is* a DNS leak. The workstation's own `:53`
traffic to any external resolver is dropped in the forward chain, so a program
that hardcodes `8.8.8.8` fails instead of quietly bypassing the resolver.

## What `make verify` proves

`make verify` detects the phase from the gateway itself, so there is no flag to
forget. With a tunnel configured it asserts:

| Check | What it means |
|-------|---------------|
| exit IP | Mullvad's own endpoint, asked **from the workstation**, reports `mullvad_exit_ip: true` |
| DNS | an uncached lookup resolves via `10.20.0.1`, and UDP **and** TCP `:53` to external resolvers both fail |
| IPv6 | no v6 egress, with a positive control proving `ping -6` itself works |
| topology | the workstation still has exactly one NIC |
| kill-switch | with `wg0` stopped: no ICMP, no TCP, no DNS, and the gateway has no clear-net path either |
| **WAN silence** | with `wg0` stopped, `tcpdump -Q out` on the WAN NIC captures nothing but the permitted endpoint and management SSH |
| established flow | a flow **already running** through the tunnel cannot survive the tunnel dropping |
| boot ordering | `wg-quick` is ordered after `nftables`, `nftables` is enabled, and forwarding is not persistent |

The last three are the ones that matter, and they are why this suite is longer
than it looks like it needs to be:

- **conntrack does not key on the output interface.** A flow established through
  the tunnel stays `ESTABLISHED` for days after the tunnel dies, so an unqualified
  `ct state established accept` re-admits it on the clear-net NIC. This repo
  shipped exactly that bug. Testing only *new* connections after tunnel-down
  passes cleanly while the hole is wide open.
- **Asking the guest is not the same as watching the wire.** A leaked packet can
  leave un-SNATed with source `10.20.0.10`, for which SLIRP has no return path —
  so no reply ever comes back and a reply-based probe calls that "blocked". When
  this was tested with a deliberately permissive forward rule, every guest-side
  check reported OK while the workstation's packets were leaving the WAN NIC.
  Only the packet capture caught it.
- **Silence is never scored as security.** A probe that fails to run, a cached
  DNS answer, or a traffic generator that emits nothing all look exactly like a
  perfectly closed gateway. Each of those has turned this suite green during
  development while something was open, so every probe now reports "did not run"
  distinctly from "was blocked", and anything ambiguous is a FAILURE.

To satisfy yourself the suite can fail, break it on purpose:

```bash
make ssh gateway
sudo nft insert rule inet filter forward iifname enp0s2 oifname enp0s1 accept
# then, from the host:
make verify              # must FAIL, printing the leaked packets
make ssh gateway
sudo systemctl restart nftables   # restores the real ruleset
```

## Fleet layout

`lab.conf` is the single source of truth. Each entry is
`"name:role [cpu=N] [ram=MiB] [disk=GB]"`:

```bash
LAB_VMS=(
  "gateway:gateway cpu=2 ram=2048 disk=20"
  "workstation:workstation cpu=4 ram=4096 disk=60"
)
```

The **role** decides the NIC layout, and that is not configurable in `lab.conf`
on purpose — the security property depends on it:

| Role | NIC layout | Reached from the host by |
|------|-----------|--------------------------|
| `gateway` | `dual`: emulated NAT (internet + SSH forward) **and** internal NIC `10.20.0.1` | `ssh -p 2301 anon@127.0.0.1` |
| anything else | `internal`: **only** the internal NIC, default route the gateway | ProxyJump through the gateway |

The gateway must stay the **first** fleet entry: its host SSH port is
`2300 + index` (`ssh_port_for`), and both the workstation's ProxyJump and `scripts/verify.sh`
derive that port from index 1.

## Consoles and the UTM display

A distro's **`-cloud` kernel flavour is built with no DRM drivers at all** — no
virtio-gpu, no framebuffer. A guest running one sees UTM's display device
(`lspci` shows the Virtio GPU) but nothing binds to it, so UTM reports "Display
output is not active" forever. That single fact drives the setup here:

| VM | Display in UTM | How |
|----|----------------|-----|
| `gateway` | **works** | Debian's `generic` image ships the standard `linux-image-arm64` kernel, which has `virtio_gpu`. Nothing to install. |
| `workstation` | **works** | Kali publishes **only** the `genericcloud` variant, so Ansible swaps the kernel — which needs apt, which needs egress, which is why it waited for the tunnel. |

Verify on either guest with `ls /sys/class/drm` (expect `card0`) and
`cat /sys/class/graphics/fb0/name` (expect `virtio_gpudrmfb`).

### The Kali display, and why it waited

The `workstation` role installs `linux-image-arm64`, points grub at it with
`GRUB_DEFAULT=saved` and reboots — ported from the sibling lab's `attacker` role
along with its two hard-won details: grub sorts the `cloud` flavour *ahead* of the
plain one at the same version, and purging the cloud kernel wedges the boot, so it
stays installed as a fallback.

It is controlled by two flags in `ansible/group_vars/role_workstation.yaml`:

```yaml
workstation_has_egress: true      # the gateway forwards this host's traffic
workstation_console_kernel: true  # the feature that needs it
```

Both were false until the tunnel worked, and that order is the point: Kali's
kernel and every package in `common_packages` download **through the VPN** rather
than over your real IP. They stay separate flags so that enabling the feature
without the egress fails immediately with an explanatory message instead of an apt
timeout. If you ever remove the tunnel, set `workstation_has_egress` back to
`false` first.

A desktop (Phase 3's Mullvad Browser needs one) depends on this having run: an
XFCE greeter has nothing to draw on under the cloud kernel.

### Serial console (works on both, any kernel)

Both guests put their kernel console and a getty on `ttyAMA0`, and UTM exposes it
to the host as a pseudo-tty. It works regardless of kernel flavour, which makes it
the reliable recovery path when the display or the network is the thing that is
broken:

```bash
make console gateway        # attaches with screen; detach: Ctrl-a k, then y
make console workstation
```

- The pty path (`/dev/ttysNNN`) is assigned by UTM at VM start and **changes on
  every boot**, which is why `make console` queries it live rather than hardcoding it.
- `cloud-init` sets `lock_passwd: true`, which would leave the console able to
  show boot output but not accept a login. The console passwords in `.env` unlock
  it (`chpasswd` on the guest, so no crypt/passlib needed on the control node), so
  the console is a real recovery path — which matters most for the workstation,
  whose only other access is through the gateway. **SSH stays key-only on both**
  (`passwordauthentication no`); these passwords are console/GUI only.
- The role also removes the Kali image's agetty **auto-login drop-ins**, which
  would otherwise hand anyone opening the console a root shell with no
  authentication. That needs no egress, so it applies from Phase 1 on.

If you would rather have the console *inside* the UTM window, switch the VM's
serial device to "Built-in Terminal" in UTM (Edit → Serial, VM stopped). That
takes the pty away from the host; `make console` detects this and points you at
the window instead.

## Threat model, honestly

Target level: **provider-resistant and leak-proof**, with the correlation
resistance that multihop buys and no more.

Guaranteed and testable, today: no clear-traffic leak (fail-closed kill-switch,
tunnel-only DNS, no IPv6), and provider resistance (anonymous acquisition,
no-logs, entry and exit in different countries). **Not** guaranteed: absolute
anonymity against a global passive adversary correlating traffic worldwide, or
application-layer fingerprinting — a browser that identifies you does so equally
well through a perfect tunnel. See `docs/superpowers/specs/` for the full
statement.

Two limits worth stating plainly:

- `make verify` asserts a **negative**, and a negative can only ever be tested
  against the vectors someone thought of. It proves those specific vectors are
  closed; it is not proof of anonymity.
- The residual failure mode is `nftables.service` failing to load at all: with no
  ruleset the kernel default is accept. That is why the ruleset is installed with
  `nft -c` validation (an unparseable file cannot land in the first place) and why
  forwarding is granted by that unit rather than by a persistent sysctl.

The VPN subscription is an external prerequisite, acquired anonymously — not a
build step. Credentials live **only on the gateway**, never on the workstation.

## License

GPLv3. See `LICENSE`.
