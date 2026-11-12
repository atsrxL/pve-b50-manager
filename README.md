# GPU Manager for Proxmox VE

A Proxmox VE node plugin for discrete-GPU telemetry and Intel SR-IOV VF
management. This fork keeps the pmx-gpu-manager layout, but replaces its
uniform-quota Battlemage implementation with the current xe SR-IOV ABI and
true per-VF profiles.

## B50 / Battlemage support

The implementation recognises the validated Battlemage IDs 8086:e211,
8086:e212, 8086:e222, and 8086:e223 (including Arc Pro B60 and B50), and uses
the live sriov_totalvfs value as the effective limit. It does not assume that
the static family-map maximum is usable on a particular card or driver build.

Current Battlemage resource paths are modelled as:

~~~
/sys/kernel/debug/dri/<PF-BDF>/sriov/vfN/tile0/
  vram_quota
  ggtt_quota
  gt0/{contexts_quota,doorbells_quota,exec_quantum_ms,preempt_timeout_us}
  gt1/{contexts_quota,doorbells_quota,exec_quantum_ms,preempt_timeout_us}

/sys/kernel/debug/dri/<PF-BDF>/sriov/restore_auto_provisioning
/sys/bus/pci/devices/<PF-BDF>/sriov_admin/.bulk_profile/sched_priority
/sys/bus/pci/devices/<PF-BDF>/sriov_admin/{pf,vfN}/profile/sched_priority
~~~

GT directories are discovered at runtime. The B50/B60 fallback is GT0 + GT1
only for the pre-creation state where VF directories do not yet exist.

## What the v3 VF editor does

- Creates or removes Intel SR-IOV VFs.
- Sets the VF count using the live hardware limit.
- Configures each VF independently; values are never averaged into one quota.
- Supports explicit auto, custom, and unchanged resource modes.
- Configures VRAM, GGTT, contexts, doorbells, execution quantum, and preemption
  timeout.
- Shows live effective values, mixed GT values, driver binding, VM assignment,
  and whether a consumer VM is running.
- Reads and writes scheduler priority as a device-wide bulk profile.
- Persists verified profiles for restoration before PVE guests start.
- Detects drift between live and persisted VF count, resources, and scheduler.
- Double-clicking a VF's VM cell assigns it to a stopped QEMU VM, moves it, or
  leaves it unassigned. Assignment also binds the VF to vfio-pci explicitly,
  which is required while sriov_drivers_autoprobe is disabled.
- Quick Whole-GPU Passthrough replaces every VF assignment with one PF
  assignment: select a stopped QEMU VM, confirm the transaction, and the plugin
  removes this GPU's VFs and persistent profiles before binding the PF to
  vfio-pci and adding it to the selected VM.
- On AuthenticAMD hosts, the B50 PF view reports the active, persistent, and
  live ATS state. The UI can prepare or remove the package-owned `pci=noats`
  boot policy; it never reboots the node automatically.
- The B50 Power Saving dialog can temporarily park all VFs, keep their VM
  hostpci entries and persistent profiles, and apply the tested 10 ms runtime
  autosuspend delay. It uses the stock xe driver and does not require a custom
  kernel.

auto never means “write quota 0”. Switching an existing custom resource back to
auto requires a VF reprovision so the driver can calculate it again.

## Safety model

SR-IOV writes are serialized with one host lock, hold PVE's PCI-reservation
lock against concurrent passthrough starts, and use read-after-write
verification.

- A VF-count change or forced reprovision is rejected while the PF or any VF is
  present in a VM hostpci configuration. Detach those PCI functions first.
- Same-count resource edits are rejected while any consumer VM is running.
  All existing QEMU configurations on the node are locked, then PCI consumers
  are checked again immediately before the write.
- The live VF/resource/driver/scheduler state is snapshotted before mutation.
  A failed change attempts to restore topology, resource values, scheduler,
  driver bindings, autoprobe state, and the prior persistence file.
- Reprovisioning always creates VFs with driver autoprobe disabled. Quotas and
  the device-wide PF/VF scheduler profile are verified before saved drivers are
  restored.
- Persistence is written only after live verification succeeds.
- A VF must have a complete boot-restorable profile before it can be assigned
  to a VM. Persistence cannot be disabled while the PF or a VF remains in any
  VM configuration; unassignment remains available as a recovery operation if
  an old profile is incomplete.
- Removing VFs also removes their boot restore entry, so a reboot cannot
  unexpectedly recreate them.
- Multiple persistent PFs are validated before the first hardware write. If a
  later PF fails, already-applied PFs are rolled back in reverse order.
- The whole-GPU quick mode locks every QEMU configuration and PVE's PCI
  reservation state before changing anything. Every affected VM must be
  stopped and unlocked. On failure it restores the PF driver, VFIO policy,
  SR-IOV topology and profiles, and the original VM configurations.
- Whole-GPU quick mode changes only the selected GPU PF and its VFs. Separate
  audio functions and unrelated PCI devices are neither detached nor moved.
  After the ATS safety state is verified, selecting the VM that already owns a
  correctly configured PF is a no-op, including while that VM is running.
- On an AuthenticAMD host, passthrough of the physical `8086:e212` B50 is
  rejected before any topology, driver, persistence, or VM write unless the
  running command line contains the exact `pci=noats` token, the future boot
  policy is persistent, and `lspci` reports `ATSCtl: Enable-`. Unknown PCI or
  CPU identity fails closed; VFs and unrelated devices are outside this guard.
- Native `qm`, API, and HA starts run a full hostpci preflight before PVE
  reserves or prepares any PCI function. A second low-level check protects
  direct `prepare_pci_device` callers and `driver=keep` configurations.
- The boot binders are ordered before `pve-guests`; failed binders or missing
  native start guards prevent automatic guest startup.
- B50 power saving requires the PF to remain on xe and every GPU consumer VM
  to be stopped. A live VF topology also requires a complete, drift-free
  persistent profile before any VF is removed.
- While VFs are parked, native QEMU starts, direct SR-IOV/VFIO/ATS writes, and
  wake-up status probes fail closed. The device list reports sleeping state
  using only non-waking runtime-power attributes.
- Explicit exit rebuilds the exact VF count and BDF topology, reapplies resource
  profiles, scheduler and drivers, restores the prior autosuspend settings, and
  clears the runtime recovery record only after verification succeeds.

The low scheduler profile is the recommended B50 default. normal is exposed as
an experimental option only: it requires an explicit confirmation and is
blocked while any VF is assigned. A tested B50 configuration has previously
shown guest Code 43 and loss of guest-agent/RDP connectivity with normal.

The device grid's VFIO cell opens an explicit xe/vfio-pci selector for the PF.
The live switch uses the same GPU, VM-config, and PCI-reservation lock order as
SR-IOV changes, rejects active VFs and PF/VF consumers, checks conflicting boot
profiles, verifies the resulting driver and persistent policy, and rolls both
back on failure. VM hostpci configuration remains under Proxmox VE control.

## Installation

Build a Debian package on a Debian/Proxmox-compatible environment:

~~~bash
make test
make deb
~~~

Then install the resulting package on the PVE node:

~~~bash
dpkg -i ../pve-gpu-manager_*.deb
~~~

Installation adds a GPU section under the selected PVE node. The package applies
small, owned marker blocks to the PVE hardware API index, web template, and the
two QemuServer start boundaries used for native ATS and parked-VF checks. Reapplying the
integration is idempotent. Package removal removes only those marker blocks; it
does not restore an old whole-file backup over upgraded PVE files.

On upgrade, legacy uniform SR-IOV profiles are migrated to explicit v2 per-VF
profiles before boot restore is enabled. Obsolete package-owned global VFIO
blacklist/module-load files and their legacy `vfio-pci.ids=` GRUB argument are
removed, boot files are refreshed only when that old policy existed, and
pvedaemon plus pveproxy are restarted so the installed Perl and JavaScript
integration are used immediately. Other kernel arguments are retained. The
upgrade does not start the VFIO or SR-IOV boot services and therefore does not
change live GPU topology.

Awaited dpkg file triggers replay the marker integrations when qemu-server or
pve-manager replaces their files, including a normal direct `dpkg -i` update.
Do not use `dpkg --no-triggers` or start VMs concurrently while dpkg is unpacking
qemu-server; those exceptional paths bypass the trigger completion guarantee.

### AMD B50 ATS workflow

For the affected physical B50 on an AuthenticAMD host:

1. Read `/{bdf}/ats-policy` to inspect the live and future-boot state.
2. POST the endpoint to create the package-owned persistent `pci=noats` policy.
   Existing external policy is accepted but never claimed or edited.
3. Reboot only when `reboot_required` is true, then verify `safe=true` before
   assigning or starting the PF.
4. DELETE removes only package-owned policy and is rejected while any affected
   B50 PF remains assigned, persistently selected for VFIO, or bound to
   `vfio-pci`.

### B50 runtime power-saving workflow

1. Keep the B50 PF on xe, stop every VM which owns one of its VFs, and make sure
   the current VF profile is persisted without drift.
2. Select the B50 and open **Power Saving**. Entering the mode removes only the
   live VF functions, preserves VM hostpci configuration and `gpu-sriov.conf`,
   sets runtime power control to `auto` with a 10 ms delay, and verifies runtime
   suspend plus PCI D3.
3. Telemetry, ATS and VF status reads which could wake the GPU remain paused.
   VM starts and conflicting GPU changes are rejected with an instruction to
   exit Power Saving.
4. Use **Exit Power Saving** to restore and verify the saved topology. This mode
   is deliberately runtime-only: a host reboot drops the `/run` recovery record,
   and the ordinary persistent SR-IOV boot restore recreates the VFs before
   guests start.

Do not install a development build on a production node without first reviewing
the generated package and taking a current PVE configuration backup.

## Dependencies

- Proxmox VE 8.x or 9.x
- qemu-server 8.x or 9.x
- Perl and libpve-common-perl
- pciutils
- linux-perf for optional telemetry

The current B50 validation target is PVE 9.2 with the xe driver.

## API

Endpoints are under /api2/json/nodes/{node}/hardware/gpu:

| Method | Path | Purpose |
|---|---|---|
| GET | / | List supported GPU PFs and telemetry |
| GET | /{bdf} | Read one GPU |
| GET | /{bdf}/sriov | Read capabilities, VFs, consumers, and drift |
| POST | /{bdf}/sriov | Transactionally create/update/remove VFs |
| DELETE | /{bdf}/sriov | Safely remove all VFs and persistence |
| GET | /{bdf}/vf | List live VFs and resources |
| GET | /{bdf}/vf/{index} | Read one VF |
| PUT | /{bdf}/vf/{index}/assignment | Assign/move a VF to a stopped QEMU VM; vmid=0 clears it |
| POST | /{bdf}/passthrough | Replace all stopped VF/PF consumers with one whole-PF VM assignment |
| POST | /{bdf}/vfio | Switch the PF between xe and vfio-pci with safety guards |
| GET | /{bdf}/ats-policy | Read active, persistent, and live ATS safety state |
| POST | /{bdf}/ats-policy | Prepare persistent pci=noats policy without rebooting |
| DELETE | /{bdf}/ats-policy | Remove package-owned policy after affected PFs are released |
| GET | /{bdf}/power-policy | Read B50 runtime power state, blockers, and non-waking suspend status |
| POST | /{bdf}/power-policy | Enter or exit transactional runtime-only B50 power saving |

The SR-IOV POST accepts a JSON-encoded vf_profiles array. Every persistent profile
must explicitly choose auto or custom for all resources.

~~~json
[
  {
    "vf_index": 1,
    "resources": {
      "vram": {"mode": "custom", "quota": 8589934592},
      "ggtt": {"mode": "custom", "quota": 1073741824},
      "contexts": {"mode": "custom", "quota": 16384},
      "doorbells": {"mode": "custom", "quota": 64},
      "exec_quantum_ms": {"mode": "custom", "quota": 0},
      "preempt_timeout_us": {"mode": "custom", "quota": 0}
    }
  },
  {
    "vf_index": 2,
    "resources": {
      "vram": {"mode": "custom", "quota": 6442450944},
      "ggtt": {"mode": "auto"},
      "contexts": {"mode": "auto"},
      "doorbells": {"mode": "auto"},
      "exec_quantum_ms": {"mode": "auto"},
      "preempt_timeout_us": {"mode": "auto"}
    }
  }
]
~~~

Legacy uniform POST fields remain accepted for API compatibility, but the web UI
does not silently retry with them.

## Development and validation

~~~bash
# Unit and packaging lifecycle tests
make test

# Playwright UI tests against an explicit PVE test target
cd test/e2e
npm install
npx playwright test
~~~

t/08-pve-b50-api.t loads the real production Perl modules when PVE libraries are
available and exercises a same-count B50 profile transaction against an isolated
fake sysfs/config tree. It is skipped on non-PVE machines.

t/09-vf-assignment.t exercises stopped-VM VF assignment, movement, removal,
whole-PF conversion and movement, running same-target no-op behavior, driver
reconciliation, conflict handling, and rollback when PVE libraries are
available.

t/10-sriov-boot-rollback.t covers multi-PF rollback, legacy-profile migration,
and PF/VF scheduler consistency under Bash 4 or newer.
`test/frontend-state.cjs` uses real ExtJS window lifecycles to cover saved-profile
refresh, drift reconciliation, fresh assignment eligibility, failed reads and
topology changes. Run on the build worker with Playwright installed and the
ExtJS theme CSS imports combined into one file:

~~~bash
GPU_EXTJS_PATH=/path/to/ext-all-debug.js \
GPU_EXTJS_CSS_PATH=/path/to/combined-theme.css \
BROWSER_PATH=/path/to/chrome make frontend-test
~~~

`frontend-test` is explicit opt-in and is not part of `make test` or the default
GitHub build/release workflows. Without `GPU_EXTJS_PATH` it prints a skip reason;
with that variable set, missing dependencies or failed assertions fail the target.
The removed source-text assertions are not equivalent to browser behavior coverage.
This isolated suite does not cover every GPU feature or replace `make e2e-test`
against a real, dedicated PVE test node before production deployment.

The visible GPU panel reconciles full SR-IOV policy at most once per 15 seconds
between explicit actions; VF assignment always requests fresh state first.
Background reconciliation failures are silent. User-requested assignment reads
show loading and report failed, empty or superseded responses explicitly.
Installed frontend cache keys derive from the JavaScript content SHA-256.

t/12-ats-policy.t covers GRUB/proxmox-boot-tool ownership and rollback plus the
boot binder gate. t/13-native-ats-guard.t covers affected-device identity,
active/future ATS policy, full hostpci preflight, and marker replay/removal.
t/14-power-policy.t covers atomic runtime state, native VM-start rejection,
PCI mappings, malformed-state fail-closed behavior, and multi-PF isolation.

Project layout:

~~~
src/PVE/API2/Hardware/GPU.pm        REST API and transactions
src/PVE/API2/Hardware/GPU/Intel.pm  Intel ABI adapter
src/PVE/GPU/SRIOV.pm                profile parsing and validation
src/PVE/GPU/Power.pm                runtime state and native VM-start guard
src/js/pve-gpu-plugin.js            ExtJS node UI
src/scripts/                        boot restore and integration helpers
src/systemd/                        boot ordering
debian/                             Debian package lifecycle
t/                                  unit/integration tests
~~~

## License status

The upstream repository currently references a LICENSE file but does not
contain one. Treat the source as having no explicit redistribution licence until
the upstream author clarifies it. Do not publish or redistribute this fork or
its binary package on the assumption that a missing licence grants permission.
