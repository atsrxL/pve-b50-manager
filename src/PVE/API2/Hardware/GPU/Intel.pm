package PVE::API2::Hardware::GPU::Intel;

use strict;
use warnings;
use File::Glob ':bsd_glob';
use PVE::Tools qw(run_command);
use PVE::GPU::SRIOV qw(active_sched_priority);

# ---------------------------------------------------------------------------
# Device family map
# ---------------------------------------------------------------------------
my $DEVICE_FAMILIES = {
    '0x56c0' => { family => 'flex',     max_vfs => 31, tiles => 1 },
    '0x56c1' => { family => 'flex',     max_vfs => 31, tiles => 1 },
    '0x56c2' => { family => 'flex',     max_vfs => 31, tiles => 1 },
    '0x0bd4' => { family => 'pvc',      max_vfs => 62, tiles => 2 },
    '0x0bd5' => { family => 'pvc',      max_vfs => 62, tiles => 2 },
    '0x0bd6' => { family => 'pvc',      max_vfs => 62, tiles => 2 },
    '0x0bda' => { family => 'pvc_ext',  max_vfs => 63, tiles => 2 },
    '0x0bdb' => { family => 'pvc_ext',  max_vfs => 63, tiles => 2 },
    '0x0b6e' => { family => 'pvc_ext',  max_vfs => 63, tiles => 2 },
    '0xe211' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe212' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe222' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe223' => { family => 'bmg_12vf', max_vfs => 12, tiles => 1 },
};

# Fallback device name map when lspci is unavailable
my $DEVICE_NAMES = {
    '0x56c0' => 'Intel Data Center GPU Flex 170',
    '0x56c1' => 'Intel Data Center GPU Flex 140',
    '0x56c2' => 'Intel Data Center GPU Flex 140 (2T)',
    '0x0bd4' => 'Intel Data Center GPU Max 1550',
    '0x0bd5' => 'Intel Data Center GPU Max 1100',
    '0x0bd6' => 'Intel Data Center GPU Max 1100C',
    '0x0bda' => 'Intel Data Center GPU Max 1450',
    '0x0bdb' => 'Intel Data Center GPU Max 1350',
    '0x0b6e' => 'Intel Data Center GPU Max (PVC-XT)',
    '0xe211' => 'Intel Arc Pro B60 (Battlemage G21)',
    '0xe212' => 'Intel Arc Pro B50 (Battlemage G21)',
    '0xe222' => 'Intel Battlemage GPU G21',
    '0xe223' => 'Intel Battlemage GPU G21 (12VF)',
};

# ---------------------------------------------------------------------------
# Helper: check if device is Battlemage family
# ---------------------------------------------------------------------------
sub is_bmg {
    my ($class, $device_id) = @_;
    $device_id = lc($device_id);
    $device_id = "0x$device_id" unless $device_id =~ /^0x/;
    my $info = $DEVICE_FAMILIES->{$device_id};
    return 0 unless defined $info;
    return ($info->{family} eq 'bmg' || $info->{family} eq 'bmg_12vf') ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Plugin interface: identify_device
# ---------------------------------------------------------------------------
sub identify_device {
    my ($class, $device_id) = @_;
    $device_id = lc($device_id);
    $device_id = "0x$device_id" unless $device_id =~ /^0x/;
    return $DEVICE_FAMILIES->{$device_id};
}

# ---------------------------------------------------------------------------
# Plugin interface: device_name_fallback
# Returns fallback name for a device ID when lspci is unavailable
# ---------------------------------------------------------------------------
sub device_name_fallback {
    my ($class, $device_id) = @_;
    my $norm = lc($device_id);
    $norm = "0x$norm" unless $norm =~ /^0x/;
    return $DEVICE_NAMES->{$norm} // "Intel GPU ($device_id)";
}

# ---------------------------------------------------------------------------
# Plugin interface: read_telemetry
# ---------------------------------------------------------------------------
sub read_telemetry {
    my ($class, $card, $bdf, $driver) = @_;
    my $result = {
        temperature_c      => undef,
        mem_temperature_c  => undef,
        power_w            => undef,
        power_tdp_w        => undef,
        clock_mhz          => undef,
        clock_max_mhz      => undef,
        gpu_util_pct       => undef,
        lmem_total_mb      => undef,
        lmem_used_mb       => undef,
        fan_rpm            => undef,
        throttled          => undef,
        health             => 'OK',
    };

    # Temperature: read all hwmon temp sensors, match by label
    my $hwmon_base = PVE::API2::Hardware::GPU::sysfs_path("/sys/class/drm/$card/device/hwmon");
    my @hwmon_dirs = bsd_glob("$hwmon_base/hwmon*");
    my $got_labeled_temp = 0;
    for my $hwmon_dir (@hwmon_dirs) {
        my @temp_files = bsd_glob("$hwmon_dir/temp*_input");
        for my $tf (@temp_files) {
            (my $label_file = $tf) =~ s/_input$/_label/;
            my $label = '';
            if (open(my $lfh, '<', $label_file)) {
                $label = <$lfh>;
                chomp $label if defined $label;
                close($lfh);
            }

            open(my $fh, '<', $tf) or next;
            my $val = <$fh>;
            close($fh);
            next unless defined $val;
            chomp $val;
            my $temp = $val / 1000.0;

            if ($label eq 'pkg' || $label eq 'GPU') {
                $result->{temperature_c} = $temp;
                $got_labeled_temp = 1;
            } elsif ($label eq 'vram' || $label eq 'Memory') {
                $result->{mem_temperature_c} = $temp;
                $got_labeled_temp = 1;
            } elsif (!$got_labeled_temp && !defined $result->{temperature_c}) {
                # Fallback: first temp sensor if no labels
                $result->{temperature_c} = $temp;
            }
        }
    }

    # Power: try power*_input (i915, microwatts -> W) first,
    # then compute from energy*_input delta (xe driver, microjoules)
    HWMON_POWER: for my $hwmon_dir (@hwmon_dirs) {
        # Method 1: direct power reading (i915)
        my @pwr_files = bsd_glob("$hwmon_dir/power*_input");
        for my $pf (@pwr_files) {
            open(my $fh, '<', $pf) or next;
            my $val = <$fh>;
            close($fh);
            if (defined $val) {
                chomp $val;
                $result->{power_w} = sprintf("%.1f", $val / 1_000_000.0);
                last HWMON_POWER;
            }
        }

        # Method 2: energy counter delta (xe driver)
        my @energy_files = bsd_glob("$hwmon_dir/energy1_input");
        for my $ef (@energy_files) {
            open(my $fh1, '<', $ef) or next;
            my $e1 = <$fh1>;
            close($fh1);
            chomp $e1 if defined $e1;
            next unless defined $e1 && $e1 =~ /^\d+$/;

            # Brief sleep for delta measurement
            select(undef, undef, undef, 0.1);  # 100ms

            open(my $fh2, '<', $ef) or next;
            my $e2 = <$fh2>;
            close($fh2);
            chomp $e2 if defined $e2;
            next unless defined $e2 && $e2 =~ /^\d+$/;

            my $delta_uj = $e2 - $e1;
            if ($delta_uj > 0) {
                # delta_uj / 0.1s = microwatts, convert to watts
                $result->{power_w} = sprintf("%.1f", ($delta_uj / 100_000.0));
                last HWMON_POWER;
            }
        }

        # Method 3: TDP from power1_cap (fallback)
        if (!defined $result->{power_w}) {
            my @cap_files = bsd_glob("$hwmon_dir/power1_cap");
            for my $cf (@cap_files) {
                open(my $fh, '<', $cf) or next;
                my $val = <$fh>;
                close($fh);
                if (defined $val) {
                    chomp $val;
                    $result->{power_tdp_w} = sprintf("%.0f", $val / 1_000_000.0);
                    last;
                }
            }
        }
    }

    # Fan speed: hwmon/hwmon*/fan*_input (RPM)
    for my $hwmon_dir (@hwmon_dirs) {
        my @fan_files = bsd_glob("$hwmon_dir/fan*_input");
        for my $ff (@fan_files) {
            open(my $fh, '<', $ff) or next;
            my $val = <$fh>;
            close($fh);
            if (defined $val) {
                chomp $val;
                $result->{fan_rpm} = int($val) if $val =~ /^\d+$/;
                last;
            }
        }
        last if defined $result->{fan_rpm};
    }

    # Clock rate: xe driver uses tile0/gt0/freq0/ (act_freq + max_freq)
    # i915 uses device/tile*/gt_cur_freq_mhz
    if (defined $bdf) {
        my $card_dev = PVE::API2::Hardware::GPU::sysfs_path("/sys/class/drm/$card/device");
        # xe driver path
        my $freq_base = "$card_dev/tile0/gt0/freq0";
        if (-d $freq_base) {
            my $act = do { open(my $f, '<', "$freq_base/act_freq") or undef; defined $f ? do { my $v = <$f>; close $f; chomp $v if defined $v; $v } : undef };
            my $max = do { open(my $f, '<', "$freq_base/max_freq") or undef; defined $f ? do { my $v = <$f>; close $f; chomp $v if defined $v; $v } : undef };
            $result->{clock_mhz} = int($act) if defined $act && $act =~ /^\d+$/;
            $result->{clock_max_mhz} = int($max) if defined $max && $max =~ /^\d+$/;
        } else {
            # i915 fallback
            my @freq_files = bsd_glob("$card_dev/tile*/gt_cur_freq_mhz");
            for my $ff (@freq_files) {
                open(my $fh, '<', $ff) or next;
                my $val = <$fh>;
                close($fh);
                if (defined $val) {
                    chomp $val;
                    $result->{clock_mhz} = int($val) if $val =~ /^\d+$/;
                    last;
                }
            }
        }
    }

    # VRAM: from debugfs vram0_mm (size + usage in bytes)
    if (defined $bdf) {
        my $vram_mm_path = PVE::API2::Hardware::GPU::sysfs_path("/sys/kernel/debug/dri/$bdf/vram0_mm");
        if (open(my $fh, '<', $vram_mm_path)) {
            my $total_bytes = 0;
            while (my $line = <$fh>) {
                if ($line =~ /^\s*size:\s*(\d+)/) {
                    $total_bytes = $1;
                }
                if ($line =~ /^\s*usage:\s*(\d+)/) {
                    $result->{lmem_used_mb} = int($1 / (1024 * 1024));
                }
            }
            close($fh);

            # Subtract PF lmem_spare (reserved for PF, not provisionable to VFs)
            my $spare_path = PVE::API2::Hardware::GPU::sysfs_path(
                "/sys/kernel/debug/dri/$bdf/sriov/pf/tile0/vram_spare"
            );
            if (open(my $sfh, '<', $spare_path)) {
                my $spare = <$sfh>;
                close($sfh);
                if (defined $spare) {
                    chomp $spare;
                    $total_bytes -= $spare if $spare =~ /^\d+$/;
                }
            }
            $result->{lmem_total_mb} = int($total_bytes / (1024 * 1024)) if $total_bytes > 0;
        }
    }

    # Fallback: LMEM free from sysfs iov path (i915 driver)
    if (!defined $result->{lmem_total_mb}) {
        my $lmem_path = "/sys/class/drm/$card/iov/pf/gt0/available/lmem_free";
        my $lmem_val  = PVE::API2::Hardware::GPU::read_sysfs($lmem_path);
        if (defined $lmem_val && $lmem_val =~ /^\d+$/) {
            $result->{lmem_total_mb} = int($lmem_val / (1024 * 1024));
        }
    }

    # GPU utilization via perf PMU counters (xe driver)
    if (defined $bdf) {
        my $pmu_dev = "xe_$bdf";
        $pmu_dev =~ s/:/_/g;  # xe_0000_03_00.0
        if (-d "/sys/bus/event_source/devices/$pmu_dev") {
        eval {
            my ($active, $total);
            run_command(
                ['perf', 'stat', '-e',
                 "$pmu_dev/engine-active-ticks/,$pmu_dev/engine-total-ticks/",
                 '-I', '200', '-x', ',', 'sleep', '0.3'],
                outfunc => sub {},
                errfunc => sub {
                    my $line = shift;
                    if ($line =~ /(\d+),,\Q$pmu_dev\E\/engine-active-ticks\//) {
                        $active = $1;
                    } elsif ($line =~ /(\d+),,\Q$pmu_dev\E\/engine-total-ticks\//) {
                        $total = $1;
                    }
                },
            );
            if (defined $active && defined $total && $total > 0) {
                $result->{gpu_util_pct} = sprintf("%.1f", ($active / $total) * 100);
            } else {
                $result->{gpu_util_pct} = 0;
            }
        };
        # Non-fatal: perf may not be installed
        }
    }

    # Throttle detection
    if (defined $bdf) {
        my $card_dev = PVE::API2::Hardware::GPU::sysfs_path("/sys/class/drm/$card/device");
        my $throttle_path = "$card_dev/tile0/gt0/freq0/throttle";
        if (open(my $fh, '<', $throttle_path)) {
            my $val = <$fh>;
            close($fh);
            if (defined $val) {
                chomp $val;
                $result->{throttled} = ($val ne '' && $val ne '0') ? \1 : \0;
            }
        }
    }

    # Derive health status from thresholds
    my @issues;
    if (defined $result->{temperature_c} && $result->{temperature_c} >= 95) {
        push @issues, 'GPU temp critical';
    }
    if (defined $result->{mem_temperature_c} && $result->{mem_temperature_c} >= 85) {
        push @issues, 'VRAM temp critical';
    }
    if ($result->{throttled} && ${$result->{throttled}}) {
        push @issues, 'Throttled';
    }
    if (@issues) {
        $result->{health} = join(', ', @issues);
    }

    return $result;
}

# ---------------------------------------------------------------------------
# Discover GT indices without assuming that one tile means one GT.  Current
# Battlemage exposes VRAM/GGTT at tile scope and contexts/doorbells/scheduling
# below both gt0 and gt1.
# ---------------------------------------------------------------------------
sub enumerate_gts {
    my ($class, $family, $card, $bdf, $vf_index, $tile) = @_;
    return [0] if $family ne 'bmg' && $family ne 'bmg_12vf';

    my @roots = (
        "/sys/kernel/debug/dri/$bdf/sriov/vf$vf_index/tile$tile",
        "/sys/kernel/debug/dri/$bdf/sriov/pf/tile$tile",
    );
    my %indices;
    for my $root (@roots) {
        my $full = PVE::API2::Hardware::GPU::sysfs_path($root);
        for my $path (bsd_glob("$full/gt*")) {
            $indices{$1} = 1 if $path =~ m{/gt(\d+)$} && -d $path;
        }
    }

    # G21 B50/B60 currently has two GTs.  The fallback is used only before
    # the first VF is enabled, when vfN directories may not exist yet.
    return [0, 1] if !%indices;
    return [sort { $a <=> $b } keys %indices];
}

# ---------------------------------------------------------------------------
# Plugin interface: get_vf_resource_paths
# Values are arrays because GT-scoped resources have one file per GT.
# ---------------------------------------------------------------------------
sub get_vf_resource_paths {
    my ($class, $family, $card, $bdf, $vf_index, $tile) = @_;

    if ($family eq 'bmg' || $family eq 'bmg_12vf') {
        my $base = "/sys/kernel/debug/dri/$bdf/sriov/vf$vf_index/tile$tile";
        my $gts = $class->enumerate_gts($family, $card, $bdf, $vf_index, $tile);
        return {
            vram               => ["$base/vram_quota"],
            ggtt               => ["$base/ggtt_quota"],
            contexts           => [map { "$base/gt$_/contexts_quota" } @$gts],
            doorbells          => [map { "$base/gt$_/doorbells_quota" } @$gts],
            exec_quantum_ms    => [map { "$base/gt$_/exec_quantum_ms" } @$gts],
            preempt_timeout_us => [map { "$base/gt$_/preempt_timeout_us" } @$gts],
            debug_priority     => [map { "$base/gt$_/sched_priority" } @$gts],
        };
    } else {
        my $base = "/sys/class/drm/$card/iov/vf$vf_index/gt$tile";
        return {
            vram               => ["$base/lmem_quota"],
            ggtt               => ["$base/ggtt_quota"],
            contexts           => ["$base/contexts_quota"],
            doorbells          => ["$base/doorbells_quota"],
            exec_quantum_ms    => ["$base/exec_quantum_ms"],
            preempt_timeout_us => ["$base/preempt_timeout_us"],
        };
    }
}

# Legacy scalar-path adapter retained for callers outside this package.
sub get_vf_paths {
    my ($class, @args) = @_;
    my $paths = $class->get_vf_resource_paths(@args);
    return {
        lmem_quota         => $paths->{vram}[0],
        ggtt_quota         => $paths->{ggtt}[0],
        exec_quantum_ms    => $paths->{exec_quantum_ms}[0],
        preempt_timeout_us => $paths->{preempt_timeout_us}[0],
    };
}

sub read_pf_available {
    my ($class, $family, $card, $bdf, $tile) = @_;

    if ($family eq 'bmg' || $family eq 'bmg_12vf') {
        my $base = "/sys/kernel/debug/dri/$bdf/sriov/pf/tile$tile";
        my $gts = $class->enumerate_gts($family, $card, $bdf, 1, $tile);
        my (@contexts, @doorbells);
        for my $gt (@$gts) {
            push @contexts, int(PVE::API2::Hardware::GPU::read_sysfs(
                "$base/gt$gt/contexts_spare"
            ) // 0);
            push @doorbells, int(PVE::API2::Hardware::GPU::read_sysfs(
                "$base/gt$gt/doorbells_spare"
            ) // 0);
        }
        return {
            vram_spare      => int(PVE::API2::Hardware::GPU::read_sysfs("$base/vram_spare") // 0),
            ggtt_spare      => int(PVE::API2::Hardware::GPU::read_sysfs("$base/ggtt_spare") // 0),
            contexts_spare  => \@contexts,
            doorbells_spare => \@doorbells,
            gt_count        => scalar(@$gts),
        };
    }

    my $base = "/sys/class/drm/$card/iov/pf/gt$tile/available";
    return {
        vram_spare      => int(PVE::API2::Hardware::GPU::read_sysfs("$base/lmem_free") // 0),
        ggtt_spare      => int(PVE::API2::Hardware::GPU::read_sysfs("$base/ggtt_free") // 0),
        contexts_spare  => [int(PVE::API2::Hardware::GPU::read_sysfs("$base/contexts_free") // 0)],
        doorbells_spare => [int(PVE::API2::Hardware::GPU::read_sysfs("$base/doorbells_free") // 0)],
        gt_count        => 1,
    };
}

sub prepare_auto_provisioning {
    my ($class, $family, $bdf) = @_;
    return 1 if $family ne 'bmg' && $family ne 'bmg_12vf';

    my $path = "/sys/kernel/debug/dri/$bdf/sriov/restore_auto_provisioning";
    PVE::API2::Hardware::GPU::write_sysfs($path, 1);
    return 1;
}

sub read_scheduler_priority {
    my ($class, $bdf, $vf_index) = @_;
    $vf_index //= 1;
    my $raw = PVE::API2::Hardware::GPU::read_sysfs(
        "/sys/bus/pci/devices/$bdf/sriov_admin/vf$vf_index/profile/sched_priority"
    );
    return active_sched_priority($raw);
}

sub set_scheduler_priority {
    my ($class, $bdf, $priority) = @_;
    my $path = "/sys/bus/pci/devices/$bdf/sriov_admin/.bulk_profile/sched_priority";
    PVE::API2::Hardware::GPU::write_sysfs($path, $priority);
    return 1;
}

sub get_sriov_capabilities {
    my ($class, $family, $card, $bdf, $num_vfs) = @_;
    my $is_bmg = ($family eq 'bmg' || $family eq 'bmg_12vf');
    my $auto_path = PVE::API2::Hardware::GPU::sysfs_path(
        "/sys/kernel/debug/dri/$bdf/sriov/restore_auto_provisioning"
    );
    my $sched_path = PVE::API2::Hardware::GPU::sysfs_path(
        "/sys/bus/pci/devices/$bdf/sriov_admin/.bulk_profile/sched_priority"
    );

    return {
        per_vf_profiles            => \1,
        auto_provisioning          => ($is_bmg && -e $auto_path) ? \1 : \0,
        count_change_requires_reset => \1,
        resources => {
            vram => {
                supported => \1, writable => \1, scope => 'vf_tile', unit => 'bytes',
                alignment_bytes => 128 * 1024 * 1024,
            },
            ggtt => {
                supported => \1, writable => \1, scope => 'vf_tile', unit => 'bytes',
                alignment_bytes => 128 * 1024 * 1024,
            },
            contexts => {
                supported => \1, writable => \1, scope => 'vf_gt', unit => 'count',
            },
            doorbells => {
                supported => \1, writable => \1, scope => 'vf_gt', unit => 'count',
            },
            exec_quantum_ms => {
                supported => \1, writable => \1, scope => 'vf_gt', unit => 'milliseconds',
            },
            preempt_timeout_us => {
                supported => \1, writable => \1, scope => 'vf_gt', unit => 'microseconds',
            },
        },
        scheduler => {
            supported        => -e $sched_path ? \1 : \0,
            writable         => -w $sched_path ? \1 : \0,
            scope            => 'device_bulk',
            values           => ['low', 'normal'],
            default          => 'low',
            recommended      => 'low',
            dangerous_values => ['normal'],
            live_change_safe => \0,
        },
    };
}

# ---------------------------------------------------------------------------
# Plugin interface: read_firmware_version
# ---------------------------------------------------------------------------
sub read_firmware_version {
    my ($class, $bdf) = @_;
    my $guc_path = PVE::API2::Hardware::GPU::sysfs_path("/sys/kernel/debug/dri/$bdf/gt0/uc/guc_info");
    if (open(my $fh, '<', $guc_path)) {
        while (my $line = <$fh>) {
            if ($line =~ /found release version\s+([\d.]+)/) {
                close($fh);
                return $1;
            }
        }
        close($fh);
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Plugin interface: native_drivers
# ---------------------------------------------------------------------------
sub native_drivers {
    my ($class) = @_;
    return ['xe', 'i915'];
}

# ---------------------------------------------------------------------------
# Plugin interface: run_prechecks
# Returns vendor-specific driver check result
# ---------------------------------------------------------------------------
sub run_prechecks {
    my ($class, $bdf, $card, $driver) = @_;

    my $pass = ($driver eq 'i915' || $driver eq 'xe') ? 1 : 0;
    return {
        pass   => $pass ? \1 : \0,
        detail => $pass
            ? "$driver driver bound"
            : "Driver '$driver' bound (expected i915 or xe)",
    };
}

# ---------------------------------------------------------------------------
# Register with GPU framework
# ---------------------------------------------------------------------------
PVE::API2::Hardware::GPU::register_vendor('8086', __PACKAGE__);

1;
