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
> an active test that drops the tunnel and watches the WAN NIC. The exit country
> is chosen in `.env` and the multihop config is assembled at build time.
>
> Phase 1 built the isolation underneath. Phase 3 is complete: the XFCE desktop,
> Mullvad Browser, and a Kali toolset selected per function in `lab.conf`. See
> `docs/superpowers/`.

> **Before you rely on this, read [Threat model,
> honestly](#threat-model-honestly).** `make verify` asserts a negative, so it
> proves the vectors someone thought of are closed, not that you are anonymous.
> The things most likely to undo the whole exercise (how you paid, where your
> account number has been, what the Mac is running) sit outside anything this
> code can check.

## Architecture

```
   macOS host (untrusted transport, out of scope)
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
**ProxyJump through the gateway**, including Ansible, which uses the same hop
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

**Step 0, before any `make` target: you need a Mullvad subscription.** The build
has no tunnel without one, and *how you obtained it* decides whether any of the
rest means anything. Read "Threat model, honestly" before you pay for it. The
mistakes that matter are made here, not in the code.

```bash
# 1. Get the account (external prerequisite)
#    Pay with Monero or cash. A bank-linked payment ties the account to you.
#    The account NUMBER is the only credential there is -- never paste it into a
#    terminal, a chat, a shell history or an AI assistant. See the threat model.

# 2. Download WireGuard configs from Mullvad's config generator into secrets/,
#    named exactly <hostname>.conf -- e.g. nl-ams-wg-001.conf. Grabbing every
#    country at once is fine; that is what MULLVAD_EXIT selects from.
chmod 600 secrets/*.conf       # the bundle unpacks world-readable

# 3. Build
cp lab.conf.example lab.conf   # adjust if you want other names/sizes
make preflight                 # checks tools; generates the SSH key and .env
$EDITOR .env                   # set MULLVAD_EXIT, e.g. "nl"
make up                        # images, VMs, cloud-init, Ansible
make verify                    # assert the isolation property -- read the output
make ssh gateway               # direct, over the host port forward
make ssh workstation           # via ProxyJump through the gateway
```

`make preflight` refuses to build rather than guess: no configs in `secrets/` for
the country you named, a pair that is not genuine multihop, or an unusable config
all stop it **before any VM exists**, each with a message that says what to
change. If it passes and `make verify` is green, read the "What is not" part of
the threat model anyway. A green run is a narrower claim than it looks.

`make up` is idempotent: re-running it reconciles cpu/ram of existing VMs and
starts anything that is stopped. `make destroy` deletes both VMs and
`generated/`, keeping the base images. That is also the disposable-workstation
mechanism: destroy, then `make up` clones a fresh Kali from the base image.

## How long `make up` takes, and how to watch it

A full cold build (`make destroy`, then `make up`) is **measured at about
6.5 minutes** end to end on an M-series Mac, with the desktop and Mullvad Browser
installed. That figure assumes `KALI_TOOL_GROUPS` is empty, the default.
Selecting tool groups adds time on top of it, roughly proportional to their
package count over the tunnel; see "Kali toolset" below for a measured
incremental install, not a whole-build figure.

**That figure excludes the base-image download**, which `make destroy` does not
touch and which every build after the first reuses from `images/`. On a genuinely
first-ever run, that download dominates everything on this page. The Kali image
alone is ~25 GiB raw, and no measurement of the rest is a useful predictor of
it. See the "Base images" row below.

Of the 6.5 minutes, roughly half is the workstation's ~950-package desktop,
downloaded over the VPN, so the figure tracks your exit node more than your Mac.
(Before the desktop existed the same build took about 3 minutes.) Re-measure on
your own link with

```bash
make destroy && time make up 2>&1 | tee cold-build.log
```

If yours takes noticeably longer than that, the two things that vary are named
below; if it takes *much* longer with an idle VM, see "When it is genuinely
stuck".

What `make up` does, in order:

| Phase | What happens |
|-------|--------------|
| Preflight | tool checks, SSH key, `.env`, WireGuard config validation |
| Base images | verified against their published checksums. **The first run ever downloads them.** The Kali image alone is ~25 GiB raw, so that download dominates everything else and can take tens of minutes on a slow link. Every later build reuses the cache |
| Staging | a per-VM disk is cloned from each base image and resized. Effectively free on APFS, which copies on write |
| Provisioning | UTM creates and boots both VMs, then the build waits for SSH |
| cloud-init | first boot: user, keys, static addressing |
| Ansible (gateway) | WireGuard, the kill-switch, unbound |
| Ansible (workstation) | packages, **a whole kernel, a 951-package desktop and a browser, all downloaded through the VPN**, then a reboot |

The last row is the one that scales with your tunnel: the workstation has no
route of its own, so every byte it installs crosses the VPN. A slow exit node
shows up here and nowhere else. That is the entire point of enabling its egress
only after the tunnel works.

**Why it looks stuck.** Ansible prints a task's name and then nothing at all
until that task finishes, so the longest steps are exactly the ones that show no
output: `Install the standard Kali kernel`, `Install the Kali XFCE desktop`, the
reboot handler after them, and, on a first-ever run, the image download before
Ansible starts at all. The desktop task is the longest single silence in the
build by a wide margin. Silence is normal; silence *plus an idle VM* is not.

### Watching it

Run the build so you can read it afterwards:

```bash
make up 2>&1 | tee build.log
```

Beware `| tail`: it buffers everything until the command ends, so you see nothing
while it runs. `tee` does not.

From another terminal:

```bash
make status                 # are both VMs actually running
make console gateway        # serial console: real boot output, works on any kernel
```

Or ask the gateway how far it has got. These flip on in this order:

```bash
make ssh gateway
systemctl is-active nftables wg-quick@wg0 unbound
sudo wg show wg0 latest-handshakes     # non-zero means the tunnel is really up
```

### When it is genuinely stuck

A task that sits for more than a few minutes while the VM is idle is a bug, not
patience. The build reconfigures the network underneath its own SSH connection,
so a rule that stops covering the management path drops both the replies *and*
the RST. The control node is never told, and `make up` would hang indefinitely.
That is why `ansible.cfg` sets `ServerAliveInterval`: a connection that has truly
stopped answering now fails the run in about two minutes with a real error
instead of hanging. Both known instances of this are written up in the comments
at `ansible/roles/gateway/templates/nftables.conf.j2` and `ansible.cfg`.

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
file, never `-e key=value`, because command-line arguments are visible to every user on
the host in `ps auxww`. The `group_vars` defaults stay empty strings on purpose,
since those files *are* tracked.

### Host-only subnet (and the VPN collision it can cause)

The internal segment rides an Apple **vmnet host-only** switch. That switch has
its own subnet, the address the host side of the bridge (`bridge100` on the Mac)
gets, and **macOS assigns it, not this repo**: UTM only asks vmnet for `host`
mode, and macOS picks the bridge address itself (`192.168.128.0/24` by default),
with no reliable knob to change it (see below). It is independent of
`LAB_SEGMENT`, which is the static address space the guests use on that switch.

This bites when the vmnet subnet **overlaps a route the Mac already has**. The
macOS default is `192.168.128.0/24`, and a WireGuard VPN (Squawker) used a tunnel
whose gateway was `192.168.128.1` inside a pushed `192.168.128.0/18`. Because a
connected `/24` on `bridge100` outranks the tunnel's `/18`, macOS bound the VPN's
`10.x` routes to the **bridge** instead of the tunnel. Symptom: the VPN client
says "tunnel up", but hosts behind it are unreachable. The packets vanish into
the VM switch. Confirm with `route -n get <ip>`; if `interface:` is `bridge…`
rather than a `utun…`, this is it.

Moving the bridge off that range turns out **not to be cleanly possible** on
current Apple Silicon macOS. `com.apple.vmnet.plist`'s `Host_Net_*` keys are
ignored for host mode (setting them leaves `bridge100` where it was), and the
`Shared_Net_Address` + wiping `/var/db/dhcpd_leases` workaround is reverted by
the system on the next VM start. It is "not bulletproof" by every account. So
this repo does **not** try to move the bridge.

Instead we treat the collision as a fail-closed condition. `HOST_ONLY_SUBNET` in
`lab.conf` **declares the subnet the bridge actually uses** (`192.168.128.0/24`,
the macOS default), and `make preflight` refuses to build while a live route's
gateway lands inside it, which is exactly what a colliding VPN looks like. The
remedy is operational and 100% reliable: **bring the VPN down (or the VMs down)
before building**, so the bridge and the tunnel are never up on the same range at
once. Preflight also warns if the running bridge is on a subnet other than the
declared one, so a future macOS default change surfaces immediately rather than
silently.

If you ever *do* want to attempt the move, the fragile community recipe is:

```bash
P=/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist
sudo defaults write "$P" Shared_Net_Address -string 172.16.20.1   # NOT Host_Net_*
sudo defaults write "$P" Shared_Net_Mask   -string 255.255.255.0
sudo rm -f /var/db/dhcpd_leases            # else bootpd re-derives the old subnet
make down && osascript -e 'quit app "UTM"' && sudo reboot
```

Expect macOS to sometimes revert it; if it does, set `HOST_ONLY_SUBNET` back to
whatever `bridge100` actually shows and rely on the preflight guard.
See [UTM #4932](https://github.com/utmapp/UTM/discussions/4932) and
[Apple DTS 702377](https://developer.apple.com/forums/thread/702377).

## The anonymity layer

The gateway runs a **Mullvad multihop WireGuard tunnel**, and an nftables ruleset
whose three chains are all `policy drop`. The only clear-net egress permitted
anywhere is **UDP to one endpoint IP and port**. Everything else (the
workstation's traffic, the gateway's own `apt`, unbound's upstream queries) goes
through the tunnel or nowhere.

### Getting an account and a config

The subscription is an external prerequisite, not a build step, and how you buy
it decides whether any of this means anything:

- Pay with **Monero or cash**. Not iDEAL, not a card. A bank-linked payment ties
  the account to your identity and defeats the entire exercise.
- Generate WireGuard configs on Mullvad's site. **Every config their generator
  emits is single-hop**, one per server, and there is no multihop option to tick.
  Getting a second hop is a change you or this repo makes afterwards.
- Then pick one of two ways to get there, and set exactly one of them in `.env`
  (they are mutually exclusive, and setting both is refused):
  - **`MULLVAD_EXIT`**: drop the downloaded configs into `secrets/` as
    `<hostname>.conf` and name the exit country. The build assembles multihop
    for you; see "Choosing the exit country" below. This is the easier path and
    the one `make verify` can check.
  - **`MULLVAD_WG_CONFIG`**: point it at a multihop config you assembled
    yourself, saved outside this repo and `chmod 600`. The whole config is the
    artifact, so no keys are ever transcribed by hand.

The endpoint **must be an IP address, not a hostname**. Resolving a hostname to
bring the tunnel up would need clear-net DNS before the tunnel exists, a leak by
construction. `make preflight` validates the config it is going to use, either
way, and tells you exactly what is wrong if it is not usable.

The config is sanitised before it ever reaches the gateway: the `DNS =` line is
stripped (unbound owns DNS), IPv6 addresses are removed, and any `PostUp` /
`PreDown` hooks are dropped (nftables owns egress). It is installed **on the
gateway only**, mode `0600`, and never touches the workstation.

### Choosing the exit country

Set the exit in `.env` by name, at whatever precision you want:

```bash
MULLVAD_EXIT="bg"        # any Bulgarian server you have a config for
MULLVAD_ENTRY=""         # empty: any active server in another country
```

One config per server must sit in `secrets/` as `<hostname>.conf`. Mullvad's
config generator will hand you every server at once; drop them in.

**The build assembles multihop for you.** A Mullvad multihop config is the exit
server's own config with one line changed: `Endpoint = <entry ip>:<exit
multihop port>`. That is exactly what the build writes, to a `0600` temp
file that never persists. It is assembled twice: `make preflight` builds one to
validate it and throws it away, and the copy that actually reaches the gateway
is assembled during `make up` / `make configure` from the same pinned pair.
(`make configure` never runs preflight, so it cannot rely on it.) The entry sees
your real IP but not your destination; the exit sees your destination but not
your IP.

**Single-hop is refused, not discouraged.** The build fails before any VM exists
if entry and exit are the same server, share a country, or resolve to port
51820. Every config Mullvad's generator emits is single-hop, so this is the
difference between what you downloaded and what you asked for.

**Your choice is pinned.** `generated/mullvad-exit.chosen` holds the two
hostnames (never keys), so `make configure` cannot move your tunnel to another
country mid-lab. `make destroy` clears it, so each fresh lab gets a fresh pair.
Editing `MULLVAD_EXIT` discards the pin on the next run.

**`make verify` checks you got what you chose.** It compares the exit hostname
`am.i.mullvad.net` reports against the pinned one, and the pinned one against
`MULLVAD_EXIT`, failing on either mismatch. The second comparison is what makes
the first mean anything: edit `MULLVAD_EXIT` and run `make verify` before
`make configure`, and the tunnel still matches the *old* pin perfectly.
Egressing via *some* Mullvad exit was never the claim worth making.

**A fetch happens over your real IP.** Selecting a server needs Mullvad's public
relay list (`https://api.mullvad.net/www/relays/wireguard/`), and it is fetched
from your Mac, not through the tunnel. During `make up` there is no tunnel to
use yet. It is cached in `generated/` for 7 days. Note that `make configure`
needs the list too (it assembles the config itself, and never runs preflight),
so a configure-only run against a cache older than 7 days makes that same
real-IP request even though the lab is already up and the tunnel is working. If
you would rather not make the request at all, use `MULLVAD_WG_CONFIG` with a
config you assembled yourself.

`MULLVAD_EXIT` and `MULLVAD_WG_CONFIG` are mutually exclusive; setting both is
refused rather than resolved by precedence. Switching between them is fine, but
`make verify` reads `.env` to know which one built the lab: with `MULLVAD_EXIT`
set it demands a readable pin and fails without one, and with only
`MULLVAD_WG_CONFIG` set it says out loud that the country check does not apply
and ignores any pin left over from an earlier lab.

### When the tunnel is down, nothing moves

This is a feature and it will surprise you at least once. With `wg0` down the
gateway cannot `apt update`, cannot resolve a name, and cannot reach anything at
all except the one WireGuard endpoint. The workstation gets no ICMP, no TCP and
no DNS. Management SSH from the host keeps working. That is the repair path, and it
arrives on the port forward and cannot carry traffic outward.

Forwarding follows the same rule: `net.ipv4.ip_forward` is **0 on disk** and is
switched on by `nftables.service` only once the ruleset has actually loaded. A
kernel that forwards while no rules exist is the one combination that leaks
everything, so it is made impossible rather than merely unlikely.

### DNS

`unbound` on the gateway listens on `10.20.0.1` and loopback, never the WAN NIC,
and forwards only to Mullvad's in-tunnel resolver. There is no second, clear-net
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
  leave un-SNATed with source `10.20.0.10`, for which SLIRP has no return path,
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
on purpose. The security property depends on it:

| Role | NIC layout | Reached from the host by |
|------|-----------|--------------------------|
| `gateway` | `dual`: emulated NAT (internet + SSH forward) **and** internal NIC `10.20.0.1` | `ssh -p 2301 anon@127.0.0.1` |
| anything else | `internal`: **only** the internal NIC, default route the gateway | ProxyJump through the gateway |

The gateway must stay the **first** fleet entry: its host SSH port is
`2300 + index` (`ssh_port_for`), and both the workstation's ProxyJump and `scripts/verify.sh`
derive that port from index 1.

## Consoles and the UTM display

A distro's **`-cloud` kernel flavour is built with no DRM drivers at all**: no
virtio-gpu, no framebuffer. A guest running one sees UTM's display device
(`lspci` shows the Virtio GPU) but nothing binds to it, so UTM reports "Display
output is not active" forever. That single fact drives the setup here:

| VM | Display in UTM | How |
|----|----------------|-----|
| `gateway` | **works** | Debian's `generic` image ships the standard `linux-image-arm64` kernel, which has `virtio_gpu`. Nothing to install. |
| `workstation` | **works** | Kali publishes **only** the `genericcloud` variant, so Ansible swaps the kernel, which needs apt, which needs egress, which is why it waited for the tunnel. |

Verify on either guest with `ls /sys/class/drm` (expect `card0`) and
`cat /sys/class/graphics/fb0/name` (expect `virtio_gpudrmfb`).

### The Kali display, and why it waited

The `workstation` role installs `linux-image-arm64`, points grub at it with
`GRUB_DEFAULT=saved` and reboots, ported from the sibling lab's `attacker` role
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

The desktop itself sits on top of this. `kali-desktop-xfce` and Mullvad Browser
are installed by the `workstation` role behind `workstation_desktop`, and log in
through a `lightdm` greeter that deliberately **never** auto-logs in: the
console password in `.env` is required, and the role refuses to run without it.

Two things about that install are worth knowing:

- It is by far the longest operation in the repo. 951 packages and a browser,
  every byte through the VPN.
- `kali-desktop-xfce` hard-depends on NetworkManager and recommends ten
  NetworkManager VPN plugins. The plugins are purged and asserted absent by
  `make verify`; NetworkManager itself is installed but configured with
  `dns=none` and the workstation's NIC marked unmanaged, so it can neither take
  the interface nor rewrite `/etc/resolv.conf`. A GUI VPN wizard on the one host
  that must never hold VPN credentials is not a cosmetic concern, and neither is
  a daemon that rewrites the resolver this design depends on.

### Kali toolset

`KALI_TOOL_GROUPS` in `lab.conf` picks which Kali function groups the
workstation gets, space separated, without the `kali-tools-` prefix:

```bash
KALI_TOOL_GROUPS="top10 web passwords"
```

Empty is a legitimate build: a bare Kali with the desktop and browser.

The prefix is prepended by the code and never typed, which is a security
control rather than a convenience. Measured on 2026-07-30 with `apt-get -s`
against the live archive: all 29 `kali-tools-*` groups pull no VPN package at
all, while `kali-linux-headless`, `-default` and `-large` each pull `openvpn`,
`vpnc` and `vpnc-scripts`, and `kali-linux-everything` adds `wireguard-tools`.
Those four are exactly what `make verify`'s no-VPN-client assertion would fail
on, and none of them can be named in `KALI_TOOL_GROUPS`.

The measurement is not trusted on its own. Kali can add a `Recommends` at any
time, so the role re-checks after every install: anything on the watch list
that is present gets purged, and a purge that would take the requested tools
with it fails the build instead of running. `make verify` then asserts,
independently, both that no VPN client is installed and that every configured
group is.

Everything is downloaded through the multihop tunnel, never over the real IP.
That is the reason it is slow: a group is 300 to 650 packages (the per-group
sizes are listed in `lab.conf.example`). Installing `top10` and `web`, 301 and
609 new packages respectively, with `make configure` against an
already-provisioned workstation was measured on 2026-07-31 at **4m 5s**
wall-clock (`time`'s own line:
`4:05.48 total`), leaving `dpkg-query -W | wc -l` at 1966 packages and `df -h /`
at 12G used of 59G. Re-running `make configure` immediately afterwards changed
nothing on either host, which is the idempotency the role is supposed to have
at this size too.

That figure is an incremental install on top of an existing desktop, not a
whole-build number: it starts from a workstation that already has cloud-init,
the kernel swap and the desktop done, so it is not directly comparable to the
"How long `make up` takes" figures above, which are measured with
`KALI_TOOL_GROUPS` empty (the default).

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
  the console is a real recovery path, which matters most for the workstation,
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

### What is guaranteed, and testable

No clear-traffic leak (fail-closed kill-switch, tunnel-only DNS, no IPv6), and
provider resistance: entry and exit in different countries, so neither Mullvad
server sees both who you are and where you went. `make verify` asserts all of it
against the running lab, including an active test that drops the tunnel and
watches the WAN NIC.

### What is not

**`make verify` green does not mean "I am anonymous."** It means the vectors
someone thought of are closed. It asserts a negative, and a negative can only
ever be tested against a list. Specifically, none of the following is covered by
any check in this repo:

- **Your Mullvad account number is your only credential, and you cannot change
  it.** There is no password beside it, no second factor, and no rotation: the
  number is fixed for the life of the account, so recovering from a disclosure
  means buying a *new* account and a new subscription. Brute force is not the
  threat (16 digits against a rate-limited server is hopeless); disclosure is.
  Treat it like a bearer token. Never paste it into a terminal, a chat, an issue,
  a shell history or an AI assistant, and note that anything you type into a tool
  that keeps a transcript sits on disk in plaintext, indefinitely.
- **With an AI assistant attached to your editor, highlighting a secret is
  enough.** The editor plugin sends your current selection along with whatever
  you type, so the value reaches the assistant's context and its on-disk
  transcript without you copying, pasting, or asking about it. Opening the file
  is harmless (only the path is sent); selecting text in it is not. This is not a
  hypothetical: it happened twice while this repo was being written, and is why
  the warning exists.
- **What a leaked account number actually costs you** is smaller than it looks,
  which is worth knowing before you panic-buy a replacement. Someone holding it
  can spend your remaining time, remove your WireGuard keys and add their own,
  and generally disrupt you. They cannot read your traffic history, because
  Mullvad does not keep it, and there is no email address or payment method
  behind the account to expose if you bought it with cash or Monero. The damage
  is theft of service and sabotage, not deanonymisation.
- **Deleting a key file does not revoke the key.** WireGuard keys stay valid at
  Mullvad until you remove them there. Rotating locally and leaving the old one
  registered means the old one still works.
- **How you paid.** A bank-linked payment ties the account to your identity and
  no tunnel repairs that. Monero or cash, or the exercise is theatre.
- **The macOS host.** It is untrusted transport, deliberately out of scope.
  Anything watching the Mac (a backup agent, an EDR tool, an MDM profile, a
  screen recorder) sees everything before it ever reaches the tunnel.
- **One request over your real IP.** Selecting an exit needs Mullvad's public
  relay list, fetched from the Mac before the lab exists. It is cached for 7
  days. `MULLVAD_WG_CONFIG` avoids it entirely.
- **Application-layer fingerprinting.** A browser that identifies you does so
  just as well through a perfect tunnel. That is what Mullvad Browser is for, and
  why the workstation ships it rather than a hardened Firefox.
- **Traffic-volume and timing correlation** by an adversary who sees both ends.
  Multihop raises the cost; it does not remove the possibility.
- **What you do inside the session.** Logging into an account that is yours ends
  the exercise regardless of how clean the plumbing is.

### Operator mistakes that break the guarantee

These are the concrete actions, not abstractions. Each has bitten this repo or
came within one change of doing so:

| You do this | What goes wrong |
|-------------|-----------------|
| Edit `MULLVAD_EXIT`, then run `make verify` before `make configure` | You verify the **old** tunnel. The exit assertion now catches this, but the ordering is not intuitive: change `.env` → `make configure` → `make verify`. |
| Change `nftables.conf.j2` or `verify.sh` and skip the negative control | A too-permissive forward rule passes every guest-side probe. This is not hypothetical: it happened, and only `tcpdump -Q out` on the WAN caught it. The recipe is in "What `make verify` proves". |
| Unpack Mullvad's config bundle and leave it at the default mode | Hundreds of private keys world-readable. `make preflight` and the build now warn, but the warning scrolls past. Run `chmod 600 secrets/*.conf`. |
| `apt install` a VPN client on the workstation | The check enumerates known clients plus any `network-manager-*` plugin. A client under an unfamiliar name is **not** caught. The workstation must never hold VPN credentials. |
| Trust "the tests pass" | Tests can pass without testing anything. Ask for the mutation evidence instead: *break the guard and show me the test fails.* See `CLAUDE.md`. |
| Reuse the workstation across engagements | It is disposable by design. `make destroy && make up` gives a fresh Kali and a fresh entry/exit pair. |
| Run the lab while a host VPN is up | The vmnet bridge can hijack a route that falls inside its subnet. `make preflight` refuses; see "Host-only subnet". |

### Residual technical failure mode

`nftables.service` failing to load at all: with no ruleset, the kernel default is
accept. That is why the ruleset is installed with `nft -c` validation, so an
unparseable file cannot land in the first place, and why forwarding is granted
by that unit rather than by a persistent sysctl. `make verify` checks both.

The VPN subscription is an external prerequisite, acquired anonymously, not a
build step. Credentials live **only on the gateway**, never on the workstation.
See `docs/superpowers/specs/` for the full statement.

## If you change this code

One rule matters more than the rest, and it is not obvious:

> **A guard is not tested until someone has broken it and watched the test die.**

"The suite is green" is nearly no information in this repo. Every property here is
a *negative* (no leak, no VPN client, not the wrong country), and a negative
passes by default. A test that never exercises its guard, a probe that failed to
run, and a genuinely closed gateway all produce the same silence.

So when you add or change a guard: delete it, run the covering test, and confirm
the test fails **through the assertion that names that behaviour**, not through
an unrelated crash. Then put it back. It costs a minute and it is the only thing
that distinguishes a test that runs from a test that bites.

This is not defensive boilerplate. All of the following shipped looking correct
during development, and mutation is what exposed each one:

- a helper printing a bare newline on zero matches, so "nothing matched" and "one
  empty result" were indistinguishable to every caller downstream
- a required rejection branch no fixture could reach: deleting the guard left the
  suite green
- a test for the entry/exit different-country rule, the whole point of multihop,
  that caught its own regression in **14 of 30 runs**, because random selection
  landed on a legal pair often enough. Twenty green runs had proven *stability*,
  which is a different question from *sensitivity*
- a production check weakened from `-s` to `-e` to satisfy a fixture that was
  itself wrong. Fix the fixture, never the guard
- a code comment asserting a SIGPIPE-safety property the implementation did not
  have, measured failing 30 times out of 30 against the real relay list
- a regression test whose fixture was too small to trigger the condition it was
  written to catch

Also: after **any** change to `nftables.conf.j2` or `scripts/verify.sh`, re-run
the negative control in "What `make verify` proves". Guest-side probes cannot see
a packet that leaves un-SNATed and gets no reply; only `tcpdump -Q out` on the WAN
can. That is not a hypothetical. It is how a real leak was found here.

`make test` runs the shell unit tests with no UTM and no Mullvad account needed.
`make lint` syntax-checks every script. Both are cheap; run them constantly.

## License

GPLv3. See `LICENSE`.
