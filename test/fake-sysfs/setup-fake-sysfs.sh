#!/bin/bash
# Creates a complete fake sysfs/procfs/debugfs tree for testing the PVE GPU plugin
# without requiring real Intel GPU hardware.
#
# Usage: setup-fake-sysfs.sh [--root DIR]
#   --root DIR: root of fake tree (default: /tmp/fake-gpu)

set -e

ROOT="/tmp/fake-gpu"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            ROOT="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

echo "Setting up fake sysfs tree at: $ROOT"

# Remove existing tree and recreate clean
if [ -d "$ROOT" ]; then
    rm -rf "$ROOT"
fi

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
mkfile() {
    local path="$1"
    local content="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
    chmod 666 "$path"   # simulate writable sysfs files
}

# ---------------------------------------------------------------------------
# /proc/cpuinfo
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/proc"
cat > "$ROOT/proc/cpuinfo" << 'EOF'
processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6
model		: 106
model name	: Intel(R) Xeon(R) Gold 6338N CPU @ 2.20GHz
stepping	: 6
microcode	: 0xd0003e9
cpu MHz		: 2200.000
cache size	: 48640 KB
physical id	: 0
siblings	: 4
core id		: 0
cpu cores	: 4
apicid		: 0
initial apicid	: 0
fpu		: yes
fpu_exception	: yes
cpuid level	: 27
wp		: yes
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc art arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni pclmulqdq dtes64 monitor ds_cpl vmx smx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid dca sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm 3dnowprefetch cpuid_fault epb cat_l3 cat_l2 cdp_l3 invpcid_single ssbd mba ibrs ibpb stibp ibrs_enhanced tpr_shadow vnmi flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid cqm rdt_a avx512f avx512dq rdseed adx smap avx512ifma clflushopt clwb intel_pt avx512cd sha_ni avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local split_lock_detect avx512_vpopcntdq avx512_vbmi2 avx512_vnni avx512_bitalg avx512_vp2intersect rdpid movdiri movdir64b md_clear ibt flush_l1d arch_capabilities
bogomips	: 4400.00
EOF
chmod 444 "$ROOT/proc/cpuinfo"

# ---------------------------------------------------------------------------
# IOMMU
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/sys/class/iommu/dmar0"

# ---------------------------------------------------------------------------
# Unsupported Flex 170 negative control — BDF 0000:03:00.0
#
# The Intel backend intentionally supports Battlemage only.  Keep this PCI
# function present so enumeration tests prove that an Intel GPU with an
# unsupported device ID is ignored.
# ---------------------------------------------------------------------------
PF0="$ROOT/sys/bus/pci/devices/0000:03:00.0"
mkdir -p "$PF0"

mkfile "$PF0/vendor"                  "0x8086"
mkfile "$PF0/device"                  "0x56c0"
mkfile "$PF0/subsystem_vendor"        "0x8086"
mkfile "$PF0/subsystem_device"        "0x4905"
mkfile "$PF0/numa_node"               "0"
mkfile "$PF0/sriov_totalvfs"          "31"
mkfile "$PF0/sriov_numvfs"            "0"
mkfile "$PF0/sriov_drivers_autoprobe" "1"

# driver symlink: basename must be "i915"
mkdir -p "$ROOT/sys/module/i915"
# relative path from $PF0 up to ROOT/sys/module/i915
ln -sfn "../../../../module/i915" "$PF0/driver"

# drm render node (empty dir)
mkdir -p "$PF0/drm/renderD128"

# virtfn symlinks pointing at VF PCI device dirs (relative)
ln -sfn "../0000:03:00.1" "$PF0/virtfn0"
ln -sfn "../0000:03:00.2" "$PF0/virtfn1"
ln -sfn "../0000:03:00.3" "$PF0/virtfn2"
ln -sfn "../0000:03:00.4" "$PF0/virtfn3"

# hwmon under the PF device
mkdir -p "$PF0/hwmon/hwmon0"
mkfile "$PF0/hwmon/hwmon0/temp1_input"  "42000"
mkfile "$PF0/hwmon/hwmon0/power1_input" "65300000"

# VF PCI device stubs (with physfn symlink back to PF)
for bdf in 0000:03:00.1 0000:03:00.2 0000:03:00.3 0000:03:00.4; do
    VF="$ROOT/sys/bus/pci/devices/$bdf"
    mkdir -p "$VF"
    mkfile "$VF/vendor" "0x8086"
    mkfile "$VF/device" "0x56c0"
    ln -sfn "../0000:03:00.0" "$VF/physfn"
done

# DRM class entry for card0
mkdir -p "$ROOT/sys/class/drm/card0"
# card0/device -> the PF PCI device dir (absolute symlink for reliability)
ln -sfn "$PF0" "$ROOT/sys/class/drm/card0/device"
# card0 -> PCI device (canonical DRM sysfs layout)
ln -sfn "../../bus/pci/devices/0000:03:00.0" "$ROOT/sys/class/drm/card0/device_rel"

# SR-IOV IOV directory under card0
IOV="$ROOT/sys/class/drm/card0/iov"

# PF GT0 available resources
mkfile "$IOV/pf/gt0/available/lmem_free"      "16106127360"
mkfile "$IOV/pf/gt0/available/ggtt_free"      "4026531840"
mkfile "$IOV/pf/gt0/available/contexts_free"  "8192"
mkfile "$IOV/pf/gt0/available/doorbells_free" "480"

# VF slots vf1..vf4
for vf in vf1 vf2 vf3 vf4; do
    mkfile "$IOV/$vf/gt0/lmem_quota"         "0"
    mkfile "$IOV/$vf/gt0/ggtt_quota"         "0"
    mkfile "$IOV/$vf/gt0/exec_quantum_ms"    "0"
    mkfile "$IOV/$vf/gt0/preempt_timeout_us" "0"
done

# Also expose the IOV dir from the PCI device path (some drivers do both)
ln -sfn "$IOV" "$PF0/iov"

# ---------------------------------------------------------------------------
# Supported BMG GPU — BDF 0000:04:00.0
# ---------------------------------------------------------------------------
PF1="$ROOT/sys/bus/pci/devices/0000:04:00.0"
mkdir -p "$PF1"

mkfile "$PF1/vendor"                  "0x8086"
mkfile "$PF1/device"                  "0xe211"
mkfile "$PF1/subsystem_vendor"        "0x8086"
mkfile "$PF1/subsystem_device"        "0x0000"
mkfile "$PF1/numa_node"               "0"
mkfile "$PF1/sriov_totalvfs"          "24"
mkfile "$PF1/sriov_numvfs"            "0"
mkfile "$PF1/sriov_drivers_autoprobe" "1"
mkfile "$PF1/driver_override"          ""

# BMG uses the xe driver
mkdir -p "$ROOT/sys/module/xe"
ln -sfn "../../../../module/xe" "$PF1/driver"

mkdir -p "$PF1/drm/renderD129"

# DRM class entries for card1 and its render node
mkdir -p "$ROOT/sys/class/drm/card1"
ln -sfn "$PF1" "$ROOT/sys/class/drm/card1/device"
mkdir -p "$ROOT/sys/class/drm/renderD129"
ln -sfn "$PF1" "$ROOT/sys/class/drm/renderD129/device"

# Deterministic BMG telemetry exposed through card1/device.
mkdir -p "$PF1/hwmon/hwmon1"
mkfile "$PF1/hwmon/hwmon1/temp1_label"  "GPU"
mkfile "$PF1/hwmon/hwmon1/temp1_input"  "43000"
mkfile "$PF1/hwmon/hwmon1/temp2_label"  "Memory"
mkfile "$PF1/hwmon/hwmon1/temp2_input"  "55000"
mkfile "$PF1/hwmon/hwmon1/power1_input" "48000000"
mkfile "$PF1/tile0/gt0/freq0/act_freq"  "2100"
mkfile "$PF1/tile0/gt0/freq0/max_freq"  "2400"

# Current xe SR-IOV debugfs layout for BMG.
DBG="$ROOT/sys/kernel/debug/dri/0000:04:00.0"
SRIOV="$DBG/sriov"
mkfile "$SRIOV/restore_auto_provisioning" "1"
mkfile "$SRIOV/pf/tile0/vram_spare"       "134217728"
mkfile "$SRIOV/pf/tile0/ggtt_spare"       "268435456"
for gt in 0 1; do
    mkfile "$SRIOV/pf/tile0/gt$gt/contexts_spare"  "32768"
    mkfile "$SRIOV/pf/tile0/gt$gt/doorbells_spare" "128"
done

# Dormant VF controls and PCI identities.  sriov_numvfs remains zero, so these
# are not enumerated as live VFs; they model the control files exposed by xe.
for vf in 1 2 3 4; do
    VF_BDF="0000:04:00.$vf"
    VF="$ROOT/sys/bus/pci/devices/$VF_BDF"
    mkdir -p "$VF"
    mkfile "$VF/vendor"          "0x8086"
    mkfile "$VF/device"          "0xe211"
    mkfile "$VF/driver_override" ""
    ln -sfn "../0000:04:00.0" "$VF/physfn"
    ln -sfn "../$VF_BDF" "$PF1/virtfn$((vf - 1))"

    VF_TILE="$SRIOV/vf$vf/tile0"
    mkfile "$VF_TILE/vram_quota" "4294967296"
    mkfile "$VF_TILE/ggtt_quota" "1073741824"
    for gt in 0 1; do
        mkfile "$VF_TILE/gt$gt/contexts_quota"        "16384"
        mkfile "$VF_TILE/gt$gt/doorbells_quota"       "64"
        mkfile "$VF_TILE/gt$gt/exec_quantum_ms"       "8"
        mkfile "$VF_TILE/gt$gt/preempt_timeout_us"    "5000"
        mkfile "$VF_TILE/gt$gt/sched_priority"        "0"
    done
done

# xe scheduler profile interface used by status/capability discovery.
mkfile "$PF1/sriov_admin/.bulk_profile/sched_priority" "[low] normal"
mkfile "$PF1/sriov_admin/pf/profile/sched_priority"    "[low] normal"
for vf in 1 2 3 4; do
    mkfile "$PF1/sriov_admin/vf$vf/profile/sched_priority" "[low] normal"
done

# Firmware version exposed by the detail endpoint.
mkfile "$DBG/gt0/uc/guc_info" "GuC firmware: found release version 70.44.1"

# VRAM info
cat > "$DBG/vram0_mm" << 'VRAMEOF'
  use_type: 1
  use_tt: 0
  size: 25669140480
  usage: 134217728
default_page_size: 4KiB
VRAMEOF
chmod 666 "$DBG/vram0_mm"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Fake sysfs tree created at: $ROOT"
echo ""
echo "Devices:"
echo "  Flex 170 (0x56c0)  BDF=0000:03:00.0  unsupported negative control"
echo "  BMG      (0xe211)  BDF=0000:04:00.0  card=card1  render=renderD129  driver=xe"
echo "    SR-IOV totalvfs=24  numvfs=0  scheduler=low"
echo "    debugfs: $DBG  vram=25669140480 bytes"
echo "    hwmon: GPU=43°C  VRAM=55°C  power=48W"
echo ""
echo "Set PVE_GPU_SYSFS_ROOT=$ROOT to use this tree."
