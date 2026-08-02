# Mutation evidence: the Kali toolset (`feature/kali-toolset`)

CLAUDE.md's rule: *a guard is not tested until someone has broken it and
watched the test die.* This file is that record, kept where it survives merge
(`.superpowers/` and `docs/superpowers/` are both gitignored; this is not).
Each entry names the guard, what was mutated, what ran, and which assertion
caught it. Full transcripts for the entries carried over from the original
six-task implementation live in
`.superpowers/sdd/2026-07-30-kali-toolset/task-*-report.md` (gitignored, not
part of this record, cited here for whoever wants the verbatim output).

## `parse_tool_groups` charset guard (`scripts/lib.sh`)

Weakened `[[ "$g" =~ ^[a-z0-9][a-z0-9-]*$ ]]` to `[[ -n "$g" ]]`. `bash
tests/tool-groups.sh` failed on every injection/charset case (`web; rm -rf
/`, `web&&reboot`, `$(id)`, `web/../../etc`, `Web`, `-web`, `web.passwords`,
`web_passwords`), each through its own `should have been rejected` assertion,
not a generic abort. Restored; suite green again. Source: task-1-report.md.

## `kali-*` prefix rejection (`scripts/lib.sh`)

Deleted the `case "$g" in kali-*) die ...` block. The suite failed on all four
umbrella-metapackage cases (`kali-linux-large`, `kali-linux-everything`, `web
kali-linux-headless`, `kali-tools-web`) plus the `render_tool_groups_var`
case, each through its named `should have been rejected` assertion. Restored;
green. Source: task-1-report.md.

## Pathname-expansion (noglob) handling (`scripts/lib.sh`)

Before the fix, `parse_tool_groups '*'` expanded the glob in the caller's
shell before the charset guard ever ran: it printed `ansible` (a real
directory name that happens to pass the charset regex) and only then died on
`ansible.cfg`. `tests/tool-groups.sh`'s glob assertions failed with the
expanded name visible in the output (`got: ansible`), proving the accept-then-
die order rather than a clean rejection. Fixed with `set -f` / `set +f`
around the word-splitting loop, restoring the caller's noglob state
afterward. Source: task-1-report.md.

## Watch-list drift test (`tests/vpn-watch-list.sh`)

Two directions tested against the two copies of the VPN watch list
(`scripts/verify.sh`'s `vpn_watch_list` and `ansible/group_vars/role_workstation.yaml`'s
`workstation_vpn_watch_list`):

- Deleted `- openvpn` from the group_vars copy: failed on the drift diff
  (`< openvpn`) and on the named-package assertion (`openvpn is missing from
  the watch list`).
- Added `- something-else` to the group_vars copy: failed on the drift diff
  (`> something-else`).

Both restored, diffed byte-identical against a pre-mutation backup, suite
green. Source: task-3-report.md.

## Tool-group existence check (`ansible/roles/workstation/tasks/tools.yaml`, "Fail on a tool group Kali does not have")

With the guard intact, `KALI_TOOL_GROUPS="detect nosuchgroup"` failed cleanly
through the guard's own `ansible.builtin.fail`, naming `nosuchgroup`,
`changed=0`. With the guard deleted, the same selection instead failed inside
"Install the selected Kali tool groups" with a raw apt error (`No package
matching 'kali-tools-nosuchgroup' is available`) -- the failure mode the guard
exists to replace with a clear diagnosis. Guard restored, verified green.
Source: task-4-report.md.

## Purge-collateral guard ("Refuse a purge that would take the requested tools with it")

`bash` turned out to have no apt-level dependents on this image, so it was not
a usable case; `libosip2-15t64` (a library `sentrypeer` depends on, itself
pulled in by `kali-tools-detect`) was substituted after verifying the cascade
with a read-only `apt-get -s purge` simulation. Added to the watch list,
`workstation_desktop` temporarily set `false` to isolate the test from
`desktop.yaml`'s then-unconditional purge of the same list (see finding 1
below), `make configure` failed through the guard's own
`ansible.builtin.fail`, naming the correct collateral (`sentrypeer
kali-tools-detect`), `changed=0` -- nothing was actually purged. This test is
also what caught the original brief's regex bug (`^Remv ` only, never
matching the `Purg ` lines apt actually emits for directly-named packages),
which would have let this exact scenario purge for real. Restored; verified
green. Source: task-4-report.md.

## `verify.sh` tool-group-installed assertion (original `vpn_pkg_present`-based version)

Two mutations, against a live guest:

- **Broke the fact**: removed `kali-tools-detect` from the workstation via
  `apt-get remove`. `make verify` failed through `workstation is missing tool
  group(s) that KALI_TOOL_GROUPS asked for: kali-tools-detect`. Reinstalled
  via `make configure`; green again.
- **Broke the guard**: replaced the `if ! groups_list=$(parse_tool_groups);
  then note_fail ...; else ...; fi` wrapper with a bare `groups_list=$(parse_tool_groups
  || true)`, expecting (per the brief) a silent false-pass. What actually
  happened was a hard `set -e` abort at `parse_tool_groups`'s own `die`: under
  bash 3.2, `exit` inside a function called from a command substitution
  terminates the subshell before `|| true` on the outer assignment can ever
  run, so the whole script aborted rather than printing a false green. Still a
  real failure mode (the explicit `if !` branch is still required for correct
  behavior), just a different one than predicted; recorded rather than
  glossed over. Guard restored; verified green.

Source: task-5-report.md (also documents the WAN negative control run
immediately after this change, per CLAUDE.md's rule to re-run it after any
`verify.sh` edit).

## Finding 2: `pkg_fully_installed` (`scripts/verify.sh`, this fix wave)

The original assertion called `vpn_pkg_present`, which is deliberately biased
toward "present" (any status but `not-installed`/`config-files` counts) --
correct where present means bad (the VPN scan), wrong where present means
good (a tool group actually finished installing): `unpacked` or
`half-configured` would read as "installed," exactly the state an apt run
that died mid-tunnel leaves behind.

Added `pkg_fully_installed()`, which accepts only the literal `installed`
status, and switched the tool-group block to call it instead. Mutation:
widened `pkg_fully_installed` to also accept `half-configured`. Ran
`tests/vpn-pkg-scan.sh`'s new contrast case (`kali-tools-web
half-configured`, expected rejected by `pkg_fully_installed` and accepted by
`vpn_pkg_present`):

```
pkg_fully_installed vs vpn_pkg_present, opposite polarity:
  FAIL half-configured must not count as fully installed
vpn-pkg-scan: FAILED
```

Failed through the named assertion, not a generic abort. Restored; `bash
tests/vpn-pkg-scan.sh` diffed byte-identical against a pre-mutation backup and
reported OK.

## Finding 3: unparseable-simulation guard (`ansible/roles/workstation/tasks/tools.yaml`, "Refuse to act on a purge simulation that could not be read")

The collateral guard derived `would_remove` purely from a regex over
`apt-get -s purge`'s simulated output. If that regex ever matches nothing --
apt changes its wording, a locale difference, output on stderr instead of
stdout -- `would_remove` comes back short of what was actually asked to be
purged, the collateral computation (`would_remove | difference(...)`) sees an
artificially small set, its `when:` goes false, and the real purge runs
unopposed: the same failure shape as the `Remv`-only regex bug documented
above, one layer up.

Added a task that fails whenever `anon_vpn_present` (what was actually asked
to be purged) is not a subset of `would_remove` (what the simulation reported
removing) -- by construction every member of `anon_vpn_present` must appear in
`would_remove` when the parse works, since apt always echoes back a `Purg `
line for every package named directly on its own command line.

Mutation: installed `vpnc-scripts` (in `workstation_vpn_watch_list`, no
reverse dependencies on this image, harmless to purge) on the workstation via
an ad-hoc `ansible ... -m raw apt-get install`. Broke the regex in "Name what
the purge simulation reports removing" so it matches nothing
(`select('match', '^NEVERMATCH ')` in place of `^(Remv|Purg) `). Ran `make
configure`:

```
TASK [workstation : Refuse to act on a purge simulation that could not be read] ***
[ERROR]: Task failed: Action failed: apt-get -s purge vpnc-scripts did not
report removing vpnc-scripts; its output could not be parsed, so the
collateral check below proves nothing.
```

Firing through the new guard's own assertion; "Purge the VPN client packages"
never reached; `vpnc-scripts` still installed afterward (`changed=0`).
Restored the regex, confirmed `git diff` on `tools.yaml` against the fix-wave
commit was empty, re-ran `make configure`: the guard was skipped, the real
purge task ran and removed `vpnc-scripts` (`changed=1` on the workstation),
confirmed absent via `dpkg-query`.

## Finding 1 (not a new guard, a placement bug): `desktop.yaml`'s purge ran before `tools.yaml`'s guard

Not itself a guard with a mutation test, since the fix is a deletion, but
recorded because it is the critical finding of this fix wave and the original
implementation's own evidence (task-4-report.md, "Concerns" #2) had already
surfaced it live: with the pre-fix `desktop.yaml`, adding a real-dependent
package to the watch list caused `desktop.yaml`'s unconditional,
non-simulated purge to attempt removing it for real, before `tools.yaml`'s
simulate-first guard was ever reached (only apt's own essential-package
protection saved `bash` from actually being removed in that session,
protection that does not extend to a non-essential package). Confirmed before
fixing that `tools.yaml`'s purge sequence has no `when:` gate tying it to
group selection or to the desktop -- it runs on every `make configure`
already, covering the identical `workstation_vpn_watch_list` -- so deleting
the `desktop.yaml` copy loses no coverage. See the "make configure twice" and
dpkg-query evidence in `final-fix-report.md` for the resulting idempotent
behavior.
