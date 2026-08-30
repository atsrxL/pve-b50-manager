#!/bin/bash
# Manage the package-owned, host-wide pci=noats boot policy.
#
# This helper deliberately does not source /etc/default/grub (or any other
# user configuration) and never reboots the host.  enable and disable are
# explicit operations; status is read-only.

set -euo pipefail

readonly NOATS_TOKEN='pci=noats'
readonly GRUB_DROPIN_NAME='99-pve-gpu-manager-noats.cfg'
readonly GRUB_POLICY_MARKER='# pve-gpu-manager managed pci=noats'
readonly MARKER_CONTENT='pve-gpu-manager managed pci=noats'

FAKE_ROOT="${PVE_GPU_ROOT:-${PVE_GPU_FAKE_ROOT:-}}"

rooted_default() {
    local path="$1"
    if [[ -n "$FAKE_ROOT" ]]; then
        printf '%s%s' "${FAKE_ROOT%/}" "$path"
    else
        printf '%s' "$path"
    fi
}

GRUB_DEFAULT="${PVE_GPU_GRUB_DEFAULT:-${PVE_GPU_GRUB_PATH:-$(rooted_default '/etc/default/grub')}}"
GRUB_DROPIN="${PVE_GPU_GRUB_DROPIN:-${PVE_GPU_GRUB_NOATS_CONFIG:-${PVE_GPU_GRUB_DROPIN_PATH:-$(rooted_default "/etc/default/grub.d/$GRUB_DROPIN_NAME")}}}"
GRUB_DIR="${PVE_GPU_GRUB_DIR:-${PVE_GPU_GRUB_CONFIG_DIR:-}}"
if [[ -z "$GRUB_DIR" ]]; then
    case "$GRUB_DROPIN" in
        */*) GRUB_DIR="${GRUB_DROPIN%/*}" ;;
        *) GRUB_DIR='.' ;;
    esac
fi

KERNEL_CMDLINE="${PVE_GPU_KERNEL_CMDLINE:-${PVE_GPU_KERNEL_CMDLINE_FILE:-${PVE_GPU_CMDLINE_PATH:-$(rooted_default '/etc/kernel/cmdline')}}}"
MANAGED_MARKER="${PVE_GPU_ATS_MARKER:-${PVE_GPU_NOATS_MARKER:-${PVE_GPU_MANAGED_MARKER:-${PVE_GPU_MARKER_PATH:-$(rooted_default '/var/lib/pve-gpu-manager/ats-noats.managed')}}}}"
UPDATE_GRUB_CMD="${PVE_GPU_UPDATE_GRUB_CMD:-${PVE_GPU_UPDATE_GRUB_COMMAND:-${PVE_GPU_UPDATE_GRUB:-update-grub}}}"
PROXMOX_BOOT_TOOL_CMD="${PVE_GPU_PROXMOX_BOOT_TOOL_CMD:-${PVE_GPU_PROXMOX_BOOT_TOOL_COMMAND:-${PVE_GPU_PROXMOX_BOOT_TOOL:-${PVE_GPU_PBT_CMD:-proxmox-boot-tool}}}}"
PROXMOX_BOOT_UUIDS="${PVE_GPU_PROXMOX_BOOT_UUIDS:-$(rooted_default '/etc/kernel/proxmox-boot-uuids')}"
BOOT_MODE_REQUESTED="${PVE_GPU_BOOT_MODE:-${PVE_GPU_ATS_BOOT_MODE:-${PVE_GPU_BOOTMODE:-auto}}}"
CURRENT_CMDLINE="${PVE_GPU_CURRENT_CMDLINE:-${PVE_GPU_CURRENT_CMDLINE_FILE:-${PVE_GPU_PROC_CMDLINE:-$(rooted_default '/proc/cmdline')}}}"
ATSCTL_FILE="${PVE_GPU_ATSCTL_FILE:-${PVE_GPU_ATS_CONTROL_FILE:-$(rooted_default '/sys/module/pci/parameters/disable_ats')}}"

TXN_DIR=''

cleanup() {
    if [[ -n "$TXN_DIR" && -d "$TXN_DIR" ]]; then
        rm -rf -- "$TXN_DIR"
    fi
}
trap cleanup EXIT

usage() {
    printf 'Usage: %s {status|enable|disable}\n' "$0" >&2
}

error_message() {
    local code="$1"
    printf 'error=%s\n' "$code"
    printf 'pve-gpu-manager ATS policy: %s\n' "$code" >&2
}

path_parent() {
    local path="$1"
    case "$path" in
        */*) printf '%s' "${path%/*}" ;;
        *) printf '.' ;;
    esac
}

ensure_parent() {
    local parent
    parent=$(path_parent "$1")
    [[ -d "$parent" ]] || mkdir -p -- "$parent"
}

begin_transaction() {
    local temp_root="${PVE_GPU_ATS_TMPDIR:-${TMPDIR:-/tmp}}"
    TXN_DIR=$(mktemp -d "$temp_root/pve-gpu-manager-ats.XXXXXX")
}

snapshot_file() {
    local path="$1"
    local name="$2"

    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" ]] || return 1
        if ! cp -p -- "$path" "$TXN_DIR/$name.data"; then
            return 1
        fi
        : > "$TXN_DIR/$name.present" || return 1
    else
        : > "$TXN_DIR/$name.absent" || return 1
    fi
}

restore_snapshot() {
    local path="$1"
    local name="$2"

    if [[ -e "$TXN_DIR/$name.present" ]]; then
        ensure_parent "$path" || return 1
        cp -p -- "$TXN_DIR/$name.data" "$path" || return 1
    else
        if [[ -e "$path" || -L "$path" ]]; then
            rm -f -- "$path" || return 1
        fi
    fi
}

write_atomic_from_file() {
    local source="$1"
    local destination="$2"
    local parent temp

    parent=$(path_parent "$destination")
    ensure_parent "$destination" || return 1
    temp=$(mktemp "$parent/.pve-gpu-manager-ats.XXXXXX") || return 1
    if ! cp -p -- "$source" "$temp"; then
        rm -f -- "$temp"
        return 1
    fi
    if ! mv -f -- "$temp" "$destination"; then
        rm -f -- "$temp"
        return 1
    fi
}

write_atomic_content() {
    local destination="$1"
    local content="$2"
    local parent temp

    parent=$(path_parent "$destination")
    ensure_parent "$destination" || return 1
    temp=$(mktemp "$parent/.pve-gpu-manager-ats.XXXXXX") || return 1
    if ! printf '%s' "$content" > "$temp"; then
        rm -f -- "$temp"
        return 1
    fi
    chmod 0644 "$temp" || {
        rm -f -- "$temp"
        return 1
    }
    if ! mv -f -- "$temp" "$destination"; then
        rm -f -- "$temp"
        return 1
    fi
}

line_has_noats() {
    local line="$1"

    # Grub defaults are shell-like assignments.  Removing comments and quote
    # characters lets us check the kernel argument as a real token without
    # evaluating any user-controlled shell text.
    line="${line%%#*}"
    line="${line//\"/ }"
    line="${line//\'/ }"
    [[ "$line" =~ (^|[[:space:]])pci=noats($|[[:space:]]) ]]
}

grub_file_has_noats() {
    local path="$1"
    local line

    [[ -f "$path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if line_has_noats "$line"; then
            return 0
        fi
    done < "$path"
    return 1
}

grub_external_has_noats() {
    local path

    if grub_file_has_noats "$GRUB_DEFAULT"; then
        return 0
    fi

    [[ -d "$GRUB_DIR" ]] || return 1
    for path in "$GRUB_DIR"/*; do
        [[ -f "$path" ]] || continue
        [[ "$path" == "$GRUB_DROPIN" ]] && continue
        if grub_file_has_noats "$path"; then
            return 0
        fi
    done
    return 1
}

cmdline_file_has_noats() {
    local path="$1"

    [[ -f "$path" ]] || return 1
    perl -0ne \
        '$found = 1 if /(?<!\S)pci=noats(?!\S)/; END { exit($found ? 0 : 1) }' \
        "$path"
}

cmdline_file_noats_count() {
    local path="$1"

    [[ -f "$path" ]] || {
        printf '0'
        return 0
    }
    perl -0ne '
        $count += () = /(?<!\S)pci=noats(?!\S)/g;
        END { print $count + 0 }
    ' "$path"
}

make_cmdline_with_noats() {
    local source="$1"
    local destination="$2"

    if [[ ! -f "$source" ]]; then
        printf '%s\n' "$NOATS_TOKEN" > "$destination"
        return 0
    fi

    # Keep every existing argument and append one exact token.  The common
    # one-line cmdline and its final newline are retained byte-for-byte apart
    # from the appended token and its separator.
    perl -0pe '
        if (!/(?<!\S)pci=noats(?!\S)/) {
            my $ending = "";
            if (s/((?:\r?\n)+)\z//) {
                $ending = $1;
            }
            if (length($_) && $_ !~ /[ \t]\z/) {
                $_ .= " ";
            }
            $_ .= "pci=noats" . $ending;
        }
    ' "$source" > "$destination"
}

make_cmdline_without_one_noats() {
    local source="$1"
    local destination="$2"

    # Remove exactly one token owned by the marker.  Preserve all unrelated
    # arguments and the file's line ending.  If a second token was supplied by
    # somebody else, it remains visible and unmanaged after this operation.
    perl -0pe '
        if (/(?<!\S)pci=noats(?!\S)/) {
            if (s/\Apci=noats[ \t]+//) {
            } elsif (s/\Apci=noats(?=[ \t]*(?:\r?\n)*\z)//) {
            } elsif (s/[ \t]+pci=noats(?=[ \t]*(?:\r?\n)*\z)//) {
            } else {
                s/([ \t])pci=noats[ \t]+/$1/ ||
                    s/([ \t])pci=noats(?=\r?\n)/$1/;
            }
        }
    ' "$source" > "$destination"
}

make_grub_with_noats() {
    local source="$1"
    local destination="$2"

    if [[ -f "$source" ]]; then
        cp -p -- "$source" "$destination" || return 1
        # A trailing blank line is harmless and avoids trying to parse shell
        # quoting while adding the package-owned assignment.
        # The generated GRUB fragment must expand this variable when GRUB reads it.
        # shellcheck disable=SC2016
        printf '\n%s\nGRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} pci=noats"\n' \
            "$GRUB_POLICY_MARKER" >> "$destination"
    else
        # The generated GRUB fragment must expand this variable when GRUB reads it.
        # shellcheck disable=SC2016
        printf '%s\nGRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} pci=noats"\n' \
            "$GRUB_POLICY_MARKER" > "$destination"
    fi
}

make_grub_without_noats() {
    local source="$1"
    local destination="$2"

    # This is only called for the package path.  Keep any unrelated content a
    # pre-existing package fragment may contain; normal generated fragments
    # are removed entirely by grub_disable below using their marker.
    sed -E 's/(^|[[:space:]"'"'"'])pci=noats($|[[:space:]"'"'"'])/\1\2/g' \
        "$source" > "$destination"
}

read_atsctl() {
    local value

    if [[ ! -f "$ATSCTL_FILE" ]]; then
        printf 'unknown'
        return 0
    fi
    IFS= read -r value < "$ATSCTL_FILE" || true
    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        1|y|yes|on|true|disabled|disable) printf 'disabled' ;;
        0|n|no|off|false|enabled|enable) printf 'enabled' ;;
        *) printf 'unknown' ;;
    esac
}

current_cmdline_noats() {
    if cmdline_file_has_noats "$CURRENT_CMDLINE"; then
        printf '1'
    else
        printf '0'
    fi
}

emit_state() {
    local persistent="$1"
    local managed="$2"
    local changed="$3"
    local current atsctl reboot_required

    current=$(current_cmdline_noats)
    atsctl=$(read_atsctl)
    if [[ "$current" == "$persistent" ]]; then
        reboot_required=0
    else
        reboot_required=1
    fi

    printf 'boot_mode=%s\n' "$BOOT_MODE"
    printf 'current_cmdline_noats=%s\n' "$current"
    printf 'active_noats=%s\n' "$current"
    printf 'atsctl=%s\n' "$atsctl"
    printf 'persistent_noats=%s\n' "$persistent"
    printf 'future_boot_noats=%s\n' "$persistent"
    printf 'managed=%s\n' "$managed"
    printf 'changed=%s\n' "$changed"
    printf 'reboot_required=%s\n' "$reboot_required"
}

report_failure() {
    local code="$1"
    local persistent="$2"
    local managed="$3"

    emit_state "$persistent" "$managed" 0
    error_message "$code"
    return 1
}

run_command() {
    local command_line="$1"
    shift

    # Command overrides are intentionally test-friendly while still avoiding
    # shell evaluation of their contents.  A bare command is resolved through
    # PATH; an absolute/relative executable path is invoked directly.
    if [[ "$command_line" == */* ]]; then
        "$command_line" "$@"
    else
        command "$command_line" "$@"
    fi
}

normalize_boot_mode() {
    local requested
    requested=$(printf '%s' "$BOOT_MODE_REQUESTED" | tr '[:upper:]' '[:lower:]')

    case "$requested" in
        grub|grub2|grub-mkconfig)
            printf 'grub'
            ;;
        proxmox-boot-tool|proxmox_boot_tool|proxmox|pbt)
            printf 'proxmox-boot-tool'
            ;;
        systemd-boot|systemd_boot)
            # PVE's systemd-boot path is maintained by proxmox-boot-tool.
            printf 'systemd-boot'
            ;;
        auto|'')
            # proxmox-boot-tool is authoritative only when it has a configured
            # ESP list.  The executable and /etc/kernel/cmdline can both exist
            # on a GRUB host without being its active boot path.
            if [[ -s "$PROXMOX_BOOT_UUIDS" && -f "$KERNEL_CMDLINE" ]] &&
                { [[ "$PROXMOX_BOOT_TOOL_CMD" == */* && -x "$PROXMOX_BOOT_TOOL_CMD" ]] ||
                  [[ "$PROXMOX_BOOT_TOOL_CMD" != */* ]] && command -v "$PROXMOX_BOOT_TOOL_CMD" >/dev/null 2>&1; }; then
                printf 'proxmox-boot-tool'
            else
                printf 'grub'
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

grub_state() {
    local external=0
    local dropin_noats=0
    local managed=0

    if grub_external_has_noats; then
        external=1
    fi
    if grub_file_has_noats "$GRUB_DROPIN"; then
        dropin_noats=1
    fi
    if [[ "$dropin_noats" == 1 ]] && grub_dropin_is_owned; then
        managed=1
    fi
    printf '%s %s\n' "$((external || dropin_noats))" "$managed"
}

grub_dropin_is_owned() {
    [[ -f "$GRUB_DROPIN" ]] || return 1
    grep -Fqx "$GRUB_POLICY_MARKER" "$GRUB_DROPIN" || return 1
    grub_file_has_noats "$GRUB_DROPIN"
}

grub_dropin_conflict() {
    if [[ ! -e "$GRUB_DROPIN" && ! -L "$GRUB_DROPIN" ]]; then
        return 1
    fi
    ! grub_dropin_is_owned
}

grub_dropin_is_usable() {
    if [[ ! -e "$GRUB_DROPIN" && ! -L "$GRUB_DROPIN" ]]; then
        return 0
    fi
    grub_dropin_is_owned
}

proxmox_state() {
    local persistent=0
    local managed=0

    if cmdline_file_has_noats "$KERNEL_CMDLINE"; then
        persistent=1
        if marker_is_owned; then
            managed=1
        fi
    fi
    printf '%s %s\n' "$persistent" "$managed"
}

marker_is_owned() {
    [[ -f "$MANAGED_MARKER" ]] || return 1
    grep -Fqx "$MARKER_CONTENT" "$MANAGED_MARKER"
}

grub_status() {
    local persistent managed
    read -r persistent managed < <(grub_state)
    emit_state "$persistent" "$managed" 0
}

proxmox_status() {
    local persistent managed
    read -r persistent managed < <(proxmox_state)
    emit_state "$persistent" "$managed" 0
}

grub_enable() {
    local persistent managed
    read -r persistent managed < <(grub_state)

    # A pre-existing file at the package path is not ours unless it carries
    # our ownership marker.  Do not append to or later delete a user's file.
    if grub_dropin_conflict; then
        emit_state "$persistent" 0 0
        error_message 'dropin_conflict'
        return 1
    fi

    # An existing user policy is authoritative.  Do not create a second
    # package policy or claim ownership of somebody else's argument.
    if grub_external_has_noats; then
        emit_state 1 0 0
        return 0
    fi
    if [[ "$managed" == 1 ]]; then
        emit_state 1 1 0
        return 0
    fi
    if ! grub_dropin_is_usable; then
        emit_state "$persistent" 0 0
        error_message 'dropin_conflict'
        return 1
    fi

    if ! begin_transaction || ! snapshot_file "$GRUB_DROPIN" grub; then
        report_failure 'snapshot_failed' "$persistent" "$managed"
        return 1
    fi

    local new_file="$TXN_DIR/grub.new"
    if ! make_grub_with_noats "$GRUB_DROPIN" "$new_file" ||
        ! write_atomic_from_file "$new_file" "$GRUB_DROPIN"; then
        if ! restore_snapshot "$GRUB_DROPIN" grub; then
            report_failure 'write_failed_rollback_failed' "$persistent" "$managed"
            return 1
        fi
        report_failure 'write_failed' "$persistent" "$managed"
        return 1
    fi

    if ! run_command "$UPDATE_GRUB_CMD" >&2; then
        if ! restore_snapshot "$GRUB_DROPIN" grub; then
            report_failure 'refresh_failed_rollback_failed' "$persistent" "$managed"
            return 1
        fi
        report_failure 'refresh_failed' "$persistent" "$managed"
        return 1
    fi

    emit_state 1 1 1
}

grub_disable() {
    local persistent managed
    read -r persistent managed < <(grub_state)

    if grub_dropin_conflict; then
        emit_state "$persistent" 0 0
        error_message 'dropin_conflict'
        return 1
    fi
    if grub_external_has_noats && [[ "$managed" != 1 ]]; then
        emit_state "$persistent" 0 0
        error_message 'external_policy'
        return 1
    fi
    [[ "$managed" == 1 ]] || {
        emit_state 0 0 0
        return 0
    }

    # The package owns a complete drop-in, identified by its marker.  Never
    # edit or delete a pre-existing file merely because it contains noats.
    if ! begin_transaction || ! snapshot_file "$GRUB_DROPIN" grub; then
        report_failure 'snapshot_failed' "$persistent" "$managed"
        return 1
    fi

    if ! rm -f -- "$GRUB_DROPIN"; then
        report_failure 'write_failed' "$persistent" "$managed"
        return 1
    fi

    if ! run_command "$UPDATE_GRUB_CMD" >&2; then
        if ! restore_snapshot "$GRUB_DROPIN" grub; then
            report_failure 'refresh_failed_rollback_failed' "$persistent" "$managed"
            return 1
        fi
        report_failure 'refresh_failed' "$persistent" "$managed"
        return 1
    fi

    read -r persistent managed < <(grub_state)
    emit_state "$persistent" "$managed" 1
}

proxmox_enable() {
    local persistent managed
    read -r persistent managed < <(proxmox_state)

    # Without our marker, a token already in /etc/kernel/cmdline is external
    # policy and must remain untouched.
    if [[ "$persistent" == 1 ]]; then
        if [[ "$managed" == 1 ]]; then
            emit_state 1 1 0
        else
            emit_state 1 0 0
        fi
        return 0
    fi

    # A marker path occupied by somebody else is not a safe place to record
    # ownership.  Do not overwrite it while enabling the policy.
    if [[ -e "$MANAGED_MARKER" || -L "$MANAGED_MARKER" ]] &&
        ! marker_is_owned; then
        emit_state 0 0 0
        error_message 'marker_conflict'
        return 1
    fi

    # An absent cmdline is not a safe basis for appending a token: creating a
    # guessed file could discard the bootloader's root, console, or initrd
    # arguments.  A real PVE installation always has this file in this mode.
    if [[ ! -f "$KERNEL_CMDLINE" ]]; then
        emit_state 0 0 0
        error_message 'cmdline_missing'
        return 1
    fi

    if ! begin_transaction || ! snapshot_file "$KERNEL_CMDLINE" cmdline ||
        ! snapshot_file "$MANAGED_MARKER" marker; then
        report_failure 'snapshot_failed' "$persistent" "$managed"
        return 1
    fi

    local new_cmdline="$TXN_DIR/cmdline.new"
    local new_marker="$TXN_DIR/marker.new"
    if ! make_cmdline_with_noats "$KERNEL_CMDLINE" "$new_cmdline" ||
        ! write_atomic_from_file "$new_cmdline" "$KERNEL_CMDLINE" ||
        ! printf '%s\n' "$MARKER_CONTENT" > "$new_marker" ||
        ! write_atomic_from_file "$new_marker" "$MANAGED_MARKER"; then
        if ! restore_snapshot "$KERNEL_CMDLINE" cmdline ||
            ! restore_snapshot "$MANAGED_MARKER" marker; then
            report_failure 'write_failed_rollback_failed' "$persistent" "$managed"
            return 1
        fi
        report_failure 'write_failed' "$persistent" "$managed"
        return 1
    fi

    if ! run_command "$PROXMOX_BOOT_TOOL_CMD" refresh >&2; then
        if ! restore_snapshot "$KERNEL_CMDLINE" cmdline ||
            ! restore_snapshot "$MANAGED_MARKER" marker; then
            report_failure 'refresh_failed_rollback_failed' "$persistent" "$managed"
            return 1
        fi
        report_failure 'refresh_failed' "$persistent" "$managed"
        return 1
    fi

    emit_state 1 1 1
}

proxmox_disable() {
    local persistent managed noats_count
    read -r persistent managed < <(proxmox_state)

    if [[ "$persistent" == 1 && "$managed" != 1 ]]; then
        emit_state 1 0 0
        error_message 'external_policy'
        return 1
    fi
    if [[ -e "$MANAGED_MARKER" || -L "$MANAGED_MARKER" ]] &&
        ! marker_is_owned; then
        emit_state "$persistent" 0 0
        error_message 'marker_conflict'
        return 1
    fi
    if [[ "$persistent" == 0 && ! -f "$MANAGED_MARKER" ]]; then
        emit_state 0 0 0
        return 0
    fi
    if [[ ! -f "$KERNEL_CMDLINE" ]]; then
        emit_state "$persistent" 0 0
        error_message 'cmdline_missing'
        return 1
    fi

    noats_count=$(cmdline_file_noats_count "$KERNEL_CMDLINE")
    if [[ "$managed" == 1 && "$noats_count" -gt 1 ]]; then
        emit_state 1 1 0
        error_message 'token_conflict'
        return 1
    fi

    if ! begin_transaction || ! snapshot_file "$KERNEL_CMDLINE" cmdline ||
        ! snapshot_file "$MANAGED_MARKER" marker; then
        report_failure 'snapshot_failed' "$persistent" "$managed"
        return 1
    fi

    local new_cmdline="$TXN_DIR/cmdline.new"
    if [[ "$persistent" == 1 ]]; then
        if ! make_cmdline_without_one_noats "$KERNEL_CMDLINE" "$new_cmdline" ||
            ! write_atomic_from_file "$new_cmdline" "$KERNEL_CMDLINE"; then
            if ! restore_snapshot "$KERNEL_CMDLINE" cmdline ||
                ! restore_snapshot "$MANAGED_MARKER" marker; then
                report_failure 'write_failed_rollback_failed' "$persistent" "$managed"
                return 1
            fi
            report_failure 'write_failed' "$persistent" "$managed"
            return 1
        fi
    fi
    if [[ -f "$MANAGED_MARKER" ]] && ! rm -f -- "$MANAGED_MARKER"; then
        if ! restore_snapshot "$KERNEL_CMDLINE" cmdline ||
            ! restore_snapshot "$MANAGED_MARKER" marker; then
            report_failure 'write_failed_rollback_failed' "$persistent" "$managed"
            return 1
        fi
        report_failure 'write_failed' "$persistent" "$managed"
        return 1
    fi

    if [[ "$persistent" == 1 ]]; then
        if ! run_command "$PROXMOX_BOOT_TOOL_CMD" refresh >&2; then
            if ! restore_snapshot "$KERNEL_CMDLINE" cmdline ||
                ! restore_snapshot "$MANAGED_MARKER" marker; then
                report_failure 'refresh_failed_rollback_failed' "$persistent" "$managed"
                return 1
            fi
            report_failure 'refresh_failed' "$persistent" "$managed"
            return 1
        fi
    fi

    read -r persistent managed < <(proxmox_state)
    emit_state "$persistent" "$managed" 1
}

main() {
    local action="${1:-}"

    if [[ "$#" != 1 || ! "$action" =~ ^(status|enable|disable)$ ]]; then
        usage
        return 2
    fi
    if ! BOOT_MODE=$(normalize_boot_mode); then
        printf 'error=invalid_boot_mode\n' >&2
        return 2
    fi

    case "$BOOT_MODE" in
        grub)
            case "$action" in
                status) grub_status ;;
                enable) grub_enable ;;
                disable) grub_disable ;;
            esac
            ;;
        proxmox-boot-tool|systemd-boot)
            case "$action" in
                status) proxmox_status ;;
                enable) proxmox_enable ;;
                disable) proxmox_disable ;;
            esac
            ;;
    esac
}

main "$@"
