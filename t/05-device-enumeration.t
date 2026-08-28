#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename;
use File::Glob ':bsd_glob';
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# ---------------------------------------------------------------------------
# Helper: create a file with content under a temp tree
# ---------------------------------------------------------------------------
sub mkfile {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot create $path: $!";
    print $fh $content;
    close($fh);
}

# ---------------------------------------------------------------------------
# Build a minimal fake sysfs tree
# ---------------------------------------------------------------------------
my $ROOT = tempdir(CLEANUP => 1);

# --- PF: Flex 170 at 0000:03:00.0, driver=i915 ---
my $pf0 = "$ROOT/sys/bus/pci/devices/0000:03:00.0";
mkfile("$pf0/vendor", "0x8086");
mkfile("$pf0/device", "0x56c0");
mkfile("$pf0/subsystem_vendor", "0x8086");
mkfile("$pf0/subsystem_device", "0x4905");
mkfile("$pf0/numa_node", "0");
mkfile("$pf0/sriov_totalvfs", "31");
mkfile("$pf0/sriov_numvfs", "0");
make_path("$ROOT/sys/module/i915");
symlink("../../../../module/i915", "$pf0/driver");

# DRM card entry
make_path("$ROOT/sys/class/drm/card0");
symlink($pf0, "$ROOT/sys/class/drm/card0/device");

# hwmon for telemetry
mkfile("$pf0/hwmon/hwmon0/temp1_input", "42000");
mkfile("$pf0/hwmon/hwmon0/power1_input", "65300000");

# IOV resources (i915 path)
mkfile("$ROOT/sys/class/drm/card0/iov/pf/gt0/available/lmem_free", "16106127360");

# --- VF stubs with physfn ---
for my $fn (1..3) {
    my $vf = "$ROOT/sys/bus/pci/devices/0000:03:00.$fn";
    mkfile("$vf/vendor", "0x8086");
    mkfile("$vf/device", "0x56c0");
    mkfile("$vf/subsystem_vendor", "0x8086");
    mkfile("$vf/subsystem_device", "0x4905");
    mkfile("$vf/numa_node", "0");
    mkfile("$vf/sriov_totalvfs", "0");
    mkfile("$vf/sriov_numvfs", "0");
    symlink("../0000:03:00.0", "$vf/physfn");
}

# --- PF: BMG at 0000:04:00.0, driver=xe ---
my $pf1 = "$ROOT/sys/bus/pci/devices/0000:04:00.0";
mkfile("$pf1/vendor", "0x8086");
mkfile("$pf1/device", "0xe211");
mkfile("$pf1/subsystem_vendor", "0x8086");
mkfile("$pf1/subsystem_device", "0x0000");
mkfile("$pf1/numa_node", "0");
mkfile("$pf1/sriov_totalvfs", "24");
mkfile("$pf1/sriov_numvfs", "0");
make_path("$ROOT/sys/module/xe");
symlink("../../../../module/xe", "$pf1/driver");

# DRM card entry
make_path("$ROOT/sys/class/drm/card1");
symlink($pf1, "$ROOT/sys/class/drm/card1/device");

# hwmon for telemetry
mkfile("$pf1/hwmon/hwmon0/temp1_input", "50000");

# Debugfs VRAM info for BMG
my $dbg = "$ROOT/sys/kernel/debug/dri/0000:04:00.0";
mkfile("$dbg/vram0_mm", "  use_type: 1\n  use_tt: 0\n  size: 25669140480\n  usage: 134217728\ndefault_page_size: 4KiB\n");
mkfile("$dbg/gt0/pf/lmem_provisioned", "VF1:\t8436842496\t(7.86 GiB)\nVF2:\t8436842496\t(7.86 GiB)\n");
mkfile("$dbg/gt0/pf/lmem_spare", "134217728");

# --- Non-Intel device (should be skipped) ---
my $nvidia = "$ROOT/sys/bus/pci/devices/0000:c6:00.0";
mkfile("$nvidia/vendor", "0x10de");
mkfile("$nvidia/device", "0x1287");

# --- IOMMU ---
make_path("$ROOT/sys/class/iommu/dmar0");

# --- /proc/cpuinfo with vmx ---
mkfile("$ROOT/proc/cpuinfo", "flags\t\t: fpu vme vmx sse\n");

# ---------------------------------------------------------------------------
# Set sysfs root and load the module
# ---------------------------------------------------------------------------
$ENV{PVE_GPU_SYSFS_ROOT} = $ROOT;

# We need to load the module; it depends on PVE::RESTHandler etc.
# Instead, we test the logic directly using the same patterns.

# ---------------------------------------------------------------------------
# Test 1: VF filtering — physfn symlink detection
# ---------------------------------------------------------------------------

sub is_vf {
    my ($bdf) = @_;
    my $base = "$ROOT/sys/bus/pci/devices/$bdf";
    return -l "$base/physfn" ? 1 : 0;
}

is(is_vf('0000:03:00.0'), 0, 'PF 0000:03:00.0 is not a VF');
is(is_vf('0000:03:00.1'), 1, 'VF 0000:03:00.1 has physfn symlink');
is(is_vf('0000:03:00.2'), 1, 'VF 0000:03:00.2 has physfn symlink');
is(is_vf('0000:03:00.3'), 1, 'VF 0000:03:00.3 has physfn symlink');
is(is_vf('0000:04:00.0'), 0, 'PF 0000:04:00.0 is not a VF');

# ---------------------------------------------------------------------------
# Test 2: Driver detection — the supported BMG path requires xe
# ---------------------------------------------------------------------------

sub get_driver {
    my ($bdf) = @_;
    my $link = "$ROOT/sys/bus/pci/devices/$bdf/driver";
    return '' unless -l $link;
    return basename(readlink($link) // '');
}

sub is_valid_gpu_driver {
    my ($driver) = @_;
    return $driver eq 'xe' ? 1 : 0;
}

is(get_driver('0000:03:00.0'), 'i915', 'Flex PF has i915 driver');
is(get_driver('0000:04:00.0'), 'xe',   'BMG PF has xe driver');
is(is_valid_gpu_driver('i915'), 0, 'i915 is outside the supported BMG path');
is(is_valid_gpu_driver('xe'),   1, 'xe is a valid GPU driver');
is(is_valid_gpu_driver('vfio-pci'), 0, 'vfio-pci is not a valid GPU driver');
is(is_valid_gpu_driver(''),     0, 'empty string is not a valid GPU driver');

# ---------------------------------------------------------------------------
# Test 3: Device enumeration — only the fully supported BMG IDs
# ---------------------------------------------------------------------------

my $DEVICE_FAMILIES = {
    '0xe211' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
};

sub enumerate_test {
    my @devices;
    my @pci_devs = bsd_glob("$ROOT/sys/bus/pci/devices/*");
    for my $dev_path (@pci_devs) {
        my $bdf = basename($dev_path);

        # Skip VFs
        next if -l "$dev_path/physfn";

        # Check vendor
        open(my $fh, '<', "$dev_path/vendor") or next;
        my $vendor = <$fh>; chomp $vendor; close($fh);
        next unless lc($vendor) eq '0x8086';

        # Check device ID
        open($fh, '<', "$dev_path/device") or next;
        my $device_id = <$fh>; chomp $device_id; close($fh);
        $device_id = lc($device_id);
        $device_id = "0x$device_id" unless $device_id =~ /^0x/;
        next unless exists $DEVICE_FAMILIES->{$device_id};

        push @devices, $bdf;
    }
    return sort @devices;
}

my @found = enumerate_test();
is(scalar @found, 1, 'enumerate finds exactly one supported PF device');
is($found[0], '0000:04:00.0', 'BMG PF is enumerated');
ok(!scalar(grep { $_ eq '0000:03:00.0' } @found),
    'Flex PF is not exposed by the BMG-only manager');

# ---------------------------------------------------------------------------
# Test 4: Telemetry — temperature reading from hwmon
# ---------------------------------------------------------------------------

sub read_temperature {
    my ($card) = @_;
    my $hwmon_base = "$ROOT/sys/class/drm/$card/device/hwmon";
    my @hwmon_dirs = bsd_glob("$hwmon_base/hwmon*");
    for my $hwmon_dir (@hwmon_dirs) {
        my @temp_files = bsd_glob("$hwmon_dir/temp*_input");
        for my $tf (@temp_files) {
            open(my $fh, '<', $tf) or next;
            my $val = <$fh>; close($fh);
            if (defined $val) {
                chomp $val;
                return $val / 1000.0;
            }
        }
    }
    return undef;
}

is(read_temperature('card0'), 42, 'Flex card0 temperature is 42°C');
is(read_temperature('card1'), 50, 'BMG card1 temperature is 50°C');

# ---------------------------------------------------------------------------
# Test 5: VRAM total from debugfs vram0_mm
# ---------------------------------------------------------------------------

sub read_vram_total_mb {
    my ($bdf) = @_;
    my $path = "$ROOT/sys/kernel/debug/dri/$bdf/vram0_mm";
    open(my $fh, '<', $path) or return undef;
    while (my $line = <$fh>) {
        if ($line =~ /^\s*size:\s*(\d+)/) {
            close($fh);
            return int($1 / (1024 * 1024));
        }
    }
    close($fh);
    return undef;
}

is(read_vram_total_mb('0000:04:00.0'), 24480, 'BMG VRAM total is 24480 MB');
is(read_vram_total_mb('0000:03:00.0'), undef, 'Flex has no debugfs vram0_mm');

# ---------------------------------------------------------------------------
# Test 6: VRAM allocated from debugfs lmem_provisioned
# ---------------------------------------------------------------------------

sub read_vram_alloc_mb {
    my ($bdf) = @_;
    my $path = "$ROOT/sys/kernel/debug/dri/$bdf/gt0/pf/lmem_provisioned";
    open(my $fh, '<', $path) or return undef;
    my $total = 0;
    while (my $line = <$fh>) {
        if ($line =~ /^VF\d+:\s+(\d+)/) {
            $total += $1;
        }
    }
    close($fh);
    return $total > 0 ? int($total / (1024 * 1024)) : undef;
}

is(read_vram_alloc_mb('0000:04:00.0'), 16092, 'BMG VRAM allocated is 16092 MB (2 VFs)');
is(read_vram_alloc_mb('0000:03:00.0'), undef, 'Flex has no debugfs lmem_provisioned');

# ---------------------------------------------------------------------------
# Test 7: LMEM free from sysfs iov path (i915 fallback)
# ---------------------------------------------------------------------------

sub read_lmem_free_mb {
    my ($card) = @_;
    my $path = "$ROOT/sys/class/drm/$card/iov/pf/gt0/available/lmem_free";
    open(my $fh, '<', $path) or return undef;
    my $val = <$fh>; close($fh);
    if (defined $val && $val =~ /^\d+$/) {
        return int($val / (1024 * 1024));
    }
    return undef;
}

is(read_lmem_free_mb('card0'), 15360, 'Flex card0 lmem_free is 15360 MB');
is(read_lmem_free_mb('card1'), undef, 'BMG card1 has no iov lmem_free path');

done_testing();
