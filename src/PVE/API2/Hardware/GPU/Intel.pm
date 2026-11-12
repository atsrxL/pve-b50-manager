package PVE::API2::Hardware::GPU::Intel;

use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_RDWR O_WRONLY :flock);
use File::Glob ':bsd_glob';
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);
use Time::HiRes qw(time);
use PVE::Tools qw(run_command);
use PVE::GPU::Power qw(is_deep_idle);
use PVE::GPU::SRIOV qw(active_sched_priority);

# ---------------------------------------------------------------------------
# Device family map
# ---------------------------------------------------------------------------
my $DEVICE_FAMILIES = {
    '0xe211' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe212' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe222' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe223' => { family => 'bmg_12vf', max_vfs => 12, tiles => 1 },
};

# Fallback device name map when lspci is unavailable
my $DEVICE_NAMES = {
    '0xe211' => 'Intel Arc Pro B60 (Battlemage G21)',
    '0xe212' => 'Intel Arc Pro B50 (Battlemage G21)',
    '0xe222' => 'Intel Battlemage GPU G21',
    '0xe223' => 'Intel Battlemage GPU G21 (12VF)',
};

# Intel's B50 board profile reports a 73 W Card PL2 before user overrides.
# Other device IDs deliberately fall back to the first value observed by PGM.
my $DEFAULT_CARD_PL2_W = {
    '0xe212' => 73,
};

my @XE_ENGINE_EVENTS = (
    { name => 'render',   class => 0, instance => 0, gt => 0, group => 'render' },
    { name => 'copy',     class => 1, instance => 0, gt => 0, group => 'copy' },
    { name => 'compute',  class => 4, instance => 0, gt => 0, group => 'compute' },
    { name => 'video0',   class => 2, instance => 0, gt => 1, group => 'media' },
    { name => 'video1',   class => 2, instance => 1, gt => 1, group => 'media' },
    { name => 'enhance0', class => 3, instance => 0, gt => 1, group => 'media' },
    { name => 'enhance1', class => 3, instance => 1, gt => 1, group => 'media' },
);

my $XE_FDINFO_ENGINE_GROUP = {
    rcs => 'render',
    bcs => 'copy',
    ccs => 'compute',
    vcs => 'media',
    vecs => 'media',
};

sub _normalise_bdf {
    my ($bdf) = @_;
    return undef if !defined($bdf);
    $bdf = lc($bdf);
    # pvedaemon runs with Perl taint checks enabled.  Returning the original
    # value after merely matching it leaves the taint marker intact and makes
    # PVE::Tools::run_command abort in the child before perf can be exec'd.
    # Capture the complete canonical value so it is both validated and
    # explicitly untainted before it reaches a command argument or path.
    my ($clean) = $bdf =~ /^([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])$/;
    return $clean;
}

sub _read_text_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $value = <$fh>;
    close($fh) or return undef;
    return $value;
}

sub _memory_value_kib {
    my ($value, $unit) = @_;
    return undef if !defined($value) || $value !~ /^\d+(?:\.\d+)?$/;
    $unit = lc($unit // 'kib');
    my %factor = (
        b => 1 / 1024,
        kb => 1000 / 1024,
        kib => 1,
        mb => 1000**2 / 1024,
        mib => 1024,
        gb => 1000**3 / 1024,
        gib => 1024**2,
    );
    return undef if !exists($factor{$unit});
    return (0 + $value) * $factor{$unit};
}

# DRM fdinfo is the same per-client resident-memory and engine-cycle accounting
# consumed by nvtop/libdrm.  A DRM client can expose several duplicated file
# descriptors, so deduplicate by the driver's device-wide drm-client-id.
sub _read_pf_fdinfo_snapshot {
    my ($bdf) = @_;
    $bdf = _normalise_bdf($bdf);
    return undef if !defined($bdf);

    my $proc_root = PVE::API2::Hardware::GPU::sysfs_path('/proc');
    return undef if !-d $proc_root;

    my %clients;
    for my $path (bsd_glob("$proc_root/[0-9]*/fdinfo/*")) {
        my $text = _read_text_file($path);
        next if !defined($text);
        my ($driver) = $text =~ /^drm-driver:\s*(\S+)\s*$/m;
        my ($pdev) = $text =~ /^drm-pdev:\s*(\S+)\s*$/m;
        my ($client_id) = $text =~ /^drm-client-id:\s*(\d+)\s*$/m;
        next if !defined($driver) || lc($driver) ne 'xe';
        next if !defined($pdev) || lc($pdev) ne $bdf;
        next if !defined($client_id);

        my $resident_kib = 0;
        while ($text =~ /^drm-resident-vram\d*:\s*(\d+(?:\.\d+)?)\s*([KMGT]?i?B)?\s*$/mig) {
            my $kib = _memory_value_kib($1, $2);
            $resident_kib += $kib if defined($kib);
        }

        my %engines;
        my $timestamp_score = 0;
        for my $suffix (keys %$XE_FDINFO_ENGINE_GROUP) {
            my ($busy) = $text =~ /^drm-cycles-\Q$suffix\E:\s*(\d+)\s*$/m;
            my ($total) = $text =~ /^drm-total-cycles-\Q$suffix\E:\s*(\d+)\s*$/m;
            next if !defined($busy) || !defined($total);
            my ($capacity) = $text =~ /^drm-engine-capacity-\Q$suffix\E:\s*(\d+)\s*$/m;
            $capacity = 1 if !defined($capacity) || $capacity < 1;
            $engines{$suffix} = {
                busy => 0 + $busy,
                total => 0 + $total,
                capacity => 0 + $capacity,
            };
            $timestamp_score = $total if $total > $timestamp_score;
        }

        # The same client can appear through card and render-node FDs.  Keep
        # the newest coherent engine snapshot and the largest memory snapshot.
        my $existing = $clients{$client_id};
        if (!defined($existing) || $timestamp_score >= $existing->{timestamp_score}) {
            my $largest_resident = defined($existing) &&
                $existing->{resident_kib} > $resident_kib
                ? $existing->{resident_kib}
                : $resident_kib;
            $clients{$client_id} = {
                resident_kib => $largest_resident,
                engines => \%engines,
                timestamp_score => $timestamp_score,
            };
        } elsif ($resident_kib > $existing->{resident_kib}) {
            $existing->{resident_kib} = $resident_kib;
        }
    }

    return { clients => \%clients };
}

sub _pf_resident_vram_mb_from_snapshot {
    my ($snapshot) = @_;
    return undef if ref($snapshot) ne 'HASH' || ref($snapshot->{clients}) ne 'HASH';

    my $total_kib = 0;
    $total_kib += $_->{resident_kib} // 0 for values %{$snapshot->{clients}};
    return 0 + sprintf('%.1f', $total_kib / 1024);
}

sub read_pf_resident_vram_mb {
    my ($class, $bdf) = @_;
    return _pf_resident_vram_mb_from_snapshot(_read_pf_fdinfo_snapshot($bdf));
}

sub _empty_engine_metrics {
    return {
        gpu_util_pct => undef,
        render_util_pct => undef,
        compute_util_pct => undef,
        media_util_pct => undef,
        copy_util_pct => undef,
    };
}

sub _engine_cache_path {
    my ($bdf, $num_vfs) = @_;
    (my $safe_bdf = $bdf) =~ s/:/_/g;
    my $directory = $ENV{PVE_GPU_TELEMETRY_CACHE_DIR}
        // PVE::API2::Hardware::GPU::sysfs_path('/run/pve-gpu/telemetry');
    return ($directory, "$directory/xe-$safe_bdf-vf$num_vfs.json");
}

sub _read_engine_cache {
    my ($path, $bdf, $num_vfs) = @_;
    my $text = _read_text_file($path);
    return undef if !defined($text);
    my $payload = eval { decode_json($text) };
    return undef if ref($payload) ne 'HASH';
    return undef if ($payload->{bdf} // '') ne $bdf;
    return undef if ($payload->{num_vfs} // -1) != $num_vfs;
    return undef if !defined($payload->{sampled_at}) ||
        time() - $payload->{sampled_at} < 0 ||
        time() - $payload->{sampled_at} >= 1.0;
    return $payload;
}

sub _write_engine_cache {
    my ($directory, $path, $payload) = @_;
    eval {
        make_path($directory, { mode => 0755 }) if !-d $directory;
        my $tmp = "$path.tmp.$$";
        sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644)
            or die "Cannot create telemetry cache '$tmp': $!\n";
        print {$fh} encode_json($payload)
            or die "Cannot write telemetry cache '$tmp': $!\n";
        close($fh) or die "Cannot close telemetry cache '$tmp': $!\n";
        rename($tmp, $path)
            or die "Cannot publish telemetry cache '$path': $!\n";
        1;
    };
    # Telemetry remains available even when /run cannot be written.
    return 1;
}

sub _lock_engine_cache {
    my ($directory, $path) = @_;
    my $lock_fh;
    my $locked = eval {
        make_path($directory, { mode => 0755 }) if !-d $directory;
        sysopen($lock_fh, "$path.lock", O_RDWR | O_CREAT, 0644)
            or die "Cannot open telemetry lock '$path.lock': $!\n";
        flock($lock_fh, LOCK_EX)
            or die "Cannot lock telemetry cache '$path': $!\n";
        1;
    };
    if (!$locked) {
        close($lock_fh) if defined($lock_fh);
        return undef;
    }
    return $lock_fh;
}

sub _calculate_engine_metrics {
    my ($samples) = @_;
    my $result = _empty_engine_metrics();
    my %maximum;

    for my $event (@XE_ENGINE_EVENTS) {
        my $entry = $samples->{$event->{name}};
        next if ref($entry) ne 'HASH';
        my $active = $entry->{active};
        my $total = $entry->{total};
        next if !defined($active) || !defined($total) || $total <= 0;
        my $util = 100 * $active / $total;
        $util = 100 if $util > 100;
        $util = 0 if $util < 0;
        my $group = $event->{group};
        $maximum{$group} = $util
            if !defined($maximum{$group}) || $util > $maximum{$group};
        $maximum{gpu} = $util
            if !defined($maximum{gpu}) || $util > $maximum{gpu};
    }

    for my $group (qw(gpu render compute media copy)) {
        $result->{"${group}_util_pct"} = 0 + sprintf('%.1f', $maximum{$group})
            if defined($maximum{$group});
    }
    return $result;
}

# GuC total ticks are the quanta allocated to one PCI function, not a
# device-wide wall-clock denominator.  Summing the active and total counters
# for the same physical engine across the PF and all enabled VFs produces the
# whole-device utilization.  This also remains correct on BMG firmware which
# currently reports VF work in function 0's active counter while still
# splitting total quanta between every function.
sub _calculate_device_engine_metrics {
    my ($samples, $num_vfs) = @_;
    my %combined;

    for my $event (@XE_ENGINE_EVENTS) {
        for my $function (0 .. $num_vfs) {
            my $entry = $samples->{$function}{$event->{name}};
            next if ref($entry) ne 'HASH';
            next if !defined($entry->{active}) || !defined($entry->{total});
            $combined{$event->{name}}{active} += $entry->{active};
            $combined{$event->{name}}{total} += $entry->{total};
        }
    }

    return _calculate_engine_metrics(\%combined);
}

sub _function_active_ticks {
    my ($samples) = @_;
    my $active = 0;
    for my $event (@XE_ENGINE_EVENTS) {
        my $entry = $samples->{$event->{name}};
        $active += $entry->{active}
            if ref($entry) eq 'HASH' && defined($entry->{active});
    }
    return $active;
}

sub _calculate_pf_fdinfo_metrics {
    my ($before, $after) = @_;
    my $result = _empty_engine_metrics();
    return $result
        if ref($before) ne 'HASH' || ref($before->{clients}) ne 'HASH' ||
           ref($after) ne 'HASH' || ref($after->{clients}) ne 'HASH';

    my (%busy_delta, %largest_capacity_window);
    for my $client_id (keys %{$before->{clients}}) {
        my $old = $before->{clients}{$client_id};
        my $new = $after->{clients}{$client_id};
        next if ref($old) ne 'HASH' || ref($new) ne 'HASH';
        next if ref($old->{engines}) ne 'HASH' || ref($new->{engines}) ne 'HASH';

        for my $suffix (keys %$XE_FDINFO_ENGINE_GROUP) {
            my $old_engine = $old->{engines}{$suffix};
            my $new_engine = $new->{engines}{$suffix};
            next if ref($old_engine) ne 'HASH' || ref($new_engine) ne 'HASH';
            my $busy = $new_engine->{busy} - $old_engine->{busy};
            my $total = $new_engine->{total} - $old_engine->{total};
            next if $busy < 0 || $total <= 0;
            my $capacity = $new_engine->{capacity} // $old_engine->{capacity} // 1;
            $capacity = 1 if $capacity < 1;
            $busy_delta{$suffix} += $busy;
            my $capacity_window = $total * $capacity;
            $largest_capacity_window{$suffix} = $capacity_window
                if !defined($largest_capacity_window{$suffix}) ||
                   $capacity_window > $largest_capacity_window{$suffix};
        }
    }

    my %maximum;
    for my $suffix (keys %$XE_FDINFO_ENGINE_GROUP) {
        my $window = $largest_capacity_window{$suffix};
        next if !defined($window) || $window <= 0;
        my $util = 100 * ($busy_delta{$suffix} // 0) / $window;
        $util = 100 if $util > 100;
        $util = 0 if $util < 0;
        my $group = $XE_FDINFO_ENGINE_GROUP->{$suffix};
        $maximum{$group} = $util
            if !defined($maximum{$group}) || $util > $maximum{$group};
        $maximum{gpu} = $util
            if !defined($maximum{gpu}) || $util > $maximum{gpu};
    }

    for my $group (qw(gpu render compute media copy)) {
        $result->{"${group}_util_pct"} = 0 + sprintf('%.1f', $maximum{$group})
            if defined($maximum{$group});
    }
    return $result;
}

# Sample PF and every enabled VF in one perf process.  The shared /run cache
# lets separate pvedaemon workers serving the device and VF endpoints reuse
# the same sample for approximately one second.
sub read_engine_telemetry {
    my ($class, $bdf, $num_vfs) = @_;
    $bdf = _normalise_bdf($bdf);
    return undef if !defined($bdf);
    $num_vfs //= 0;
    my ($clean_num_vfs) = "$num_vfs" =~ /^(\d{1,2})$/;
    return undef if !defined($clean_num_vfs);
    $num_vfs = 0 + $clean_num_vfs;
    return undef if $num_vfs > 64;

    my ($cache_dir, $cache_path) = _engine_cache_path($bdf, $num_vfs);
    my $cached = _read_engine_cache($cache_path, $bdf, $num_vfs);
    return $cached if defined($cached);

    # Device-list and VF-list requests can land in separate pvedaemon workers
    # at the same instant.  Serialize the first miss, then recheck the cache so
    # only one worker starts perf and every waiter reuses that sample.
    my $cache_lock = _lock_engine_cache($cache_dir, $cache_path);
    if (defined($cache_lock)) {
        $cached = _read_engine_cache($cache_path, $bdf, $num_vfs);
        return $cached if defined($cached);
    }

    my %samples;
    my %metrics;
    $metrics{$_} = _empty_engine_metrics() for 0 .. $num_vfs;

    (my $pmu_bdf = $bdf) =~ s/:/_/g;
    my $pmu = "xe_$pmu_bdf";
    my $pmu_path = PVE::API2::Hardware::GPU::sysfs_path(
        "/sys/bus/event_source/devices/$pmu"
    );

    my ($pf_fdinfo_before, $pf_fdinfo_after);
    my $pf_fdinfo_metrics = _empty_engine_metrics();
    if (-d $pmu_path) {
        $pf_fdinfo_before = _read_pf_fdinfo_snapshot($bdf);
        my @command = ('perf', 'stat', '--no-big-num', '-x,', '-a');
        for my $function (0 .. $num_vfs) {
            for my $event (@XE_ENGINE_EVENTS) {
                for my $counter ([active => '0x02'], [total => '0x03']) {
                    my ($kind, $code) = @$counter;
                    my $alias = "fn${function}_$event->{name}_${kind}";
                    my $spec = "$pmu/event=$code," .
                        "engine_class=$event->{class}," .
                        "engine_instance=$event->{instance}," .
                        "function=$function,gt=$event->{gt},name=$alias/";
                    push @command, '-e', $spec;
                }
            }
        }
        my $sample_seconds = $ENV{PVE_GPU_PMU_SAMPLE_SECONDS} // '0.2';
        my ($clean_sample_seconds) = "$sample_seconds" =~ /^(0(?:\.\d+)?)$/;
        $sample_seconds = defined($clean_sample_seconds) && $clean_sample_seconds > 0
            ? $clean_sample_seconds
            : '0.2';
        push @command, '--', 'sleep', $sample_seconds;

        my $perf_sample_ok = eval {
            run_command(
                \@command,
                timeout => 3,
                outfunc => sub {},
                errfunc => sub {
                    my $line = shift;
                    return if !defined($line);
                    if ($line =~ /^\s*(\d+(?:\.\d+)?),,fn(\d+)_([a-z0-9]+)_(active|total),/) {
                        $samples{$2}{$3}{$4} = 0 + $1;
                    }
                },
            );
            1;
        };
        $pf_fdinfo_after = _read_pf_fdinfo_snapshot($bdf) if $perf_sample_ok;
        for my $function (0 .. $num_vfs) {
            $metrics{$function} = _calculate_engine_metrics(
                $samples{$function} // {}
            );
        }
        if ($perf_sample_ok) {
            $pf_fdinfo_metrics = _calculate_pf_fdinfo_metrics(
                $pf_fdinfo_before,
                $pf_fdinfo_after,
            );
        }
    }

    my $device_metrics = _calculate_device_engine_metrics(\%samples, $num_vfs);
    my %active_ticks_by_function = map {
        $_ => _function_active_ticks($samples{$_} // {})
    } 0 .. $num_vfs;
    my %vfs = map { $_ => $metrics{$_} } 1 .. $num_vfs;
    my $payload = {
        bdf => $bdf,
        num_vfs => $num_vfs,
        sampled_at => time(),
        # Keep the historical key for callers, but report physical-device
        # utilization (including VF work) in the physical-device row.
        pf => $device_metrics,
        device => $device_metrics,
        host_pf => $pf_fdinfo_metrics,
        vfs => \%vfs,
        active_ticks_by_function => \%active_ticks_by_function,
        pf_resident_vram_mb => defined($pf_fdinfo_after)
            ? _pf_resident_vram_mb_from_snapshot($pf_fdinfo_after)
            : $class->read_pf_resident_vram_mb($bdf),
    };
    _write_engine_cache($cache_dir, $cache_path, $payload);
    close($cache_lock) if defined($cache_lock);
    return $payload;
}

sub default_card_pl2_w {
    my ($class, $device_id) = @_;
    return undef if !defined($device_id);
    $device_id = lc($device_id);
    $device_id = "0x$device_id" if $device_id !~ /^0x/;
    return $DEFAULT_CARD_PL2_W->{$device_id};
}

sub read_power_limit {
    my ($class, $card) = @_;
    return {
        supported => \0,
        limit_name => 'Card PL2',
        reason => 'The xe hwmon Card PL2 control is unavailable',
    } if !defined($card) || $card eq '';

    my $hwmon_logical = "/sys/class/drm/$card/device/hwmon";
    my $hwmon_base = PVE::API2::Hardware::GPU::sysfs_path($hwmon_logical);
    for my $directory (bsd_glob("$hwmon_base/hwmon*")) {
        my ($hwmon_name) = $directory =~ m{/([^/]+)\z};
        next if !defined($hwmon_name) || $hwmon_name !~ /^hwmon\d+$/;
        my $name = _read_text_file("$directory/name") // '';
        $name =~ s/\s+\z//;
        next if $name ne '' && $name ne 'xe';
        my $cap_path = "$directory/power1_cap";
        my $raw = _read_text_file($cap_path);
        next if !defined($raw);
        $raw =~ s/\s+\z//;
        next if $raw !~ /^\d+$/;

        my $result = {
            supported => \1,
            writable => -w $cap_path ? \1 : \0,
            limit_name => 'Card PL2',
            current_w => 0 + sprintf('%.1f', $raw / 1_000_000),
            sysfs_path => "$hwmon_logical/$hwmon_name/power1_cap",
        };
        for my $bound (qw(min max)) {
            my $value = _read_text_file("$directory/power1_cap_$bound");
            next if !defined($value);
            $value =~ s/\s+\z//;
            $result->{"${bound}_w"} = 0 + sprintf('%.1f', $value / 1_000_000)
                if $value =~ /^\d+$/;
        }
        return $result;
    }

    return {
        supported => \0,
        limit_name => 'Card PL2',
        reason => 'The xe hwmon Card PL2 control is unavailable',
    };
}

sub write_power_limit {
    my ($class, $card, $watts) = @_;
    die "Power limit must be a positive number of watts\n"
        if !defined($watts) || $watts !~ /^\d+(?:\.\d+)?$/ || $watts <= 0;
    my $status = $class->read_power_limit($card);
    die "$status->{reason}\n" if !${$status->{supported}};
    die "Card PL2 is read-only\n" if !${$status->{writable}};
    my $microwatts = int($watts * 1_000_000 + 0.5);
    PVE::API2::Hardware::GPU::write_sysfs($status->{sysfs_path}, $microwatts);
    my $verified = $class->read_power_limit($card);
    die "Card PL2 disappeared after the write\n" if !${$verified->{supported}};
    die "Card PL2 verification failed: requested $watts W, read back $verified->{current_w} W\n"
        if abs($verified->{current_w} - $watts) > 0.05;
    return $verified;
}

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
        lmem_pf_resident_mb => undef,
        lmem_allocator_used_mb => undef,
        fan_rpm            => undef,
        throttled          => undef,
        health             => 'OK',
        sleeping           => \0,
    };

    if (defined($bdf) && is_deep_idle($bdf)) {
        my $base = "/sys/bus/pci/devices/$bdf";
        $result->{sleeping} = \1;
        $result->{health} = 'Sleeping';
        $result->{power_mode} = 'deep-idle';
        $result->{runtime_status} =
            PVE::API2::Hardware::GPU::read_sysfs("$base/power/runtime_status");
        my $usage = PVE::API2::Hardware::GPU::read_sysfs("$base/power/runtime_usage");
        $result->{runtime_usage} = int($usage)
            if defined($usage) && $usage =~ /^\d+$/;
        my $delay = PVE::API2::Hardware::GPU::read_sysfs(
            "$base/power/autosuspend_delay_ms"
        );
        $result->{autosuspend_delay_ms} = int($delay)
            if defined($delay) && $delay =~ /^-?\d+$/;
        $result->{pci_power_state} =
            PVE::API2::Hardware::GPU::read_sysfs("$base/power_state");
        return $result;
    }

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

    # Clock rate: act_freq is the PCODE-resolved clock actually running now;
    # cur_freq is the GuC request and can remain pinned at max_freq.  A zero
    # act_freq is a valid idle reading; use cur_freq only when act_freq is
    # unavailable or malformed.
    # i915 uses device/tile*/gt_cur_freq_mhz
    if (defined $bdf) {
        my $card_dev = PVE::API2::Hardware::GPU::sysfs_path("/sys/class/drm/$card/device");
        # xe driver path
        my $freq_base = "$card_dev/tile0/gt0/freq0";
        if (-d $freq_base) {
            my $act = _read_text_file("$freq_base/act_freq");
            my $cur = _read_text_file("$freq_base/cur_freq");
            my $max = _read_text_file("$freq_base/max_freq");
            $act =~ s/\s+\z// if defined($act);
            $cur =~ s/\s+\z// if defined($cur);
            $max =~ s/\s+\z// if defined($max);
            if (defined($act) && $act =~ /^\d+$/) {
                $result->{clock_mhz} = int($act);
            } elsif (defined($cur) && $cur =~ /^\d+$/) {
                $result->{clock_mhz} = int($cur);
            }
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

    # VRAM allocator totals.  New xe kernels place vram_mm below tile0;
    # older kernels used vram0_mm at the device root.  Allocator usage includes
    # VF quotas and is therefore kept as a diagnostic value, not PF usage.
    if (defined $bdf) {
        my @vram_mm_paths = map {
            PVE::API2::Hardware::GPU::sysfs_path($_)
        } (
            "/sys/kernel/debug/dri/$bdf/tile0/vram_mm",
            "/sys/kernel/debug/dri/$bdf/vram0_mm",
        );
        for my $vram_mm_path (@vram_mm_paths) {
            next if !open(my $fh, '<', $vram_mm_path);
            my $total_bytes = 0;
            while (my $line = <$fh>) {
                if ($line =~ /^\s*size:\s*(\d+)/) {
                    $total_bytes = $1;
                }
                if ($line =~ /^\s*usage:\s*(\d+)/) {
                    $result->{lmem_allocator_used_mb} = int($1 / (1024 * 1024));
                }
            }
            close($fh);
            $result->{lmem_total_mb} = int($total_bytes / (1024 * 1024)) if $total_bytes > 0;
            last;
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

    # PF/VF engine utilization and PF resident VRAM share one batched Xe PMU
    # sample and one approximately one-second cache.
    if (defined $bdf) {
        my $num_vfs = PVE::API2::Hardware::GPU::read_sysfs(
            "/sys/bus/pci/devices/$bdf/sriov_numvfs"
        );
        $num_vfs = 0 if !defined($num_vfs) || $num_vfs !~ /^\d+$/;
        my $sample = eval { $class->read_engine_telemetry($bdf, int($num_vfs)) };
        if (ref($sample) eq 'HASH') {
            $result->{gpu_util_pct} = $sample->{pf}{gpu_util_pct}
                if ref($sample->{pf}) eq 'HASH';
            $result->{lmem_pf_resident_mb} = $sample->{pf_resident_vram_mb};
            # Backward-compatible field now carries the user-visible PF
            # resident value instead of global allocator/VF quota usage.
            $result->{lmem_used_mb} = $sample->{pf_resident_vram_mb};
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
    my ($class, $bdf, $function_index) = @_;
    $function_index //= 0;
    my $function = $function_index == 0 ? 'pf' : "vf$function_index";
    my $raw = PVE::API2::Hardware::GPU::read_sysfs(
        "/sys/bus/pci/devices/$bdf/sriov_admin/$function/profile/sched_priority"
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
    return ['xe'];
}

# ---------------------------------------------------------------------------
# Plugin interface: run_prechecks
# Returns vendor-specific driver check result
# ---------------------------------------------------------------------------
sub run_prechecks {
    my ($class, $bdf, $card, $driver) = @_;

    my $pass = $driver eq 'xe' ? 1 : 0;
    return {
        pass   => $pass ? \1 : \0,
        detail => $pass
            ? "$driver driver bound"
            : "Driver '$driver' bound (expected xe)",
    };
}

# ---------------------------------------------------------------------------
# Register with GPU framework
# ---------------------------------------------------------------------------
PVE::API2::Hardware::GPU::register_vendor('8086', __PACKAGE__);

1;
