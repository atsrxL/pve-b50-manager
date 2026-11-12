#!/usr/bin/env bash
# Restore explicit per-BDF xe Card PL2 limits using native hwmon only.

set -euo pipefail

POWER_LIMIT_CONF=${PVE_GPU_POWER_LIMIT_CONF:-/etc/pve/local/gpu-power-limit.conf}
SYSFS_ROOT=${PVE_GPU_SYSFS_ROOT:-}

log() {
    logger -t pve-gpu-power-limit -- "$*" 2>/dev/null || true
    printf 'pve-gpu-power-limit: %s\n' "$*"
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

root_path() {
    local path=$1
    [[ $path == /* ]] || { log "ERROR: non-absolute sysfs path '$path'"; return 1; }
    [[ $path != *'/../'* && $path != *'/./'* ]] || {
        log "ERROR: unsafe sysfs path '$path'"
        return 1
    }
    printf '%s%s' "$SYSFS_ROOT" "$path"
}

find_power_cap() {
    local bdf=$1
    local pci directory name cap
    pci=$(root_path "/sys/bus/pci/devices/$bdf")
    shopt -s nullglob
    for directory in "$pci"/hwmon/hwmon*; do
        [[ -d $directory ]] || continue
        name=''
        [[ -r $directory/name ]] && read -r name < "$directory/name" || true
        [[ -z $name || $name == xe ]] || continue
        cap="$directory/power1_cap"
        if [[ -r $cap && -w $cap ]]; then
            printf '%s' "$cap"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

apply_section() {
    local bdf=$1 api_version=$2 device_id=$3 persist=$4 watts=$5
    [[ -n $bdf ]] || return 0
    [[ $bdf =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || {
        log "ERROR: invalid GPU BDF '$bdf'"
        return 1
    }
    [[ $api_version == 1 ]] || {
        log "ERROR: unsupported power-limit api_version '$api_version' for $bdf"
        return 1
    }
    [[ $persist == 0 || $persist == 1 ]] || {
        log "ERROR: invalid persist value '$persist' for $bdf"
        return 1
    }
    [[ $persist == 1 ]] || return 0
    [[ $watts =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        log "ERROR: invalid persistent_w '$watts' for $bdf"
        return 1
    }
    awk -v value="$watts" 'BEGIN { exit !(value >= 1 && value <= 300) }' || {
        log "ERROR: persistent_w '$watts' is outside 1..300 W for $bdf"
        return 1
    }

    local pci live_device driver cap attempt microwatts readback
    pci=$(root_path "/sys/bus/pci/devices/$bdf")
    if [[ ! -d $pci ]]; then
        log "WARNING: $bdf is absent; Card PL2 was not restored"
        return 0
    fi
    if [[ -n $device_id && -r $pci/device ]]; then
        read -r live_device < "$pci/device"
        if [[ ${live_device,,} != ${device_id,,} ]]; then
            log "WARNING: $bdf device ID changed from $device_id to $live_device; Card PL2 was not applied"
            return 0
        fi
    fi
    driver=''
    [[ -L $pci/driver ]] && driver=$(basename "$(readlink -f "$pci/driver")")
    if [[ $driver != xe ]]; then
        log "WARNING: $bdf uses '${driver:-no driver}', not xe; retained Card PL2 policy was not applied"
        return 0
    fi

    cap=''
    for attempt in {1..40}; do
        cap=$(find_power_cap "$bdf" || true)
        [[ -n $cap ]] && break
        sleep 0.25
    done
    if [[ -z $cap ]]; then
        log "WARNING: xe Card PL2 control did not appear for $bdf; retained policy was not applied"
        return 0
    fi

    microwatts=$(awk -v value="$watts" 'BEGIN { printf "%.0f", value * 1000000 }')
    printf '%s\n' "$microwatts" > "$cap"
    read -r readback < "$cap"
    [[ $readback == "$microwatts" ]] || {
        log "ERROR: Card PL2 verification failed for $bdf (wanted $microwatts, read $readback)"
        return 1
    }
    log "Restored $bdf Card PL2 to $watts W"
}

[[ -f $POWER_LIMIT_CONF ]] || exit 0

declare -A seen_sections=()
section=''
api_version=''
device_id=''
persist='0'
persistent_w=''

while IFS= read -r raw || [[ -n $raw ]]; do
    line=$(trim "$raw")
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line =~ ^\[([^]]+)\]$ ]]; then
        apply_section "$section" "$api_version" "$device_id" "$persist" "$persistent_w"
        section=${BASH_REMATCH[1],,}
        [[ -z ${seen_sections[$section]+x} ]] || {
            log "ERROR: duplicate section '$section' in $POWER_LIMIT_CONF"
            exit 1
        }
        seen_sections[$section]=1
        api_version=''
        device_id=''
        persist='0'
        persistent_w=''
        continue
    fi
    [[ -n $section && $line == *=* ]] || {
        log "ERROR: malformed line in $POWER_LIMIT_CONF: $line"
        exit 1
    }
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    case "$key" in
        api_version) api_version=$value ;;
        device_id) device_id=$value ;;
        persist) persist=$value ;;
        persistent_w) persistent_w=$value ;;
        original_w) ;;
        *) log "ERROR: unknown key '$key' in section '$section'"; exit 1 ;;
    esac
done < "$POWER_LIMIT_CONF"

apply_section "$section" "$api_version" "$device_id" "$persist" "$persistent_w"
