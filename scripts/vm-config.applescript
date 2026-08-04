-- Read or change the CPU/RAM of an EXISTING UTM VM.
-- Usage: vm-config.applescript get <name>            -> prints "<cpu> <ram-mib>"
--        vm-config.applescript set <name> <cpu> <ram-mib>  -> prints "ok"
--
-- UTM only allows `update configuration` while the VM is stopped; create-vm.sh
-- stops it first. With create-vm.applescript the only place that talks to UTM.
on run argv
	set op to item 1 of argv
	set vmName to item 2 of argv

	tell application "UTM"
		set vm to virtual machine named vmName
		if op is "get" then
			set cfg to configuration of vm
			return ((cpu cores of cfg) as text) & " " & ((memory of cfg) as text)
		else if op is "set" then
			set cpuCores to (item 3 of argv) as integer
			set memMiB to (item 4 of argv) as integer
			update configuration vm with {cpu cores:cpuCores, memory:memMiB}
			return "ok"
		else
			error "vm-config: unknown op " & op
		end if
	end tell
end run
