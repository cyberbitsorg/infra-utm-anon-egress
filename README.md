# UTM anonymous egress

A **gateway VM plus an isolated Kali workstation** on UTM for Apple Silicon. The
gateway is the single anonymity layer; the workstation has **no independent path
to the internet at all**. The macOS host is treated as untrusted transport and is
out of scope by design: nothing about the guarantee depends on host state.

Sibling to `infra-utm-redteam-lab`, sharing its machinery (UTM AppleScript
provisioning, cloud-init bootstrap, Ansible, `lab.conf` fleet) but not its
purpose or lifecycle. An anonymous engagement box must not share footing with
intentionally vulnerable VMs.

> **Phase 1 (this milestone) deliberately contains no VPN.** It builds the
> isolation the anonymity layer will later sit on, and proves it: the
> workstation reaches the gateway and *nothing else*. Phases 2 (VPN +
> fail-closed nftables kill-switch + leak-test suite) and 3 (Kali tooling) build
> on this foundation. See `docs/superpowers/`.

## Architecture

```
   macOS host (untrusted transport — out of scope)
        | UTM SLIRP NAT (gateway only)
        v
   +-------------------+        internal-only vmnet-host segment
   |  gateway VM       |        (NO route to internet/host)
   |  (Debian ARM64)   |<==============================+
   |  - wan NIC (NAT)  |                               |
   |  - internal NIC   |        +----------------------+------+
   |    10.20.0.1      |        |  workstation                |
   |  - Phase 2: VPN + |        |  (Kali ARM64)               |
   |    nftables       |        |  - ONLY NIC: internal       |
   |    kill-switch    |        |    10.20.0.10               |
   +-------------------+        |  - default route = gateway  |
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
make up                        # preflight, images, VMs, cloud-init, Ansible
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
make console <n> # serial console (the UTM display never works, see below)
make verify      # security property: workstation isolated but reaches gateway
make test        # shell unit tests, no UTM needed
make lint        # bash -n on scripts, ansible-lint if present
make down        # stop VMs
make destroy     # delete VMs and generated artifacts
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
| `workstation` | dead until Phase 2 | Kali publishes **only** the `genericcloud` variant, so the kernel must be swapped from Ansible — which needs apt, which needs egress the workstation does not have yet. |

Verify it on the gateway with `ls /sys/class/drm` (expect `card0`) and
`cat /sys/class/graphics/fb0/name` (expect `virtio_gpudrmfb`).

### The Kali display, and why it waits

The `workstation` role already contains the fix — install `linux-image-arm64`,
point grub at it with `GRUB_DEFAULT=saved`, reboot — ported from the sibling
lab's `attacker` role along with its two hard-won details: grub sorts the `cloud`
flavour *ahead* of the plain one at the same version, and purging the cloud
kernel wedges the boot, so it stays installed as a fallback.

It is gated off, in `ansible/group_vars/role_workstation.yaml`:

```yaml
workstation_has_egress: false      # the gateway forwards this host's traffic
workstation_console_kernel: false  # the feature that needs it
```

Flip both once Phase 2's tunnel is up. Doing it in that order is deliberate:
Kali's kernel and desktop then download **through the tunnel** rather than over
your real IP. Enabling the feature without the egress flag fails immediately with
an explanatory message instead of an apt timeout.

A desktop (Phase 3's Mullvad Browser needs one) depends on this block having run:
an XFCE greeter has nothing to draw on under the cloud kernel.

### Serial console (works on both, any kernel)

Both guests put their kernel console and a getty on `ttyAMA0`, and UTM exposes it
to the host as a pseudo-tty. This is the only console the workstation has today:

```bash
make console gateway        # attaches with screen; detach: Ctrl-a k, then y
make console workstation
```

- The pty path (`/dev/ttysNNN`) is assigned by UTM at VM start and **changes on
  every boot**, which is why `make console` queries it live rather than hardcoding it.
- `cloud-init` sets `lock_passwd: true`, so by default the login prompt cannot be
  passed: it is a **diagnostic** channel (boot messages, cloud-init failures), not
  a way in. Set `workstation_console_password` to make it a real recovery path —
  worth considering, since the workstation has no host port forward and the
  console is its only access if the gateway ever fails. SSH stays key-only either way.
- The role also removes the Kali image's agetty **auto-login drop-ins**, which
  would otherwise hand anyone opening the console a root shell with no
  authentication. That needs no egress, so it applies from Phase 1 on.

If you would rather have the console *inside* the UTM window, switch the VM's
serial device to "Built-in Terminal" in UTM (Edit → Serial, VM stopped). That
takes the pty away from the host; `make console` detects this and points you at
the window instead.

## Threat model, honestly

Target level: **provider-resistant and leak-proof**, with meaningful
correlation-resistance once the mixnet lands in Phase 2.

Guaranteed and testable: no clear-traffic leak (fail-closed kill-switch,
tunnel-only DNS, no IPv6 leak), provider resistance (anonymous acquisition,
no-logs, multi-hop). **Not** guaranteed: absolute anonymity against a global
passive adversary correlating traffic worldwide, and application-layer
fingerprinting. See `docs/superpowers/specs/` for the full statement.

VPN subscriptions are an external prerequisite, acquired anonymously — not a
build step. Credentials will live **only on the gateway**, never on the
workstation.

## License

GPLv3. See `LICENSE`.
