#!/usr/bin/perl
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $bash = '/bin/bash';
my $version = `$bash -c 'printf "%s" "\${BASH_VERSINFO[0]}"'`;
plan skip_all => 'power-limit boot restore test requires Bash 4 or newer'
    if !$version || $version < 4;

my $script = "$FindBin::Bin/../src/scripts/apply-power-limit.sh";
ok(-x $script || -f $script, 'power-limit restore script exists');

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot create $path: $!";
    print {$fh} $content;
    close($fh) or die "Cannot close $path: $!";
}

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot read $path: $!";
    my $content = <$fh>;
    close($fh);
    chomp($content);
    return $content;
}

sub run_restore {
    my ($root, $config) = @_;
    local %ENV = %ENV;
    $ENV{PVE_GPU_SYSFS_ROOT} = $root;
    $ENV{PVE_GPU_POWER_LIMIT_CONF} = $config;
    return system($bash, $script) >> 8;
}

my $root = tempdir(CLEANUP => 1);
my $bdf = '0000:0b:00.0';
my $pci = "$root/sys/bus/pci/devices/$bdf";
my $driver = "$root/sys/bus/pci/drivers/xe";
my $cap = "$pci/hwmon/hwmon7/power1_cap";
my $config = "$root/etc/pve/local/gpu-power-limit.conf";
make_path($pci, $driver);
symlink($driver, "$pci/driver") or die $!;
write_file("$pci/device", "0xe212\n");
write_file("$pci/hwmon/hwmon7/name", "xe\n");
write_file($cap, "60000000\n");
write_file($config, <<CONF);
[$bdf]
api_version = 1
device_id = 0xe212
original_w = 73
persist = 1
persistent_w = 55.5
CONF

is(run_restore($root, $config), 0, 'boot restore accepts a valid per-BDF Card PL2 policy');
is(read_file($cap), '55500000', 'boot restore writes and verifies exact microwatts');

write_file($cap, "60000000\n");
write_file($config, <<CONF);
[$bdf]
api_version = 1
device_id = 0xe212
original_w = 73
persist = 0
CONF
is(run_restore($root, $config), 0, 'an immediate-only record is a valid no-op at boot');
is(read_file($cap), '60000000', 'persist=0 does not touch Card PL2 during boot');

write_file($config, <<CONF);
[$bdf]
api_version = 1
device_id = 0xe211
original_w = 73
persist = 1
persistent_w = 55
CONF
is(run_restore($root, $config), 0, 'a reused BDF with another device ID is skipped safely');
is(read_file($cap), '60000000', 'device-ID mismatch cannot write another PCI device');

write_file($config, <<CONF);
[$bdf]
api_version = 1
device_id = 0xe212
persist = 1
persistent_w = 500
CONF
isnt(run_restore($root, $config), 0, 'malformed or unsafe boot power limits fail validation');
is(read_file($cap), '60000000', 'an unsafe persistent value is rejected before sysfs write');

open(my $script_fh, '<', $script) or die $!;
local $/;
my $source = <$script_fh>;
close($script_fh);
unlike($source, qr/(?:^|[;&|])\s*xpu-smi\b/m,
    'boot persistence does not execute xpu-smi');

done_testing();
