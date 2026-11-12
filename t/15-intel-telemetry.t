#!/usr/bin/perl
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

our $ROOT = tempdir(CLEANUP => 1);
our $RUN_COUNT = 0;
our @LAST_COMMAND;

BEGIN {
    package PVE::Tools;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::run_command"} = \&run_command
            if grep { $_ eq 'run_command' } @symbols;
    }
    sub run_command {
        my ($command, %options) = @_;
        $main::RUN_COUNT++;
        @main::LAST_COMMAND = @$command;
        my $emit = $options{errfunc};
        my %active = (
            '0/render' => 50,
            '0/compute' => 75,
            '1/video0' => 20,
            '2/copy' => 10,
        );
        for my $function (0 .. 2) {
            for my $event (qw(render copy compute video0 video1 enhance0 enhance1)) {
                my $value = $active{"$function/$event"} // 0;
                $emit->("$value,,fn${function}_${event}_active,1,100.00,,");
                $emit->("100,,fn${function}_${event}_total,1,100.00,,");
            }
        }
        return 1;
    }
    $INC{'PVE/Tools.pm'} = 1;

    package PVE::GPU::Power;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::is_deep_idle"} = sub { 0 }
            if grep { $_ eq 'is_deep_idle' } @symbols;
    }
    $INC{'PVE/GPU/Power.pm'} = 1;

    package PVE::GPU::SRIOV;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::active_sched_priority"} = sub { return 'low' }
            if grep { $_ eq 'active_sched_priority' } @symbols;
    }
    $INC{'PVE/GPU/SRIOV.pm'} = 1;

    package PVE::API2::Hardware::GPU;
    sub sysfs_path {
        my ($path) = @_;
        return "$main::ROOT$path";
    }
    sub read_sysfs {
        my ($path) = @_;
        my $full = sysfs_path($path);
        open(my $fh, '<', $full) or return undef;
        my $value = <$fh>;
        close($fh);
        chomp($value) if defined($value);
        return $value;
    }
    sub write_sysfs {
        my ($path, $value) = @_;
        my $full = sysfs_path($path);
        open(my $fh, '>', $full) or die "Cannot write $full: $!";
        print {$fh} $value;
        close($fh) or die "Cannot close $full: $!";
        return 1;
    }
    sub register_vendor { return 1 }
    $INC{'PVE/API2/Hardware/GPU.pm'} = 1;
}

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot create $path: $!";
    print {$fh} $content;
    close($fh) or die "Cannot close $path: $!";
}

my ($safe_lib) = "$FindBin::Bin/../src" =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe test library path\n" if !defined($safe_lib);
unshift @INC, $safe_lib;

$ENV{PVE_GPU_TELEMETRY_CACHE_DIR} = "$ROOT/run/pve-gpu/telemetry";
$ENV{PVE_GPU_PMU_SAMPLE_SECONDS} = '0.01';

require PVE::API2::Hardware::GPU::Intel;

my $bdf = '0000:0b:00.0';
make_path("$ROOT/sys/bus/event_source/devices/xe_0000_0b_00.0");

my $client = <<'FDINFO';
drm-driver: xe
drm-client-id: 7
drm-pdev: 0000:0b:00.0
drm-resident-vram0: 1048576 KiB
drm-cycles-ccs: 1234
drm-total-cycles-ccs: 5678
FDINFO
write_file("$ROOT/proc/100/fdinfo/3", $client);
write_file("$ROOT/proc/100/fdinfo/4", $client); # duplicate FD for client 7
write_file("$ROOT/proc/200/fdinfo/5", <<'FDINFO');
drm-driver: xe
drm-client-id: 8
drm-pdev: 0000:0b:00.0
drm-resident-vram0: 262144 KiB
FDINFO
write_file("$ROOT/proc/300/fdinfo/6", <<'FDINFO');
drm-driver: xe
drm-client-id: 9
drm-pdev: 0000:0c:00.0
drm-resident-vram0: 999999 KiB
FDINFO

is(
    PVE::API2::Hardware::GPU::Intel->read_pf_resident_vram_mb($bdf),
    1280,
    'PF resident VRAM deduplicates DRM FDs and ignores another GPU',
);
my $parsed_fdinfo = PVE::API2::Hardware::GPU::Intel::_read_pf_fdinfo_snapshot($bdf);
is($parsed_fdinfo->{clients}{7}{engines}{ccs}{busy}, 1234,
    'Xe fdinfo snapshot parses per-client compute cycles');
is($parsed_fdinfo->{clients}{7}{engines}{ccs}{capacity}, 1,
    'Xe fdinfo snapshot defaults an omitted engine capacity to one');

my $fdinfo_before = {
    clients => {
        7 => {
            engines => {
                rcs => { busy => 0, total => 10_000, capacity => 1 },
                bcs => { busy => 200, total => 10_000, capacity => 1 },
                ccs => { busy => 1_000, total => 10_000, capacity => 1 },
                vcs => { busy => 0, total => 10_000, capacity => 2 },
                vecs => { busy => 0, total => 10_000, capacity => 2 },
            },
        },
        8 => {
            engines => {
                rcs => { busy => 0, total => 10_000, capacity => 1 },
                bcs => { busy => 100, total => 10_000, capacity => 1 },
                ccs => { busy => 500, total => 10_000, capacity => 1 },
                vcs => { busy => 0, total => 10_000, capacity => 2 },
                vecs => { busy => 0, total => 10_000, capacity => 2 },
            },
        },
    },
};
my $fdinfo_after = {
    clients => {
        7 => {
            engines => {
                rcs => { busy => 0, total => 11_000, capacity => 1 },
                bcs => { busy => 400, total => 11_000, capacity => 1 },
                ccs => { busy => 1_994, total => 11_000, capacity => 1 },
                vcs => { busy => 500, total => 11_000, capacity => 2 },
                vecs => { busy => 0, total => 11_000, capacity => 2 },
            },
        },
        8 => {
            engines => {
                rcs => { busy => 0, total => 11_000, capacity => 1 },
                bcs => { busy => 100, total => 11_000, capacity => 1 },
                ccs => { busy => 500, total => 11_000, capacity => 1 },
                vcs => { busy => 0, total => 11_000, capacity => 2 },
                vecs => { busy => 0, total => 11_000, capacity => 2 },
            },
        },
    },
};
my $fdinfo_metrics = PVE::API2::Hardware::GPU::Intel::_calculate_pf_fdinfo_metrics(
    $fdinfo_before,
    $fdinfo_after,
);
is($fdinfo_metrics->{gpu_util_pct}, 99.4,
    'PF fdinfo reports the busiest real engine instead of GuC quanta ratio');
is($fdinfo_metrics->{compute_util_pct}, 99.4,
    'PF fdinfo aggregates compute work from every DRM client');
is($fdinfo_metrics->{copy_util_pct}, 20,
    'PF fdinfo calculates copy utilization in the GPU clock domain');
is($fdinfo_metrics->{media_util_pct}, 25,
    'PF fdinfo normalises grouped media engines by reported capacity');

my $sample = PVE::API2::Hardware::GPU::Intel->read_engine_telemetry($bdf, 2);
is($RUN_COUNT, 1, 'PF and both VFs use one perf invocation');
is($sample->{pf}{gpu_util_pct}, 25,
    'physical-device GPU utilization uses all function quanta');
is($sample->{pf}{render_util_pct}, 16.7,
    'physical-device render utilization includes idle VF quanta');
is($sample->{pf}{compute_util_pct}, 25,
    'physical-device compute utilization includes PF and VF quanta');
ok(!exists($sample->{vf_function0_recovery}),
    'function 0 scheduling quanta are not repackaged as VF utilization');
is($sample->{vfs}{1}{media_util_pct}, 20, 'VF1 media utilization is parsed');
is($sample->{vfs}{1}{gpu_util_pct}, 20, 'VF1 aggregate utilization is parsed');
is($sample->{vfs}{2}{copy_util_pct}, 10, 'VF2 copy utilization is parsed');
is($sample->{active_ticks_by_function}{0}, 125,
    'cache records function 0 active ticks for attribution diagnostics');
is($sample->{active_ticks_by_function}{1}, 20,
    'cache records VF1 active ticks for attribution diagnostics');
is($sample->{active_ticks_by_function}{2}, 10,
    'cache records VF2 active ticks for attribution diagnostics');
is($sample->{pf_resident_vram_mb}, 1280, 'PMU cache carries PF resident VRAM');

my @events = grep { $LAST_COMMAND[$_] eq '-e' } 0 .. $#LAST_COMMAND;
is(scalar(@events), 42, 'one command contains seven active/total engine pairs for PF and two VFs');
is(scalar(grep { /xpu-smi/ } @LAST_COMMAND), 0, 'native PMU sampling does not invoke xpu-smi');

my $cached = PVE::API2::Hardware::GPU::Intel->read_engine_telemetry($bdf, 2);
is($RUN_COUNT, 1, 'a second read within one second reuses the shared cache');
is($cached->{vfs}{2}{gpu_util_pct}, 10, 'cached VF telemetry preserves values');
ok(
    -f "$ENV{PVE_GPU_TELEMETRY_CACHE_DIR}/xe-0000_0b_00.0-vf2.json.lock",
    'shared PMU cache uses a cross-process lock for simultaneous API requests',
);

my $hwmon = "$ROOT/sys/class/drm/card1/device/hwmon/hwmon7";
write_file("$hwmon/name", "xe\n");
write_file("$hwmon/power1_cap", "60000000\n");
my $limit = PVE::API2::Hardware::GPU::Intel->read_power_limit('card1');
ok(${$limit->{supported}}, 'xe power1_cap is exposed as Card PL2');
is($limit->{current_w}, 60, 'Card PL2 reports microwatts as watts');
is(PVE::API2::Hardware::GPU::Intel->default_card_pl2_w('0xe212'), 73,
    'B50 restore profile retains its verified 73 W original Card PL2');

my $written = PVE::API2::Hardware::GPU::Intel->write_power_limit('card1', 55.5);
is($written->{current_w}, 55.5, 'Card PL2 write is read back and verified');
open(my $cap_fh, '<', "$hwmon/power1_cap") or die $!;
my $raw_cap = <$cap_fh>;
close($cap_fh);
is($raw_cap, '55500000', 'Card PL2 writes the exact microwatt sysfs value');

my $freq_base = "$ROOT/sys/class/drm/card1/device/tile0/gt0/freq0";
write_file("$freq_base/act_freq", "0\n");
write_file("$freq_base/cur_freq", "1200\n");
write_file("$freq_base/max_freq", "2600\n");
my $frequency = PVE::API2::Hardware::GPU::Intel->read_telemetry(
    'card1',
    $bdf,
    'xe',
);
is($frequency->{clock_mhz}, 0,
    'xe current frequency preserves a real zero act_freq while idle');
is($frequency->{clock_max_mhz}, 2600,
    'xe frequency reports the configured maximum');
unlink("$freq_base/act_freq") or die "Cannot remove fake act_freq: $!";
$frequency = PVE::API2::Hardware::GPU::Intel->read_telemetry(
    'card1',
    $bdf,
    'xe',
);
is($frequency->{clock_mhz}, 1200,
    'xe current frequency falls back when act_freq is unavailable');
write_file("$freq_base/act_freq", "2100\n");
$frequency = PVE::API2::Hardware::GPU::Intel->read_telemetry(
    'card1',
    $bdf,
    'xe',
);
is($frequency->{clock_mhz}, 2100,
    'a positive PCODE-resolved act_freq is the actual current frequency');

# pvedaemon loads API modules under perl -T.  Exercise the real telemetry
# command builder with BDF, VF count, and sample duration arriving through
# tainted argv/environment values, and reject any tainted command argument in
# the run_command double.  This catches failures that ordinary pvesh and this
# test process (without -T) cannot reproduce.
my ($taint_perl) = $^X =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe Perl interpreter path\n" if !defined($taint_perl);
my $taint_program = <<'PERL';
use strict;
use warnings;
use Scalar::Util qw(tainted);

BEGIN {
    package PVE::Tools;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::run_command"} = \&run_command
            if grep { $_ eq 'run_command' } @symbols;
    }
    sub run_command {
        my ($command, %options) = @_;
        die "tainted PMU command argument\n"
            if grep { Scalar::Util::tainted($_) } @$command;
        my $emit = $options{errfunc};
        $emit->('0,,fn0_render_active,1,100.00,,');
        $emit->('100,,fn0_render_total,1,100.00,,');
        $emit->('0,,fn1_compute_active,1,100.00,,');
        $emit->('100,,fn1_compute_total,1,100.00,,');
        $emit->('0,,fn2_copy_active,1,100.00,,');
        $emit->('100,,fn2_copy_total,1,100.00,,');
        return 1;
    }
    $INC{'PVE/Tools.pm'} = 1;

    package PVE::GPU::Power;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::is_deep_idle"} = sub { 0 }
            if grep { $_ eq 'is_deep_idle' } @symbols;
    }
    $INC{'PVE/GPU/Power.pm'} = 1;

    package PVE::GPU::SRIOV;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::active_sched_priority"} = sub { 'low' }
            if grep { $_ eq 'active_sched_priority' } @symbols;
    }
    $INC{'PVE/GPU/SRIOV.pm'} = 1;

    package PVE::API2::Hardware::GPU;
    sub sysfs_path { return "$main::ROOT$_[0]" }
    sub read_sysfs { return undef }
    sub write_sysfs { return 1 }
    sub register_vendor { return 1 }
    $INC{'PVE/API2/Hardware/GPU.pm'} = 1;
}

my ($root_raw, $bdf, $num_vfs, $sample_seconds) = @ARGV;
my ($root) = $root_raw =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe fixture root\n" if !defined($root);
$main::ROOT = $root;
$ENV{PVE_GPU_TELEMETRY_CACHE_DIR} = "$root/run/pve-gpu/telemetry-taint";
$ENV{PVE_GPU_PMU_SAMPLE_SECONDS} = $sample_seconds;

require PVE::API2::Hardware::GPU::Intel;
my $sample = PVE::API2::Hardware::GPU::Intel->read_engine_telemetry(
    $bdf,
    $num_vfs,
);
die "taint-mode PMU sample failed\n"
    if ref($sample) ne 'HASH' || $sample->{vfs}{2}{copy_util_pct} != 0;
PERL

is(
    system(
        $taint_perl,
        '-T',
        '-I', $safe_lib,
        '-e', $taint_program,
        $ROOT,
        $bdf,
        '2',
        '0.01',
    ),
    0,
    'Xe PMU command arguments are untainted under pvedaemon perl -T',
);

done_testing();
