-- Create one QEMU aarch64 VM in UTM from an existing disk + cloud-init seed.
--
-- The NIC layout is PER ROLE and is the security property of this repo:
--
--   nicLayout "dual" (the gateway only):
--     net0 = "emulated" (QEMU user/SLIRP): NAT for internet + the host SSH
--            port-forward. The hostfwd ONLY works with QEMU user networking; UTM
--            "shared" (vmnet-shared) silently ignores port forwards, so keep net0
--            "emulated" so the 127.0.0.1:{port} SSH forward works.
--     net1 = "host" (vmnet-host): the isolated internal segment.
--
--   nicLayout "internal" (everything else, e.g. the workstation):
--     net0 = "host" (vmnet-host) and NOTHING ELSE. No NAT NIC, so the VM has no
--            path to the internet, the host, or the host's LAN -- only the
--            internal segment, where the gateway is its default route. No host
--            port forward either: the host reaches it by SSH ProxyJump through
--            the gateway.
--
-- All "host" mode NICs share one Apple vmnet L2 switch, so the VMs on the
-- segment reach each other on 10.20.0.0/24. (Two "emulated" NICs do NOT bridge:
-- each is its own private SLIRP net, so guest-to-guest traffic never flows.)
-- "host" mode is host-only with no gateway of its own, which is exactly why an
-- internal-only VM cannot leak.
--
-- Invoked by create-vm.sh via: osascript create-vm.applescript <args...>
--
-- NOTE: This is the single integration point with UTM. Property names follow the
-- UTM AppleScript dictionary (docs.getutm.app/scripting/reference). If a future
-- UTM version rejects a key, adjust it here only.
on run argv
	set vmName to item 1 of argv
	set diskPath to item 2 of argv
	set seedPath to item 3 of argv
	set memMiB to (item 4 of argv) as integer
	set cpuCores to (item 5 of argv) as integer
	set macNat to item 6 of argv
	set macInternal to item 7 of argv
	set sshPort to (item 8 of argv) as integer
	set nicLayout to item 9 of argv

	set diskFile to POSIX file diskPath
	set seedFile to POSIX file seedPath

	-- NOTE: do NOT set `protocol:TCP` on the port forward. UTM 4.7.x fails to
	-- coerce the `network protocol` enum inside this nested make record (-1700).
	-- Omitting it defaults to TCP, which is what the SSH forward needs anyway.
	--
	-- NOTE: the cloud-init seed is a NON-removable (removable:false) drive so UTM
	-- attaches it as VirtIO, not a USB CD-ROM. On UTM 4.7.x (QEMU 10) a removable
	-- seed becomes a USB/XHCI CD-ROM that hangs the guest during boot (both vCPUs
	-- spin ~200%, no network ever comes up). A VirtIO drive boots cleanly, and the
	-- NoCloud datasource still finds it by the "cidata" filesystem label.
	--
	-- NOTE: the display is effectively decorative here, and UTM will always say
	-- "Display output is not active" for it. Both base images run the distro's
	-- '-cloud' kernel flavour, which ships NO DRM drivers (no virtio-gpu, no
	-- framebuffer): the guest sees the virtio-gpu-pci device but nothing binds to
	-- it. The display is kept anyway because a VM with no display at all is
	-- awkward in the UTM GUI, and a future non-cloud kernel would light it up.
	--
	-- The SERIAL port is the console that actually works: the guests put their
	-- kernel console and a getty on ttyAMA0, and UTM's DEFAULT for a new QEMU VM
	-- already attaches one pl011 UART exposed to the host as a pseudo-tty
	-- (interface:ptty). scripts/console.sh queries that pty and attaches to it.
	--
	-- NOTE: do NOT add `serial ports:{{interface:ptty}}` to this record to make
	-- that explicit. UTM 4.7.x rejects the whole configuration with -1700 ("Can't
	-- make {...} into type qemu configuration"), the same enum-coercion quirk as
	-- `protocol:TCP` on the port forward above. Relying on UTM's default is the
	-- only way to get the serial device at creation time; if a future UTM ever
	-- drops that default, add the device in the GUI (Edit -> new device -> Serial)
	-- and console.sh will pick it up.
	tell application "UTM"
		if nicLayout is "dual" then
			set nics to {{mode:emulated, address:macNat, port forwards:{{host address:"127.0.0.1", host port:sshPort, guest port:22}}}, {mode:host, address:macInternal}}
		else
			set nics to {{mode:host, address:macInternal}}
		end if
		set vm to make new virtual machine with properties {backend:qemu, configuration:{name:vmName, architecture:"aarch64", uefi:true, memory:memMiB, cpu cores:cpuCores, drives:{{removable:false, source:diskFile}, {removable:false, source:seedFile}}, displays:{{hardware:"virtio-gpu-pci"}}, network interfaces:nics}}
		return id of vm
	end tell
end run
