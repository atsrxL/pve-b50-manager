# GPU Manager for Proxmox VE

A Proxmox VE node plugin for discrete-GPU telemetry and Intel SR-IOV VF
management. This fork keeps the pmx-gpu-manager layout, but replaces its
uniform-quota Battlemage implementation with the current xe SR-IOV ABI and
true per-VF profiles.

## B50 / Battlemage support

The implementation recognises Intel Arc Pro B50 (8086:e212) and B60
(8086:e211) PFs and uses the live sriov_totalvfs value as the effective limit.
It does not assume that the static family-map maximum is usable on a particular
card or driver build.

Current Battlemage resource paths are modelled as:

~~~
/sys/kernel/debug/dri/<PF-BDF>/sriov/vfN/tile0/
  vram_quota
  ggtt_quota
  gt0/{contexts_quota,doorbells_quota,exec_quantum_ms,preempt_timeout_us}
  gt1/{contexts_quota,doorbells_quota,exec_quantum_ms,preempt_timeout_us}

/sys/kernel/debug/dri/<PF-BDF>/sriov/restore_auto_provisioning
/sys/bus/pci/devices/<PF-BDF>/sriov_admin/.bulk_profile/sched_priority
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
  the all-VF scheduler profile are verified before saved drivers are restored.
- Persistence is written only after live verification succeeds.
- Removing VFs also removes their boot restore entry, so a reboot cannot
  unexpectedly recreate them.
- This release accepts one persistent GPU PF per node. Multi-PF boot restore is
  rejected before any hardware write because cross-PF rollback is not yet
  transactional.

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
small, owned marker blocks to the PVE hardware API index and web template.
Reapplying the integration is idempotent. Package removal removes only those
marker blocks; it does not restore an old whole-file backup over upgraded PVE
files.

Do not install a development build on a production node without first reviewing
the generated package and taking a current PVE configuration backup.

## Dependencies

- Proxmox VE 8.x or 9.x
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
| POST | /{bdf}/vfio | Switch the PF between xe and vfio-pci with safety guards |

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
driver reconciliation, conflict handling, and rollback when PVE libraries are
available.

Project layout:

~~~
src/PVE/API2/Hardware/GPU.pm        REST API and transactions
src/PVE/API2/Hardware/GPU/Intel.pm  Intel ABI adapter
src/PVE/GPU/SRIOV.pm                profile parsing and validation
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
