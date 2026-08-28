# PVE GPU/GPU Manager Plugin — Technical Specification

> Historical upstream specification. The shipped implementation is limited to
> the validated Intel Battlemage IDs and xe ABI documented in `README.md`;
> Flex/PVC/Nvidia examples below do not describe current runtime support.

## 1. Introduction

### 1.1 Purpose

This document specifies the design, interfaces, data models, and behavior of the PVE GPU/GPU Manager Plugin — a Proxmox VE extension that provides discovery, monitoring, and SR-IOV virtual function management for Intel discrete GPUs.

### 1.2 Scope

The plugin covers:

- Hardware enumeration and identification of Intel discrete GPUs (Flex/ATS-M, Ponte Vecchio, Battlemage)
- Real-time telemetry collection (temperature, power, memory, utilization)
- SR-IOV prerequisite validation
- Virtual function lifecycle management (create, list, inspect, remove)
- Configuration persistence across host reboots
- Proxmox web UI integration as a native node tab
- Debian packaging and distribution

### 1.3 Constraints

| Constraint | Detail |
|------------|--------|
| No external dependencies | All hardware interaction via sysfs, `/proc`, `lspci`, and kernel interfaces. No `gpumcli` or `libgpum`. |
| Proxmox VE ≥ 8.0 | Requires PVE 8.x API and ExtJS 7 framework |
| Kernel support | Requires i915 driver with SR-IOV patches (kernel ≥ 6.1 recommended) |
| Perl runtime | Backend must use PVE's existing Perl stack (no Python/Go daemons) |
| Cluster-safe | All API endpoints proxy to the target node; no cluster-wide state |

### 1.4 Terminology

| Term | Definition |
|------|-----------|
| BDF | PCI Bus:Device.Function address (e.g., `0000:03:00.0`) |
| DRM | Direct Rendering Manager — Linux kernel GPU subsystem |
| PF | Physical Function — the host-visible GPU PCI function |
| VF | Virtual Function — an SR-IOV-provisioned sub-device passable to VMs |
| LMEM | Local Memory — GPU-attached VRAM |
| GGTT | Global Graphics Translation Table — GPU address space |
| Tile | A discrete compute block within a multi-tile GPU (PVC has 2 tiles) |

---

## 2. System Architecture

### 2.1 Component Diagram

```
┌──────────────────────────────────────────────────────────┐
│  Proxmox Web UI (Browser)                                │
│  ┌────────────────────────────────────────────────────┐  │
│  │  pve-gpu-plugin.js (ExtJS Panel)                   │  │
│  │  ├── GpuDeviceGrid                                 │  │
│  │  ├── GpuDeviceDetail                               │  │
│  │  └── GpuSriovPanel                                 │  │
│  └──────────────────┬─────────────────────────────────┘  │
│                     │ REST API (HTTPS)                    │
└─────────────────────┼────────────────────────────────────┘
                      │
┌─────────────────────┼────────────────────────────────────┐
│  Proxmox VE Node    │                                    │
│  ┌──────────────────▼─────────────────────────────────┐  │
│  │  PVE::API2::Hardware::GPU (Perl Module)            │  │
│  │  ├── list_devices()                                │  │
│  │  ├── device_detail()                               │  │
│  │  ├── sriov_status()                                │  │
│  │  ├── create_vfs()                                  │  │
│  │  ├── remove_vfs()                                  │  │
│  │  ├── list_vfs()                                    │  │
│  │  └── vf_detail()                                   │  │
│  └──────────────────┬─────────────────────────────────┘  │
│                     │                                    │
│  ┌──────────────────▼─────────────────────────────────┐  │
│  │  Hardware Abstraction Layer (sysfs / procfs)       │  │
│  │  ├── /sys/class/drm/card*/                         │  │
│  │  ├── /sys/bus/pci/devices/                         │  │
│  │  ├── /sys/class/drm/{card}/iov/                    │  │
│  │  ├── /sys/class/drm/{card}/device/hwmon/           │  │
│  │  └── /proc/cpuinfo                                 │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  pve-gpu-sriov.service (systemd oneshot)           │  │
│  │  └── apply-sriov-config.sh                         │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### 2.2 File Layout

| Path | Type | Description |
|------|------|-------------|
| `/usr/share/perl5/PVE/API2/Hardware/GPU.pm` | Perl module | Backend API implementation |
| `/usr/share/pve-manager/js/pve-gpu-plugin.js` | JavaScript | Frontend ExtJS plugin |
| `/usr/lib/pve-gpu/apply-sriov-config.sh` | Shell script | Boot-time SR-IOV apply script |
| `/etc/pve/local/gpu-vf-templates.conf` | INI config | VF resource allocation templates |
| `/etc/pve/local/gpu-sriov.conf` | INI config | Persisted VF state per device |
| `/lib/systemd/system/pve-gpu-sriov.service` | Systemd unit | Boot service for persistence |

### 2.3 Integration Points

Only two existing Proxmox files require patching:

1. **`/usr/share/pve-manager/index.html.tpl`** — `<script>` tag insertion for plugin JS
2. **`/usr/share/perl5/PVE/API2/Nodes.pm`** — Sub-route registration for `hardware/gpu`

---

## 3. Data Models

### 3.1 GPU Device Record

Returned by `GET /nodes/{node}/hardware/gpu` (list) and `GET /nodes/{node}/hardware/gpu/{bdf}` (detail).

```json
{
  "bdf": "0000:03:00.0",
  "device_name": "Intel Data Center GPU Flex 170",
  "vendor_id": "0x8086",
  "device_id": "0x56c0",
  "subsystem_vendor_id": "0x8086",
  "subsystem_device_id": "0x4905",
  "family": "flex",
  "drm_card": "card0",
  "drm_render": "renderD128",
  "driver": "i915",
  "numa_node": 0,
  "tiles": 1,
  "sriov_capable": true,
  "sriov_total_vfs": 31,
  "sriov_num_vfs": 4,
  "persisted": true,
  "telemetry": {
    "temperature_c": 42,
    "power_w": 65.3,
    "lmem_total_bytes": 16106127360,
    "lmem_free_bytes": 8388608000,
    "gpu_utilization_pct": null
  }
}
```

#### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `bdf` | string | yes | PCI Bus:Device.Function address, used as primary key |
| `device_name` | string | yes | Human-readable device name from lspci |
| `vendor_id` | string | yes | PCI vendor ID (always `0x8086` for Intel) |
| `device_id` | string | yes | PCI device ID, hex string |
| `subsystem_vendor_id` | string | yes | PCI subsystem vendor ID |
| `subsystem_device_id` | string | yes | PCI subsystem device ID |
| `family` | string | yes | One of: `flex`, `pvc`, `pvc_ext`, `bmg` |
| `drm_card` | string | yes | DRM card name (e.g., `card0`) |
| `drm_render` | string | yes | DRM render node (e.g., `renderD128`) |
| `driver` | string | yes | Kernel driver bound to device |
| `numa_node` | integer | yes | NUMA node affinity (-1 if not applicable) |
| `tiles` | integer | yes | Number of compute tiles (1 or 2) |
| `sriov_capable` | boolean | yes | Whether device supports SR-IOV |
| `sriov_total_vfs` | integer | yes | Maximum VFs supported (0 if not capable) |
| `sriov_num_vfs` | integer | yes | Currently active VF count |
| `persisted` | boolean | yes | Whether boot persistence is configured |
| `telemetry` | object | detail only | Telemetry data (omitted from list endpoint) |

### 3.2 Device Family Map

Used for device identification and default configuration.

| Family Key | Device IDs | Max VFs | Tiles | Notes |
|------------|-----------|---------|-------|-------|
| `flex` | `0x56c0`, `0x56c1`, `0x56c2` | 31 | 1 | ATS-M / Data Center GPU Flex |
| `pvc` | `0x0bd4`, `0x0bd5`, `0x0bd6` | 62 | 2 | Ponte Vecchio |
| `pvc_ext` | `0x0bda`, `0x0bdb`, `0x0b6e` | 63 | 2 | Ponte Vecchio Extended |
| `bmg` | `0xe211`, `0xe212`, `0xe222` | 24 | 1 | Battlemage |
| `bmg_12vf` | `0xe223` | 12 | 1 | Battlemage (reduced VF) |

This map is defined as a constant hash in `GPU.pm` and referenced by device ID during enumeration.

### 3.3 SR-IOV Precheck Result

Returned by `GET /nodes/{node}/hardware/gpu/{bdf}/sriov`.

```json
{
  "bdf": "0000:03:00.0",
  "checks": {
    "cpu_virtualization": {
      "pass": true,
      "detail": "vmx"
    },
    "iommu": {
      "pass": true,
      "detail": "DMAR devices found"
    },
    "sriov_bios": {
      "pass": true,
      "detail": "sriov_totalvfs = 31"
    },
    "i915_driver": {
      "pass": true,
      "detail": "driver = i915"
    }
  },
  "all_pass": true,
  "sriov_total_vfs": 31,
  "sriov_num_vfs": 4,
  "available_resources": {
    "tiles": [
      {
        "tile": 0,
        "lmem_free_bytes": 8388608000,
        "ggtt_free_bytes": 4026531840,
        "contexts_free": 8192,
        "doorbells_free": 480
      }
    ]
  },
  "persisted_config": {
    "template": "flex-56c0-4vf",
    "num_vfs": 4
  }
}
```

#### Precheck Rules

| Check ID | Method | Pass Condition | Failure Message |
|----------|--------|----------------|-----------------|
| `cpu_virtualization` | Parse `/proc/cpuinfo` flags | `vmx` or `svm` present | "CPU virtualization (VT-x/AMD-V) not enabled in BIOS" |
| `iommu` | Check `/sys/class/iommu/*/` exists | At least one IOMMU device | "IOMMU not enabled — enable VT-d/AMD-Vi in BIOS and add `intel_iommu=on` to kernel cmdline" |
| `sriov_bios` | Read `sriov_totalvfs` from sysfs | Value > 0 | "SR-IOV not enabled in BIOS or not supported by device" |
| `i915_driver` | Read driver symlink | Basename is `i915` | "Device not bound to i915 driver (found: {actual})" |

### 3.4 Virtual Function Record

Returned by `GET /nodes/{node}/hardware/gpu/{bdf}/vf` (list) and `GET /nodes/{node}/hardware/gpu/{bdf}/vf/{vfIndex}` (detail).

```json
{
  "vf_index": 1,
  "bdf": "0000:03:00.1",
  "tiles": [
    {
      "tile": 0,
      "lmem_quota_bytes": 4194304000,
      "ggtt_quota_bytes": 1006632960,
      "contexts": 1024,
      "doorbells": 60,
      "exec_quantum_ms": 20,
      "preempt_timeout_us": 1000
    }
  ],
  "vm_id": null,
  "status": "available"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `vf_index` | integer | VF index (1-based) |
| `bdf` | string | PCI address of the VF |
| `tiles` | array | Per-tile resource allocation |
| `tiles[].lmem_quota_bytes` | integer | Allocated local memory in bytes |
| `tiles[].ggtt_quota_bytes` | integer | Allocated GGTT space in bytes |
| `tiles[].contexts` | integer | Allocated execution contexts |
| `tiles[].doorbells` | integer | Allocated doorbells |
| `tiles[].exec_quantum_ms` | integer | Execution time quantum in ms |
| `tiles[].preempt_timeout_us` | integer | Preemption timeout in microseconds |
| `vm_id` | integer or null | Proxmox VM ID if assigned, else null |
| `status` | string | `available`, `assigned`, `error` |

### 3.5 VF Template Configuration

File: `/etc/pve/local/gpu-vf-templates.conf`

INI format with section-per-template.

```ini
[template-name]
device_ids = 0x56c0, 0x56c2       # Comma-separated PCI device IDs this template applies to
num_vfs = 4                         # Number of VFs to create
vf_lmem = 4194304000               # LMEM per VF in bytes
vf_contexts = 1024                  # Execution contexts per VF
vf_doorbells = 60                   # Doorbells per VF
vf_ggtt = 1006632960               # GGTT per VF in bytes
scheduler = flexible_30fps          # Optional scheduler profile
drivers_autoprobe = 0               # 0 = don't auto-bind VFs to host driver
```

**Validation rules:**
- `device_ids`: At least one valid hex PCI ID
- `num_vfs`: 1 ≤ value ≤ `sriov_totalvfs` for the target device
- `vf_lmem`: Must be > 0 and `num_vfs * vf_lmem ≤ total_lmem`
- `vf_ggtt`: Must be > 0 and `num_vfs * vf_ggtt ≤ total_ggtt`
- `drivers_autoprobe`: 0 or 1

### 3.6 Persistent SR-IOV Configuration

File: `/etc/pve/local/gpu-sriov.conf`

```ini
[0000:03:00.0]
device_id = 0x56c0
num_vfs = 4
template = flex-56c0-4vf
persist = 1

# Optional per-VF overrides
[0000:03:00.0/vf1]
lmem_quota = 8388608000
ggtt_quota = 2013265920
```

**Identity resolution:** Devices are keyed by PCI BDF. On boot, if a BDF is not found, the apply script attempts fallback matching by `device_id` + physical slot. A journal warning is emitted on fallback match; an error is logged if no match is found.

---

## 4. API Specification

All endpoints are registered under the `PVE::API2::Hardware::GPU` module with `proxyto => 'node'`.

### 4.1 List Devices

```
GET /api2/json/nodes/{node}/hardware/gpu
```

**Parameters:** None

**Returns:** Array of GPU device records (without `telemetry` field).

**Behavior:**
1. Call `PVE::SysFSTools::lspci()` or parse `lspci -Dnn` output
2. Filter by vendor `0x8086` and display class `0x03xx`
3. For each matching device, resolve DRM card via `/sys/class/drm/card*/device` symlinks
4. Match device ID against the family map (§3.2)
5. Read SR-IOV status from `sriov_totalvfs` and `sriov_numvfs`
6. Check persistence config for the BDF
7. Return sorted by BDF

**Errors:**
- 500 if sysfs is inaccessible

### 4.2 Device Detail

```
GET /api2/json/nodes/{node}/hardware/gpu/{bdf}
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `bdf` | string (path) | PCI address, format: `DDDD:BB:DD.F` |

**Returns:** Single GPU device record including `telemetry`.

**Behavior:**
1. Validate BDF format via regex: `^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$`
2. Verify device exists at `/sys/bus/pci/devices/{bdf}`
3. Populate all fields from §3.1
4. Read telemetry: temperature from `hwmon/hwmon*/temp*_input`, power from `power*_input`, memory from IOV sysfs
5. Convert units: millidegrees → degrees C, microwatts → watts

**Errors:**
- 404 if BDF not found or not an Intel GPU
- 500 if sysfs read fails

### 4.3 SR-IOV Status

```
GET /api2/json/nodes/{node}/hardware/gpu/{bdf}/sriov
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `bdf` | string (path) | PCI address |

**Returns:** SR-IOV precheck result (§3.3).

**Behavior:**
1. Run all four prechecks (§3.3)
2. Read available resources from IOV sysfs tree
3. Load persisted config if present
4. Return aggregated result

### 4.4 Create Virtual Functions

```
POST /api2/json/nodes/{node}/hardware/gpu/{bdf}/sriov
```

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `bdf` | string (path) | yes | — | PCI address |
| `num_vfs` | integer | yes | — | Number of VFs to create (1 ≤ n ≤ `sriov_totalvfs`) |
| `template` | string | no | — | Template name from `gpu-vf-templates.conf` |
| `lmem_per_vf` | integer | no | — | LMEM bytes per VF (overrides template) |
| `ggtt_per_vf` | integer | no | — | GGTT bytes per VF (overrides template) |
| `contexts_per_vf` | integer | no | — | Contexts per VF (overrides template) |
| `doorbells_per_vf` | integer | no | — | Doorbells per VF (overrides template) |
| `exec_quantum_ms` | integer | no | 20 | Execution quantum in ms |
| `preempt_timeout_us` | integer | no | 1000 | Preemption timeout in us |
| `drivers_autoprobe` | integer | no | 0 | 0 or 1 |
| `persist` | boolean | no | true | Save config for reboot persistence |

**Behavior:**
1. Run SR-IOV prechecks — reject if any fail (400)
2. Verify no VFs currently active (if active, return 409 — must remove first)
3. Resolve resource quotas:
   - If `template` provided: load template values, then apply per-field overrides
   - If no template: require `lmem_per_vf` and `ggtt_per_vf` explicitly, or compute even split from available resources
4. Validate total allocation does not exceed available resources
5. For each VF index 1..`num_vfs`, for each tile:
   - Write `lmem_quota` to `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/lmem_quota`
   - Write `ggtt_quota` to `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/ggtt_quota`
   - Write `exec_quantum_ms` to respective sysfs path
   - Write `preempt_timeout_us` to respective sysfs path
   - **BMG variant:** Write via debugfs paths instead (§4.4.1)
6. Write `drivers_autoprobe` to `/sys/class/drm/{card}/device/sriov_drivers_autoprobe`
7. Write `num_vfs` to `/sys/class/drm/{card}/device/sriov_numvfs`
8. Verify VFs appeared: check `sriov_numvfs` reads back expected value
9. If `persist` is true, write/update `/etc/pve/local/gpu-sriov.conf`
10. Return created VF list

**Error handling:**
- If sysfs write fails at step 5-7, attempt rollback: write `0` to `sriov_numvfs`
- Return 500 with detail of which write failed

#### 4.4.1 BMG Debugfs Variant

For Battlemage devices (`family = bmg` or `bmg_12vf`), resource provisioning uses debugfs:

| Resource | Path |
|----------|------|
| LMEM quota | `/sys/kernel/debug/dri/{bdf}/gt{tile}/vf{n}/lmem_quota` |
| LMEM spare | `/sys/kernel/debug/dri/{bdf}/gt{tile}/pf/lmem_spare` |

The API module must detect family and select the appropriate write path. Debugfs access requires root — the PVE API daemon runs as root, so this is satisfied.

### 4.5 Remove Virtual Functions

```
DELETE /api2/json/nodes/{node}/hardware/gpu/{bdf}/sriov
```

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `bdf` | string (path) | yes | — | PCI address |
| `remove_persist` | boolean | no | false | Also remove persistent config |

**Behavior:**
1. Verify VFs are not assigned to running VMs (if any are, return 409)
2. Write `0` to `/sys/class/drm/{card}/device/sriov_numvfs`
3. Verify VF count is 0
4. If `remove_persist` is true, remove the device section from `gpu-sriov.conf`
5. Return success

**Errors:**
- 409 if VFs are in use by running VMs
- 404 if device not found
- 500 if sysfs write fails

### 4.6 List Virtual Functions

```
GET /api2/json/nodes/{node}/hardware/gpu/{bdf}/vf
```

**Returns:** Array of VF records (§3.4).

**Behavior:**
1. Read `sriov_numvfs` — if 0, return empty array
2. For each VF 1..numvfs:
   - Resolve VF PCI BDF via `/sys/class/drm/{card}/device/virtfn{n-1}/` symlink
   - Read resource quotas from IOV sysfs (or debugfs for BMG)
   - Check if VF PCI address is assigned to any VM in PVE config
3. Return VF array sorted by index

### 4.7 Virtual Function Detail

```
GET /api2/json/nodes/{node}/hardware/gpu/{bdf}/vf/{vfIndex}
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `bdf` | string (path) | PCI address of the PF |
| `vfIndex` | integer (path) | VF index (1-based) |

**Returns:** Single VF record (§3.4).

---

## 5. Sysfs Interface Specification

### 5.1 Device Enumeration Paths

| Purpose | Path Pattern | Read/Write |
|---------|-------------|------------|
| DRM card list | `/sys/class/drm/card*` | R |
| Card-to-PCI mapping | `/sys/class/drm/{card}/device` (symlink) | R |
| PCI vendor ID | `/sys/class/drm/{card}/device/vendor` | R |
| PCI device ID | `/sys/class/drm/{card}/device/device` | R |
| Driver binding | `/sys/class/drm/{card}/device/driver` (symlink) | R |
| NUMA node | `/sys/class/drm/{card}/device/numa_node` | R |
| Render node | `/sys/class/drm/{card}/device/drm/renderD*` | R |

### 5.2 Telemetry Paths

| Metric | Path Pattern | Unit | Conversion |
|--------|-------------|------|------------|
| Temperature | `/sys/class/drm/{card}/device/hwmon/hwmon*/temp*_input` | millidegrees C | ÷ 1000 |
| Power | `/sys/class/drm/{card}/device/hwmon/hwmon*/power*_input` | microwatts | ÷ 1,000,000 |
| LMEM free | `/sys/class/drm/{card}/iov/pf/gt{tile}/available/lmem_free` | bytes | — |
| GPU frequency | `/sys/class/drm/{card}/device/tile*/gt_cur_freq_mhz` | MHz | — |

### 5.3 SR-IOV Management Paths

| Purpose | Path Pattern | Read/Write |
|---------|-------------|------------|
| Total VFs supported | `/sys/class/drm/{card}/device/sriov_totalvfs` | R |
| Active VF count | `/sys/class/drm/{card}/device/sriov_numvfs` | R/W |
| Drivers autoprobe | `/sys/class/drm/{card}/device/sriov_drivers_autoprobe` | R/W |
| VF PCI link | `/sys/class/drm/{card}/device/virtfn{n}/` (symlink) | R |

### 5.4 VF Resource Provisioning Paths (Standard — Flex, PVC)

| Resource | Path Pattern | R/W |
|----------|-------------|-----|
| LMEM quota | `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/lmem_quota` | R/W |
| GGTT quota | `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/ggtt_quota` | R/W |
| Exec quantum | `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/exec_quantum_ms` | R/W |
| Preempt timeout | `/sys/class/drm/{card}/iov/vf{n}/gt{tile}/preempt_timeout_us` | R/W |

### 5.5 VF Resource Provisioning Paths (BMG — Debugfs Variant)

| Resource | Path Pattern | R/W |
|----------|-------------|-----|
| LMEM quota | `/sys/kernel/debug/dri/{bdf}/gt{tile}/vf{n}/lmem_quota` | R/W |
| LMEM spare | `/sys/kernel/debug/dri/{bdf}/gt{tile}/pf/lmem_spare` | R/W |

### 5.6 Available Resource Paths

| Resource | Path Pattern |
|----------|-------------|
| LMEM free | `/sys/class/drm/{card}/iov/pf/gt{tile}/available/lmem_free` |
| GGTT free | `/sys/class/drm/{card}/iov/pf/gt{tile}/available/ggtt_free` |
| Contexts free | `/sys/class/drm/{card}/iov/pf/gt{tile}/available/contexts_free` |
| Doorbells free | `/sys/class/drm/{card}/iov/pf/gt{tile}/available/doorbells_free` |

---

## 6. Frontend Specification

### 6.1 Plugin Registration

The plugin JS file registers:
- A new tab `gpu` in `PVE.node.Config` using `Ext.define('PVE.node.GpuManager', ...)`
- Tab title: **"GPU/GPU"**
- Tab icon: `fa-microchip`
- Tab position: after "Disks" in the hardware section

### 6.2 GpuDeviceGrid (Main View)

**Type:** `Ext.grid.Panel`

**Store:** `Ext.data.Store` backed by `GET /nodes/{node}/hardware/gpu`, auto-refresh every 30 seconds.

**Columns:**

| Header | DataIndex | Width | Renderer |
|--------|-----------|-------|----------|
| Device | `device_name` | flex | — |
| BDF | `bdf` | 140px | monospace font |
| Device ID | `device_id` | 100px | — |
| Temperature | `telemetry.temperature_c` | 100px | `{value} °C` with color thresholds |
| SR-IOV | `sriov_status` | 150px | Computed: "Not supported" / "Capable" / "Active (N VFs)" |
| Persisted | `persisted` | 80px | Icon: `fa-save` if true |

**Toolbar:**
- **Refresh** button

**Behavior:**
- Single-click selects a row and loads detail panel
- Double-click opens the device detail in an expanded view

### 6.3 GpuDeviceDetail (Detail Panel)

**Type:** `Ext.panel.Panel` with card layout, shown below/beside the grid.

**Sections:**

#### 6.3.1 Properties Card

Key-value display of all device fields from §3.1 (excluding telemetry).

#### 6.3.2 Telemetry Card

- Temperature gauge: 0–105°C range, warning at 85°C, critical at 95°C
- Power gauge: 0–max TDP range
- Memory bar: used/total LMEM

Auto-refresh every 10 seconds via `GET /nodes/{node}/hardware/gpu/{bdf}`.

#### 6.3.3 SR-IOV Precheck Card

Status indicators for each precheck (§3.3):
- Green checkmark icon + "Pass" text if `pass: true`
- Red X icon + failure message if `pass: false`

Loaded via `GET /nodes/{node}/hardware/gpu/{bdf}/sriov`.

### 6.4 GpuSriovPanel (VF Management)

**Visible when:** Device is SR-IOV capable and all prechecks pass.

#### 6.4.1 Create VFs Dialog

**Type:** `Ext.window.Window` (modal)

**Fields:**

| Field | Type | Validation |
|-------|------|-----------|
| Number of VFs | `numberfield` | min=1, max=`sriov_total_vfs` |
| Template | `combobox` | Optional, loaded from API (filtered by device_id) |
| LMEM per VF | `numberfield` | Shown when no template; min=1, unit selector (MB/GB) |
| GGTT per VF | `numberfield` | Shown when no template |
| Persist across reboots | `checkbox` | Default: checked |

**Behavior:**
- Selecting a template auto-populates resource fields (read-only)
- Clearing template enables manual resource input
- Submit sends `POST /nodes/{node}/hardware/gpu/{bdf}/sriov`
- Shows progress bar during creation
- On success, refreshes VF grid and device grid

#### 6.4.2 VF Grid

**Type:** `Ext.grid.Panel`

**Columns:**

| Header | DataIndex | Width |
|--------|-----------|-------|
| VF # | `vf_index` | 60px |
| BDF | `bdf` | 140px |
| LMEM | `tiles[0].lmem_quota_bytes` | 120px (rendered as human-readable) |
| GGTT | `tiles[0].ggtt_quota_bytes` | 120px |
| Status | `status` | 100px |
| VM | `vm_id` | 80px |

**Toolbar:**
- **Create VFs** button (opens dialog §6.4.1)
- **Remove All VFs** button (with confirmation dialog; includes checkbox "Also remove persistent config")

### 6.5 Error Handling

- API errors displayed via `Ext.Msg.alert` with the error message from the response body
- Precheck failures disable the "Create VFs" button with tooltip explaining which check failed
- Network errors trigger a retry notification with manual retry button

---

## 7. Boot Persistence Specification

### 7.1 Systemd Service

**Unit:** `pve-gpu-sriov.service`

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
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### 7.2 Apply Script Behavior

`/usr/lib/pve-gpu/apply-sriov-config.sh`:

1. **Wait for DRM devices** — poll `/sys/class/drm/card*` with 1-second intervals, timeout after 60 seconds
2. **Parse config** — read `/etc/pve/local/gpu-sriov.conf`
3. **For each `[bdf]` section where `persist = 1`:**
   a. Resolve BDF → DRM card mapping
   b. If BDF not found, attempt fallback match by `device_id` + slot position; log warning
   c. If no match found, log error and continue to next device
   d. If template specified, load values from `gpu-vf-templates.conf`
   e. Apply per-VF overrides from `[bdf/vfN]` sections
   f. Write resource quotas to sysfs (standard or BMG debugfs paths)
   g. Write `drivers_autoprobe`
   h. Write `sriov_numvfs`
   i. Verify VFs created; log result
4. **Exit 0 always** — boot must never be blocked by GPU configuration failures

### 7.3 Drift Detection

The API `GET /nodes/{node}/hardware/gpu/{bdf}/sriov` response includes a `drift` field when:
- A persisted config exists but current runtime state differs (e.g., different VF count, different resource quotas)
- The persisted BDF no longer matches any device

```json
{
  "drift": {
    "detected": true,
    "details": "Persisted config: 4 VFs, current: 0 VFs"
  }
}
```

The frontend displays a warning banner when drift is detected.

---

## 8. Packaging Specification

### 8.1 Debian Package

**Package name:** `pve-gpu-manager`

**Dependencies:**
- `pve-manager (>= 8.0)`
- `perl`
- `libpve-common-perl`
- `pciutils` (provides `lspci`)

**Conflicts:** None expected (no file overlap with stock PVE packages)

### 8.2 Installation Scripts

#### postinst

1. Back up original files:
   - `cp /usr/share/pve-manager/index.html.tpl /usr/share/pve-manager/index.html.tpl.pre-gpu`
   - `cp /usr/share/perl5/PVE/API2/Nodes.pm /usr/share/perl5/PVE/API2/Nodes.pm.pre-gpu`
2. Apply patches:
   - Insert `<script src="/pve2/js/pve-gpu-plugin.js"></script>` into `index.html.tpl`
   - Insert `__PACKAGE__->register_method({ subclass => "PVE::API2::Hardware::GPU", path => 'hardware/gpu' });` into `Nodes.pm`
3. Enable and start systemd service: `systemctl enable --now pve-gpu-sriov.service`
4. Restart `pveproxy`: `systemctl restart pveproxy.service`

#### prerm

1. Restore backup files:
   - `cp /usr/share/pve-manager/index.html.tpl.pre-gpu /usr/share/pve-manager/index.html.tpl`
   - `cp /usr/share/perl5/PVE/API2/Nodes.pm.pre-gpu /usr/share/perl5/PVE/API2/Nodes.pm`
2. Disable systemd service: `systemctl disable pve-gpu-sriov.service`
3. Restart `pveproxy`: `systemctl restart pveproxy.service`

#### postrm (purge only)

1. Remove config files: `/etc/pve/local/gpu-sriov.conf`, `/etc/pve/local/gpu-vf-templates.conf`
2. Remove backup files: `*.pre-gpu`

### 8.3 Upgrade Safety

An APT hook at `/etc/apt/apt.conf.d/99-pve-gpu-reapply` re-applies patches after `pve-manager` upgrades:

```
DPkg::Post-Invoke { "if [ -x /usr/lib/pve-gpu/reapply-patches.sh ]; then /usr/lib/pve-gpu/reapply-patches.sh; fi"; };
```

The reapply script:
1. Checks if patches are already applied (idempotent)
2. Backs up new files before patching
3. Applies patches
4. Restarts `pveproxy` only if patches were actually applied
5. Logs all actions to syslog

---

## 9. Security & Authentication

### 9.1 Proxmox Auth Integration

All API endpoints are served through `pveproxy` and inherit PVE's full authentication and authorization stack. No custom auth logic is implemented.

#### Authentication

- **Ticket auth**: Browser sessions use PVE auth tickets (cookie `PVEAuthCookie`) issued by `POST /access/ticket`. The ticket is verified by `PVE::AccessControl::verify_ticket()` on every request.
- **API token auth**: Programmatic access uses `PVEAPIToken=USER@REALM!TOKENID=SECRET` in the `Authorization` header. Verified by `PVE::AccessControl::verify_token()`.
- **CSRF protection**: All state-changing requests (POST, PUT, DELETE) require a valid `CSRFPreventionToken` header matching the auth ticket. This is enforced automatically by the PVE API framework.

#### Authorization — Per-Endpoint Permissions

Each endpoint declares its required privilege via the `permissions` property in the API method registration. Permissions are checked against the PVE ACL tree at the path `/nodes/{node}`.

| Endpoint | Method | Required Privilege | ACL Path |
|----------|--------|--------------------|----------|
| List devices | GET | `Sys.Audit` | `/nodes/{node}` |
| Device detail | GET | `Sys.Audit` | `/nodes/{node}` |
| SR-IOV status | GET | `Sys.Audit` | `/nodes/{node}` |
| Create VFs | POST | `Sys.Modify` | `/nodes/{node}` |
| Remove VFs | DELETE | `Sys.Modify` | `/nodes/{node}` |
| List VFs | GET | `Sys.Audit` | `/nodes/{node}` |
| VF detail | GET | `Sys.Audit` | `/nodes/{node}` |

**Implementation pattern** (matching `PVE::API2::Hardware::PCI`):

```perl
__PACKAGE__->register_method({
    name => 'list_devices',
    path => '',
    method => 'GET',
    proxyto => 'node',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    description => "List Intel GPU/GPU devices on the node.",
    # ...
});

__PACKAGE__->register_method({
    name => 'create_vfs',
    path => '{bdf}/sriov',
    method => 'POST',
    proxyto => 'node',
    protected => 1,
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    description => "Create SR-IOV virtual functions.",
    # ...
});
```

Key attributes:
- **`proxyto => 'node'`**: Ensures the request is forwarded to and executed on the correct cluster node, even when the API call is made through a different node's proxy.
- **`protected => 1`**: Set on all write endpoints. Ensures the handler runs inside `pvedaemon` (which runs as root), not in the unprivileged `pveproxy` worker. This is required for sysfs/debugfs write access.

#### Privilege Rationale

| Privilege | Usage | Justification |
|-----------|-------|---------------|
| `Sys.Audit` | Read endpoints | Standard PVE privilege for viewing node hardware info. Matches `PVE::API2::Hardware::PCI` pattern. |
| `Sys.Modify` | Write endpoints | Standard PVE privilege for modifying node configuration. Creating/removing VFs changes hardware state. |

Users with the `PVEAdmin` or `Administrator` role have both privileges by default. The `PVEAuditor` role has `Sys.Audit` only (read-only access).

### 9.2 Frontend Auth Handling

The ExtJS frontend relies on PVE's built-in auth mechanisms:
- `Proxmox.Utils.API2Request` automatically includes the auth cookie and CSRF token on all API calls
- 401 responses redirect to the login page
- 403 responses display an "insufficient permissions" error dialog
- No auth tokens or credentials are stored or managed by plugin code

### 9.3 Input Validation

| Parameter | Validation | Regex / Rule |
|-----------|-----------|-------------|
| `bdf` | PCI BDF format | `^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$` |
| `num_vfs` | Integer range | `1 ≤ n ≤ sriov_totalvfs` (device-specific max) |
| `template` | Alphanumeric + hyphens | `^[a-zA-Z0-9_-]+$` — must exist in templates config |
| `lmem_per_vf` | Positive integer | `> 0`, `num_vfs * value ≤ available` |
| `ggtt_per_vf` | Positive integer | `> 0`, `num_vfs * value ≤ available` |
| `vfIndex` | Positive integer | `1 ≤ n ≤ sriov_numvfs` |
| `drivers_autoprobe` | Boolean integer | `0` or `1` |

All parameters are validated using PVE's `PVE::JSONSchema` type system, which provides:
- Type coercion and range checking
- Automatic 400 responses for invalid input
- Protection against injection via sysfs paths (no user input is interpolated into file paths without validation)

### 9.4 Sysfs Write Safety

- All sysfs/debugfs paths are constructed from validated BDF + device family constants — never from raw user input
- File paths are built using known DRM card names resolved from kernel symlinks
- Write operations use Perl's `sysopen` with `O_WRONLY` — no shell interpolation
- The apply-sriov-config.sh boot script reads only from trusted config files under `/etc/pve/local/`

### 9.5 Additional Security Controls

| Concern | Mitigation |
|---------|-----------|
| Sysfs write access | Write endpoints are `protected => 1`, running in `pvedaemon` as root |
| Config file tampering | `/etc/pve/local/` is a node-local pmxcfs path; access follows PVE's cluster filesystem permissions |
| Debugfs access (BMG) | Debugfs is mounted root-only by default; `pvedaemon` runs as root |
| VF removal safety | API checks for VM assignments before removing VFs; returns 409 if any VF is in use |
| Boot script failures | Script always exits 0; failures logged to journal, never blocks boot |
| Cluster request forgery | `proxyto => 'node'` with auth forwarding ensures requests are re-authenticated on the target node |

---

## 10. Testing Strategy

### 10.1 Unit Tests

- BDF validation regex
- Device family map lookups
- Config file parsing (templates and persistent config)
- Resource quota calculations (even split, template-based, manual)
- Precheck logic with mocked sysfs reads

### 10.2 Integration Tests

- API endpoint round-trip: create VFs → list → detail → remove
- Persistence: create with `persist=true` → verify config file written → simulate reboot apply
- Template loading: verify template values populate correctly
- BMG path selection: verify debugfs paths used for BMG device IDs

### 10.3 Manual Verification

- Install `.deb` package on a Proxmox host with an Intel GPU
- Verify the "GPU/GPU" tab appears in the web UI
- Confirm device enumeration shows correct GPU info
- Create VFs with a template and verify in `lspci`
- Reboot and verify VFs are restored
- Remove VFs and verify cleanup
- Uninstall package and verify clean removal

---

## 11. Future Considerations

These items are explicitly **out of scope** for the initial implementation but inform design decisions:

- **Per-VF telemetry** — monitoring individual VF utilization (requires i915 PMU per-VF support)
- **Scheduler configuration UI** — exposing scheduler profiles (flexible, strict, burstable QOS)
- **Multi-vendor support** — extending to NVIDIA/AMD GPUs
- **VM integration** — auto-suggesting VF passthrough when creating VMs
- **Cluster-wide view** — aggregated GPU inventory across all nodes
