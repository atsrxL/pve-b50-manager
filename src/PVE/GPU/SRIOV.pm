package PVE::GPU::SRIOV;

use strict;
use warnings;

use Exporter qw(import);
use JSON::PP qw(decode_json);
use Scalar::Util qw(looks_like_number);

our @EXPORT_OK = qw(
    active_sched_priority
    decode_vf_profiles
    effective_max_vfs
    normalise_resource_profile
    untaint_sysfs_write_path
    validate_vf_profiles
);

my @RESOURCE_NAMES = qw(
    vram
    ggtt
    contexts
    doorbells
    exec_quantum_ms
    preempt_timeout_us
);

my %RESOURCE_RULES = (
    vram => {
        minimum => 128 * 1024 * 1024,
        alignment => 128 * 1024 * 1024,
    },
    ggtt => {
        minimum => 128 * 1024 * 1024,
        alignment => 128 * 1024 * 1024,
    },
    contexts => { minimum => 1 },
    doorbells => { minimum => 1 },
    exec_quantum_ms => { minimum => 0 },
    preempt_timeout_us => { minimum => 0 },
);

sub _untaint_absolute_path {
    my ($path, $label) = @_;
    $label //= 'path';

    die "Missing $label\n" if !defined($path) || $path eq '';
    my ($clean) = $path =~ m{\A(/[A-Za-z0-9_./:+\-]+)\z};
    die "Unsafe $label\n" if !defined($clean);
    die "Unsafe $label contains a relative path component\n"
        if $clean =~ m{(?:\A|/)\.{1,2}(?:/|\z)};
    return $clean;
}

sub untaint_sysfs_write_path {
    my ($path, $fake_root) = @_;
    my $clean = _untaint_absolute_path($path, 'sysfs write path');

    if (defined($fake_root) && $fake_root ne '') {
        my $root = _untaint_absolute_path($fake_root, 'fake sysfs root');
        $root =~ s{/+\z}{};
        my $prefix = "$root/sys/";
        die "Refusing a write outside the configured fake sysfs root\n"
            if index($clean, $prefix) != 0;
    } else {
        die "Refusing a write outside /sys\n"
            if index($clean, '/sys/') != 0;
    }

    # The regex captures above are the deliberate taint boundary.  The caller
    # can safely pass this return value to sysopen while Perl runs with -T.
    return $clean;
}

sub effective_max_vfs {
    my ($declared, $live) = @_;

    $declared = 0 if !defined($declared) || $declared !~ /^\d+$/;
    $live = 0 if !defined($live) || $live !~ /^\d+$/;

    return $live if $live > 0 && ($declared == 0 || $live < $declared);
    return $declared;
}

sub active_sched_priority {
    my ($raw) = @_;
    return undef if !defined($raw);

    return lc($1) if $raw =~ /\[(low|normal|high)\]/i;
    return 'low' if $raw =~ /^\s*0\s*$/;
    return 'normal' if $raw =~ /^\s*1\s*$/;
    return 'high' if $raw =~ /^\s*2\s*$/;
    return lc($1) if $raw =~ /^\s*(low|normal|high)\s*$/i;
    return undef;
}

sub normalise_resource_profile {
    my ($name, $input) = @_;
    die "Unknown VF resource '$name'\n" if !exists($RESOURCE_RULES{$name});

    $input //= { mode => 'unchanged' };
    die "Resource '$name' profile must be an object\n" if ref($input) ne 'HASH';

    my $mode = lc($input->{mode} // 'unchanged');
    die "Resource '$name' mode must be auto, custom, or unchanged\n"
        if $mode !~ /^(?:auto|custom|unchanged)$/;

    my $result = { mode => $mode };
    return $result if $mode ne 'custom';

    my $quota = exists($input->{quota}) ? $input->{quota} : $input->{value};
    die "Custom resource '$name' requires quota\n" if !defined($quota);
    die "Custom resource '$name' quota must be a non-negative integer\n"
        if !looks_like_number($quota) || $quota !~ /^\d+$/;

    my $quota_text = "$quota";
    $quota_text =~ s/^0+(?=\d)//;
    my $max_exact_json_integer = '9007199254740991';
    die "Custom resource '$name' quota exceeds the exact JSON integer range\n"
        if length($quota_text) > length($max_exact_json_integer) ||
           (length($quota_text) == length($max_exact_json_integer) &&
            $quota_text gt $max_exact_json_integer);

    $quota = int($quota_text);
    my $rule = $RESOURCE_RULES{$name};
    die "Custom resource '$name' quota must be at least $rule->{minimum}\n"
        if $quota < $rule->{minimum};
    if ($rule->{alignment} && $quota % $rule->{alignment} != 0) {
        die "Custom resource '$name' quota must be aligned to $rule->{alignment} bytes\n";
    }

    $result->{quota} = $quota;
    return $result;
}

sub decode_vf_profiles {
    my ($json, $num_vfs) = @_;
    die "vf_profiles is required when num_vfs is greater than zero\n"
        if !defined($json) || $json eq '';

    my $decoded;
    eval { $decoded = decode_json($json) };
    die "Invalid vf_profiles JSON: $@" if $@;
    die "vf_profiles must be a JSON array\n" if ref($decoded) ne 'ARRAY';

    return validate_vf_profiles($decoded, $num_vfs);
}

sub validate_vf_profiles {
    my ($profiles, $num_vfs) = @_;
    die "VF count must be a positive integer\n"
        if !defined($num_vfs) || $num_vfs !~ /^\d+$/ || $num_vfs < 1;
    die "vf_profiles must be an array\n" if ref($profiles) ne 'ARRAY';
    die "vf_profiles must contain exactly $num_vfs entries\n"
        if scalar(@$profiles) != $num_vfs;

    my %seen;
    my @normalised;
    for my $profile (@$profiles) {
        die "Each VF profile must be an object\n" if ref($profile) ne 'HASH';
        my $index = $profile->{vf_index};
        die "VF profile has an invalid vf_index\n"
            if !defined($index) || $index !~ /^\d+$/ || $index < 1 || $index > $num_vfs;
        die "Duplicate VF profile for VF$index\n" if $seen{$index}++;

        my $resources = $profile->{resources} // {};
        die "VF$index resources must be an object\n" if ref($resources) ne 'HASH';
        for my $name (keys %$resources) {
            die "Unknown VF resource '$name'\n" if !exists($RESOURCE_RULES{$name});
        }

        my %normalised_resources;
        for my $name (@RESOURCE_NAMES) {
            $normalised_resources{$name} = normalise_resource_profile(
                $name,
                $resources->{$name},
            );
        }

        push @normalised, {
            vf_index => int($index),
            resources => \%normalised_resources,
        };
    }

    for my $index (1 .. $num_vfs) {
        die "Missing VF profile for VF$index\n" if !$seen{$index};
    }

    return [sort { $a->{vf_index} <=> $b->{vf_index} } @normalised];
}

1;
