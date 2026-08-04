-- Create one QEMU aarch64 VM in UTM from an existing disk + cloud-init seed.
--
-- The NIC layout is PER ROLE and is the security property of this repo:
--   "dual" (gateway only): net0 "emulated" (SLIRP NAT -- the only mode where
--   the hostfwd works) plus net1 "host", the isolated segment.
--   "internal" (everything else): one "host" NIC and NOTHING ELSE, so no path
--   off the segment. All "host" NICs share one vmnet switch with no gateway.
--
-- With vm-config.applescript the only integration point with UTM: if a future
-- version rejects a property key, adjust it here only.
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

	-- Do NOT set `protocol:TCP` on the port forward: UTM 4.7.x fails to coerce
	-- the enum inside this nested record (-1700); omitting it defaults to TCP.
	--
	-- The seed is a NON-removable drive so UTM attaches it as VirtIO: a
	-- removable seed becomes a USB CD-ROM that hangs the boot on UTM 4.7.x.
	-- NoCloud still finds it by the "cidata" label.
	--
	-- Do NOT add `serial ports:{{interface:ptty}}` either: same -1700 quirk.
	-- UTM's default for a new QEMU VM already attaches a pl011 UART as a host
	-- pseudo-tty, which scripts/console.sh queries and attaches to.
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
