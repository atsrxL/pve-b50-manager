#!/bin/bash
# Bind only explicitly configured PCI functions to vfio-pci.

set -euo pipefail

VFIO_CONF="${PVE_GPU_VFIO_CONF:-/etc/pve-gpu-vfio.conf}"
SYSFS_ROOT="${PVE_GPU_SYSFS_ROOT:-}"
PROC_ROOT="${PVE_GPU_PROC_ROOT:-}"
if [[ -z "$PROC_ROOT" ]]; then
    if [[ -n "$SYSFS_ROOT" ]]; then
        PROC_ROOT="$SYSFS_ROOT/proc"
    else
        PROC_ROOT='/proc'
    fi
fi
PROC_CMDLINE="${PVE_GPU_PROC_CMDLINE:-${PVE_GPU_PROC_CMDLINE_FILE:-$PROC_ROOT/cmdline}}"
CPUINFO="${PVE_GPU_CPUINFO:-${PVE_GPU_CPUINFO_FILE:-$PROC_ROOT/cpuinfo}}"
LSPCI_CMD="${PVE_GPU_LSPCI_CMD:-${PVE_GPU_LSPCI:-lspci}}"
ATS_POLICY_HELPER="${PVE_GPU_ATS_POLICY_HELPER:-${PVE_GPU_ATS_POLICY_SCRIPT:-/usr/lib/pve-gpu/manage-ats-policy.sh}}"

log() {
    logger -t pve-gpu-vfio -- "$*" 2>/dev/null || true
    printf '%s\n' "$*"
}

sysfs() {
    printf '%s%s' "$SYSFS_ROOT" "$1"
}

write_attr() {
    local path="$1"
    local value="$2"
    # An empty driver_override is cleared by writing an empty line; a
    # zero-byte write leaves the previous override in place.
    printf '%s\n' "$value" > "$(sysfs "$path")"
}

driver_for() {
    local link
    link="$(sysfs "/sys/bus/pci/devices/$1/driver")"
    if [[ -L "$link" ]]; then
        basename "$(readlink "$link")"
    fi
}

read_sysfs_value() {
    local path="$1"
    local value=''

    [[ -r "$path" ]] || return 1
    IFS= read -r value < "$path" || [[ -n "$value" ]]
    printf '%s' "$value"
}

command_run() {
    local command_line="$1"
    shift

    if [[ "$command_line" == */* ]]; then
        "$command_line" "$@"
    else
        command "$command_line" "$@"
    fi
}

cpu_is_amd() {
    local vendor="${PVE_GPU_CPU_VENDOR:-}"

    if [[ -z "$vendor" ]]; then
        [[ -r "$CPUINFO" ]] || return 2
        vendor=$(awk -F: '
            /^[[:space:]]*vendor_id[[:space:]]*:/ {
                value = $2
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        ' "$CPUINFO")
    fi
    [[ -n "$vendor" ]] || return 2
    vendor=$(printf '%s' "$vendor" | tr '[:upper:]' '[:lower:]')
    case "$vendor" in
        authenticamd)
            return 0
            ;;
        genuineintel)
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}

cmdline_has_exact_noats() {
    [[ -r "$PROC_CMDLINE" ]] || return 1
    perl -0ne \
        '$found = 1 if /(?<!\S)pci=noats(?!\S)/; END { exit($found ? 0 : 1) }' \
        "$PROC_CMDLINE"
}

ats_policy_has_persistent_noats() {
    local output

    output=$(command_run "$ATS_POLICY_HELPER" status 2>/dev/null) || return 1
    printf '%s\n' "$output" | grep -Eq '^persistent_noats=1$'
}

lspci_reports_ats_disabled() {
    local bdf="$1"
    local output

    output=$(command_run "$LSPCI_CMD" -s "$bdf" -vv 2>/dev/null) || return 1
    printf '%s\n' "$output" | grep -Eiq 'ATSCtl:[[:space:]]*Enable-([,[:space:]]|$)' || return 1
    ! printf '%s\n' "$output" | grep -Eiq 'ATSCtl:[[:space:]]*Enable\+([,[:space:]]|$)'
}

ats_guard_required() {
    local bdf="$1"
    local dev vendor device physfn

    dev="$(sysfs "/sys/bus/pci/devices/$bdf")"
    [[ -d "$dev" ]] || return 2
    physfn="$dev/physfn"
    # VFs can report the same vendor/device ID as the PF, but this policy is
    # intentionally host-PF-only.  A physfn link is the kernel's authoritative
    # distinction and works in the fake sysfs used by the tests as well.
    [[ -L "$physfn" || -e "$physfn" ]] && return 1

    vendor=$(read_sysfs_value "$dev/vendor") || return 2
    device=$(read_sysfs_value "$dev/device") || return 2
    vendor=${vendor#0x}
    device=${device#0x}
    vendor=$(printf '%s' "$vendor" | tr '[:upper:]' '[:lower:]')
    device=$(printf '%s' "$device" | tr '[:upper:]' '[:lower:]')
    [[ "$vendor" =~ ^[0-9a-f]{4}$ && "$device" =~ ^[0-9a-f]{4}$ ]] || return 2
    [[ "$vendor" == '8086' && "$device" == 'e212' ]] || return 1
    cpu_is_amd
}

check_ats_safety() {
    local bdf="$1"
    local guard_status

    if ats_guard_required "$bdf"; then
        guard_status=0
    else
        guard_status=$?
        [[ "$guard_status" == 1 ]] && return 0
        log "ERROR: Cannot determine whether Intel e212 PF $bdf is safe to bind (guard status $guard_status)"
        return 1
    fi
    if ! cmdline_has_exact_noats; then
        log "ERROR: Refusing to bind Intel e212 PF $bdf on AMD without exact pci=noats in $PROC_CMDLINE"
        return 1
    fi
    if ! ats_policy_has_persistent_noats; then
        log "ERROR: Refusing to bind Intel e212 PF $bdf unless the future boot policy reports persistent_noats=1"
        return 1
    fi
    if ! lspci_reports_ats_disabled "$bdf"; then
        log "ERROR: Refusing to bind Intel e212 PF $bdf on AMD unless lspci reports ATSCtl Enable-"
        return 1
    fi
}

main() {
    if [[ ! -f "$VFIO_CONF" ]]; then
        log "No VFIO config at $VFIO_CONF; nothing to bind"
        return 0
    fi

    local requested=0
    local bound=0
    local line bdf dev current actual
    local -a configured_bdfs=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        bdf=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
        if [[ ! "$bdf" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
            log "ERROR: Refusing invalid PCI BDF '$line'"
            return 1
        fi

        requested=$((requested + 1))
        configured_bdfs+=("$bdf")
    done < "$VFIO_CONF"

    # Preflight every configured function before loading the binder or writing
    # any driver_override/unbind/probe attribute.  This keeps a later unsafe
    # e212 PF from leaving an earlier configured function half-applied.
    for bdf in "${configured_bdfs[@]}"; do
        dev="$(sysfs "/sys/bus/pci/devices/$bdf")"
        if [[ ! -d "$dev" ]]; then
            log "ERROR: Configured PCI function $bdf does not exist"
            return 1
        fi
        check_ats_safety "$bdf" || return 1
    done

    if [[ -z "$SYSFS_ROOT" ]]; then
        modprobe vfio-pci
    fi

    for bdf in "${configured_bdfs[@]}"; do
        dev="$(sysfs "/sys/bus/pci/devices/$bdf")"

        current="$(driver_for "$bdf")"
        if [[ "$current" != "vfio-pci" ]]; then
            log "Binding $bdf from ${current:-unbound} to vfio-pci"
            write_attr "/sys/bus/pci/devices/$bdf/driver_override" "vfio-pci"
            if [[ -n "$current" ]]; then
                write_attr "/sys/bus/pci/devices/$bdf/driver/unbind" "$bdf"
            fi
            write_attr "/sys/bus/pci/drivers_probe" "$bdf"
        fi

        actual="$(driver_for "$bdf")"
        if [[ "$actual" != "vfio-pci" ]]; then
            log "ERROR: $bdf expected vfio-pci after binding, found ${actual:-unbound}"
            return 1
        fi

        # The device stays bound; clearing the override avoids leaking policy
        # into a later manual reprobe in the same boot.
        write_attr "/sys/bus/pci/devices/$bdf/driver_override" "" || true
        bound=$((bound + 1))
    done

    log "VFIO binding complete ($bound/$requested configured PCI functions)"
}

main "$@"
