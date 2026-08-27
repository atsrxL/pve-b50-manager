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
NO_RESTART="${PVE_GPU_NO_RESTART:-0}"

INDEX_BEGIN='<!-- BEGIN PVE GPU MANAGER -->'
INDEX_END='<!-- END PVE GPU MANAGER -->'
SCRIPT_TAG='<script src="/pve2/js/pve-gpu-plugin.js"></script>'

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
        || die "Cannot create temporary file beside $pve_gpu_source"
    cp -p "$pve_gpu_source" "$pve_gpu_temp" \
        || die "Cannot preserve metadata from $pve_gpu_source"
    printf '%s\n' "$pve_gpu_temp"
}

replace_if_changed() {
    pve_gpu_target=$1
    pve_gpu_candidate=$2

    if cmp -s "$pve_gpu_target" "$pve_gpu_candidate"; then
        rm -f "$pve_gpu_candidate"
        return 0
    fi

    mv "$pve_gpu_candidate" "$pve_gpu_target" \
        || die "Cannot replace $pve_gpu_target"
    CHANGED=1
}

# Strip both current marker blocks and the exact unmarked tag used by v1.0.0.
clean_index_to() {
    pve_gpu_input=$1
    pve_gpu_output=$2

    awk -v begin="$INDEX_BEGIN" -v end="$INDEX_END" -v legacy="$SCRIPT_TAG" '
        $0 == begin {
            if (inside) exit 40;
            inside = 1;
            next;
        }
        $0 == end {
            if (!inside) exit 41;
            inside = 0;
            next;
        }
        inside { next; }
        {
            line = $0;
            block = begin legacy end;
            while ((at = index(line, block)) > 0) {
                line = substr(line, 1, at - 1) substr(line, at + length(block));
            }
            while ((at = index(line, legacy)) > 0) {
                line = substr(line, 1, at - 1) substr(line, at + length(legacy));
            }
            if (line ~ /^[[:space:]]*$/ && $0 != line) next;
            print line;
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

apply_index() {
    [ -f "$INDEX_TPL" ] || die "$INDEX_TPL not found"
    pve_gpu_clean=$(new_temp_like "$INDEX_TPL" clean)
    pve_gpu_final=$(new_temp_like "$INDEX_TPL" apply)

    if ! clean_index_to "$INDEX_TPL" "$pve_gpu_clean"; then
        rm -f "$pve_gpu_clean" "$pve_gpu_final"
        die "Malformed marker block in $INDEX_TPL"
    fi
    if ! patch_index_to "$pve_gpu_clean" "$pve_gpu_final"; then
        rm -f "$pve_gpu_clean" "$pve_gpu_final"
        die "Cannot find </head> in $INDEX_TPL"
    fi
    rm -f "$pve_gpu_clean"
    replace_if_changed "$INDEX_TPL" "$pve_gpu_final"
}

apply_hardware() {
    [ -f "$HARDWARE_PM" ] || die "$HARDWARE_PM not found"
    pve_gpu_clean=$(new_temp_like "$HARDWARE_PM" clean)
    pve_gpu_final=$(new_temp_like "$HARDWARE_PM" apply)

    if ! clean_hardware_to "$HARDWARE_PM" "$pve_gpu_clean"; then
        rm -f "$pve_gpu_clean" "$pve_gpu_final"
        die "Malformed marker block in $HARDWARE_PM"
    fi
    if ! patch_hardware_to "$pve_gpu_clean" "$pve_gpu_final"; then
        rm -f "$pve_gpu_clean" "$pve_gpu_final"
        die "Unsupported $HARDWARE_PM layout or unrecognised GPU patch"
    fi
    rm -f "$pve_gpu_clean"
    replace_if_changed "$HARDWARE_PM" "$pve_gpu_final"
}

remove_index() {
    [ -f "$INDEX_TPL" ] || return 0
    pve_gpu_clean=$(new_temp_like "$INDEX_TPL" remove)
    if ! clean_index_to "$INDEX_TPL" "$pve_gpu_clean"; then
        rm -f "$pve_gpu_clean"
        die "Malformed marker block in $INDEX_TPL"
    fi
    replace_if_changed "$INDEX_TPL" "$pve_gpu_clean"
}

remove_hardware() {
    [ -f "$HARDWARE_PM" ] || return 0
    pve_gpu_clean=$(new_temp_like "$HARDWARE_PM" remove)
    if ! clean_hardware_to "$HARDWARE_PM" "$pve_gpu_clean"; then
        rm -f "$pve_gpu_clean"
        die "Malformed marker block in $HARDWARE_PM"
    fi
    replace_if_changed "$HARDWARE_PM" "$pve_gpu_clean"
}

remove_legacy_nodes() {
    [ -f "$NODES_PM" ] || return 0
    pve_gpu_clean=$(new_temp_like "$NODES_PM" remove)
    if ! clean_legacy_nodes_to "$NODES_PM" "$pve_gpu_clean"; then
        rm -f "$pve_gpu_clean"
        die "Cannot clean legacy integration from $NODES_PM"
    fi
    replace_if_changed "$NODES_PM" "$pve_gpu_clean"
}

restart_pve_services() {
    [ "$CHANGED" -eq 1 ] || return 0
    [ "$NO_RESTART" = 1 ] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    [ -d /run/systemd/system ] || return 0

    systemctl restart pvedaemon \
        || log "WARNING: Failed to restart pvedaemon"
    systemctl restart pveproxy \
        || log "WARNING: Failed to restart pveproxy"
}

apply_all() {
    apply_index
    apply_hardware
    remove_legacy_nodes
    restart_pve_services
    log "Marker integration is present"
}

remove_all() {
    remove_index
    remove_hardware
    remove_legacy_nodes
    restart_pve_services
    log "Marker integration is absent"
}

case "${1:---apply}" in
    --apply)
        apply_all
        ;;
    --remove)
        remove_all
        ;;
    *)
        echo "Usage: $0 [--apply|--remove]" >&2
        exit 2
        ;;
esac

exit 0
