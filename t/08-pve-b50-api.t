#!/usr/bin/perl
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP qw(encode_json);
use Test::More;

delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';

my $root = tempdir(CLEANUP => 1);
my $config = "$root/etc/pve/local/gpu-sriov.conf";
my $power_limit_config = "$root/etc/pve/local/gpu-power-limit.conf";
my $qemu_dir = "$root/etc/pve/qemu-server";
make_path(dirname($config), $qemu_dir);

$ENV{PVE_GPU_SYSFS_ROOT} = $root;
$ENV{PVE_GPU_SRIOV_CONF} = $config;
$ENV{PVE_GPU_POWER_LIMIT_CONF} = $power_limit_config;
$ENV{PVE_GPU_QEMU_CONF_DIR} = $qemu_dir;
$ENV{PVE_GPU_SRIOV_LOCK} = "$root/sriov.lock";
$ENV{PVE_GPU_PCI_RESERVATION_LOCK} = "$root/pci-id-reservations.lock";

my ($safe_lib) = "$FindBin::Bin/../src" =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe test library path\n" if !defined($safe_lib);
unshift @INC, $safe_lib;
eval { require PVE::API2::Hardware::GPU; 1 }
    or plan skip_all => "PVE Perl modules are unavailable: $@";

sub write_file {
    my ($path, $value) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot create $path: $!";
    print {$fh} $value;
    close($fh);
}

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot read $path: $!";
    local $/;
    my $value = <$fh>;
    close($fh);
    chomp($value);
    return $value;
}

my $pf = '0000:0b:00.0';
my $pf_path = "$root/sys/bus/pci/devices/$pf";
for my $pair (
    [vendor => '0x8086'],
    [device => '0xe212'],
    [subsystem_vendor => '0x8086'],
    [subsystem_device => '0x0000'],
    [numa_node => '0'],
    [sriov_totalvfs => '2'],
    [sriov_numvfs => '2'],
    [sriov_drivers_autoprobe => '0'],
) {
    write_file("$pf_path/$pair->[0]", $pair->[1]);
}
make_path("$root/sys/module/xe");
symlink("$root/sys/module/xe", "$pf_path/driver") or die $!;
make_path("$root/sys/class/drm/card0");
symlink($pf_path, "$root/sys/class/drm/card0/device") or die $!;
write_file("$pf_path/hwmon/hwmon0/name", "xe\n");
write_file("$pf_path/hwmon/hwmon0/power1_cap", "60000000\n");
make_path("$root/sys/class/iommu/dmar0");
write_file("$root/proc/cpuinfo", "flags: vmx\n");

my @vram = (8 * 1024**3, 6 * 1024**3);
for my $vf (1 .. 2) {
    my $vf_bdf = "0000:0b:00.$vf";
    my $vf_path = "$root/sys/bus/pci/devices/$vf_bdf";
    make_path($vf_path, "$root/sys/bus/pci/drivers/vfio-pci");
    symlink($pf_path, "$vf_path/physfn") or die $!;
    symlink("$root/sys/bus/pci/drivers/vfio-pci", "$vf_path/driver") or die $!;
    symlink($vf_path, "$pf_path/virtfn" . ($vf - 1)) or die $!;

    my $tile = "$root/sys/kernel/debug/dri/$pf/sriov/vf$vf/tile0";
    write_file("$tile/vram_quota", $vram[$vf - 1]);
    write_file("$tile/ggtt_quota", 1024**3);
    for my $gt (0 .. 1) {
        write_file("$tile/gt$gt/contexts_quota", 16384);
        write_file("$tile/gt$gt/doorbells_quota", 64);
        write_file("$tile/gt$gt/exec_quantum_ms", 0);
        write_file("$tile/gt$gt/preempt_timeout_us", 0);
        write_file("$tile/gt$gt/sched_priority", 0);
    }
}

my $pf_debug = "$root/sys/kernel/debug/dri/$pf/sriov/pf/tile0";
write_file("$pf_debug/vram_spare", 128 * 1024**2);
write_file("$pf_debug/ggtt_spare", 128 * 1024**2);
for my $gt (0 .. 1) {
    write_file("$pf_debug/gt$gt/contexts_spare", 1024);
    write_file("$pf_debug/gt$gt/doorbells_spare", 8);
}
write_file("$root/sys/kernel/debug/dri/$pf/sriov/restore_auto_provisioning", 0);
write_file("$pf_path/sriov_admin/pf/profile/sched_priority", '[low] normal');
write_file("$pf_path/sriov_admin/vf1/profile/sched_priority", '[low] normal');
write_file("$pf_path/sriov_admin/vf2/profile/sched_priority", '[low] normal');
write_file("$pf_path/sriov_admin/.bulk_profile/sched_priority", 'low');
write_file("$root/sys/bus/pci/drivers_probe", '');

sub custom_profile {
    my ($vf, $vram_quota, $contexts, $doorbells) = @_;
    return {
        vf_index => $vf,
        resources => {
            vram => { mode => 'custom', quota => $vram_quota },
            ggtt => { mode => 'custom', quota => 1024**3 },
            contexts => { mode => 'custom', quota => $contexts },
            doorbells => { mode => 'custom', quota => $doorbells },
            exec_quantum_ms => { mode => 'custom', quota => 0 },
            preempt_timeout_us => { mode => 'custom', quota => 0 },
        },
    };
}

my $profiles = [
    custom_profile(1, 8 * 1024**3, 16384, 64),
    custom_profile(2, 6 * 1024**3, 8192, 32),
];
my $result = PVE::API2::Hardware::GPU::_configure_sriov_v2($pf, {
    num_vfs => 2,
    vf_profiles => encode_json($profiles),
    sched_priority => 'low',
    drivers_autoprobe => 0,
    persist => 1,
});

ok(${$result->{success}}, 'same-count per-VF transaction succeeds in fake sysfs');
is($result->{sriov_numvfs}, 2, 'VF count remains two');
is(scalar(@{$result->{vfs}}), 2, 'response contains both VFs');
is($result->{vfs}[0]{vram_quota}, 8 * 1024**3, 'response preserves VF1 8 GiB');
is($result->{vfs}[1]{vram_quota}, 6 * 1024**3, 'response preserves VF2 6 GiB');

my $vf2_tile = "$root/sys/kernel/debug/dri/$pf/sriov/vf2/tile0";
is(read_file("$vf2_tile/gt0/contexts_quota"), 8192,
    'VF2 contexts are written to GT0');
is(read_file("$vf2_tile/gt1/contexts_quota"), 8192,
    'VF2 contexts are written to GT1');
is(read_file("$vf2_tile/gt0/doorbells_quota"), 32,
    'VF2 doorbells are written to GT0');
is(read_file("$vf2_tile/gt1/doorbells_quota"), 32,
    'VF2 doorbells are written to GT1');
is(read_file("$vf2_tile/vram_quota"), 6 * 1024**3,
    'VF2 VRAM uses the tile-scoped xe vram_quota path');

# A forced topology rebuild must resolve an unchanged scheduler while the old
# VFs still exist.  Capture the value handed to persistence to ensure the
# post-rebuild default cannot replace the transaction-before scheduler.
my @persisted_schedulers;
my $persist_profiles_impl = \&PVE::API2::Hardware::GPU::_persist_profiles;
{
    no warnings 'redefine';
    local *PVE::API2::Hardware::GPU::_persist_profiles = sub {
        my ($rec, $profiles, $scheduler) = @_;
        push @persisted_schedulers, $scheduler;
        return $persist_profiles_impl->(@_);
    };
    # The ordinary-file fixture cannot model kernel VF unbind/rebind, but the
    # transaction and its scheduler resolution remain real.
    local *PVE::API2::Hardware::GPU::_unbind_all_vfs = sub { return 1 };
    local *PVE::API2::Hardware::GPU::_restore_reprovisioned_drivers = sub { return 1 };
    my $rebuild = PVE::API2::Hardware::GPU::_configure_sriov_v2($pf, {
        num_vfs => 2,
        vf_profiles => encode_json($profiles),
        sched_priority => 'unchanged',
        drivers_autoprobe => 0,
        force_reprovision => 1,
        persist => 1,
    });
    ok($rebuild && ${$rebuild->{success}},
        'forced VF topology rebuild succeeds with unchanged scheduler');
}
is($persisted_schedulers[-1], 'low',
    'topology rebuild persists the scheduler captured before VF recreation');
my $rebuild_config = PVE::API2::Hardware::GPU::parse_ini_config($config);
is($rebuild_config->{$pf}{sched_priority}, 'low',
    'topology rebuild does not persist the new-VF default scheduler');

my $persisted = read_file($config);
like($persisted, qr/^\[$pf\/vf1\]$/m, 'persistence contains a VF1 section');
like($persisted, qr/^\[$pf\/vf2\]$/m, 'persistence contains a VF2 section');
like($persisted, qr/^vram_mode = custom$/m, 'persistence records explicit custom mode');
like($persisted, qr/^driver = vfio-pci$/m, 'persistence records the VF driver');

my $auto_profiles = [@$profiles];
$auto_profiles->[0] = {
    %{$profiles->[0]},
    resources => {
        %{$profiles->[0]{resources}},
        vram => { mode => 'auto' },
    },
};
eval {
    PVE::API2::Hardware::GPU::_configure_sriov_v2($pf, {
        num_vfs => 2,
        vf_profiles => encode_json($auto_profiles),
        sched_priority => 'unchanged',
        persist => 1,
    });
};
like($@, qr/requires force_reprovision=1/,
    'custom to auto cannot silently leave the old quota in place');

eval {
    PVE::API2::Hardware::GPU::_configure_sriov_v2($pf, {
        num_vfs => 2,
        vf_profiles => encode_json($profiles),
        sched_priority => 'normal',
        persist => 1,
    });
};
like($@, qr/requires allow_unsafe_scheduler=1/,
    'normal scheduler requires explicit experimental acknowledgement');

my $live_rec = PVE::API2::Hardware::GPU::_collect_device($pf, 0);
my $power_limit = PVE::API2::Hardware::GPU::_power_limit_status($pf);
ok(${$power_limit->{supported}}, 'B50 xe Card PL2 is available');
is($power_limit->{current_w}, 60, 'live Card PL2 is read in watts');
is($power_limit->{original_w}, 73, 'B50 restore value uses the verified device profile');

my $limited = PVE::API2::Hardware::GPU::_change_power_limit($pf, 'set', 55, 1);
is($limited->{current_w}, 55, 'Card PL2 changes immediately');
ok(${$limited->{persistent}}, 'Card PL2 override is marked for boot persistence');
is($limited->{persistent_w}, 55, 'boot persistence stores the requested Card PL2');
is(read_file("$pf_path/hwmon/hwmon0/power1_cap"), 55_000_000,
    'live power1_cap write is verified in microwatts');
my $power_config = PVE::API2::Hardware::GPU::parse_ini_config($power_limit_config, 1);
is($power_config->{$pf}{original_w}, 73, 'persistent state retains the original limit');
is($power_config->{$pf}{persistent_w}, 55, 'persistent state retains the boot limit');

my $restored = PVE::API2::Hardware::GPU::_change_power_limit($pf, 'restore', undef, 0);
is($restored->{current_w}, 73, 'Restore Original returns Card PL2 to 73 W');
ok(!${$restored->{persistent}}, 'Restore Original clears boot persistence');
$power_config = PVE::API2::Hardware::GPU::parse_ini_config($power_limit_config, 1);
ok(!exists($power_config->{$pf}), 'Restore Original removes the per-BDF override section');

is(PVE::API2::Hardware::GPU::_read_scheduler_priority($live_rec), 'low',
    'scheduler read requires the same value from the PF and every VF');
write_file("$pf_path/sriov_admin/vf2/profile/sched_priority", '[normal] low');
is(PVE::API2::Hardware::GPU::_read_scheduler_priority($live_rec), 'mixed',
    'mixed per-VF scheduler state is reported explicitly');
write_file("$pf_path/sriov_admin/vf2/profile/sched_priority", '[low] normal');
write_file("$pf_path/sriov_admin/pf/profile/sched_priority", '[normal] low');
is(PVE::API2::Hardware::GPU::_read_scheduler_priority($live_rec), 'mixed',
    'a PF scheduler mismatch is reported explicitly');
eval { PVE::API2::Hardware::GPU::_snapshot_state($live_rec) };
like($@, qr/consistent BMG scheduler profile/,
    'a transaction cannot snapshot and overwrite a mismatched PF scheduler');

my $scheduler_writes = 0;
{
    no warnings 'redefine';
    local *PVE::API2::Hardware::GPU::Intel::set_scheduler_priority = sub {
        $scheduler_writes++;
        write_file("$pf_path/sriov_admin/vf1/profile/sched_priority", '[low] normal');
        write_file("$pf_path/sriov_admin/vf2/profile/sched_priority", '[low] normal');
        return 1;
    };
    eval { PVE::API2::Hardware::GPU::_set_scheduler_priority($live_rec, 'low') };
    like($@, qr/Scheduler verification failed.*mixed/,
        'scheduler verification fails when a bulk update leaves the PF unchanged');
}
is($scheduler_writes, 1,
    'a matching VF state does not short-circuit a mismatched PF scheduler');
{
    no warnings 'redefine';
    local *PVE::API2::Hardware::GPU::Intel::set_scheduler_priority = sub {
        write_file("$pf_path/sriov_admin/pf/profile/sched_priority", '[low] normal');
        write_file("$pf_path/sriov_admin/vf1/profile/sched_priority", '[low] normal');
        write_file("$pf_path/sriov_admin/vf2/profile/sched_priority", '[low] normal');
        return 1;
    };
    eval { PVE::API2::Hardware::GPU::_set_scheduler_priority($live_rec, 'low') };
    is($@, '', 'scheduler verification succeeds only after PF and all VFs match');
}

my $live_vfs = PVE::API2::Hardware::GPU::_vf_records($live_rec);

subtest 'Windows QGA telemetry replaces unattributable BMG scheduling quanta' => sub {
    my $guest_metrics = PVE::API2::Hardware::GPU::_parse_windows_guest_engine_telemetry(
        encode_json({
            adapters => [
                {
                    name => 'luid_0x00000000_0x00007BBC_phys_0',
                    dedicated => 1_896_734_720,
                    shared => 123_564_032,
                    committed => 2_328_932_352,
                },
                {
                    name => 'luid_0x00000000_0x00007B55_phys_0',
                    dedicated => 0,
                    shared => 16_384,
                    committed => 3_227_648,
                },
            ],
            engines => [
                { name => 'pid_11388_luid_0x00000000_0x00007BBC_phys_0_eng_0_engtype_3D', value => 81.5 },
                { name => 'pid_1560_luid_0x00000000_0x00007BBC_phys_0_eng_0_engtype_3D', value => 3.2 },
                { name => 'pid_6576_luid_0x00000000_0x00007BBC_phys_0_eng_0_engtype_3D', value => 2.4 },
                { name => 'pid_6576_luid_0x00000000_0x00007BBC_phys_0_eng_1_engtype_VideoDecode', value => 7.6 },
                { name => 'pid_9999_luid_0x00000000_0x00007B55_phys_0_eng_0_engtype_3D', value => 99 },
            ],
        }),
    );
    is($guest_metrics->{gpu_util_pct}, 87.1,
        'overall guest GPU is the busiest physical B50 engine');
    is($guest_metrics->{render_util_pct}, 87.1,
        '3D clients sharing one engine are summed once');
    is($guest_metrics->{compute_util_pct}, 0,
        'Compute remains independent from overall GPU and Render');
    is($guest_metrics->{media_util_pct}, 7.6,
        'VideoDecode is grouped under Media');

    write_file("$qemu_dir/202.conf", "hostpci0: 0000:0b:00.2,rombar=0,pcie=1\n");
    {
        no warnings 'redefine';
        local *PVE::API2::Hardware::GPU::_vm_is_running = sub { return $_[0] == 202 };
        local *PVE::API2::Hardware::GPU::_read_windows_guest_engine_telemetry = sub {
            is($_[0], 202, 'guest telemetry is requested once for the running VM');
            return $guest_metrics;
        };
        local *PVE::API2::Hardware::GPU::Intel::read_engine_telemetry = sub {
            return {
                device => {
                    gpu_util_pct => 16.7,
                    render_util_pct => 0,
                    compute_util_pct => 16.7,
                    media_util_pct => 0,
                    copy_util_pct => 0,
                },
                host_pf => { gpu_util_pct => 0 },
                vfs => {
                    1 => { map { $_ => 0 } qw(gpu_util_pct render_util_pct compute_util_pct media_util_pct copy_util_pct) },
                    2 => { map { $_ => 0 } qw(gpu_util_pct render_util_pct compute_util_pct media_util_pct copy_util_pct) },
                },
                active_ticks_by_function => { 0 => 50, 1 => 0, 2 => 0 },
            };
        };
        my $vfs = PVE::API2::Hardware::GPU::_vf_records($live_rec, 1);
        is($vfs->[0]{compute_util_pct}, 0,
            'stopped VF keeps its direct idle PMU value');
        is($vfs->[1]{gpu_util_pct}, 87.1,
            'running VF receives the live guest overall GPU value');
        is($vfs->[1]{render_util_pct}, 87.1,
            'running VF receives the guest 3D value as Render');
        is($vfs->[1]{compute_util_pct}, 0,
            'running VF does not relabel 3D work as Compute');
        is($vfs->[1]{engine_util_source}, 'windows-pdh-qga',
            'guest-assisted utilization is explicitly labelled');
    }

    {
        no warnings 'redefine';
        local *PVE::API2::Hardware::GPU::_vm_is_running = sub { return $_[0] == 202 };
        local *PVE::API2::Hardware::GPU::_read_windows_guest_engine_telemetry = sub { return undef };
        local *PVE::API2::Hardware::GPU::Intel::read_engine_telemetry = sub {
            return {
                device => { gpu_util_pct => 16.7, compute_util_pct => 16.7 },
                host_pf => { gpu_util_pct => 0 },
                vfs => {
                    1 => { gpu_util_pct => 0, compute_util_pct => 0 },
                    2 => { gpu_util_pct => 0, compute_util_pct => 0 },
                },
                active_ticks_by_function => { 0 => 50, 1 => 0, 2 => 0 },
            };
        };
        my $vfs = PVE::API2::Hardware::GPU::_vf_records($live_rec, 1);
        is($vfs->[1]{compute_util_pct}, undef,
            'function 0 scheduling quanta are hidden when guest telemetry is unavailable');
        is($vfs->[1]{engine_util_source}, 'xe-pmu-attribution-unavailable',
            'unavailable actual utilization is explicit rather than fixed at 50 percent');
    }

    write_file("$qemu_dir/201.conf", "hostpci0: 0000:0b:00.1,rombar=0,pcie=1\n");
    {
        no warnings 'redefine';
        local *PVE::API2::Hardware::GPU::_vm_is_running = sub { return 1 };
        local *PVE::API2::Hardware::GPU::_read_windows_guest_engine_telemetry = sub { return undef };
        local *PVE::API2::Hardware::GPU::Intel::read_engine_telemetry = sub {
            return {
                device => { gpu_util_pct => 16.7, compute_util_pct => 16.7 },
                host_pf => { gpu_util_pct => 0 },
                vfs => {
                    1 => { gpu_util_pct => 0, compute_util_pct => 0 },
                    2 => { gpu_util_pct => 0, compute_util_pct => 0 },
                },
                active_ticks_by_function => { 0 => 50, 1 => 0, 2 => 0 },
            };
        };
        my $vfs = PVE::API2::Hardware::GPU::_vf_records($live_rec, 1);
        is($vfs->[0]{compute_util_pct}, undef,
            'multiple running VFs are not given invented utilization');
        is($vfs->[1]{engine_util_source}, 'xe-pmu-attribution-unavailable',
            'ambiguous multi-VF attribution is explicitly labelled');
    }
    unlink("$qemu_dir/201.conf") or die $!;
    unlink("$qemu_dir/202.conf") or die $!;
};

my $missing_persistence = PVE::API2::Hardware::GPU::_calculate_persistence_drift(
    $live_rec,
    {},
    $live_vfs,
    'low',
);
ok($missing_persistence->{has_drift} && $missing_persistence->{persistence} &&
    $missing_persistence->{count},
    'live VFs without persistent sections are reported as drift');

my $persist_config = PVE::API2::Hardware::GPU::parse_ini_config($config);
my $unreadable_scheduler = PVE::API2::Hardware::GPU::_calculate_persistence_drift(
    $live_rec,
    $persist_config,
    $live_vfs,
    undef,
);
ok($unreadable_scheduler->{scheduler} &&
    $unreadable_scheduler->{scheduler_unreadable},
    'an unreadable live scheduler is reported as drift');

subtest 'persistence cannot be removed while PF/VF assignments remain' => sub {
    my $before = read_file($config);
    for my $consumer (
        [$pf, 'PF'],
        ['0000:0b:00.1', 'VF'],
    ) {
        write_file(
            "$qemu_dir/999.conf",
            "hostpci0: $consumer->[0],rombar=0\n",
        );
        {
            no warnings 'redefine';
            local *PVE::API2::Hardware::GPU::_with_vm_locks = sub {
                my ($vmids, $code) = @_;
                return $code->();
            };
            local *PVE::API2::Hardware::GPU::_vm_is_running = sub { return 0 };
            eval {
                PVE::API2::Hardware::GPU::_configure_sriov_v2($pf, {
                    num_vfs => 2,
                    vf_profiles => encode_json($profiles),
                    sched_priority => 'unchanged',
                    drivers_autoprobe => 0,
                    persist => 0,
                });
            };
        }
        like($@, qr/Cannot disable SR-IOV persistence.*VM999/,
            "$consumer->[1] assignment blocks persist=0");
        is(read_file($config), $before,
            "$consumer->[1] rejection preserves the persistent profile");
    }
    unlink("$qemu_dir/999.conf") or die $!;
};

write_file("$qemu_dir/999.conf", "hostpci0: definitely-not-a-bdf\n");
eval {
    PVE::API2::Hardware::GPU::check_vf_vm_assignments($pf, 'card0', 2, 1);
};
like($@, qr/Invalid hostpci BDF/,
    'strict mutation scan fails closed on an invalid hostpci entry');
ok(-e "$root/pci-id-reservations.lock",
    'transaction used an isolated PVE PCI reservation lock');

is(PVE::API2::Hardware::GPU::_scheduler_for_transaction(
        'unchanged', 1, { count => 2, scheduler => 'low' }, 2),
    'low',
    'topology rebuild resolves unchanged to the snapshotted scheduler');
is(PVE::API2::Hardware::GPU::_scheduler_for_transaction(
        'unchanged', 1, { count => 0, scheduler => 'normal' }, 2),
    'normal',
    'first VF creation preserves the snapshotted PF scheduler');
eval {
    PVE::API2::Hardware::GPU::_scheduler_for_transaction(
        'unchanged', 1, { count => 0, scheduler => undef }, 2);
};
like($@, qr/Cannot preserve an unreadable or mixed scheduler/,
    'first VF creation cannot replace an unreadable PF scheduler with low');
eval {
    PVE::API2::Hardware::GPU::_scheduler_for_transaction(
        'unchanged', 1, { count => 2, scheduler => 'mixed' }, 2);
};
like($@, qr/Cannot preserve an unreadable or mixed scheduler/,
    'mixed scheduler state cannot be silently lost during reprovision');

write_file("$pf_path/sriov_numvfs", 'unreadable');
eval { PVE::API2::Hardware::GPU::_collect_device($pf, 0) };
like($@, qr/Cannot read a valid non-negative integer/,
    'an invalid live VF count cannot be represented as zero in a device record');
eval { PVE::API2::Hardware::GPU::_snapshot_state($live_rec) };
like($@, qr/Cannot read a valid non-negative integer/,
    'an unreadable live VF count fails closed instead of becoming zero');
write_file("$pf_path/sriov_numvfs", '-1');
eval { PVE::API2::Hardware::GPU::_snapshot_state($live_rec) };
like($@, qr/Cannot read a valid non-negative integer/,
    'a negative live VF count fails closed instead of becoming zero');
unlink("$pf_path/sriov_numvfs") or die "Cannot remove sriov_numvfs fixture: $!";
eval { PVE::API2::Hardware::GPU::_collect_device($pf, 0) };
like($@, qr/Cannot read a valid non-negative integer/,
    'a missing live VF count fails closed instead of becoming zero');
write_file("$pf_path/sriov_numvfs", 2);

for my $unsupported (
    ['0000:0c:00.0', '0x10de', '0x1287', 'unregistered Nvidia device'],
    ['0000:0d:00.0', '0x8086', '0x56c0', 'unsupported Intel Flex device'],
) {
    my ($bdf, $vendor, $device, $label) = @$unsupported;
    write_file("$root/sys/bus/pci/devices/$bdf/vendor", $vendor);
    write_file("$root/sys/bus/pci/devices/$bdf/device", $device);
    my $record;
    eval { $record = PVE::API2::Hardware::GPU::_collect_device($bdf, 0) };
    is($@, '', "$label is skipped without reading absent SR-IOV controls");
    is($record, undef, "$label is not enumerated");
}

my $persist_flag_config = PVE::API2::Hardware::GPU::parse_ini_config($config, 1);
$persist_flag_config->{$pf}{persist} = 0;
PVE::API2::Hardware::GPU::write_ini_config($config, $persist_flag_config);
my $not_persisted = PVE::API2::Hardware::GPU::_collect_device($pf, 0);
ok(!${$not_persisted->{persisted}},
    'device grid persistence follows persist=0 rather than section presence');
my $disabled_vfs = PVE::API2::Hardware::GPU::_vf_records($not_persisted);
is($disabled_vfs->[0]{resources}{vram}{mode}, 'unknown',
    'a disabled device section is not used as VF resource provenance');
my $disabled_drift = PVE::API2::Hardware::GPU::_calculate_persistence_drift(
    $not_persisted,
    $persist_flag_config,
    $disabled_vfs,
    'low',
);
ok($disabled_drift->{has_drift} && $disabled_drift->{persistence},
    'persist=0 is reported as non-restorable configuration drift');
ok(PVE::API2::Hardware::GPU::_profiles_require_auto_reprovision(
        $not_persisted,
        $auto_profiles,
        $persist_flag_config,
    ),
    'auto mode cannot trust a disabled persisted profile');
ok(!PVE::API2::Hardware::GPU::_profiles_require_auto_reprovision(
        $not_persisted,
        $profiles,
        $persist_flag_config,
    ),
    'all-custom profiles do not require reprovision merely because persistence is disabled');

$persist_flag_config->{$pf}{sched_priority} = 'normal';
$persist_flag_config->{$pf}{allow_unsafe_scheduler} = 1;
PVE::API2::Hardware::GPU::write_ini_config($config, $persist_flag_config);
eval {
    PVE::API2::Hardware::GPU::_persist_profiles(
        $not_persisted,
        $profiles,
        'normal',
        0,
        1,
        0,
        'unchanged',
    );
};
like($@, qr/requires allow_unsafe_scheduler=1/,
    'a disabled profile cannot donate its prior normal-scheduler acknowledgement');

$persist_flag_config->{$pf}{persist} = 1;
$persist_flag_config->{$pf}{sched_priority} = 'low';
$persist_flag_config->{$pf}{allow_unsafe_scheduler} = 0;
PVE::API2::Hardware::GPU::write_ini_config($config, $persist_flag_config);

my $invalid_driver_config = PVE::API2::Hardware::GPU::parse_ini_config($config, 1);
$invalid_driver_config->{"$pf/vf1"}{driver} = 'i915';
my $invalid_driver_drift = PVE::API2::Hardware::GPU::_calculate_persistence_drift(
    $live_rec,
    $invalid_driver_config,
    $live_vfs,
    'low',
);
ok($invalid_driver_drift->{has_drift} && $invalid_driver_drift->{persistence},
    'an unsupported persisted BMG VF driver is reported as drift');
like(join('; ', @{$invalid_driver_drift->{issues}}), qr/VF1.*unsupported.*i915/,
    'driver drift identifies the invalid VF profile');

my $invalid_ack_config = PVE::API2::Hardware::GPU::parse_ini_config($config, 1);
$invalid_ack_config->{$pf}{allow_unsafe_scheduler} = 2;
my $invalid_ack_drift = PVE::API2::Hardware::GPU::_calculate_persistence_drift(
    $live_rec,
    $invalid_ack_config,
    $live_vfs,
    'low',
);
ok($invalid_ack_drift->{has_drift} && $invalid_ack_drift->{scheduler},
    'an invalid unsafe-scheduler acknowledgement is reported as drift');

my $scheduler_rollback_calls = 0;
{
    no warnings 'redefine';
    local *PVE::API2::Hardware::GPU::_read_sriov_numvfs = sub { return 0 };
    local *PVE::API2::Hardware::GPU::_set_scheduler_priority = sub {
        my ($rec, $scheduler) = @_;
        $scheduler_rollback_calls++ if $scheduler eq 'normal';
        return 1;
    };
    local *PVE::API2::Hardware::GPU::_set_autoprobe = sub { return 1 };
    my $rollback_errors = PVE::API2::Hardware::GPU::_rollback_state(
        $live_rec,
        {
            count => 0,
            autoprobe => 1,
            scheduler => 'normal',
            path_values => {},
            drivers => [],
            config => undef,
        },
        0,
    );
    is_deeply($rollback_errors, [], 'zero-VF API rollback completes cleanly');
}
is($scheduler_rollback_calls, 1,
    'zero-VF API rollback restores the snapshotted PF scheduler');

done_testing();
