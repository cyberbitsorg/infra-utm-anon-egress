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

## The UTM display says "Display output is not active"

That is expected and permanent. Both base images run the distro's **`-cloud`
kernel flavour**, which is built with no DRM drivers at all — no virtio-gpu, no
framebuffer. The guest sees UTM's display device (`lspci` shows the Virtio GPU)
but nothing ever binds to it, so the display view stays dark no matter what.

The console that works is the **serial** one: the guests put their kernel console
and a getty on `ttyAMA0`, and UTM exposes it to the host as a pseudo-tty.

```bash
make console gateway        # attaches with screen; detach: Ctrl-a k, then y
make console workstation
```

Two things worth knowing:

- The pty path (`/dev/ttysNNN`) is assigned by UTM at VM start and **changes on
  every boot**, which is why `make console` queries it live instead of hardcoding it.
- `cloud-init` sets `lock_passwd: true`, so the login prompt on that console
  cannot be passed. It is a **diagnostic** channel — boot messages, cloud-init
  failures — not a way in, and not a recovery path. If you want it to be one, set
  a console password deliberately (SSH stays key-only either way).

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
