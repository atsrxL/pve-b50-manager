#!/bin/bash
# Bind only explicitly configured PCI functions to vfio-pci.

set -euo pipefail

VFIO_CONF="${PVE_GPU_VFIO_CONF:-/etc/pve-gpu-vfio.conf}"
SYSFS_ROOT="${PVE_GPU_SYSFS_ROOT:-}"

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

main() {
    if [[ ! -f "$VFIO_CONF" ]]; then
        log "No VFIO config at $VFIO_CONF; nothing to bind"
        return 0
    fi

    if [[ -z "$SYSFS_ROOT" ]]; then
        modprobe vfio-pci
    fi

    local requested=0
    local bound=0
    local line bdf dev current actual
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        bdf="${line,,}"
        if [[ ! "$bdf" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
            log "ERROR: Refusing invalid PCI BDF '$line'"
            return 1
        fi

        requested=$((requested + 1))
        dev="$(sysfs "/sys/bus/pci/devices/$bdf")"
        if [[ ! -d "$dev" ]]; then
            log "ERROR: Configured PCI function $bdf does not exist"
            return 1
        fi

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
    done < "$VFIO_CONF"

    log "VFIO binding complete ($bound/$requested configured PCI functions)"
}

main "$@"
