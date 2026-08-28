# PVE GPU/GPU Manager — UI Mockups & Workflow Diagrams

> Historical upstream mockups. The current UI and supported Battlemage/xe scope
> are documented in `README.md`; Flex/i915 screens below are retained only as
> design history.

## 1. UI Mockups

### 1.1 Node Tab — GPU/GPU Main View

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Datacenter > node1 > GPU/GPU                                    [fa-microchip] │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SR-IOV Prerequisites                                                       │
│  ┌────────────────┐ ┌──────────────┐ ┌────────────────┐ ┌───────────────┐  │
│  │ ✓ CPU Virt.    │ │ ✓ IOMMU      │ │ ✓ SR-IOV BIOS  │ │ ✓ i915 Driver │  │
│  │   (VT-x)      │ │   (VT-d)     │ │   Enabled      │ │   Loaded      │  │
│  └────────────────┘ └──────────────┘ └────────────────┘ └───────────────┘  │
│                                                                             │
│  ┌─ Toolbar ──────────────────────────────────────────────────────────────┐ │
│  │ [↻ Refresh]                                                           │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌─ GPU Devices ──────────────────────────────────────────────────────────┐ │
│  │ Device                       │ BDF           │ ID     │ Temp │ SR-IOV │ │
│  │─────────────────────────────│───────────────│────────│──────│────────│ │
│  │ Intel DC GPU Flex 170       │ 0000:03:00.0  │ 0x56c0 │ 42°C │ Active │ │
│  │                             │               │        │      │ (4 VFs)│ │
│  │─────────────────────────────│───────────────│────────│──────│────────│ │
│  │ Intel DC GPU Flex 140       │ 0000:04:00.0  │ 0x56c1 │ 38°C │Capable │ │
│  │─────────────────────────────│───────────────│────────│──────│────────│ │
│  │ Intel Arc A770              │ 0000:05:00.0  │ 0x5690 │ 35°C │  N/A   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌─ Device Detail: Intel DC GPU Flex 170 (0000:03:00.0) ─────────────────┐ │
│  │                                                                        │ │
│  │  Properties                        Telemetry                           │ │
│  │  ┌──────────────────────────┐     ┌──────────────────────────────────┐ │ │
│  │  │ Family:    Flex (ATS-M)  │     │  Temperature    Power    Memory  │ │ │
│  │  │ Device ID: 0x56c0       │     │  ┌────┐       ┌────┐   ┌──────┐ │ │ │
│  │  │ Driver:    i915          │     │  │    │       │    │   │██████│ │ │ │
│  │  │ DRM Card:  card0         │     │  │ 42 │ °C    │ 65 │ W │ 52%  │ │ │ │
│  │  │ Render:    renderD128    │     │  │    │       │    │   │      │ │ │ │
│  │  │ NUMA:      0             │     │  └────┘       └────┘   └──────┘ │ │ │
│  │  │ Tiles:     1             │     │  0   50  105  0  150   0   16GB │ │ │
│  │  │ Max VFs:   31            │     └──────────────────────────────────┘ │ │
│  │  └──────────────────────────┘                                          │ │
│  │                                                                        │ │
│  │  SR-IOV Virtual Functions                                              │ │
│  │  ┌─ Toolbar ────────────────────────────────────────────────────────┐  │ │
│  │  │ [+ Create VFs]  [✕ Remove All VFs]                              │  │ │
│  │  └──────────────────────────────────────────────────────────────────┘  │ │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │ │
│  │  │ VF# │ BDF           │ LMEM      │ GGTT      │ Status    │ VM   │  │ │
│  │  │─────│───────────────│───────────│───────────│───────────│──────│  │ │
│  │  │  1  │ 0000:03:00.1  │ 4.00 GB   │ 960 MB    │ Available │  —   │  │ │
│  │  │  2  │ 0000:03:00.2  │ 4.00 GB   │ 960 MB    │ Assigned  │ 101  │  │ │
│  │  │  3  │ 0000:03:00.3  │ 4.00 GB   │ 960 MB    │ Available │  —   │  │ │
│  │  │  4  │ 0000:03:00.4  │ 4.00 GB   │ 960 MB    │ Assigned  │ 102  │  │ │
│  │  └──────────────────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Create VFs Dialog

```
┌─── Create Virtual Functions ─────────────────────────────┐
│                                                           │
│  Device: Intel DC GPU Flex 170 (0000:03:00.0)            │
│  Available: 31 VFs max, 16 GB LMEM, 4 GB GGTT           │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Number of VFs:    [  4  ▾]   (1–31)                 │ │
│  │                                                      │ │
│  │ Template:         [ flex-56c0-4vf           ▾]      │ │
│  │                   [ ○ None (manual)          ]      │ │
│  │                   [ ● flex-56c0-4vf          ]      │ │
│  │                   [   flex-56c0-2vf          ]      │ │
│  │                                                      │ │
│  │ ── Resource Allocation (per VF) ──────────────────  │ │
│  │                                                      │ │
│  │ LMEM per VF:     [ 4,194,304,000 ] bytes  (4.0 GB) │ │
│  │ GGTT per VF:     [ 1,006,632,960 ] bytes  (960 MB) │ │
│  │ Contexts:        [ 1024          ]                   │ │
│  │ Doorbells:       [ 60            ]                   │ │
│  │ Exec Quantum:    [ 20            ] ms                │ │
│  │ Preempt Timeout: [ 1000          ] μs                │ │
│  │                                                      │ │
│  │ ── Options ───────────────────────────────────────  │ │
│  │                                                      │ │
│  │ [✓] Persist across reboots                          │ │
│  │ [ ] Auto-probe drivers                              │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                           │
│  Total LMEM: 16.0 GB / 16.0 GB  ████████████████ 100%   │
│  Total GGTT:  3.8 GB /  4.0 GB  ██████████████░░  94%   │
│                                                           │
│                              [ Cancel ]  [ Create VFs ]  │
└───────────────────────────────────────────────────────────┘
```

### 1.3 Remove VFs Confirmation Dialog

```
┌─── Remove Virtual Functions ─────────────────────────────┐
│                                                           │
│  ⚠  Are you sure you want to remove all 4 virtual        │
│     functions from Intel DC GPU Flex 170?                 │
│                                                           │
│  Device: 0000:03:00.0                                    │
│                                                           │
│  ⚠  VF 2 is assigned to VM 101                           │
│  ⚠  VF 4 is assigned to VM 102                           │
│                                                           │
│  These VMs must be stopped before VFs can be removed.     │
│                                                           │
│  [✓] Also remove persistent boot configuration           │
│                                                           │
│                              [ Cancel ]  [ Remove VFs ]  │
└───────────────────────────────────────────────────────────┘
```

### 1.4 Precheck Failure State

```
┌─── SR-IOV Prerequisites ─────────────────────────────────┐
│                                                           │
│  ✓ CPU Virtualization   VT-x enabled                     │
│  ✗ IOMMU                Not detected — enable VT-d in    │
│                         BIOS and add intel_iommu=on to   │
│                         kernel command line               │
│  ✓ SR-IOV BIOS          sriov_totalvfs = 31              │
│  ✓ i915 Driver          Loaded                           │
│                                                           │
│  ⚠ SR-IOV management disabled until all checks pass      │
│                                                           │
└───────────────────────────────────────────────────────────┘
```

### 1.5 Drift Warning Banner

```
┌─── ⚠ Configuration Drift Detected ──────────────────────┐
│                                                           │
│  Persisted: 4 VFs — Current: 0 VFs                       │
│  The saved SR-IOV configuration does not match the        │
│  running state. This may happen after a failed boot       │
│  apply or manual changes.                                 │
│                                                           │
│  [ Re-apply Config ]  [ Dismiss ]                        │
└───────────────────────────────────────────────────────────┘
```

---

## 2. Workflow Diagrams

### 2.1 Device Enumeration Flow

```mermaid
flowchart TD
    A[API Request: GET /hardware/gpu] --> B[Authenticate & authorize<br/>Sys.Audit on /nodes/node]
    B --> C[Call PVE::SysFSTools::lspci<br/>or parse lspci -Dnn]
    C --> D[Filter: vendor=0x8086<br/>class=0x03xx]
    D --> E{Any devices<br/>found?}
    E -- No --> F[Return empty array]
    E -- Yes --> G[For each PCI device]
    G --> H[Resolve DRM card via<br/>/sys/class/drm/card*/device symlink]
    H --> I[Match device_id against<br/>family map]
    I --> J[Read sriov_totalvfs<br/>and sriov_numvfs]
    J --> K[Check persistence config<br/>for this BDF]
    K --> L{More<br/>devices?}
    L -- Yes --> G
    L -- No --> M[Return device array<br/>sorted by BDF]
```

### 2.2 SR-IOV Precheck Flow

```mermaid
flowchart TD
    A[API Request: GET /hardware/gpu/BDF/sriov] --> B[Authenticate & authorize]
    B --> C[Validate BDF format]
    C --> D[Check 1: CPU Virtualization]
    D --> D1[Parse /proc/cpuinfo flags]
    D1 --> D2{vmx or svm<br/>present?}
    D2 -- Yes --> E[Check 2: IOMMU]
    D2 -- No --> D3[Record FAIL:<br/>VT-x/AMD-V not enabled]
    D3 --> E
    E --> E1[Check /sys/class/iommu/*]
    E1 --> E2{IOMMU devices<br/>exist?}
    E2 -- Yes --> F[Check 3: SR-IOV BIOS]
    E2 -- No --> E3[Record FAIL:<br/>IOMMU not enabled]
    E3 --> F
    F --> F1[Read sriov_totalvfs]
    F1 --> F2{Value > 0?}
    F2 -- Yes --> G[Check 4: i915 Driver]
    F2 -- No --> F3[Record FAIL:<br/>SR-IOV not in BIOS]
    F3 --> G
    G --> G1[Read driver symlink<br/>basename]
    G1 --> G2{Driver = i915?}
    G2 -- Yes --> H[Read available resources<br/>from IOV sysfs tree]
    G2 -- No --> G3[Record FAIL:<br/>Wrong driver]
    G3 --> H
    H --> I[Load persisted config<br/>if present]
    I --> J[Check for drift between<br/>persisted and runtime state]
    J --> K[Return precheck result<br/>with all_pass flag]
```

### 2.3 VF Creation Flow

```mermaid
flowchart TD
    A[API Request: POST /hardware/gpu/BDF/sriov] --> B[Authenticate & authorize<br/>Sys.Modify on /nodes/node]
    B --> C[Run SR-IOV prechecks]
    C --> C1{All pass?}
    C1 -- No --> C2[Return 400:<br/>Prechecks failed]
    C1 -- Yes --> D{VFs already<br/>active?}
    D -- Yes --> D1[Return 409:<br/>Remove existing VFs first]
    D -- No --> E{Template<br/>specified?}
    E -- Yes --> F[Load template values<br/>from gpu-vf-templates.conf]
    F --> G[Apply per-field overrides<br/>from request params]
    E -- No --> G1{Manual quotas<br/>provided?}
    G1 -- Yes --> G
    G1 -- No --> G2[Compute even split<br/>from available resources]
    G2 --> G
    G --> H[Validate: total allocation<br/>≤ available resources]
    H --> H1{Valid?}
    H1 -- No --> H2[Return 400:<br/>Exceeds resources]
    H1 -- Yes --> I[For each VF 1..num_vfs]
    I --> J{Device family<br/>= BMG?}
    J -- Yes --> K[Write quotas via<br/>debugfs paths]
    J -- No --> L[Write quotas via<br/>sysfs IOV paths]
    K --> M[Write drivers_autoprobe]
    L --> M
    M --> N[Write num_vfs to<br/>sriov_numvfs]
    N --> O{Verify VFs<br/>created?}
    O -- No --> P[Rollback: write 0<br/>to sriov_numvfs]
    P --> P1[Return 500:<br/>Creation failed]
    O -- Yes --> Q{Persist<br/>requested?}
    Q -- Yes --> R[Write/update<br/>gpu-sriov.conf]
    Q -- No --> S[Return created VF list]
    R --> S
```

### 2.4 VF Removal Flow

```mermaid
flowchart TD
    A[API Request: DELETE /hardware/gpu/BDF/sriov] --> B[Authenticate & authorize<br/>Sys.Modify on /nodes/node]
    B --> C[Validate BDF, resolve DRM card]
    C --> D[List current VFs]
    D --> E[Check VF-to-VM assignments<br/>in PVE config]
    E --> F{Any VFs assigned<br/>to running VMs?}
    F -- Yes --> G[Return 409: VFs in use<br/>List affected VM IDs]
    F -- No --> H[Write 0 to<br/>sriov_numvfs]
    H --> I{Verify VF<br/>count = 0?}
    I -- No --> J[Return 500:<br/>Removal failed]
    I -- Yes --> K{remove_persist<br/>= true?}
    K -- Yes --> L[Remove device section<br/>from gpu-sriov.conf]
    K -- No --> M[Return success]
    L --> M
```

### 2.5 Boot Persistence Flow

```mermaid
flowchart TD
    A[System Boot] --> B[systemd starts<br/>pve-gpu-sriov.service]
    B --> C[apply-sriov-config.sh]
    C --> D[Poll for /sys/class/drm/card*<br/>timeout: 60s]
    D --> D1{DRM devices<br/>appeared?}
    D1 -- No --> D2[Log error: timeout<br/>waiting for DRM]
    D2 --> Z[Exit 0<br/>Never block boot]
    D1 -- Yes --> E[Parse /etc/pve/local/<br/>gpu-sriov.conf]
    E --> F[For each device section<br/>where persist=1]
    F --> G[Resolve BDF → DRM card]
    G --> G1{BDF<br/>found?}
    G1 -- No --> H[Fallback: match by<br/>device_id + slot]
    H --> H1{Fallback<br/>matched?}
    H1 -- No --> I[Log error,<br/>skip device]
    I --> F2{More<br/>devices?}
    H1 -- Yes --> J[Log warning:<br/>BDF changed]
    J --> K
    G1 -- Yes --> K{Template<br/>specified?}
    K -- Yes --> L[Load template from<br/>gpu-vf-templates.conf]
    L --> M[Apply per-VF overrides]
    K -- No --> M
    M --> N[Write resource quotas<br/>to sysfs/debugfs]
    N --> O[Write drivers_autoprobe]
    O --> P[Write sriov_numvfs]
    P --> Q{VFs<br/>created?}
    Q -- Yes --> R[Log success]
    Q -- No --> S[Log error]
    R --> F2
    S --> F2
    F2 -- Yes --> F
    F2 -- No --> Z
```

### 2.6 API Request Authentication Flow

```mermaid
flowchart TD
    A[Browser: HTTPS Request] --> B[pveproxy<br/>reverse proxy]
    B --> C{Auth ticket or<br/>API token in<br/>request?}
    C -- No --> C1[Return 401<br/>Unauthorized]
    C -- Yes --> D[PVE::AccessControl<br/>verify_ticket / verify_token]
    D --> D1{Valid<br/>credentials?}
    D1 -- No --> D2[Return 401<br/>Invalid ticket/token]
    D1 -- Yes --> E{POST/PUT/DELETE?}
    E -- Yes --> F[Verify CSRFPreventionToken<br/>header matches ticket]
    F --> F1{CSRF<br/>valid?}
    F1 -- No --> F2[Return 403<br/>CSRF check failed]
    F1 -- Yes --> G
    E -- No --> G[Check ACL permission<br/>on /nodes/node path]
    G --> G1{Has required<br/>privilege?}
    G1 -- No --> G2[Return 403<br/>Insufficient privileges]
    G1 -- Yes --> H{proxyto<br/>= node?}
    H -- Yes --> I[Forward request to<br/>target node's pvedaemon]
    H -- No --> J[Execute locally]
    I --> K[GPU.pm handler<br/>executes as root]
    J --> K
    K --> L[Read/write sysfs]
    L --> M[Return JSON response]
```

### 2.7 Package Installation Flow

```mermaid
flowchart TD
    A[dpkg -i pve-gpu-manager.deb] --> B[Unpack files to<br/>target paths]
    B --> C[postinst script]
    C --> D[Backup originals:<br/>index.html.tpl.pre-gpu<br/>Nodes.pm.pre-gpu]
    D --> E[Patch index.html.tpl:<br/>insert script tag]
    E --> F[Patch Nodes.pm:<br/>register GPU sub-route]
    F --> G[systemctl enable --now<br/>pve-gpu-sriov.service]
    G --> H[systemctl restart<br/>pveproxy.service]
    H --> I[Installation complete]

    J[pve-manager upgrade] --> K[APT hook triggers<br/>99-pve-gpu-reapply]
    K --> L[reapply-patches.sh]
    L --> L1{Patches already<br/>applied?}
    L1 -- Yes --> L2[No action needed]
    L1 -- No --> M[Backup new files]
    M --> N[Re-apply patches]
    N --> O[Restart pveproxy]
    O --> P[Log to syslog]
```

### 2.8 Package Removal Flow

```mermaid
flowchart TD
    A[apt remove pve-gpu-manager] --> B[prerm script]
    B --> C[Restore backups:<br/>index.html.tpl.pre-gpu → index.html.tpl<br/>Nodes.pm.pre-gpu → Nodes.pm]
    C --> D[systemctl disable<br/>pve-gpu-sriov.service]
    D --> E[systemctl restart<br/>pveproxy.service]
    E --> F[Remove package files]
    F --> G{Purge?}
    G -- Yes --> H[postrm: remove<br/>gpu-sriov.conf<br/>gpu-vf-templates.conf<br/>*.pre-gpu backups]
    G -- No --> I[Config files retained]
```

### 2.9 Frontend Component Interaction

```mermaid
flowchart TD
    A[PVE.node.Config] --> B[GpuManager Tab<br/>fa-microchip]
    B --> C[GpuDeviceGrid]
    B --> D[SriovPrecheckBar]

    C -- row select --> E[GpuDeviceDetail]
    E --> F[PropertiesCard]
    E --> G[TelemetryCard<br/>auto-refresh 10s]
    E --> H[GpuSriovPanel]

    H --> I[VF Grid]
    H --> J[Create VFs Button]
    H --> K[Remove VFs Button]

    J -- click --> L[CreateVfsDialog]
    L -- submit --> M[POST /hardware/gpu/BDF/sriov]
    M -- success --> N[Refresh VF Grid +<br/>Device Grid]

    K -- click --> O[RemoveVfsDialog]
    O -- confirm --> P[DELETE /hardware/gpu/BDF/sriov]
    P -- success --> N

    D -- load --> Q[GET /hardware/gpu/BDF/sriov]
    C -- load --> R[GET /hardware/gpu<br/>auto-refresh 30s]
    I -- load --> S[GET /hardware/gpu/BDF/vf]
```

---

## 3. State Machine: VF Lifecycle

```mermaid
stateDiagram-v2
    [*] --> NoVFs: Device detected

    NoVFs --> Creating: POST sriov (create)
    Creating --> Active: sriov_numvfs written successfully
    Creating --> NoVFs: Rollback on failure

    Active --> Removing: DELETE sriov
    Removing --> NoVFs: sriov_numvfs = 0

    Active --> Active: VF assigned to VM
    Active --> Active: VF unassigned from VM

    state Active {
        [*] --> Available
        Available --> Assigned: VM uses VF passthrough
        Assigned --> Available: VM stopped / VF detached
        Assigned --> Error: Driver bind failure
        Error --> Available: Manual recovery
    }

    NoVFs --> Persisted: persist=true written
    Persisted --> NoVFs: persist config removed
    Persisted --> BootApply: System reboot
    BootApply --> Active: apply-sriov-config.sh success
    BootApply --> Drift: apply failed
    Drift --> Active: Manual re-apply
    Drift --> NoVFs: Remove persist config
```

---

## 4. Data Flow: Telemetry Collection

```mermaid
flowchart LR
    subgraph Kernel
        A[hwmon driver] --> B[/sys/.../temp*_input<br/>millidegrees C]
        A --> C[/sys/.../power*_input<br/>microwatts]
        D[i915 driver] --> E[/sys/.../iov/pf/gt*/available/<br/>lmem_free bytes]
        D --> F[/sys/.../tile*/gt_cur_freq_mhz]
    end

    subgraph "GPU.pm (Perl)"
        B --> G[Read & convert<br/>÷ 1000 → °C]
        C --> H[Read & convert<br/>÷ 1000000 → W]
        E --> I[Read bytes<br/>compute % used]
        F --> J[Read MHz]
        G --> K[JSON response]
        H --> K
        I --> K
        J --> K
    end

    subgraph "Browser (ExtJS)"
        K --> L[Temperature Gauge<br/>0-105°C]
        K --> M[Power Gauge<br/>0-TDP W]
        K --> N[Memory Bar<br/>used/total]
    end
```
