#!/bin/bash
# Restore persisted Intel xe SR-IOV configuration before PVE guests start.

set -Eeuo pipefail

SRIOV_CONF="${PVE_GPU_SRIOV_CONF:-/etc/pve/local/gpu-sriov.conf}"
SYSFS_ROOT="${PVE_GPU_SYSFS_ROOT:-}"
LOCK_FILE="${PVE_GPU_SRIOV_LOCK:-/run/lock/pve-gpu-sriov.lock}"
WAIT_SECONDS="${PVE_GPU_SRIOV_WAIT_SECONDS:-60}"

RESOURCE_NAMES=(
    vram
    ggtt
    contexts
    doorbells
    exec_quantum_ms
    preempt_timeout_us
)

declare -A CONFIG=()
declare -A SECTIONS=()
declare -A DEVICE_SECTIONS=()
declare -A OLD_RESOURCE_VALUES=()
declare -A OLD_DRIVERS=()
declare -A SNAPSHOT_OLD_COUNTS=()
declare -A SNAPSHOT_OLD_AUTOPROBES=()
declare -A SNAPSHOT_OLD_SCHEDULERS=()
declare -A SNAPSHOT_OLD_RESOURCE_VALUES=()
declare -A SNAPSHOT_OLD_DRIVERS=()
declare -A SNAPSHOT_PRESENT=()
declare -a WRITE_PATHS=()
declare -a WRITE_VALUES=()
declare -a WRITE_OLD_VALUES=()
declare -a APPLIED_DEVICES=()

ACTIVE_BDF=""
STATE_SNAPSHOTTED=0
OLD_COUNT=0
OLD_AUTOPROBE=0
OLD_SCHEDULER=""

log() {
    printf '%s\n' "$*"
    if [[ -z "$SYSFS_ROOT" ]] && command -v logger >/dev/null 2>&1; then
        logger -t pve-gpu-sriov -- "$*"
    fi
}

fatal() {
    log "ERROR: $*"
    exit 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

root_path() {
    printf '%s%s' "$SYSFS_ROOT" "$1"
}

read_value() {
    local full value=""
    full=$(root_path "$1")
    [[ -r "$full" ]] || return 1
    IFS= read -r value < "$full" || [[ -n "$value" ]]
    printf '%s' "$value"
}

read_full_value() {
    local full="$1"
    local value=""
    [[ -r "$full" ]] || return 1
    IFS= read -r value < "$full" || [[ -n "$value" ]]
    printf '%s' "$value"
}

write_value() {
    local logical="$1"
    local value="$2"
    local full
    full=$(root_path "$logical")
    [[ -w "$full" ]] || fatal "Control '$full' is unavailable or not writable"
    printf '%s\n' "$value" > "$full"
}

write_numeric_verified() {
    local logical="$1"
    local expected="$2"
    local actual
    write_value "$logical" "$expected"
    actual=$(read_value "$logical") || fatal "Cannot read back '$(root_path "$logical")'"
    [[ "$actual" =~ ^[0-9]+$ ]] || fatal "Non-numeric readback from '$(root_path "$logical")': '$actual'"
    (( 10#$actual == 10#$expected )) ||
        fatal "Verification failed for '$(root_path "$logical")': requested $expected, found $actual"
}

cfg() {
    local section="$1"
    local key="$2"
    local default="${3-}"
    local compound="$section|$key"
    printf '%s' "${CONFIG[$compound]-$default}"
}

parse_ini() {
    local file="$1"
    local line section="" key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line=$(trim "$line")
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            section=$(trim "${BASH_REMATCH[1]}")
            [[ -n "$section" ]] || fatal "Empty section in '$file'"
            SECTIONS["$section"]=1
            continue
        fi

        [[ -n "$section" ]] || fatal "Key outside a section in '$file': '$line'"
        [[ "$line" =~ ^([^=]+)=(.*)$ ]] || fatal "Malformed line in '$file': '$line'"
        key=$(trim "${BASH_REMATCH[1]}")
        value=$(trim "${BASH_REMATCH[2]}")
        [[ -n "$key" ]] || fatal "Empty key in section '$section'"
        CONFIG["$section|$key"]="$value"
    done < "$file"
}

wait_for_path() {
    local full="$1"
    local description="$2"
    local attempts=$((WAIT_SECONDS * 10))
    local attempt

    for ((attempt = 0; attempt <= attempts; attempt++)); do
        [[ -e "$full" ]] && return 0
        sleep 0.1
    done
    fatal "Timed out waiting for $description at '$full'"
}

wait_for_pmxcfs() {
    local config_dir
    config_dir=$(dirname "$SRIOV_CONF")
    wait_for_path "$config_dir" "pmxcfs configuration directory"
}

ensure_debugfs() {
    local debug_root
    debug_root=$(root_path /sys/kernel/debug)

    if [[ -n "$SYSFS_ROOT" ]]; then
        [[ -d "$debug_root" ]] || fatal "Test debugfs root '$debug_root' does not exist"
        return
    fi

    if ! mountpoint -q /sys/kernel/debug; then
        mount -t debugfs debugfs /sys/kernel/debug || fatal "Unable to mount debugfs"
    fi
}

discover_devices() {
    local section bdf
    for section in "${!SECTIONS[@]}"; do
        [[ "$section" != */* ]] || continue
        [[ "$section" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || continue
        [[ "$(cfg "$section" persist 0)" == "1" ]] || continue
        bdf=${section,,}
        [[ -z "${DEVICE_SECTIONS[$bdf]-}" ]] ||
            fatal "Duplicate persistent sections resolve to PCI device '$bdf'"
        DEVICE_SECTIONS["$bdf"]="$section"
    done
}

pf_path() {
    printf '/sys/bus/pci/devices/%s' "$1"
}

debug_sriov_path() {
    printf '/sys/kernel/debug/dri/%s/sriov' "$1"
}

wait_for_device_controls() {
    local bdf="$1"
    local pf debug driver
    pf=$(root_path "$(pf_path "$bdf")")
    debug=$(root_path "$(debug_sriov_path "$bdf")")

    wait_for_path "$pf/sriov_totalvfs" "SR-IOV controls for $bdf"
    wait_for_path "$pf/driver" "xe driver binding for $bdf"
    driver=$(basename "$(readlink -f "$pf/driver")")
    [[ "$driver" == "xe" ]] || fatal "PCI device $bdf is bound to '$driver', expected 'xe'"
    wait_for_path "$debug/restore_auto_provisioning" "xe SR-IOV debugfs ABI for $bdf"
    wait_for_path "$pf/sriov_admin/.bulk_profile/sched_priority" "scheduler control for $bdf"
}

is_safe_uint() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ && ${#value} -le 18 ]]
}

validate_quota() {
    local resource="$1"
    local quota="$2"
    is_safe_uint "$quota" || return 1
    case "$resource" in
        vram|ggtt)
            (( 10#$quota >= 134217728 && 10#$quota % 134217728 == 0 ))
            ;;
        contexts|doorbells)
            (( 10#$quota >= 1 ))
            ;;
        exec_quantum_ms|preempt_timeout_us)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_device_config() {
    local bdf="$1"
    local section="${DEVICE_SECTIONS[$bdf]}"
    local pf vendor live_device configured_device live_device_normalized configured_device_normalized family
    local api_version num_vfs total autoprobe scheduler unsafe vf vf_section resource mode quota driver
    pf=$(pf_path "$bdf")

    api_version=$(cfg "$section" api_version)
    [[ "$api_version" == "2" ]] || fatal "Persistent section [$section] requires api_version = 2"

    num_vfs=$(cfg "$section" num_vfs)
    if ! is_safe_uint "$num_vfs" || (( 10#$num_vfs == 0 )); then
        fatal "Invalid num_vfs '$num_vfs' in [$section]"
    fi
    total=$(read_value "$pf/sriov_totalvfs") || fatal "Cannot read sriov_totalvfs for $bdf"
    is_safe_uint "$total" || fatal "Invalid sriov_totalvfs '$total' for $bdf"
    (( 10#$num_vfs <= 10#$total )) || fatal "Requested $num_vfs VFs for $bdf, but hardware exposes only $total"

    vendor=$(read_value "$pf/vendor") || fatal "Cannot read PCI vendor for $bdf"
    [[ "${vendor,,}" == "0x8086" ]] || fatal "PCI device $bdf is not an Intel device (vendor $vendor)"
    live_device=$(read_value "$pf/device") || fatal "Cannot read PCI device ID for $bdf"
    configured_device=$(cfg "$section" device_id)
    live_device_normalized=${live_device,,}
    live_device_normalized=${live_device_normalized#0x}
    configured_device_normalized=${configured_device,,}
    configured_device_normalized=${configured_device_normalized#0x}
    if [[ -n "$configured_device" && "$configured_device_normalized" != "$live_device_normalized" ]]; then
        fatal "PCI device ID mismatch at exact BDF $bdf: config $configured_device, live $live_device"
    fi

    family=$(cfg "$section" family)
    [[ -z "$family" || "$family" == "bmg" || "$family" == "bmg_12vf" ]] ||
        fatal "Section [$section] family '$family' does not use the supported BMG xe ABI"

    autoprobe=$(cfg "$section" drivers_autoprobe)
    [[ "$autoprobe" =~ ^[01]$ ]] || fatal "Invalid drivers_autoprobe '$autoprobe' in [$section]"
    scheduler=$(cfg "$section" sched_priority low)
    [[ "$scheduler" == "low" || "$scheduler" == "normal" ]] ||
        fatal "Invalid sched_priority '$scheduler' in [$section]"
    unsafe=$(cfg "$section" allow_unsafe_scheduler 0)
    [[ "$unsafe" =~ ^[01]$ ]] || fatal "Invalid allow_unsafe_scheduler '$unsafe' in [$section]"
    [[ "$scheduler" != "normal" || "$unsafe" == "1" ]] ||
        fatal "Refusing unsafe normal scheduler for $bdf without allow_unsafe_scheduler = 1"

    for ((vf = 1; vf <= 10#$num_vfs; vf++)); do
        vf_section="$section/vf$vf"
        [[ -n "${SECTIONS[$vf_section]-}" ]] || fatal "Missing persistent section [$vf_section]"
        for resource in "${RESOURCE_NAMES[@]}"; do
            mode=$(cfg "$vf_section" "${resource}_mode")
            [[ "$mode" == "auto" || "$mode" == "custom" ]] ||
                fatal "Invalid ${resource}_mode '$mode' in [$vf_section]"
            if [[ "$mode" == "custom" ]]; then
                quota=$(cfg "$vf_section" "${resource}_quota")
                validate_quota "$resource" "$quota" ||
                    fatal "Invalid custom ${resource}_quota '$quota' in [$vf_section]"
            fi
        done
        driver=$(cfg "$vf_section" driver)
        [[ -z "$driver" || "$driver" == "vfio-pci" || "$driver" == "xe" || "$driver" == "i915" ]] ||
            fatal "Unsupported persisted driver '$driver' in [$vf_section]"
    done
}

vf_device_path() {
    local bdf="$1"
    local vf="$2"
    local link resolved
    link=$(root_path "$(pf_path "$bdf")/virtfn$((vf - 1))")
    [[ -L "$link" ]] || return 1
    resolved=$(readlink -f "$link") || return 1
    if [[ -n "$SYSFS_ROOT" && "$resolved" != "$SYSFS_ROOT"/* ]]; then
        fatal "Test VF link '$link' escapes PVE_GPU_SYSFS_ROOT"
    fi
    printf '%s' "$resolved"
}

vf_driver() {
    local vf_path driver_link
    vf_path=$(vf_device_path "$1" "$2") || return 1
    driver_link="$vf_path/driver"
    if [[ ! -L "$driver_link" ]]; then
        printf ''
        return 0
    fi
    basename "$(readlink -f "$driver_link")"
}

resource_paths() {
    local bdf="$1"
    local vf="$2"
    local resource="$3"
    local base full_base gt_dir gt index=0
    base="$(debug_sriov_path "$bdf")/vf$vf/tile0"
    full_base=$(root_path "$base")

    case "$resource" in
        vram)
            printf '%s/vram_quota\n' "$base"
            ;;
        ggtt)
            printf '%s/ggtt_quota\n' "$base"
            ;;
        contexts|doorbells)
            for gt_dir in "$full_base"/gt*; do
                [[ -d "$gt_dir" ]] || continue
                gt=$(basename "$gt_dir")
                printf '%s/%s/%s_quota\n' "$base" "$gt" "$resource"
                index=$((index + 1))
            done
            (( index > 0 )) || return 1
            ;;
        exec_quantum_ms|preempt_timeout_us)
            for gt_dir in "$full_base"/gt*; do
                [[ -d "$gt_dir" ]] || continue
                gt=$(basename "$gt_dir")
                printf '%s/%s/%s\n' "$base" "$gt" "$resource"
                index=$((index + 1))
            done
            (( index > 0 )) || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

vf_tree_ready() {
    local bdf="$1"
    local count="$2"
    local vf base full_base gt_dir found_gt
    for ((vf = 1; vf <= count; vf++)); do
        vf_device_path "$bdf" "$vf" >/dev/null || return 1
        base="$(debug_sriov_path "$bdf")/vf$vf/tile0"
        full_base=$(root_path "$base")
        [[ -e "$full_base/vram_quota" && -e "$full_base/ggtt_quota" ]] || return 1
        found_gt=0
        for gt_dir in "$full_base"/gt*; do
            [[ -d "$gt_dir" ]] || continue
            found_gt=1
            [[ -e "$gt_dir/contexts_quota" && -e "$gt_dir/doorbells_quota" ]] || return 1
            [[ -e "$gt_dir/exec_quantum_ms" && -e "$gt_dir/preempt_timeout_us" ]] || return 1
        done
        (( found_gt == 1 )) || return 1
    done
}

wait_for_vf_tree() {
    local bdf="$1"
    local count="$2"
    local attempts=$((WAIT_SECONDS * 10))
    local attempt

    (( count == 0 )) && return 0
    for ((attempt = 0; attempt <= attempts; attempt++)); do
        vf_tree_ready "$bdf" "$count" && return 0
        sleep 0.1
    done
    fatal "Timed out waiting for VF PCI functions and xe resource files for $bdf"
}

active_scheduler() {
    local bdf="$1"
    local vf="${2:-1}"
    local raw
    raw=$(read_value "$(pf_path "$bdf")/sriov_admin/vf$vf/profile/sched_priority") || return 1
    case "$raw" in
        *\[low\]*) printf 'low' ;;
        *\[normal\]*) printf 'normal' ;;
        *\[high\]*) printf 'high' ;;
        0) printf 'low' ;;
        1) printf 'normal' ;;
        2) printf 'high' ;;
        low|normal|high) printf '%s' "$raw" ;;
        *) return 1 ;;
    esac
}

scheduler_matches() {
    local bdf="$1"
    local count="$2"
    local expected="$3"
    local vf actual
    for ((vf = 1; vf <= count; vf++)); do
        actual=$(active_scheduler "$bdf" "$vf") || return 1
        [[ "$actual" == "$expected" ]] || return 1
    done
}

apply_scheduler() {
    local bdf="$1"
    local count="$2"
    local priority="$3"
    local attempts=$((WAIT_SECONDS * 10))
    local attempt path

    (( count > 0 )) || return 0
    if scheduler_matches "$bdf" "$count" "$priority"; then
        return 0
    fi

    path="$(pf_path "$bdf")/sriov_admin/.bulk_profile/sched_priority"
    write_value "$path" "$priority"
    for ((attempt = 0; attempt <= attempts; attempt++)); do
        scheduler_matches "$bdf" "$count" "$priority" && return 0
        sleep 0.1
    done
    fatal "Scheduler verification failed for $bdf: requested '$priority'"
}

unbind_vf() {
    local bdf="$1"
    local vf="$2"
    local vf_path current vf_pci
    vf_path=$(vf_device_path "$bdf" "$vf") || fatal "Cannot resolve VF$vf for $bdf"
    current=$(vf_driver "$bdf" "$vf") || fatal "Cannot read VF$vf driver for $bdf"
    [[ -n "$current" ]] || return 0
    vf_pci=$(basename "$vf_path")
    [[ -w "$vf_path/driver/unbind" ]] || fatal "Cannot unbind $vf_pci from '$current'"
    printf '%s\n' "$vf_pci" > "$vf_path/driver/unbind"
    current=$(vf_driver "$bdf" "$vf") || fatal "Cannot verify VF$vf unbind for $bdf"
    [[ -z "$current" ]] || fatal "Failed to unbind $vf_pci (found '$current')"
}

unbind_all_vfs() {
    local bdf="$1"
    local count="$2"
    local vf
    for ((vf = 1; vf <= count; vf++)); do
        unbind_vf "$bdf" "$vf"
    done
}

set_vf_driver() {
    local bdf="$1"
    local vf="$2"
    local target="$3"
    local current current_driver vf_path vf_pci override probe
    [[ -z "$target" || "$target" == "vfio-pci" || "$target" == "xe" || "$target" == "i915" ]] ||
        fatal "Refusing unsupported VF driver '$target'"

    vf_path=$(vf_device_path "$bdf" "$vf") || fatal "Cannot resolve VF$vf for $bdf"
    vf_pci=$(basename "$vf_path")
    override="$vf_path/driver_override"
    probe=$(root_path /sys/bus/pci/drivers_probe)
    [[ -w "$override" ]] || fatal "Driver override control for $vf_pci is unavailable"

    current_driver=$(vf_driver "$bdf" "$vf") || fatal "Cannot read VF$vf driver for $bdf"
    if [[ "$current_driver" == "$target" ]]; then
        printf '\n' > "$override"
        current=$(read_full_value "$override") || fatal "Cannot verify cleared driver override for $vf_pci"
        [[ -z "$current" || "$current" == "(null)" ]] ||
            fatal "Failed to clear driver override for $vf_pci"
        return 0
    fi

    if [[ -n "$target" && -z "$SYSFS_ROOT" ]]; then
        modprobe "$target" || fatal "Cannot load VF driver '$target'"
    fi

    if [[ -n "$target" ]]; then
        printf '%s\n' "$target" > "$override"
        current=$(read_full_value "$override") || fatal "Cannot verify driver override for $vf_pci"
        [[ "$current" == "$target" ]] ||
            fatal "Failed to set driver override '$target' for $vf_pci"
    fi
    [[ -z "$current_driver" ]] || unbind_vf "$bdf" "$vf"

    if [[ -z "$target" ]]; then
        printf '\n' > "$override"
        current=$(read_full_value "$override") || fatal "Cannot verify cleared driver override for $vf_pci"
        [[ -z "$current" || "$current" == "(null)" ]] ||
            fatal "Failed to clear driver override for $vf_pci"
        current=$(vf_driver "$bdf" "$vf") || fatal "Cannot verify VF$vf driver for $bdf"
        [[ -z "$current" ]] || fatal "Failed to leave $vf_pci unbound (found '$current')"
        return 0
    fi

    [[ -w "$probe" ]] || fatal "Driver probe control for $vf_pci is unavailable"
    if ! printf '%s\n' "$vf_pci" > "$probe"; then
        fatal "Failed to probe $vf_pci with '$target'"
    fi
    current=$(vf_driver "$bdf" "$vf") || fatal "Cannot verify VF$vf driver for $bdf"
    [[ "$current" == "$target" ]] ||
        fatal "Failed to bind $vf_pci to '$target' (found '${current:-unbound}')"
    printf '\n' > "$override"
    current=$(read_full_value "$override") || fatal "Cannot verify cleared driver override for $vf_pci"
    [[ -z "$current" || "$current" == "(null)" ]] ||
        fatal "Failed to clear driver override for $vf_pci"
}

restore_persisted_drivers() {
    local bdf="$1"
    local count="$2"
    local section="${DEVICE_SECTIONS[$bdf]}"
    local vf target
    for ((vf = 1; vf <= count; vf++)); do
        target=$(cfg "$section/vf$vf" driver)
        set_vf_driver "$bdf" "$vf" "$target"
    done
}

snapshot_state() {
    local bdf="$1"
    local pf vf resource path value driver
    local -a paths=()
    pf=$(pf_path "$bdf")

    OLD_RESOURCE_VALUES=()
    OLD_DRIVERS=()
    OLD_SCHEDULER=""
    OLD_COUNT=$(read_value "$pf/sriov_numvfs") || fatal "Cannot read current VF count for $bdf"
    OLD_AUTOPROBE=$(read_value "$pf/sriov_drivers_autoprobe") || fatal "Cannot read current autoprobe for $bdf"
    is_safe_uint "$OLD_COUNT" && [[ "$OLD_AUTOPROBE" =~ ^[01]$ ]] ||
        fatal "Invalid current SR-IOV state for $bdf"

    if (( 10#$OLD_COUNT > 0 )); then
        wait_for_vf_tree "$bdf" "$((10#$OLD_COUNT))"
        OLD_SCHEDULER=$(active_scheduler "$bdf" 1) || fatal "Cannot read current scheduler for $bdf"
        scheduler_matches "$bdf" "$((10#$OLD_COUNT))" "$OLD_SCHEDULER" ||
            fatal "Current scheduler profile is inconsistent across VFs for $bdf"
    fi

    for ((vf = 1; vf <= 10#$OLD_COUNT; vf++)); do
        driver=$(vf_driver "$bdf" "$vf") || fatal "Cannot snapshot VF$vf driver for $bdf"
        OLD_DRIVERS["$vf"]="$driver"
        for resource in "${RESOURCE_NAMES[@]}"; do
            paths=()
            mapfile -t paths < <(resource_paths "$bdf" "$vf" "$resource")
            (( ${#paths[@]} > 0 )) || fatal "Cannot enumerate '$resource' paths for $bdf VF$vf"
            for path in "${paths[@]}"; do
                value=$(read_value "$path") || fatal "Cannot snapshot '$(root_path "$path")'"
                is_safe_uint "$value" || fatal "Invalid numeric value '$value' in '$(root_path "$path")'"
                OLD_RESOURCE_VALUES["$path"]="$value"
            done
        done
    done
    STATE_SNAPSHOTTED=1
    save_snapshot "$bdf"
}

save_snapshot() {
    local bdf="$1"
    local path vf

    SNAPSHOT_OLD_COUNTS["$bdf"]="$OLD_COUNT"
    SNAPSHOT_OLD_AUTOPROBES["$bdf"]="$OLD_AUTOPROBE"
    SNAPSHOT_OLD_SCHEDULERS["$bdf"]="$OLD_SCHEDULER"
    SNAPSHOT_PRESENT["$bdf"]=1
    for path in "${!OLD_RESOURCE_VALUES[@]}"; do
        SNAPSHOT_OLD_RESOURCE_VALUES["$bdf|$path"]="${OLD_RESOURCE_VALUES[$path]}"
    done
    for vf in "${!OLD_DRIVERS[@]}"; do
        SNAPSHOT_OLD_DRIVERS["$bdf|$vf"]="${OLD_DRIVERS[$vf]}"
    done
}

load_snapshot() {
    local bdf="$1"
    local key path vf prefix

    [[ "${SNAPSHOT_PRESENT[$bdf]-0}" == "1" ]] || return 1
    OLD_COUNT="${SNAPSHOT_OLD_COUNTS[$bdf]}"
    OLD_AUTOPROBE="${SNAPSHOT_OLD_AUTOPROBES[$bdf]}"
    OLD_SCHEDULER="${SNAPSHOT_OLD_SCHEDULERS[$bdf]}"
    OLD_RESOURCE_VALUES=()
    OLD_DRIVERS=()

    prefix="$bdf|"
    for key in "${!SNAPSHOT_OLD_RESOURCE_VALUES[@]}"; do
        [[ "$key" == "$prefix"* ]] || continue
        path="${key#"$prefix"}"
        OLD_RESOURCE_VALUES["$path"]="${SNAPSHOT_OLD_RESOURCE_VALUES[$key]}"
    done
    for key in "${!SNAPSHOT_OLD_DRIVERS[@]}"; do
        [[ "$key" == "$prefix"* ]] || continue
        vf="${key#"$prefix"}"
        OLD_DRIVERS["$vf"]="${SNAPSHOT_OLD_DRIVERS[$key]}"
    done
    STATE_SNAPSHOTTED=1
    ACTIVE_BDF="$bdf"
}

build_write_plan() {
    local bdf="$1"
    local count="$2"
    local section="${DEVICE_SECTIONS[$bdf]}"
    local vf resource mode target path old
    local -a paths=()

    WRITE_PATHS=()
    WRITE_VALUES=()
    WRITE_OLD_VALUES=()
    for ((vf = 1; vf <= count; vf++)); do
        for resource in "${RESOURCE_NAMES[@]}"; do
            mode=$(cfg "$section/vf$vf" "${resource}_mode")
            [[ "$mode" == "custom" ]] || continue
            target=$(cfg "$section/vf$vf" "${resource}_quota")
            paths=()
            mapfile -t paths < <(resource_paths "$bdf" "$vf" "$resource")
            (( ${#paths[@]} > 0 )) || fatal "Resource '$resource' is unavailable for $bdf VF$vf"
            for path in "${paths[@]}"; do
                old=$(read_value "$path") || fatal "Cannot read '$(root_path "$path")'"
                is_safe_uint "$old" || fatal "Invalid numeric value '$old' in '$(root_path "$path")'"
                WRITE_PATHS+=("$path")
                WRITE_VALUES+=("$target")
                WRITE_OLD_VALUES+=("$old")
            done
        done
    done
}

apply_write_plan() {
    local pass index old target path actual grows
    for pass in 0 1; do
        for index in "${!WRITE_PATHS[@]}"; do
            old="${WRITE_OLD_VALUES[$index]}"
            target="${WRITE_VALUES[$index]}"
            path="${WRITE_PATHS[$index]}"
            grows=0
            (( 10#$target > 10#$old )) && grows=1
            (( grows == pass )) || continue
            write_numeric_verified "$path" "$target"
        done
    done

    for index in "${!WRITE_PATHS[@]}"; do
        path="${WRITE_PATHS[$index]}"
        target="${WRITE_VALUES[$index]}"
        actual=$(read_value "$path") || fatal "Cannot verify '$(root_path "$path")'"
        is_safe_uint "$actual" || fatal "Invalid readback '$actual' from '$(root_path "$path")'"
        (( 10#$actual == 10#$target )) ||
            fatal "Final verification failed for '$(root_path "$path")': requested $target, found $actual"
    done
}

change_topology() {
    local bdf="$1"
    local old_count="$2"
    local target_count="$3"
    local pf debug actual
    pf=$(pf_path "$bdf")
    debug=$(debug_sriov_path "$bdf")

    (( old_count > 0 )) && unbind_all_vfs "$bdf" "$old_count"
    write_numeric_verified "$pf/sriov_numvfs" 0
    write_numeric_verified "$pf/sriov_drivers_autoprobe" 0
    write_value "$debug/restore_auto_provisioning" 1
    write_numeric_verified "$pf/sriov_numvfs" "$target_count"
    wait_for_vf_tree "$bdf" "$target_count"
    actual=$(read_value "$pf/sriov_numvfs") || fatal "Cannot verify VF count for $bdf"
    (( 10#$actual == target_count )) || fatal "VF count mismatch for $bdf: requested $target_count, found $actual"
}

restore_old_resources() {
    local pass path target current grows
    for pass in 0 1; do
        for path in "${!OLD_RESOURCE_VALUES[@]}"; do
            [[ -e "$(root_path "$path")" ]] || continue
            target="${OLD_RESOURCE_VALUES[$path]}"
            current=$(read_value "$path") || continue
            is_safe_uint "$current" || continue
            grows=0
            (( 10#$target > 10#$current )) && grows=1
            (( grows == pass )) || continue
            printf '%s\n' "$target" > "$(root_path "$path")" ||
                log "ROLLBACK ERROR: Cannot restore '$(root_path "$path")'"
        done
    done
}

rollback_active_device() {
    local bdf="$ACTIVE_BDF"
    local pf debug current vf target attempts attempt
    [[ -n "$bdf" && "$STATE_SNAPSHOTTED" == "1" ]] || return 0

    log "Attempting rollback for $bdf"
    set +e
    pf=$(pf_path "$bdf")
    debug=$(debug_sriov_path "$bdf")
    current=$(read_value "$pf/sriov_numvfs")
    is_safe_uint "$current" || current=0

    if (( 10#$current != 10#$OLD_COUNT )); then
        for ((vf = 1; vf <= 10#$current; vf++)); do
            (trap - EXIT; unbind_vf "$bdf" "$vf") ||
                log "ROLLBACK ERROR: Cannot unbind current VF$vf"
        done
        (( 10#$current == 0 )) || printf '0\n' > "$(root_path "$pf/sriov_numvfs")"
        printf '0\n' > "$(root_path "$pf/sriov_drivers_autoprobe")"
        printf '1\n' > "$(root_path "$debug/restore_auto_provisioning")"
        if (( 10#$OLD_COUNT > 0 )); then
            printf '%s\n' "$OLD_COUNT" > "$(root_path "$pf/sriov_numvfs")"
            attempts=$((WAIT_SECONDS * 10))
            for ((attempt = 0; attempt <= attempts; attempt++)); do
                vf_tree_ready "$bdf" "$((10#$OLD_COUNT))" && break
                sleep 0.1
            done
        fi
    fi

    restore_old_resources
    if (( 10#$OLD_COUNT > 0 )); then
        for ((vf = 1; vf <= 10#$OLD_COUNT; vf++)); do
            target="${OLD_DRIVERS[$vf]-}"
            (trap - EXIT; set_vf_driver "$bdf" "$vf" "$target") ||
                log "ROLLBACK ERROR: Cannot restore VF$vf driver '${target:-unbound}'"
        done
        if [[ "$OLD_SCHEDULER" == "low" || "$OLD_SCHEDULER" == "normal" || "$OLD_SCHEDULER" == "high" ]]; then
            (trap - EXIT; apply_scheduler "$bdf" "$((10#$OLD_COUNT))" "$OLD_SCHEDULER") ||
                log "ROLLBACK ERROR: Cannot restore scheduler '$OLD_SCHEDULER'"
        fi
    fi
    printf '%s\n' "$OLD_AUTOPROBE" > "$(root_path "$pf/sriov_drivers_autoprobe")" ||
        log "ROLLBACK ERROR: Cannot restore sriov_drivers_autoprobe"
    log "Rollback attempt for $bdf completed"
}

rollback_completed_devices() {
    local index bdf

    (( ${#APPLIED_DEVICES[@]} > 0 )) || return 0
    log "Rolling back previously applied PFs in reverse order"
    set +e
    for ((index = ${#APPLIED_DEVICES[@]} - 1; index >= 0; index--)); do
        bdf="${APPLIED_DEVICES[$index]}"
        if ! load_snapshot "$bdf"; then
            log "ROLLBACK ERROR: Cannot load snapshot for $bdf"
            continue
        fi
        rollback_active_device
    done
    ACTIVE_BDF=""
    STATE_SNAPSHOTTED=0
}

on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then
        rollback_active_device
        rollback_completed_devices
        log "SR-IOV configuration restore failed (exit $rc)"
    fi
    exit "$rc"
}

apply_device() {
    local bdf="$1"
    local section="${DEVICE_SECTIONS[$bdf]}"
    local target_count_raw target_count current_count autoprobe scheduler

    ACTIVE_BDF="$bdf"
    snapshot_state "$bdf"
    current_count=$((10#$OLD_COUNT))
    target_count_raw=$(cfg "$section" num_vfs)
    target_count=$((10#$target_count_raw))
    autoprobe=$(cfg "$section" drivers_autoprobe)
    scheduler=$(cfg "$section" sched_priority low)

    log "Applying persistent SR-IOV profile for $bdf ($target_count VFs)"
    # Keep every existing or newly-created VF unclaimed until quotas,
    # scheduler state, and explicit per-VF driver policy are complete.
    write_numeric_verified "$(pf_path "$bdf")/sriov_drivers_autoprobe" 0
    if (( current_count != target_count )); then
        change_topology "$bdf" "$current_count" "$target_count"
    else
        log "VF count for $bdf is already $target_count; preserving topology"
        wait_for_vf_tree "$bdf" "$target_count"
    fi

    build_write_plan "$bdf" "$target_count"
    apply_write_plan
    apply_scheduler "$bdf" "$target_count" "$scheduler"
    restore_persisted_drivers "$bdf" "$target_count"
    write_numeric_verified "$(pf_path "$bdf")/sriov_drivers_autoprobe" "$autoprobe"
    scheduler_matches "$bdf" "$target_count" "$scheduler" ||
        fatal "Final scheduler verification failed for $bdf"
    log "Restored $target_count VFs for $bdf (scheduler=$scheduler, autoprobe=$autoprobe)"

    APPLIED_DEVICES+=("$bdf")
    STATE_SNAPSHOTTED=0
    ACTIVE_BDF=""
}

main() {
    local bdf
    local -a devices=()

    [[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ && ${#WAIT_SECONDS} -le 6 ]] ||
        fatal "PVE_GPU_SRIOV_WAIT_SECONDS must be a positive integer"
    if [[ -n "$SYSFS_ROOT" ]]; then
        SYSFS_ROOT="${SYSFS_ROOT%/}"
        [[ "$SYSFS_ROOT" == /* && -d "$SYSFS_ROOT" ]] ||
            fatal "PVE_GPU_SYSFS_ROOT must name an existing absolute directory"
    fi

    command -v flock >/dev/null 2>&1 || fatal "flock is required"
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>> "$LOCK_FILE"
    flock -x 9 || fatal "Cannot acquire SR-IOV lock '$LOCK_FILE'"

    wait_for_pmxcfs
    if [[ ! -f "$SRIOV_CONF" ]]; then
        log "No SR-IOV config found at $SRIOV_CONF; nothing to restore"
        return 0
    fi

    parse_ini "$SRIOV_CONF"
    discover_devices
    if (( ${#DEVICE_SECTIONS[@]} == 0 )); then
        log "No persistent SR-IOV device sections found; nothing to restore"
        return 0
    fi
    ensure_debugfs
    mapfile -t devices < <(printf '%s\n' "${!DEVICE_SECTIONS[@]}" | LC_ALL=C sort)

    # Validate every requested PF before changing any hardware state.
    for bdf in "${devices[@]}"; do
        wait_for_device_controls "$bdf"
        validate_device_config "$bdf"
    done

    for bdf in "${devices[@]}"; do
        apply_device "$bdf"
    done
    log "SR-IOV persistent configuration restored successfully"
}

trap on_exit EXIT
main "$@"
