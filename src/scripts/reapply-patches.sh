#!/bin/sh
# Apply or remove the small, explicitly marked PVE GPU Manager integration.
#
# The script deliberately does not restore whole-file backups: Proxmox may have
# upgraded those files since this package was installed. Instead it removes
# only blocks owned by this package, then builds the desired result atomically.

set -eu

INDEX_TPL="${PVE_GPU_INDEX_TPL:-/usr/share/pve-manager/index.html.tpl}"
HARDWARE_PM="${PVE_GPU_HARDWARE_PM:-/usr/share/perl5/PVE/API2/Hardware.pm}"
NODES_PM="${PVE_GPU_NODES_PM:-/usr/share/perl5/PVE/API2/Nodes.pm}"
QEMU_PCI_PM="${PVE_GPU_QEMU_PCI_PM:-/usr/share/perl5/PVE/QemuServer/PCI.pm}"
QEMU_SERVER_PM="${PVE_GPU_QEMU_SERVER_PM:-/usr/share/perl5/PVE/QemuServer.pm}"
NO_RESTART="${PVE_GPU_NO_RESTART:-0}"
FORCE_RESTART="${PVE_GPU_FORCE_RESTART:-0}"
SYSTEMD_RUNTIME_DIR="${PVE_GPU_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"

INDEX_BEGIN='<!-- BEGIN PVE GPU MANAGER -->'
INDEX_END='<!-- END PVE GPU MANAGER -->'
SCRIPT_TAG='<script src="/pve2/js/pve-gpu-plugin.js?ver=1.1.0-20"></script>'

ATS_PCI_USE_BEGIN='# BEGIN PVE GPU MANAGER ATS PCI USE'
ATS_PCI_USE_END='# END PVE GPU MANAGER ATS PCI USE'
ATS_PCI_GUARD_BEGIN='# BEGIN PVE GPU MANAGER ATS PCI GUARD'
ATS_PCI_GUARD_END='# END PVE GPU MANAGER ATS PCI GUARD'
ATS_QEMU_USE_BEGIN='# BEGIN PVE GPU MANAGER ATS QEMU USE'
ATS_QEMU_USE_END='# END PVE GPU MANAGER ATS QEMU USE'
ATS_QEMU_GUARD_BEGIN='# BEGIN PVE GPU MANAGER ATS QEMU GUARD'
ATS_QEMU_GUARD_END='# END PVE GPU MANAGER ATS QEMU GUARD'
POWER_QEMU_GUARD_BEGIN='# BEGIN PVE GPU MANAGER POWER QEMU GUARD'
POWER_QEMU_GUARD_END='# END PVE GPU MANAGER POWER QEMU GUARD'

CHANGED=0

log() {
    logger -t pve-gpu-patches "$@" 2>/dev/null || true
    echo "pve-gpu-patches: $*"
}

die() {
    log "ERROR: $*"
    exit 1
}

new_temp_like() {
    pve_gpu_source=$1
    pve_gpu_label=$2
    pve_gpu_temp=$(mktemp "${pve_gpu_source}.pve-gpu-${pve_gpu_label}.XXXXXX") \
        || return 1
    cp -p "$pve_gpu_source" "$pve_gpu_temp" \
        || { rm -f "$pve_gpu_temp"; return 1; }
    printf '%s\n' "$pve_gpu_temp"
}

# Strip every package-owned marker block regardless of the package version that
# wrote it.  PVE keeps </head> on the same line, so upgrades can leave several
# adjacent one-line blocks behind unless marker parsing is content-independent.
# Also migrate exact unmarked plugin tags written by pre-marker releases.
clean_index_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk -v begin="$INDEX_BEGIN" -v end="$INDEX_END" '
        {
            source = $0;
            line = source;
            output = "";
            changed = 0;

            while (length(line) > 0) {
                if (inside) {
                    begin_at = index(line, begin);
                    end_at = index(line, end);
                    if (begin_at > 0 && (end_at == 0 || begin_at < end_at)) exit 40;
                    if (end_at == 0) {
                        line = "";
                        changed = 1;
                        break;
                    }
                    line = substr(line, end_at + length(end));
                    inside = 0;
                    changed = 1;
                    continue;
                }

                begin_at = index(line, begin);
                end_at = index(line, end);
                if (end_at > 0 && (begin_at == 0 || end_at < begin_at)) exit 41;
                if (begin_at == 0) {
                    output = output line;
                    line = "";
                    break;
                }

                output = output substr(line, 1, begin_at - 1);
                line = substr(line, begin_at + length(begin));
                inside = 1;
                changed = 1;
            }

            # Remove only the exact plugin script shape used by this package,
            # accepting either no query string or an older ?ver= value.
            while (match(output, /<script src="\/pve2\/js\/pve-gpu-plugin[.]js([?]ver=[^"]+)?"><\/script>/)) {
                output = substr(output, 1, RSTART - 1) substr(output, RSTART + RLENGTH);
                changed = 1;
            }

            if (output ~ /^[[:space:]]*$/ && changed) next;
            print output;
        }
        END {
            if (inside) exit 42;
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

# Strip current marker blocks and the exact legacy edits made by the old
# postinst. Unknown GPU-related edits are left alone and make apply fail.
clean_hardware_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk '
        { lines[++count] = $0; }
        END {
            inside = 0;
            for (i = 1; i <= count; i++) {
                line = lines[i];

                if (line ~ /^[[:space:]]*# BEGIN PVE GPU MANAGER HARDWARE /) {
                    if (inside) exit 50;
                    inside = 1;
                    continue;
                }
                if (line ~ /^[[:space:]]*# END PVE GPU MANAGER HARDWARE /) {
                    if (!inside) exit 51;
                    inside = 0;
                    continue;
                }
                if (inside) continue;

                if (line ~ /^[[:space:]]*use PVE::API2::Hardware::GPU;[[:space:]]*$/) {
                    continue;
                }
                if (line ~ /^[[:space:]]*\{[[:space:]]*type[[:space:]]*=>[[:space:]]*[\047"]gpu[\047"][[:space:]]*\},?[[:space:]]*$/) {
                    continue;
                }

                # v1.0.0 inserted this four-line subclass registration.
                if (line ~ /^[[:space:]]*__PACKAGE__->register_method\([[:space:]]*\{[[:space:]]*$/ &&
                    lines[i + 1] ~ /^[[:space:]]*subclass[[:space:]]*=>[[:space:]]*[\047"]PVE::API2::Hardware::GPU[\047"][[:space:]]*,?[[:space:]]*$/ &&
                    lines[i + 2] ~ /^[[:space:]]*path[[:space:]]*=>[[:space:]]*[\047"]gpu[\047"][[:space:]]*,?[[:space:]]*$/ &&
                    lines[i + 3] ~ /^[[:space:]]*\}[[:space:]]*\);[[:space:]]*$/) {
                    i += 3;
                    continue;
                }

                print line;
            }
            if (inside) exit 52;
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

# The superseded reapply script touched Nodes.pm. Remove only its exact edits.
clean_legacy_nodes_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk '
        /^[[:space:]]*use PVE::API2::Hardware::GPU;[[:space:]]*$/ { next; }
        /^[[:space:]]*PVE::API2::Nodes->register_method\(/ && /PVE::API2::Hardware::GPU/ { next; }
        { print; }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

patch_index_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk -v begin="$INDEX_BEGIN" -v end="$INDEX_END" -v tag="$SCRIPT_TAG" '
        {
            line = $0;
            if (!inserted && line ~ /<\/head>/) {
                replacement = begin tag end "</head>";
                sub(/<\/head>/, replacement, line);
                inserted = 1;
            }
            print line;
        }
        END {
            if (!inserted) exit 60;
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

patch_hardware_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk '
        { lines[++count] = $0; }
        END {
            for (i = 1; i <= count; i++) {
                if (lines[i] ~ /^[[:space:]]*use PVE::API2::Hardware::/) last_use = i;
                if (lines[i] ~ /\{[[:space:]]*type[[:space:]]*=>[[:space:]]*[\047"]usb[\047"][[:space:]]*\},/) usb_entry = i;
                if (lines[i] ~ /^[[:space:]]*1;[[:space:]]*$/) final_one = i;
                if (lines[i] ~ /PVE::API2::Hardware::GPU/ ||
                    (lines[i] ~ /[\047"]gpu[\047"]/ && lines[i] ~ /type[[:space:]]*=>/)) {
                    unexpected_gpu = 1;
                }
            }

            if (!last_use || !usb_entry || unexpected_gpu) exit 70;

            quote = sprintf("%c", 39);
            index_indent = "            ";
            if (lines[usb_entry] ~ /^[[:space:]]*\{/) {
                match(lines[usb_entry], /^[[:space:]]*/);
                index_indent = substr(lines[usb_entry], RSTART, RLENGTH);
            }

            for (i = 1; i <= count; i++) {
                if (i == final_one) {
                    print "# BEGIN PVE GPU MANAGER HARDWARE REGISTER";
                    print "__PACKAGE__->register_method({";
                    print "    subclass => \"PVE::API2::Hardware::GPU\",";
                    print "    path => " quote "gpu" quote ",";
                    print "});";
                    print "# END PVE GPU MANAGER HARDWARE REGISTER";
                }

                print lines[i];

                if (i == last_use) {
                    print "# BEGIN PVE GPU MANAGER HARDWARE USE";
                    print "use PVE::API2::Hardware::GPU;";
                    print "# END PVE GPU MANAGER HARDWARE USE";
                }

                if (i == usb_entry) {
                    print index_indent "# BEGIN PVE GPU MANAGER HARDWARE INDEX";
                    print index_indent "{ type => " quote "gpu" quote " },";
                    print index_indent "# END PVE GPU MANAGER HARDWARE INDEX";
                }
            }

            # Current PVE Hardware.pm has no trailing 1;, while older variants
            # do. Append the registration when there is no final sentinel.
            if (!final_one) {
                print "# BEGIN PVE GPU MANAGER HARDWARE REGISTER";
                print "__PACKAGE__->register_method({";
                print "    subclass => \"PVE::API2::Hardware::GPU\",";
                print "    path => " quote "gpu" quote ",";
                print "});";
                print "# END PVE GPU MANAGER HARDWARE REGISTER";
            }
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

# Remove only the two owned native-start guard blocks.  The surrounding
# QemuServer::PCI source remains Proxmox-owned and is never restored from a
# package backup.
clean_qemu_pci_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk -v use_begin="$ATS_PCI_USE_BEGIN" \
        -v use_end="$ATS_PCI_USE_END" \
        -v guard_begin="$ATS_PCI_GUARD_BEGIN" \
        -v guard_end="$ATS_PCI_GUARD_END" '
        {
            line = $0;
            if (line == use_begin) {
                if (inside) exit 80;
                inside = "use";
                next;
            }
            if (line == guard_begin) {
                if (inside) exit 80;
                inside = "guard";
                next;
            }
            if (line == use_end) {
                if (inside != "use") exit 81;
                inside = "";
                next;
            }
            if (line == guard_end) {
                if (inside != "guard") exit 81;
                inside = "";
                next;
            }
            if (inside != "") next;
            print line;
        }
        END {
            if (inside != "") exit 82;
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

# Insert the import after the standard strict pragma and the guard as the
# first executable statement of prepare_pci_device.  Both anchors are exact;
# an unknown upstream layout fails closed instead of silently installing a
# partial native-start protection.
patch_qemu_pci_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk -v use_begin="$ATS_PCI_USE_BEGIN" \
        -v use_end="$ATS_PCI_USE_END" \
        -v guard_begin="$ATS_PCI_GUARD_BEGIN" \
        -v guard_end="$ATS_PCI_GUARD_END" '
        {
            line = $0;

            if (!use_inserted && line ~ /^[[:space:]]*use[[:space:]]+strict[[:space:]]*;/) {
                print line;
                print use_begin;
                print "use PVE::GPU::ATS qw(assert_safe_for_pci_device);";
                print use_end;
                use_inserted = 1;
                next;
            }

            print line;

            if (line ~ /^[[:space:]]*sub[[:space:]]+prepare_pci_device[[:space:]]*\{[[:space:]]*$/) {
                prepare_seen++;
            }

            if (prepare_seen == 1 && !guard_inserted &&
                line ~ /^[[:space:]]*my[[:space:]]*\([[:space:]]*\$vmid[[:space:]]*,[[:space:]]*\$pciid[[:space:]]*,[[:space:]]*\$index[[:space:]]*,[[:space:]]*\$device[[:space:]]*\)[[:space:]]*=[[:space:]]*\@_;[[:space:]]*$/) {
                print guard_begin;
                print "    PVE::GPU::ATS::assert_safe_for_pci_device(" "$" "pciid, " "$" "vmid);";
                print guard_end;
                guard_inserted = 1;
            }
        }
        END {
            if (!use_inserted || prepare_seen != 1 || !guard_inserted) exit 83;
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

# Strip only the native-start preflight blocks owned by this package.
clean_qemu_server_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk -v use_begin="$ATS_QEMU_USE_BEGIN" \
        -v use_end="$ATS_QEMU_USE_END" \
        -v guard_begin="$ATS_QEMU_GUARD_BEGIN" \
        -v guard_end="$ATS_QEMU_GUARD_END" \
        -v power_begin="$POWER_QEMU_GUARD_BEGIN" \
        -v power_end="$POWER_QEMU_GUARD_END" '
        {
            line = $0;
            if (line == use_begin) {
                if (inside) exit 90;
                inside = "use";
                next;
            }
            if (line == guard_begin) {
                if (inside) exit 90;
                inside = "guard";
                next;
            }
            if (line == power_begin) {
                if (inside) exit 90;
                inside = "power";
                next;
            }
            if (line == use_end) {
                if (inside != "use") exit 91;
                inside = "";
                next;
            }
            if (line == guard_end) {
                if (inside != "guard") exit 91;
                inside = "";
                next;
            }
            if (line == power_end) {
                if (inside != "power") exit 91;
                inside = "";
                next;
            }
            if (inside != "") next;
            print line;
        }
        END {
            if (inside != "") exit 92;
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

# Run one full hostpci safety pass immediately after config_to_command has
# selected every concrete PCI function and before PVE reserves or prepares
# any of them.  The lower prepare_pci_device guard remains as a second entry
# point for direct callers and for driver=keep.
patch_qemu_server_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk -v use_begin="$ATS_QEMU_USE_BEGIN" \
        -v use_end="$ATS_QEMU_USE_END" \
        -v guard_begin="$ATS_QEMU_GUARD_BEGIN" \
        -v guard_end="$ATS_QEMU_GUARD_END" \
        -v power_begin="$POWER_QEMU_GUARD_BEGIN" \
        -v power_end="$POWER_QEMU_GUARD_END" '
        {
            line = $0;

            if (!use_inserted && line ~ /^[[:space:]]*use[[:space:]]+strict[[:space:]]*;/) {
                print line;
                print use_begin;
                print "use PVE::GPU::ATS qw(assert_safe_for_hostpci_devices);";
                print "use PVE::GPU::Power qw(assert_vm_start_allowed);";
                print use_end;
                use_inserted = 1;
                next;
            }

            if (line ~ /^[[:space:]]*\(\$cmd,[[:space:]]*\$spice_port,[[:space:]]*my[[:space:]]+\$pci_devices,[[:space:]]*\$conf\)[[:space:]]*=[[:space:]]*config_to_command\([[:space:]]*$/ ||
                line ~ /^[[:space:]]*\(my[[:space:]]+\$cmd,[[:space:]]*my[[:space:]]+\$vollist,[[:space:]]*my[[:space:]]+\$spice_port,[[:space:]]*my[[:space:]]+\$pci_devices,[[:space:]]*\$conf\)[[:space:]]*=[[:space:]]*config_to_command\([[:space:]]*$/) {
                start_anchor++;
                print power_begin;
                print "        PVE::GPU::Power::assert_vm_start_allowed(" "$" "conf, " "$" "vmid);";
                print power_end;
                power_guard_inserted = 1;
                in_start_config = 1;
            }

            if (in_start_config && !guard_inserted &&
                line ~ /^[[:space:]]*my[[:space:]]+\$memory[[:space:]]*=[[:space:]]*get_current_memory\(\$conf->\{memory\}\);[[:space:]]*$/) {
                print guard_begin;
                print "        PVE::GPU::ATS::assert_safe_for_hostpci_devices(" "$" "pci_devices, " "$" "vmid);";
                print guard_end;
                guard_inserted = 1;
                in_start_config = 0;
            }

            print line;
        }
        END {
            if (!use_inserted || start_anchor != 1 || !power_guard_inserted || !guard_inserted) exit 93;
        }
    ' "$pve_gpu_input" > "$pve_gpu_output"
}

restart_pve_services() {
    [ "$NO_RESTART" = 1 ] && return 0
    [ "$CHANGED" -eq 1 ] || [ "$FORCE_RESTART" = 1 ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    [ -d "$SYSTEMD_RUNTIME_DIR" ] || return 0

    pve_gpu_restart_failed=0
    systemctl restart pvedaemon || {
        log "ERROR: Failed to restart pvedaemon after replacing PVE Perl integrations"
        pve_gpu_restart_failed=1
    }
    systemctl restart pveproxy || {
        log "ERROR: Failed to restart pveproxy after replacing PVE Perl integrations"
        pve_gpu_restart_failed=1
    }
    # try-restart is a no-op for an inactive HA LRM, but a non-zero result for
    # an active process means it may still have the unguarded module loaded.
    systemctl try-restart pve-ha-lrm || {
        log "ERROR: Failed to reload the active pve-ha-lrm after replacing QemuServer"
        pve_gpu_restart_failed=1
    }
    [ "$pve_gpu_restart_failed" -eq 0 ] \
        || die "One or more PVE VM-start processes could not be reloaded"
}

commit_staged_file() {
    pve_gpu_target=$1
    pve_gpu_staged=$2

    cmp -s "$pve_gpu_target" "$pve_gpu_staged" && return 0
    pve_gpu_commit=$(new_temp_like "$pve_gpu_target" commit) || return 1
    if ! cp "$pve_gpu_staged" "$pve_gpu_commit"; then
        rm -f "$pve_gpu_commit"
        return 1
    fi
    if ! mv "$pve_gpu_commit" "$pve_gpu_target"; then
        rm -f "$pve_gpu_commit"
        return 1
    fi
    CHANGED=1
}

# Verify the native integrations without touching the files owned by
# qemu-server.  Rebuilding the expected output in a private temporary
# directory makes this check cover marker shape, exact anchors, and
# idempotency; an unmarked or partially overwritten source therefore fails
# closed instead of being treated as healthy merely because a marker string
# happens to remain.
check_native_qemu_file() {
    pve_gpu_target=$1
    pve_gpu_kind=$2
    pve_gpu_input="$pve_gpu_health_dir/$pve_gpu_kind.input"
    pve_gpu_clean="$pve_gpu_health_dir/$pve_gpu_kind.clean"
    pve_gpu_final="$pve_gpu_health_dir/$pve_gpu_kind.final"

    cp -p "$pve_gpu_target" "$pve_gpu_input" || return 1
    case "$pve_gpu_kind" in
        pci)
            clean_qemu_pci_to "$pve_gpu_input" "$pve_gpu_clean" || return 1
            patch_qemu_pci_to "$pve_gpu_clean" "$pve_gpu_final" || return 1
            ;;
        server)
            clean_qemu_server_to "$pve_gpu_input" "$pve_gpu_clean" || return 1
            patch_qemu_server_to "$pve_gpu_clean" "$pve_gpu_final" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    cmp -s "$pve_gpu_target" "$pve_gpu_final"
}

check_native_guards() {
    [ -f "$QEMU_PCI_PM" ] || die "$QEMU_PCI_PM not found; native GPU start guards are unavailable"
    [ -f "$QEMU_SERVER_PM" ] || die "$QEMU_SERVER_PM not found; native GPU start guards are unavailable"

    pve_gpu_health_dir=$(mktemp -d "${TMPDIR:-/tmp}/pve-gpu-native-guards.XXXXXX") \
        || die "Cannot create native GPU guard health-check directory"
    if ! check_native_qemu_file "$QEMU_PCI_PM" pci ||
        ! check_native_qemu_file "$QEMU_SERVER_PM" server; then
        rm -rf "$pve_gpu_health_dir"
        die "Native GPU start guards are absent, stale, or malformed"
    fi
    rm -rf "$pve_gpu_health_dir"
    log "Native GPU start guards are healthy"
}

apply_all() {
    [ -f "$INDEX_TPL" ] || die "$INDEX_TPL not found"
    [ -f "$HARDWARE_PM" ] || die "$HARDWARE_PM not found"
    [ -f "$QEMU_PCI_PM" ] || die "$QEMU_PCI_PM not found"
    [ -f "$QEMU_SERVER_PM" ] || die "$QEMU_SERVER_PM not found"

    pve_gpu_stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/pve-gpu-patches.XXXXXX") \
        || die "Cannot create patch staging directory"
    pve_gpu_index_final="$pve_gpu_stage_dir/index.final"
    pve_gpu_hardware_final="$pve_gpu_stage_dir/hardware.final"
    pve_gpu_qemu_pci_final="$pve_gpu_stage_dir/qemu-pci.final"
    pve_gpu_qemu_server_final="$pve_gpu_stage_dir/qemu-server.final"
    pve_gpu_nodes_final="$pve_gpu_stage_dir/nodes.final"

    clean_index_to "$INDEX_TPL" "$pve_gpu_stage_dir/index.clean" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Malformed marker block in $INDEX_TPL"; }
    patch_index_to "$pve_gpu_stage_dir/index.clean" "$pve_gpu_index_final" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Cannot find </head> in $INDEX_TPL"; }
    clean_hardware_to "$HARDWARE_PM" "$pve_gpu_stage_dir/hardware.clean" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Malformed marker block in $HARDWARE_PM"; }
    patch_hardware_to "$pve_gpu_stage_dir/hardware.clean" "$pve_gpu_hardware_final" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Unsupported $HARDWARE_PM layout or unrecognised GPU patch"; }
    clean_qemu_pci_to "$QEMU_PCI_PM" "$pve_gpu_stage_dir/qemu-pci.clean" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Malformed native GPU marker block in $QEMU_PCI_PM"; }
    patch_qemu_pci_to "$pve_gpu_stage_dir/qemu-pci.clean" "$pve_gpu_qemu_pci_final" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Unsupported $QEMU_PCI_PM layout or missing prepare_pci_device anchor"; }
    clean_qemu_server_to "$QEMU_SERVER_PM" "$pve_gpu_stage_dir/qemu-server.clean" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Malformed native GPU marker block in $QEMU_SERVER_PM"; }
    patch_qemu_server_to "$pve_gpu_stage_dir/qemu-server.clean" "$pve_gpu_qemu_server_final" \
        || { rm -rf "$pve_gpu_stage_dir"; die "Unsupported $QEMU_SERVER_PM layout or missing VM start preflight anchor"; }
    if [ -f "$NODES_PM" ]; then
        clean_legacy_nodes_to "$NODES_PM" "$pve_gpu_nodes_final" \
            || { rm -rf "$pve_gpu_stage_dir"; die "Cannot clean legacy integration from $NODES_PM"; }
    fi

    pve_gpu_backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/pve-gpu-patches-backup.XXXXXX") \
        || { rm -rf "$pve_gpu_stage_dir"; die "Cannot create patch rollback directory"; }
    if ! cp -p "$INDEX_TPL" "$pve_gpu_backup_dir/index" ||
        ! cp -p "$HARDWARE_PM" "$pve_gpu_backup_dir/hardware" ||
        ! cp -p "$QEMU_PCI_PM" "$pve_gpu_backup_dir/qemu-pci" ||
        ! cp -p "$QEMU_SERVER_PM" "$pve_gpu_backup_dir/qemu-server"; then
        rm -rf "$pve_gpu_stage_dir" "$pve_gpu_backup_dir"
        die "Cannot snapshot patch targets"
    fi
    if [ -f "$NODES_PM" ] && ! cp -p "$NODES_PM" "$pve_gpu_backup_dir/nodes"; then
        rm -rf "$pve_gpu_stage_dir" "$pve_gpu_backup_dir"
        die "Cannot snapshot $NODES_PM"
    fi

    pve_gpu_commit_failed=0
    commit_staged_file "$INDEX_TPL" "$pve_gpu_index_final" || pve_gpu_commit_failed=1
    [ "$pve_gpu_commit_failed" -ne 0 ] || commit_staged_file "$HARDWARE_PM" "$pve_gpu_hardware_final" || pve_gpu_commit_failed=1
    [ "$pve_gpu_commit_failed" -ne 0 ] || commit_staged_file "$QEMU_PCI_PM" "$pve_gpu_qemu_pci_final" || pve_gpu_commit_failed=1
    [ "$pve_gpu_commit_failed" -ne 0 ] || commit_staged_file "$QEMU_SERVER_PM" "$pve_gpu_qemu_server_final" || pve_gpu_commit_failed=1
    if [ "$pve_gpu_commit_failed" -eq 0 ] && [ -f "$NODES_PM" ]; then
        commit_staged_file "$NODES_PM" "$pve_gpu_nodes_final" || pve_gpu_commit_failed=1
    fi
    if [ "$pve_gpu_commit_failed" -ne 0 ]; then
        cp -p "$pve_gpu_backup_dir/index" "$INDEX_TPL" || true
        cp -p "$pve_gpu_backup_dir/hardware" "$HARDWARE_PM" || true
        cp -p "$pve_gpu_backup_dir/qemu-pci" "$QEMU_PCI_PM" || true
        cp -p "$pve_gpu_backup_dir/qemu-server" "$QEMU_SERVER_PM" || true
        [ ! -f "$pve_gpu_backup_dir/nodes" ] || cp -p "$pve_gpu_backup_dir/nodes" "$NODES_PM" || true
        rm -rf "$pve_gpu_stage_dir" "$pve_gpu_backup_dir"
        die "Cannot commit all marker integrations; original files restored"
    fi
    rm -rf "$pve_gpu_stage_dir" "$pve_gpu_backup_dir"
    restart_pve_services
    log "Marker integration is present"
}

remove_all() {
    pve_gpu_remove_stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/pve-gpu-remove.XXXXXX") \
        || die "Cannot create remove staging directory"

    # Build every removal result before replacing any PVE-owned file.  This is
    # especially important when a later qemu-server marker is malformed: a
    # failed uninstall must not leave index/Hardware.pm/PCI.pm half-cleaned.
    if [ -f "$INDEX_TPL" ]; then
        clean_index_to "$INDEX_TPL" "$pve_gpu_remove_stage_dir/index" \
            || { rm -rf "$pve_gpu_remove_stage_dir"; die "Malformed marker block in $INDEX_TPL"; }
    fi
    if [ -f "$HARDWARE_PM" ]; then
        clean_hardware_to "$HARDWARE_PM" "$pve_gpu_remove_stage_dir/hardware" \
            || { rm -rf "$pve_gpu_remove_stage_dir"; die "Malformed marker block in $HARDWARE_PM"; }
    fi
    if [ -f "$QEMU_PCI_PM" ]; then
        clean_qemu_pci_to "$QEMU_PCI_PM" "$pve_gpu_remove_stage_dir/qemu-pci" \
            || { rm -rf "$pve_gpu_remove_stage_dir"; die "Malformed native GPU marker block in $QEMU_PCI_PM"; }
    fi
    if [ -f "$QEMU_SERVER_PM" ]; then
        clean_qemu_server_to "$QEMU_SERVER_PM" "$pve_gpu_remove_stage_dir/qemu-server" \
            || { rm -rf "$pve_gpu_remove_stage_dir"; die "Malformed native GPU marker block in $QEMU_SERVER_PM"; }
    fi
    if [ -f "$NODES_PM" ]; then
        clean_legacy_nodes_to "$NODES_PM" "$pve_gpu_remove_stage_dir/nodes" \
            || { rm -rf "$pve_gpu_remove_stage_dir"; die "Cannot clean legacy integration from $NODES_PM"; }
    fi

    pve_gpu_remove_backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/pve-gpu-remove-backup.XXXXXX") \
        || { rm -rf "$pve_gpu_remove_stage_dir"; die "Cannot create remove rollback directory"; }
    if [ -f "$INDEX_TPL" ] && ! cp -p "$INDEX_TPL" "$pve_gpu_remove_backup_dir/index"; then
        rm -rf "$pve_gpu_remove_stage_dir" "$pve_gpu_remove_backup_dir"
        die "Cannot snapshot $INDEX_TPL"
    fi
    if [ -f "$HARDWARE_PM" ] && ! cp -p "$HARDWARE_PM" "$pve_gpu_remove_backup_dir/hardware"; then
        rm -rf "$pve_gpu_remove_stage_dir" "$pve_gpu_remove_backup_dir"
        die "Cannot snapshot $HARDWARE_PM"
    fi
    if [ -f "$QEMU_PCI_PM" ] && ! cp -p "$QEMU_PCI_PM" "$pve_gpu_remove_backup_dir/qemu-pci"; then
        rm -rf "$pve_gpu_remove_stage_dir" "$pve_gpu_remove_backup_dir"
        die "Cannot snapshot $QEMU_PCI_PM"
    fi
    if [ -f "$QEMU_SERVER_PM" ] && ! cp -p "$QEMU_SERVER_PM" "$pve_gpu_remove_backup_dir/qemu-server"; then
        rm -rf "$pve_gpu_remove_stage_dir" "$pve_gpu_remove_backup_dir"
        die "Cannot snapshot $QEMU_SERVER_PM"
    fi
    if [ -f "$NODES_PM" ] && ! cp -p "$NODES_PM" "$pve_gpu_remove_backup_dir/nodes"; then
        rm -rf "$pve_gpu_remove_stage_dir" "$pve_gpu_remove_backup_dir"
        die "Cannot snapshot $NODES_PM"
    fi

    pve_gpu_remove_failed=0
    [ ! -f "$INDEX_TPL" ] || commit_staged_file "$INDEX_TPL" "$pve_gpu_remove_stage_dir/index" || pve_gpu_remove_failed=1
    [ "$pve_gpu_remove_failed" -ne 0 ] || [ ! -f "$HARDWARE_PM" ] || commit_staged_file "$HARDWARE_PM" "$pve_gpu_remove_stage_dir/hardware" || pve_gpu_remove_failed=1
    [ "$pve_gpu_remove_failed" -ne 0 ] || [ ! -f "$QEMU_PCI_PM" ] || commit_staged_file "$QEMU_PCI_PM" "$pve_gpu_remove_stage_dir/qemu-pci" || pve_gpu_remove_failed=1
    [ "$pve_gpu_remove_failed" -ne 0 ] || [ ! -f "$QEMU_SERVER_PM" ] || commit_staged_file "$QEMU_SERVER_PM" "$pve_gpu_remove_stage_dir/qemu-server" || pve_gpu_remove_failed=1
    [ "$pve_gpu_remove_failed" -ne 0 ] || [ ! -f "$NODES_PM" ] || commit_staged_file "$NODES_PM" "$pve_gpu_remove_stage_dir/nodes" || pve_gpu_remove_failed=1
    if [ "$pve_gpu_remove_failed" -ne 0 ]; then
        pve_gpu_restore_failed=0
        [ ! -f "$pve_gpu_remove_backup_dir/index" ] || cp -p "$pve_gpu_remove_backup_dir/index" "$INDEX_TPL" || pve_gpu_restore_failed=1
        [ ! -f "$pve_gpu_remove_backup_dir/hardware" ] || cp -p "$pve_gpu_remove_backup_dir/hardware" "$HARDWARE_PM" || pve_gpu_restore_failed=1
        [ ! -f "$pve_gpu_remove_backup_dir/qemu-pci" ] || cp -p "$pve_gpu_remove_backup_dir/qemu-pci" "$QEMU_PCI_PM" || pve_gpu_restore_failed=1
        [ ! -f "$pve_gpu_remove_backup_dir/qemu-server" ] || cp -p "$pve_gpu_remove_backup_dir/qemu-server" "$QEMU_SERVER_PM" || pve_gpu_restore_failed=1
        [ ! -f "$pve_gpu_remove_backup_dir/nodes" ] || cp -p "$pve_gpu_remove_backup_dir/nodes" "$NODES_PM" || pve_gpu_restore_failed=1
        rm -rf "$pve_gpu_remove_stage_dir" "$pve_gpu_remove_backup_dir"
        [ "$pve_gpu_restore_failed" -eq 0 ] \
            || die "Cannot commit removal; rollback also failed"
        die "Cannot commit all marker removals; original files restored"
    fi
    rm -rf "$pve_gpu_remove_stage_dir" "$pve_gpu_remove_backup_dir"
    restart_pve_services
    log "Marker integration is absent"
}

ACTION=--apply
for argument in "$@"; do
    case "$argument" in
        --apply|--remove)
            ACTION="$argument"
            ;;
        --check-native)
            ACTION="$argument"
            ;;
        --force-restart)
            FORCE_RESTART=1
            ;;
        --no-restart)
            NO_RESTART=1
            ;;
        *)
            echo "Usage: $0 [--apply|--remove|--check-native] [--force-restart] [--no-restart]" >&2
            exit 2
            ;;
    esac
done

case "$ACTION" in
    --apply)
        apply_all
        ;;
    --remove)
        remove_all
        ;;
    --check-native)
        check_native_guards
        ;;
esac

exit 0
