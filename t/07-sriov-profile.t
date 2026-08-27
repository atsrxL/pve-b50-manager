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

use lib do {
    my ($safe_lib) = "$FindBin::Bin/../src" =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
    die "Unsafe test library path\n" if !defined($safe_lib);
    $safe_lib;
};
use PVE::GPU::SRIOV qw(
    active_sched_priority
    decode_vf_profiles
    effective_max_vfs
    normalise_resource_profile
    untaint_sysfs_write_path
);

is(effective_max_vfs(24, 2), 2, 'live sriov_totalvfs limits the B50 UI maximum');
is(effective_max_vfs(24, 0), 24, 'declared maximum is fallback when live value is absent');
is(effective_max_vfs(0, 2), 2, 'live maximum works without a static map entry');

is(active_sched_priority('[low] normal'), 'low', 'active low scheduler is parsed');
is(active_sched_priority('low [normal]'), 'normal', 'active normal scheduler is parsed');
is(active_sched_priority('0'), 'low', 'debugfs numeric low scheduler is parsed');
is(active_sched_priority('1'), 'normal', 'debugfs numeric normal scheduler is parsed');
is(active_sched_priority('garbage'), undef, 'unknown scheduler values fail closed');

my $profiles = decode_vf_profiles(encode_json([
    {
        vf_index => 1,
        resources => {
            vram => { mode => 'custom', quota => 8 * 1024**3 },
            ggtt => { mode => 'custom', quota => 1024**3 },
            contexts => { mode => 'custom', quota => 16384 },
            doorbells => { mode => 'custom', quota => 64 },
            exec_quantum_ms => { mode => 'custom', quota => 0 },
            preempt_timeout_us => { mode => 'auto' },
        },
    },
    {
        vf_index => 2,
        resources => {
            vram => { mode => 'custom', quota => 6 * 1024**3 },
            ggtt => { mode => 'auto' },
            contexts => { mode => 'custom', quota => 8192 },
            doorbells => { mode => 'custom', quota => 32 },
        },
    },
]), 2);

is(scalar(@$profiles), 2, 'two distinct VF profiles survive decoding');
is($profiles->[0]{resources}{vram}{quota}, 8 * 1024**3, 'VF1 keeps its 8 GiB quota');
is($profiles->[1]{resources}{vram}{quota}, 6 * 1024**3, 'VF2 keeps its 6 GiB quota');
is($profiles->[0]{resources}{preempt_timeout_us}{mode}, 'auto',
    'auto is an explicit mode, not quota zero');
is($profiles->[1]{resources}{exec_quantum_ms}{mode}, 'unchanged',
    'omitted resources are explicitly unchanged');
is($profiles->[0]{resources}{exec_quantum_ms}{quota}, 0,
    'zero remains valid for execution quantum custom mode');

eval {
    normalise_resource_profile('vram', {
        mode => 'custom',
        quota => 8 * 1024**3 + 1,
    });
};
like($@, qr/aligned/, 'VRAM quotas must follow the 128 MiB alignment');

eval {
    normalise_resource_profile('contexts', { mode => 'custom', quota => 0 });
};
like($@, qr/at least 1/, 'context quota zero is rejected');

eval {
    decode_vf_profiles(encode_json([
        { vf_index => 1, resources => {} },
        { vf_index => 1, resources => {} },
    ]), 2);
};
like($@, qr/Duplicate VF profile/, 'duplicate VF indices are rejected');

eval {
    decode_vf_profiles(encode_json([
        { vf_index => 1, resources => {} },
    ]), 2);
};
like($@, qr/exactly 2 entries/, 'profile count must match num_vfs');

eval {
    decode_vf_profiles('{not-json', 1);
};
like($@, qr/Invalid vf_profiles JSON/, 'malformed JSON is rejected');

eval {
    normalise_resource_profile('contexts', {
        mode => 'custom',
        quota => '9007199254740992',
    });
};
like($@, qr/exact JSON integer range/, 'quotas larger than JavaScript can represent exactly are rejected');

is(
    untaint_sysfs_write_path(
        '/sys/bus/pci/devices/0000:0b:00.0/sriov_numvfs',
        '',
    ),
    '/sys/bus/pci/devices/0000:0b:00.0/sriov_numvfs',
    'a real sysfs write path is accepted',
);

eval { untaint_sysfs_write_path('/etc/passwd', '') };
like($@, qr/outside \/sys/, 'writes outside real sysfs are rejected');

eval {
    untaint_sysfs_write_path(
        '/tmp/pve-gpu-test/sys/../etc/passwd',
        '/tmp/pve-gpu-test',
    );
};
like($@, qr/relative path component/, 'parent traversal is rejected');

eval {
    untaint_sysfs_write_path(
        '/tmp/other/sys/bus/pci/value',
        '/tmp/pve-gpu-test',
    );
};
like($@, qr/outside the configured fake sysfs root/,
    'fake sysfs writes cannot escape their configured root');

my $taint_root_raw = tempdir(CLEANUP => 1);
my ($taint_root) = $taint_root_raw =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe taint fixture root\n" if !defined($taint_root);
my $taint_target = "$taint_root/sys/bus/pci/devices/0000:0b:00.0/sriov_numvfs";
my ($taint_test_lib) = "$FindBin::Bin/../src" =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe taint child library path\n" if !defined($taint_test_lib);
my ($taint_perl) = $^X =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe Perl interpreter path\n" if !defined($taint_perl);
make_path(dirname($taint_target));
open(my $taint_fh, '>', $taint_target) or die "Cannot create taint fixture: $!";
print {$taint_fh} "2\n";
close($taint_fh);

my $taint_program = <<'PERL';
use strict;
use warnings;
use Fcntl qw(O_TRUNC O_WRONLY);
use PVE::GPU::SRIOV qw(untaint_sysfs_write_path);
my ($path, $root) = @ARGV;
my $clean = untaint_sysfs_write_path($path, $root);
sysopen(my $fh, $clean, O_WRONLY | O_TRUNC) or die $!;
print {$fh} "7\n" or die $!;
close($fh) or die $!;
PERL

is(
    system(
        $taint_perl,
        '-T',
        '-I', $taint_test_lib,
        '-e', $taint_program,
        $taint_target,
        $taint_root,
    ),
    0,
    'untainted helper output is accepted by sysopen under perl -T',
);
open($taint_fh, '<', $taint_target) or die "Cannot read taint fixture: $!";
my $taint_value = <$taint_fh>;
close($taint_fh);
chomp($taint_value);
is($taint_value, '7', 'perl -T child wrote only the intended fake sysfs file');

done_testing();
