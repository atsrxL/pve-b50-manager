# PVE GPU/GPU Manager Plugin — Design Brief

> Historical upstream design reference. The shipped implementation is limited
> to the validated Intel Battlemage IDs and xe ABI documented in `README.md`;
> the Flex/PVC examples below are not current support claims.

## 1. Project Overview

A Proxmox VE web UI plugin that provides per-host discovery, monitoring, and SR-IOV virtual function management for Intel discrete GPUs (Data Center GPU Flex / ATS-M, Ponte Vecchio, Battlemage).

**Target users**: Proxmox VE administrators running Intel data center GPUs who need to partition physical GPUs into virtual functions for VM/container passthrough.

**Key principle**: Zero external dependencies — all hardware interaction is done natively via sysfs, lspci, and kernel interfaces. The Intel GPU Manager repository is used solely as a reference for understanding sysfs paths and device capabilities.

---

## 2. Goals

- **Enumerate** all installed GPUs per Proxmox host with full hardware details
- **Detect** SR-IOV capability and prerequisite status (VMX, IOMMU, BIOS SR-IOV)
- **Create** virtual functions with configurable resource allocations (LMEM, GGTT, contexts, doorbells)
- **Monitor** per-VF metrics (utilization, temperature, memory)
- **Remove** virtual functions cleanly
- **Persist** SR-IOV configuration across host reboots
- **Integrate** seamlessly into the Proxmox web UI as a native-feeling node tab

---

## 3. Architecture

### 3.1 Backend — Perl API Module

A new Perl module `PVE::API2::Hardware::GPU` registered as a sub-route under `/nodes/{node}/hardware/gpu`.

Endpoints:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/nodes/{node}/hardware/gpu` | List all detected Intel GPUs |
| `GET` | `/nodes/{node}/hardware/gpu/{bdf}` | Device detail (properties, telemetry) |
| `GET` | `/nodes/{node}/hardware/gpu/{bdf}/sriov` | SR-IOV status and precheck results |
| `POST` | `/nodes/{node}/hardware/gpu/{bdf}/sriov` | Create VFs (params: numVfs, lmemPerVf, persist) |
| `DELETE` | `/nodes/{node}/hardware/gpu/{bdf}/sriov` | Remove all VFs |
| `GET` | `/nodes/{node}/hardware/gpu/{bdf}/vf` | List VFs with resource allocations |
| `GET` | `/nodes/{node}/hardware/gpu/{bdf}/vf/{vfIndex}` | VF detail and metrics |

All endpoints use `proxyto => 'node'` so they execute on the correct host in a cluster.

### 3.2 Frontend — ExtJS Panel

A new tab `PVE.node.GpuManager` added to `PVE.node.Config` with:

- **Device grid** — lists all GPUs on the node (name, BDF, device ID, SR-IOV status, VF count)
- **Device detail panel** — properties, temperature, utilization gauges
- **SR-IOV management panel** — precheck indicators, VF creation form, VF list grid with resource columns

---

## 4. Native Hardware Interface

All hardware interaction is implemented directly — no dependency on `gpumcli`, `libgpum`, or any external tool.

### 4.1 Device Enumeration

- Parse `lspci -Dnn` output filtered by PCI display class (`0x03xx`) and Intel vendor ID (`0x8086`)
- Alternatively reuse Proxmox's `PVE::SysFSTools::lspci()` which already returns structured PCI data
- Map PCI BDF to DRM card via `/sys/class/drm/card*/device/` symlinks
- Identify device model by matching PCI device ID against known Intel GPU IDs:

| Family | Device IDs | Max VFs | Tiles |
|--------|-----------|---------|-------|
| ATS-M / Flex (DG1) | `0x56c0`, `0x56c1`, `0x56c2` | 31 | 1 |
| Ponte Vecchio (PVC) | `0x0bd4`, `0x0bd5`, `0x0bd6` | 62 | 2 |
| PVC Extended | `0x0bda`, `0x0bdb`, `0x0b6e` | 63 | 2 |
| Battlemage (BMG) | `0xe211`, `0xe212`, `0xe222` | 24 | 1 |
| Battlemage (BMG) | `0xe223` | 12 | 1 |

### 4.2 Device Properties

Read from sysfs per DRM card:

| Property | Source |
|----------|--------|
| Device name | PCI device name from `lspci` or `/sys/class/drm/{card}/device/device` |
| PCI BDF | Directory name under `/sys/bus/pci/devices/` |
| Vendor/Device ID | `/sys/class/drm/{card}/device/vendor`, `device` |
| DRM render node | `/dev/dri/renderD*` mapped from card |
| NUMA node | `/sys/class/drm/{card}/device/numa_node` |
| Driver | `/sys/class/drm/{card}/device/driver` symlink basename |

### 4.3 Telemetry

| Metric | Source |
|--------|--------|
| Temperature | `/sys/class/drm/{card}/device/hwmon/hwmon*/temp*_input` (millidegrees C) |
| Power | `/sys/class/drm/{card}/device/hwmon/hwmon*/power*_input` (microwatts) |
| GPU utilization | i915 PMU counters or `/sys/class/drm/{card}/device/tile*/gt_cur_freq_mhz` |
| Memory | `/sys/class/drm/{card}/iov/pf/gt{tile}/available/lmem_free` vs total |

### 4.4 SR-IOV Precheck

| Check | Method | Pass Condition |
|-------|--------|----------------|
| CPU Virtualization (VMX/SVM) | `grep -E 'vmx|svm' /proc/cpuinfo` | `vmx` (Intel VT-x) or `svm` (AMD-V) flag present |
| IOMMU | `/sys/class/iommu/*/` exists, or `dmesg \| grep DMAR` | IOMMU devices present |
| SR-IOV BIOS | `/sys/class/drm/{card}/device/sriov_totalvfs` | Value > 0 |
| i915 driver loaded | `/sys/class/drm/{card}/device/driver` -> `i915` | Symlink target is i915 |

### 4.5 SR-IOV Virtual Function Management

**Create VFs:**
1. Validate precheck passes
2. Read available resources from sysfs:
   - `/sys/class/drm/{card}/iov/pf/gt{tile}/available/lmem_free`
   - Available GGTT, contexts, doorbells (same tree)
3. Calculate per-VF resource quotas (from user input or config template)
4. Write per-VF resource attributes to sysfs:
   - `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/lmem_quota`
   - `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/ggtt_quota`
   - `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/exec_quantum_ms`
   - `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/preempt_timeout_us`
5. Write number of VFs to `/sys/class/drm/{card}/device/sriov_numvfs`
6. Optionally set scheduler: write to appropriate sysfs scheduler attribute
7. Control `drivers_autoprobe`: `/sys/class/drm/{card}/device/sriov_drivers_autoprobe`

**BMG variant**: Uses debugfs instead of sysfs for some paths:
- `/sys/kernel/debug/dri/{bdf}/gt{tile}/vf{n}/lmem_quota`
- `/sys/kernel/debug/dri/{bdf}/gt{tile}/pf/lmem_spare`

**List VFs:**
- Read `/sys/class/drm/{card}/device/sriov_numvfs` for count
- Iterate VF sysfs entries for resource allocations
- Map VF PCI functions via `/sys/class/drm/{card}/device/virtfn{n}/` symlinks

**Remove VFs:**
- Write `0` to `/sys/class/drm/{card}/device/sriov_numvfs`

### 4.6 VF Config Templates

A config file defining default resource allocations per device model and VF count, inspired by gpumanager's `vgpu.conf`:

```ini
# /etc/pve/local/gpu-vf-templates.conf

[flex-56c0-4vf]
device_ids = 0x56c0, 0x56c2
num_vfs = 4
vf_lmem = 4194304000
vf_contexts = 1024
vf_doorbells = 60
vf_ggtt = 1006632960
scheduler = flexible_30fps
drivers_autoprobe = 0

[flex-56c0-2vf]
device_ids = 0x56c0, 0x56c2
num_vfs = 2
vf_lmem = 8388608000
vf_contexts = 2048
vf_doorbells = 120
vf_ggtt = 2013265920
scheduler = flexible_burstable_qos
drivers_autoprobe = 0
```

---

## 5. Persistence Across Reboots

SR-IOV sysfs configuration is volatile — all VFs and resource quotas are lost on reboot.

### 5.1 Persistent Config Store

Per-device configuration saved to `/etc/pve/local/gpu-sriov.conf`:

```ini
[0000:03:00.0]
device_id = 0x56c0
num_vfs = 4
template = flex-56c0-4vf
persist = 1

# Per-VF overrides (optional)
[0000:03:00.0/vf1]
lmem_quota = 8388608000
```

Devices are identified by **PCI slot path** (domain:bus:device.function). If a BDF changes after hardware reconfiguration, the service logs a warning and attempts to match by device ID + physical slot.

### 5.2 Systemd Boot Service

`pve-gpu-sriov.service`:

```ini
[Unit]
Description=Apply Intel GPU SR-IOV Configuration
After=systemd-modules-load.service
After=dev-dri-card0.device
Wants=dev-dri-card0.device
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/lib/pve-gpu/apply-sriov-config.sh
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
```

The apply script:
1. Waits for `/sys/class/drm/card*` to appear (with timeout)
2. Reads `/etc/pve/local/gpu-sriov.conf`
3. For each persisted device, resolves current BDF, writes resource quotas, then writes `sriov_numvfs`
4. Logs success/failure per device to journal
5. **Never blocks boot** — failures are logged but the service exits 0

### 5.3 UI Integration

- VF creation form includes a "Persist across reboots" checkbox (default: on)
- Persisted configs shown with an indicator icon in the VF list
- "Remove VFs" prompts whether to also remove the persistent config
- Node summary widget shows if persisted config differs from current state (drift detection)

---

## 6. Proxmox UI Integration

### 6.1 File Layout (Architecture B — external JS + Perl module)

```
/usr/share/perl5/PVE/API2/Hardware/GPU.pm          # Backend API
/usr/share/pve-manager/js/pve-gpu-plugin.js         # Frontend ExtJS
/usr/lib/pve-gpu/apply-sriov-config.sh              # Boot persistence script
/etc/pve/local/gpu-vf-templates.conf                # VF config templates
/etc/pve/local/gpu-sriov.conf                       # Persisted VF state
/lib/systemd/system/pve-gpu-sriov.service           # Boot service
```

### 6.2 Integration Points (minimal patches)

Only two files require patching:

1. **`/usr/share/pve-manager/index.html.tpl`** — Add `<script>` tag for `pve-gpu-plugin.js`
2. **`/usr/share/perl5/PVE/API2/Nodes.pm`** — Register GPU sub-route:
   ```perl
   __PACKAGE__->register_method({
       subclass => "PVE::API2::Hardware::GPU",
       path => 'hardware/gpu',
   });
   ```

### 6.3 UI Views

**Node Tab — "GPU/GPU"** (icon: `fa-microchip`)

- Top: SR-IOV precheck status bar (green/red indicators for VMX, IOMMU, SR-IOV BIOS)
- Main: Device grid table

| Column | Source |
|--------|--------|
| Device | PCI device name |
| BDF | PCI address |
| Device ID | PCI device ID |
| Temperature | hwmon sysfs |
| SR-IOV | "Capable" / "Active (N VFs)" / "Not supported" |
| Persisted | Icon if boot persistence enabled |

**Device Detail** (click row to expand or open panel)

- Properties card: full device info
- Telemetry gauges: temperature, power, memory utilization
- VF Management section:
  - "Create VFs" button → dialog with: number of VFs, template selector or manual LMEM/GGTT input, persist checkbox
  - "Remove All VFs" button with confirmation
  - VF grid: index, BDF, LMEM quota, GGTT quota, status

---

## 7. Packaging & Distribution

Debian package `pve-gpu-manager`:

```
debian/
├── control           # Depends: pve-manager (>= 8.0), perl, libpve-common-perl
├── postinst          # Applies patches, enables systemd service
├── prerm             # Restores patched files from backup, disables service
├── postrm            # Cleanup config files on purge
├── changelog
└── compat
```

- `postinst` backs up original files before patching
- Apt hook at `/etc/apt/apt.conf.d/99-pve-gpu-reapply` re-applies patches after `pve-manager` upgrades
- Version constraints ensure compatibility with tested Proxmox releases

---

## 8. References

| Resource | URL / Path |
|----------|-----------|
| Intel GPU Manager (sysfs reference) | `../gpumanager` — `/core/src/vgpu/vgpu_manager.cpp`, `/core/resources/config/vgpu.conf` |
| PVE-mods (UI patching pattern) | https://github.com/Meliox/PVE-mods |
| ProxMenux (hardware detection patterns) | https://github.com/MacRimi/ProxMenux |
| Proxmox GPU Dashboard (UI widget examples) | https://github.com/en4ble1337/proxmox-gpu-dashboard |
| PVE-mods NVIDIA fork (GPU-specific mod) | https://github.com/j4ys0n/PVE-mods |
| Proxmox PCI Hardware API | `PVE::API2::Hardware::PCI` in pve-manager source |
| Proxmox Node Config UI | `www/manager6/node/Config.js` in pve-manager source |
| Linux SR-IOV sysfs interface | Kernel docs: `Documentation/PCI/pci-iov-howto.rst` |
| i915 SR-IOV provisioning | Kernel docs: `Documentation/gpu/i915.rst` (IOV section) |
