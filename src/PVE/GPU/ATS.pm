package PVE::GPU::ATS;

use strict;
use warnings;

use Exporter qw(import);
use PVE::Tools;

our @EXPORT_OK = qw(
    assert_safe_for_hostpci_devices
    assert_safe_for_pci_device
    assert_safe_for_pf
    check_pci_device
    pci_device_state
);

# Intel Battlemage B50 physical functions which are unsafe to pass through
# on an AMD host while PCI ATS is enabled.  Keep this identity deliberately
# narrow: VFs, other Intel devices, and all devices on non-AMD hosts must not
# be blocked by this guard.
my $B50_VENDOR = '8086';
my $B50_DEVICE = 'e212';
my $BDF_RE = qr/[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]/;
my $ATS_POLICY_HELPER = '/usr/lib/pve-gpu/manage-ats-policy.sh';

sub _sysfs_root {
    my $root = $ENV{PVE_GPU_SYSFS_ROOT};
    return '' if !defined($root) || $root eq '';
    $root =~ s{/+\z}{};
    return $root;
}

sub _host_path {
    my ($path) = @_;
    my $root = _sysfs_root();
    return $root . $path if $root ne '';
    return $path;
}

sub _normalise_bdf {
    my ($bdf) = @_;
    return undef if !defined($bdf);
    $bdf = lc($bdf);
    $bdf =~ s/^\s+|\s+\z//g;
    $bdf = "0000:$bdf" if $bdf =~ /^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/;
    $bdf .= '.0' if $bdf =~ /^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}$/;
    return $bdf =~ /^$BDF_RE$/o ? $bdf : undef;
}

sub _read_file {
    my ($path) = @_;
    my $full = _host_path($path);
    open(my $fh, '<', $full) or return (0, undef, "$!");
    local $/;
    my $contents = <$fh>;
    my $closed = close($fh);
    return (0, undef, "$!") if !$closed;
    return (1, $contents // '', undef);
}

sub _read_sysfs_attr {
    my ($bdf, $name) = @_;
    my ($ok, $contents, $error) = _read_file("/sys/bus/pci/devices/$bdf/$name");
    return (undef, $error) if !$ok;
    $contents =~ s/\s+\z//;
    return ($contents, undef);
}

sub _cpu_vendor {
    my ($ok, $contents, $error) = _read_file('/proc/cpuinfo');
    return (undef, $error || 'cannot read /proc/cpuinfo') if !$ok;
    return ($1, undef) if $contents =~ /^\s*vendor_id\s*:\s*(\S+)/mi;
    return (undef, 'vendor_id is missing from /proc/cpuinfo');
}

sub _active_noats {
    my ($ok, $contents, $error) = _read_file('/proc/cmdline');
    return (0, $error || 'cannot read /proc/cmdline') if !$ok;
    my $active = scalar(grep { $_ eq 'pci=noats' } split(/\s+/, $contents // ''));
    return ($active ? 1 : 0, undef);
}

sub _capture_lspci {
    my ($bdf) = @_;
    my ($stdout, $stderr, $exit_code) = ('', '', undef);
    my $ok = eval {
        $exit_code = PVE::Tools::run_command(
            ['lspci', '-vv', '-s', $bdf],
            outfunc => sub {
                $stdout .= $_[0] . "\n" if defined($_[0]);
            },
            errfunc => sub {
                $stderr .= $_[0] . "\n" if defined($_[0]);
            },
            noerr => 1,
        );
        1;
    };
    my $error = $@;
    my $success = $ok && (!defined($exit_code) || $exit_code == 0);
    return {
        success   => $success ? 1 : 0,
        exit_code => $exit_code,
        stdout    => $stdout,
        stderr    => $stderr,
        error     => $error,
    };
}

sub _ats_state {
    my ($bdf) = @_;
    my $result = _capture_lspci($bdf);
    my $output = $result->{stdout} // '';
    my ($enable, $disable) = (0, 0);
    while ($output =~ /^\s*ATSCtl\s*:\s*([^\r\n]*)/gmi) {
        my $line = $1;
        $enable = 1 if $line =~ /\bEnable\+/i;
        $disable = 1 if $line =~ /\bEnable-/i;
    }

    my $explicit_disabled = $disable && !$enable ? 1 : 0;
    my $error;
    if (!$result->{success}) {
        my $detail = $result->{error} || $result->{stderr} ||
            (defined($result->{exit_code}) ? "exit $result->{exit_code}" : 'unknown failure');
        $detail =~ s/\s+\z//;
        $error = "lspci failed: $detail";
    } elsif ($enable && $disable) {
        $error = 'lspci reported both ATSCtl Enable+ and Enable-';
    } elsif (!$enable && !$disable) {
        $error = 'lspci did not report an explicit ATSCtl Enable+/Enable- state';
    }

    return {
        enabled          => $enable && !$disable ? 1 : 0,
        supported        => ($enable || $disable) ? 1 : 0,
        explicit_disabled => $explicit_disabled,
        error            => $error,
    };
}

sub _policy_helper_status {
    my $helper = $ENV{PVE_GPU_ATS_POLICY_HELPER} // $ATS_POLICY_HELPER;
    my ($stdout, $stderr, $exit_code) = ('', '', undef);
    my $ok = eval {
        $exit_code = PVE::Tools::run_command(
            [$helper, 'status'],
            outfunc => sub {
                $stdout .= $_[0] . "\n" if defined($_[0]);
            },
            errfunc => sub {
                $stderr .= $_[0] . "\n" if defined($_[0]);
            },
            noerr => 1,
        );
        1;
    };
    my $command_error = $@;

    my %values;
    for my $line (split(/\R/, $stdout)) {
        $values{$1} = $2 if $line =~ /^([A-Za-z][A-Za-z0-9_.-]*)=(.*)$/;
    }

    my $persistent = exists($values{persistent_noats}) &&
        $values{persistent_noats} eq '1';
    my $managed = exists($values{managed}) && $values{managed} eq '1';
    my $boot_mode = $values{boot_mode} // '';
    my $success = $ok && (!defined($exit_code) || $exit_code == 0) &&
        exists($values{persistent_noats}) &&
        $values{persistent_noats} =~ /^(?:0|1)$/ &&
        exists($values{managed}) &&
        $values{managed} =~ /^(?:0|1)$/ &&
        $boot_mode =~ /^(?:grub|proxmox-boot-tool|systemd-boot)$/;

    my $error;
    if (!$success) {
        my $detail = $command_error || $stderr;
        $detail = defined($exit_code) && $exit_code != 0
            ? "exit $exit_code"
            : 'invalid or incomplete status'
            if !defined($detail) || $detail eq '';
        $detail =~ s/\s+\z//;
        $error = "ATS policy helper failed: $detail";
    }

    return {
        success => $success ? 1 : 0,
        persistent_noats => $persistent ? 1 : 0,
        managed => $managed ? 1 : 0,
        boot_mode => $boot_mode,
        error => $error,
    };
}

sub pci_device_state {
    my ($pciid) = @_;
    my $bdf = _normalise_bdf($pciid);
    die "Invalid PCI BDF for ATS safety guard\n" if !defined($bdf);

    my ($vendor, $vendor_error) = _read_sysfs_attr($bdf, 'vendor');
    my ($device, $device_error) = _read_sysfs_attr($bdf, 'device');
    my @identity_errors;
    push @identity_errors, "cannot read PCI vendor identity for $bdf"
        if !defined($vendor) || $vendor !~ /^(?:0x)?[0-9a-f]{4}$/i;
    push @identity_errors, "cannot read PCI device identity for $bdf"
        if !defined($device) || $device !~ /^(?:0x)?[0-9a-f]{4}$/i;

    my $normal_vendor = lc($vendor // '');
    my $normal_device = lc($device // '');
    $normal_vendor =~ s/^0x//;
    $normal_device =~ s/^0x//;

    # A VF has a physfn symlink.  The symlink check is intentionally done
    # before reading CPU state so unrelated devices do not need host probes.
    my $is_pf = !-l _host_path("/sys/bus/pci/devices/$bdf/physfn");
    my $is_b50_pf = $is_pf &&
        $normal_vendor eq $B50_VENDOR && $normal_device eq $B50_DEVICE;
    my $identity_unknown = @identity_errors ? 1 : 0;

    # If identity cannot be read, it is unsafe to assume that a requested
    # PCI device is harmless: it may be the affected B50 PF.  This is the
    # native-start fail-closed path.  Readable non-B50/VF devices are not
    # affected and return without lspci/cmdline probing.
    if ($identity_unknown && !$is_pf) {
        return {
            bdf           => $bdf,
            vendor        => $normal_vendor,
            device        => $normal_device,
            is_pf         => 0,
            is_b50_pf     => 0,
            affected      => 0,
            cpu_vendor    => undef,
            active_noats  => 0,
            ats_supported => 0,
            ats_enabled   => 0,
            explicit_disabled => 0,
            safe          => 1,
            reason        => 'PCI function is a VF; the host-PF ATS guard is not applicable',
        };
    }

    if ($identity_unknown) {
        return {
            bdf          => $bdf,
            vendor       => $normal_vendor,
            device       => $normal_device,
            is_pf        => $is_pf ? 1 : 0,
            is_b50_pf    => 0,
            affected     => 1,
            cpu_vendor   => undef,
            active_noats => 0,
            ats_supported => 0,
            ats_enabled  => 0,
            explicit_disabled => 0,
            safe         => 0,
            reason       => join('; ', @identity_errors) .
                '. Refusing native VM start because the PCI identity is unknown.',
        };
    }

    my $cpu_vendor;
    if (!$is_b50_pf) {
        return {
            bdf           => $bdf,
            vendor        => $normal_vendor,
            device        => $normal_device,
            is_pf         => $is_pf ? 1 : 0,
            is_b50_pf     => 0,
            affected      => 0,
            cpu_vendor    => undef,
            active_noats  => 0,
            ats_supported => 0,
            ats_enabled   => 0,
            explicit_disabled => 0,
            safe          => 1,
            reason        => 'PCI device is outside the AMD B50 ATS affected set',
        };
    }

    my ($cpu, $cpu_error) = _cpu_vendor();
    $cpu_vendor = $cpu // '';
    my $cpu_is_amd = lc($cpu_vendor) eq 'authenticamd';
    my $cpu_is_intel = lc($cpu_vendor) eq 'genuineintel';
    # A known non-AMD host is explicitly outside the workaround.  Unknown
    # CPU identity stays affected and unsafe rather than allowing a bypass.
    if ($cpu_is_intel) {
        return {
            bdf           => $bdf,
            vendor        => $normal_vendor,
            device        => $normal_device,
            is_pf         => 1,
            is_b50_pf     => 1,
            affected      => 0,
            cpu_vendor    => $cpu_vendor,
            active_noats  => 0,
            ats_supported => 0,
            ats_enabled   => 0,
            explicit_disabled => 0,
            safe          => 1,
            reason        => 'Host CPU is not AuthenticAMD; AMD B50 ATS guard is not applicable',
        };
    }

    my ($active, $active_error) = _active_noats();
    my $ats = _ats_state($bdf);
    my $policy = _policy_helper_status();
    my @reasons;
    push @reasons, "cannot determine host CPU vendor" .
        (defined($cpu_error) && $cpu_error ne '' ? ": $cpu_error" : '')
        if !$cpu_is_amd;
    push @reasons, 'current kernel command line does not contain the exact pci=noats token'
        if !$active;
    push @reasons, $active_error if defined($active_error) && $active_error ne '';
    push @reasons, $ats->{error} if $ats->{error};
    push @reasons, $policy->{error} if $policy->{error};
    push @reasons, 'future boot policy does not contain persistent pci=noats'
        if !$policy->{persistent_noats};

    my $safe = $cpu_is_amd && $active && $ats->{explicit_disabled} &&
        $policy->{success} && $policy->{persistent_noats} && !@reasons;
    return {
        bdf             => $bdf,
        vendor          => $normal_vendor,
        device          => $normal_device,
        is_pf           => 1,
        is_b50_pf       => 1,
        affected        => 1,
        cpu_vendor      => $cpu_vendor,
        active_noats    => $active ? 1 : 0,
        ats_supported   => $ats->{supported},
        ats_enabled     => $ats->{enabled},
        explicit_disabled => $ats->{explicit_disabled},
        persistent_noats => $policy->{persistent_noats},
        boot_mode       => $policy->{boot_mode},
        safe            => $safe ? 1 : 0,
        reason          => $safe
            ? 'AuthenticAMD B50 PF has exact pci=noats active and persistent with ATSCtl Enable-'
            : join('; ', @reasons),
    };
}

sub assert_safe_for_pci_device {
    my ($pciid, $vmid) = @_;
    my $state = pci_device_state($pciid);
    return $state if !$state->{affected} || $state->{safe};

    my $subject = defined($vmid) ? "VM $vmid" : 'native VM start';
    my $reason = $state->{reason} // 'AMD B50 ATS safety is not verified';
    die "Refusing $subject with affected Intel B50 PF $state->{bdf}: $reason. " .
        "Enable the persistent no-ATS policy (pci=noats), reboot, and retry.\n";
}

sub assert_safe_for_hostpci_devices {
    my ($pci_devices, $vmid) = @_;

    for my $device (values %$pci_devices) {
        for my $pci ($device->{ids}->@*) {
            assert_safe_for_pci_device($pci->{id}, $vmid);
        }
    }

    return 1;
}

sub assert_safe_for_pf { return assert_safe_for_pci_device(@_); }
sub check_pci_device { return pci_device_state(@_); }

1;
