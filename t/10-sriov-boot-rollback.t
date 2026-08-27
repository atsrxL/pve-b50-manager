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

my $output = '';
my $exit_code;
{
    local %ENV = %ENV;
    $ENV{PATH} = "$fake/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    $ENV{PVE_GPU_SYSFS_ROOT} = $fake;
    $ENV{PVE_GPU_SRIOV_CONF} = $config;
    $ENV{PVE_GPU_SRIOV_LOCK} = "$fake/sriov.lock";
    $ENV{PVE_GPU_SRIOV_WAIT_SECONDS} = 1;

    open(my $pipe, '-|', '/bin/bash', $script) or die "Cannot run boot restore: $!";
    local $/;
    $output = <$pipe> // '';
    close($pipe);
    $exit_code = $? >> 8;
}

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

done_testing();
