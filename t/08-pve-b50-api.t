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
my $qemu_dir = "$root/etc/pve/qemu-server";
make_path(dirname($config), $qemu_dir);

$ENV{PVE_GPU_SYSFS_ROOT} = $root;
$ENV{PVE_GPU_SRIOV_CONF} = $config;
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
is(PVE::API2::Hardware::GPU::_read_scheduler_priority($live_rec), 'low',
    'scheduler read requires and reports the same value from every VF');
write_file("$pf_path/sriov_admin/vf2/profile/sched_priority", '[normal] low');
is(PVE::API2::Hardware::GPU::_read_scheduler_priority($live_rec), 'mixed',
    'mixed per-VF scheduler state is reported explicitly');
eval { PVE::API2::Hardware::GPU::_snapshot_state($live_rec) };
like($@, qr/consistent BMG scheduler profile/,
    'a transaction cannot snapshot and overwrite mixed scheduler state');
write_file("$pf_path/sriov_admin/vf2/profile/sched_priority", '[low] normal');

my $live_vfs = PVE::API2::Hardware::GPU::_vf_records($live_rec);
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
        'unchanged', 1, { count => 0, scheduler => undef }, 2),
    'low',
    'first VF creation resolves unchanged to the safe low scheduler');
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

done_testing();
