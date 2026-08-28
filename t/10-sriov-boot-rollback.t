#!/usr/bin/perl
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $bash_version = qx{/bin/bash --version 2>/dev/null};
my ($bash_major) = $bash_version =~ /version (\d+)/;
if (!defined($bash_major) || $bash_major !~ /^\d+$/ || $bash_major < 4) {
    plan skip_all => 'multi-PF boot restore test requires Bash 4 or newer';
}

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $script = File::Spec->catfile($root, 'src', 'scripts', 'apply-sriov-config.sh');

sub write_file {
    my ($path, $data) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $data;
    close($fh) or die "Cannot close $path: $!";
    chmod(0666, $path) or die "Cannot chmod $path: $!";
}

sub symlink_force {
    my ($target, $path) = @_;
    unlink($path) if -e $path || -l $path;
    symlink($target, $path) or die "Cannot symlink $path: $!";
}

sub setup_pf {
    my ($fake_root, $bdf, $device, $count, $complete, $vram) = @_;
    my $pf = "$fake_root/sys/bus/pci/devices/$bdf";
    make_path($pf, "$fake_root/sys/module/xe");
    write_file("$pf/vendor", '0x8086');
    write_file("$pf/device", $device);
    write_file("$pf/sriov_totalvfs", '2');
    write_file("$pf/sriov_numvfs", "$count\n");
    write_file("$pf/sriov_drivers_autoprobe", "1\n");
    symlink_force("$fake_root/sys/module/xe", "$pf/driver");
    write_file("$pf/sriov_admin/.bulk_profile/sched_priority", "low\n");
    write_file("$pf/sriov_admin/pf/profile/sched_priority", "low\n");

    my $vf = "$fake_root/sys/bus/pci/devices/$bdf";
    my $vf_bdf = $bdf;
    $vf_bdf =~ s/\.0$/.1/;
    my $vf_path = "$fake_root/sys/bus/pci/devices/$vf_bdf";
    make_path($vf_path);
    write_file("$vf_path/vendor", '0x8086');
    write_file("$vf_path/device", $device);
    write_file("$vf_path/driver_override", "(null)\n");
    symlink_force($vf_path, "$pf/virtfn0");
    write_file("$pf/sriov_admin/vf1/profile/sched_priority", "low\n");

    my $base = "$fake_root/sys/kernel/debug/dri/$bdf/sriov/vf1/tile0";
    make_path($base);
    write_file("$fake_root/sys/kernel/debug/dri/$bdf/sriov/restore_auto_provisioning", "0\n");
    if ($complete) {
        write_file("$base/vram_quota", "$vram\n");
        write_file("$base/ggtt_quota", "268435456\n");
        for my $resource (
            [contexts_quota => 8],
            [doorbells_quota => 8],
            [exec_quantum_ms => 10],
            [preempt_timeout_us => 100],
        ) {
            write_file("$base/gt0/$resource->[0]", "$resource->[1]\n");
        }
    } else {
        write_file("$base/vram_quota", "268435456\n");
        write_file("$base/ggtt_quota", "268435456\n");
    }
}

sub run_sriov_script {
    my ($fake_root, $config_path, @arguments) = @_;
    my ($output, $exit_code);
    {
        local %ENV = %ENV;
        $ENV{PATH} = "$fake_root/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        $ENV{PVE_GPU_SYSFS_ROOT} = $fake_root;
        $ENV{PVE_GPU_SRIOV_CONF} = $config_path;
        $ENV{PVE_GPU_SRIOV_LOCK} = "$fake_root/sriov.lock";
        $ENV{PVE_GPU_SRIOV_WAIT_SECONDS} = 1;

        open(my $pipe, '-|', '/bin/bash', $script, @arguments)
            or die "Cannot run SR-IOV restore script: $!";
        local $/;
        $output = <$pipe> // '';
        close($pipe);
        $exit_code = $? >> 8;
    }
    return ($output, $exit_code);
}

my $fake = tempdir(CLEANUP => 1);
make_path(
    "$fake/sys/kernel/debug",
    "$fake/sys/bus/pci/drivers",
    "$fake/bin",
);
write_file("$fake/sys/bus/pci/drivers_probe", "\n");

# macOS has no system flock; this test only needs a non-blocking lock shim.
write_file("$fake/bin/flock", "#!/bin/sh\nexit 0\n");
chmod(0755, "$fake/bin/flock") or die "Cannot make flock shim executable: $!";

setup_pf($fake, '0000:01:00.0', '0xe211', 1, 1, 268435456);
setup_pf($fake, '0000:02:00.0', '0xe211', 0, 0, 268435456);

my $config = "$fake/etc/pve/local/gpu-sriov.conf";
write_file($config, <<'CONFIG');
[0000:01:00.0]
api_version = 2
persist = 1
device_id = 0xe211
family = bmg
num_vfs = 1
drivers_autoprobe = 1
sched_priority = low

[0000:01:00.0/vf1]
vram_mode = custom
vram_quota = 134217728
ggtt_mode = auto
contexts_mode = auto
doorbells_mode = auto
exec_quantum_ms_mode = auto
preempt_timeout_us_mode = auto

[0000:02:00.0]
api_version = 2
persist = 1
device_id = 0xe211
family = bmg
num_vfs = 1
drivers_autoprobe = 1
sched_priority = low

[0000:02:00.0/vf1]
driver = vfio-pci
vram_mode = auto
ggtt_mode = auto
contexts_mode = auto
doorbells_mode = auto
exec_quantum_ms_mode = auto
preempt_timeout_us_mode = auto
CONFIG

my ($output, $exit_code) = run_sriov_script($fake, $config);

isnt($exit_code, 0, 'later PF failure makes the multi-PF restore fail');
is(scalar(() = $output =~ /Attempting rollback for 0000:02:00\.0/g), 1,
    'the failing PF is rolled back') or diag($output);
is(scalar(() = $output =~ /Attempting rollback for 0000:01:00\.0/g), 1,
    'the earlier PF is rolled back');
cmp_ok(
    index($output, 'Attempting rollback for 0000:02:00.0'),
    '<',
    index($output, 'Attempting rollback for 0000:01:00.0'),
    'completed PFs are rolled back in reverse order',
);

is(slurp("$fake/sys/bus/pci/devices/0000:01:00.0/sriov_numvfs"), "1\n",
    'earlier PF VF topology is restored');
is(slurp("$fake/sys/bus/pci/devices/0000:01:00.0/sriov_drivers_autoprobe"), "1\n",
    'earlier PF autoprobe state is restored');
is(slurp("$fake/sys/kernel/debug/dri/0000:01:00.0/sriov/vf1/tile0/vram_quota"), "268435456\n",
    'earlier PF resource values are restored');
is(slurp("$fake/sys/bus/pci/devices/0000:02:00.0/sriov_numvfs"), "0\n",
    'failing PF VF topology is restored');

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot read $path: $!";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

{
    my $migration_root = tempdir(CLEANUP => 1);
    make_path(
        "$migration_root/sys/kernel/debug",
        "$migration_root/sys/bus/pci/drivers",
        "$migration_root/bin",
    );
    write_file("$migration_root/sys/bus/pci/drivers_probe", "\n");
    write_file("$migration_root/bin/flock", "#!/bin/sh\nexit 0\n");
    chmod(0755, "$migration_root/bin/flock") or die "Cannot make flock shim executable: $!";
    setup_pf($migration_root, '0000:03:00.0', '0xe223', 1, 1, 5368709120);

    my $legacy_config = "$migration_root/etc/pve/local/gpu-sriov.conf";
    write_file($legacy_config, <<'LEGACY');
[0000:03:00.0]
persist = 1
device_id = 0xdead
family = bmg
num_vfs = 2
lmem_per_vf = 5368709120
ggtt_per_vf = 536870912
contexts_per_vf = 32768
doorbells_per_vf = 128
exec_quantum_ms = 10
preempt_timeout_us = 100
drivers_autoprobe = 1

[0000:03:00.0/vf2]
lmem_quota = 4294967296
exec_quantum_ms = 20
LEGACY

    my ($migration_output, $migration_exit) =
        run_sriov_script($migration_root, $legacy_config, '--migrate-only');
    is($migration_exit, 0, 'legacy uniform config migrates without applying topology')
        or diag($migration_output);
    my $migrated = slurp($legacy_config);
    like($migrated, qr/^api_version = 2$/m, 'migration writes api_version 2');
    like($migrated, qr/^device_id = 0xe223$/m,
        'migration takes device ID from the exact configured BDF');
    like($migrated, qr/^family = bmg_12vf$/m,
        'migration derives the BMG family from the exact live device');
    like($migrated, qr/^sched_priority = low$/m,
        'migration records the legacy low scheduler policy explicitly');
    my ($vf1_config) = $migrated =~ /^\[0000:03:00\.0\/vf1\]\n(.*?)(?=^\[|\z)/ms;
    my ($vf2_config) = $migrated =~ /^\[0000:03:00\.0\/vf2\]\n(.*?)(?=^\[|\z)/ms;
    like($vf1_config, qr/^vram_mode = custom\n^vram_quota = 5368709120$/m,
        'uniform VF1 VRAM becomes an explicit custom quota');
    like($vf2_config, qr/^vram_mode = custom\n^vram_quota = 4294967296$/m,
        'legacy per-VF VRAM override is retained exactly');
    like($vf2_config, qr/^exec_quantum_ms_mode = custom\n^exec_quantum_ms_quota = 20$/m,
        'legacy per-VF timer override is retained exactly');
    like($vf2_config, qr/^driver = xe$/m,
        'a not-yet-created VF retains legacy autoprobe-to-xe behavior');
    unlike($migrated, qr/^lmem_per_vf\s*=/m,
        'legacy uniform resource keys are removed');

    my ($second_output, $second_exit) =
        run_sriov_script($migration_root, $legacy_config, '--migrate-only');
    is($second_exit, 0, 'second migration check succeeds') or diag($second_output);
    is(slurp($legacy_config), $migrated,
        'v1 to v2 migration is byte-for-byte idempotent');
    my @migration_temps = glob("$legacy_config.migrate.*");
    is(scalar(@migration_temps), 0, 'atomic migration leaves no temporary file');
}

{
    my $scheduler_root = tempdir(CLEANUP => 1);
    make_path(
        "$scheduler_root/sys/kernel/debug",
        "$scheduler_root/sys/bus/pci/drivers",
        "$scheduler_root/bin",
    );
    write_file("$scheduler_root/sys/bus/pci/drivers_probe", "\n");
    write_file("$scheduler_root/bin/flock", "#!/bin/sh\nexit 0\n");
    chmod(0755, "$scheduler_root/bin/flock") or die "Cannot make flock shim executable: $!";
    setup_pf($scheduler_root, '0000:04:00.0', '0xe212', 1, 1, 5368709120);
    write_file(
        "$scheduler_root/sys/bus/pci/devices/0000:04:00.0/sriov_admin/pf/profile/sched_priority",
        "normal\n",
    );

    my $scheduler_config = "$scheduler_root/etc/pve/local/gpu-sriov.conf";
    write_file($scheduler_config, <<'SCHEDULER');
[0000:04:00.0]
api_version = 2
persist = 1
device_id = 0xe212
family = bmg
num_vfs = 1
drivers_autoprobe = 1
sched_priority = low

[0000:04:00.0/vf1]
vram_mode = auto
ggtt_mode = auto
contexts_mode = auto
doorbells_mode = auto
exec_quantum_ms_mode = auto
preempt_timeout_us_mode = auto
SCHEDULER

    my ($scheduler_output, $scheduler_exit) =
        run_sriov_script($scheduler_root, $scheduler_config);
    isnt($scheduler_exit, 0, 'boot restore rejects a PF/VF scheduler mismatch');
    like($scheduler_output, qr/inconsistent across PF\/VFs/,
        'scheduler validation reports that PF and VF profiles disagree');
}

{
    my $cold_root = tempdir(CLEANUP => 1);
    make_path(
        "$cold_root/sys/kernel/debug",
        "$cold_root/sys/bus/pci/drivers",
        "$cold_root/bin",
    );
    write_file("$cold_root/sys/bus/pci/drivers_probe", "\n");
    write_file("$cold_root/bin/flock", "#!/bin/sh\nexit 0\n");
    chmod(0755, "$cold_root/bin/flock") or die "Cannot make flock shim executable: $!";
    setup_pf($cold_root, '0000:05:00.0', '0xe212', 0, 1, 5368709120);

    my $pf_scheduler =
        "$cold_root/sys/bus/pci/devices/0000:05:00.0/sriov_admin/pf/profile/sched_priority";
    my $bulk_scheduler =
        "$cold_root/sys/bus/pci/devices/0000:05:00.0/sriov_admin/.bulk_profile/sched_priority";
    write_file($pf_scheduler, "normal\n");
    symlink_force($pf_scheduler, $bulk_scheduler);

    my $cold_config = "$cold_root/etc/pve/local/gpu-sriov.conf";
    write_file($cold_config, <<'COLD');
[0000:05:00.0]
api_version = 2
persist = 1
device_id = 0xe212
family = bmg
num_vfs = 1
drivers_autoprobe = 1
sched_priority = low

[0000:05:00.0/vf1]
driver = vfio-pci
vram_mode = auto
ggtt_mode = auto
contexts_mode = auto
doorbells_mode = auto
exec_quantum_ms_mode = auto
preempt_timeout_us_mode = auto
COLD

    my ($cold_output, $cold_exit) = run_sriov_script($cold_root, $cold_config);
    isnt($cold_exit, 0, 'later failure rolls back a cold-start topology apply');
    is(slurp("$cold_root/sys/bus/pci/devices/0000:05:00.0/sriov_numvfs"), "0\n",
        'cold-start rollback restores zero VFs');
    is(slurp($pf_scheduler), "normal\n",
        'cold-start rollback restores the PF scheduler even when the snapshot had zero VFs');
    unlike($cold_output, qr/ROLLBACK ERROR: Cannot restore scheduler/,
        'zero-VF scheduler rollback completes successfully');
}

done_testing();
