#!/usr/bin/perl
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $policy_script = File::Spec->catfile($root, 'src', 'scripts', 'manage-ats-policy.sh');
my $vfio_script = File::Spec->catfile($root, 'src', 'scripts', 'apply-vfio-config.sh');
my $binder_check_script = File::Spec->catfile($root, 'src', 'scripts', 'check-pve-gpu-binders.sh');

sub write_file {
    my ($path, $data) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $data or die "Cannot write $path: $!";
    close($fh) or die "Cannot close $path: $!";
}

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot read $path: $!";
    local $/;
    my $data = <$fh> // '';
    close($fh) or die "Cannot close $path: $!";
    return $data;
}

sub make_executable {
    my ($path) = @_;
    chmod(0755, $path) or die "Cannot make $path executable: $!";
}

sub shell_command {
    my ($path, $label) = @_;
    write_file($path, <<'SH');
#!/bin/sh
printf '%s %s\n' "LABEL_PLACEHOLDER" "$*" >> "$PVE_GPU_TEST_LOG"
if [ "${PVE_GPU_FAIL_REFRESH:-0}" = 1 ]; then
    exit 42
fi
exit 0
SH
    my $contents = read_file($path);
    $contents =~ s/LABEL_PLACEHOLDER/$label/;
    write_file($path, $contents);
    make_executable($path);
}

sub parse_kv {
    my ($output) = @_;
    my %values;
    for my $line (split(/\n/, $output // '')) {
        $values{$1} = $2 if $line =~ /^([A-Za-z][A-Za-z0-9_]*)=(.*)$/;
    }
    return \%values;
}

sub run_capture {
    my ($program, $arguments, $environment) = @_;
    local %ENV = %ENV;
    for my $key (keys %{$environment // {}}) {
        if (defined($environment->{$key})) {
            $ENV{$key} = $environment->{$key};
        } else {
            delete $ENV{$key};
        }
    }

    open(my $pipe, '-|', '/bin/bash', $program, @{$arguments // []})
        or die "Cannot execute $program: $!";
    local $/;
    my $output = <$pipe> // '';
    close($pipe);
    my $status = $?;
    my $exit_code = $status == -1 ? 255 : ($status >> 8);
    return ($output, $exit_code);
}

sub log_lines {
    my ($path) = @_;
    return () if !-f $path;
    my $contents = read_file($path);
    return grep { length($_) } split(/\n/, $contents);
}

sub replace_symlink {
    my ($target, $path) = @_;
    unlink($path) if -e $path || -l $path;
    symlink($target, $path) or die "Cannot symlink $path -> $target: $!";
}

sub write_pci_attr {
    my ($fake, $bdf, $name, $value) = @_;
    write_file("$fake/sys/bus/pci/devices/$bdf/$name", $value);
}

sub setup_vfio_device {
    my ($fake, $bdf, $vendor, $device, $driver) = @_;
    my $device_path = "$fake/sys/bus/pci/devices/$bdf";
    make_path($device_path, "$fake/sys/bus/pci/drivers/$driver");
    write_pci_attr($fake, $bdf, 'vendor', "$vendor\n");
    write_pci_attr($fake, $bdf, 'device', "$device\n");
    write_pci_attr($fake, $bdf, 'driver_override', "sentinel-$bdf\n");
    replace_symlink("$fake/sys/bus/pci/drivers/$driver", "$device_path/driver");
    return $device_path;
}

subtest 'GRUB policy is explicit, package-owned, idempotent, and rollback-safe' => sub {
    my $fake = tempdir(CLEANUP => 1);
    my $default = "$fake/etc/default/grub";
    my $dropin = "$fake/etc/default/grub.d/99-pve-gpu-manager-noats.cfg";
    my $log = "$fake/state/refresh.log";
    my $update = "$fake/bin/update-grub";
    my $current = "$fake/proc/cmdline";
    my $atsctl = "$fake/sys/module/pci/parameters/disable_ats";
    my $original = "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet root=/dev/vda\"\n";

    make_path("$fake/tmp", "$fake/state");
    write_file($default, $original);
    write_file($current, "root=/dev/vda quiet\n");
    write_file($atsctl, "0\n");
    shell_command($update, 'update-grub');

    my %env = (
        PATH                    => "$fake/bin:/usr/bin:/bin",
        PVE_GPU_ROOT            => $fake,
        PVE_GPU_BOOT_MODE       => 'grub',
        PVE_GPU_UPDATE_GRUB_CMD => $update,
        PVE_GPU_TEST_LOG        => $log,
        PVE_GPU_CURRENT_CMDLINE => $current,
        PVE_GPU_ATSCTL_FILE     => $atsctl,
        PVE_GPU_ATS_TMPDIR      => "$fake/tmp",
    );

    my ($output, $exit) = run_capture($policy_script, ['status'], \%env);
    is($exit, 0, 'initial GRUB status succeeds');
    my $state = parse_kv($output);
    is($state->{boot_mode}, 'grub', 'status reports GRUB mode');
    is($state->{persistent_noats}, '0', 'initial policy is not persistent');
    is($state->{managed}, '0', 'initial policy is not package-managed');
    is($state->{changed}, '0', 'status never reports a change');
    is($state->{current_cmdline_noats}, '0', 'status reports current cmdline without noats');
    is($state->{atsctl}, 'enabled', 'status maps disable_ats=0 to ATS enabled');
    ok(!-e $dropin, 'status does not create a GRUB drop-in');
    ok(!-e $log, 'status does not invoke update-grub');

    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'GRUB enable succeeds');
    $state = parse_kv($output);
    is($state->{persistent_noats}, '1', 'enable reports persistent noats');
    is($state->{managed}, '1', 'enable reports package ownership');
    is($state->{changed}, '1', 'enable reports a change');
    is($state->{reboot_required}, '1', 'enable reports reboot required while current cmdline is unchanged');
    like(read_file($dropin), qr/^\# pve-gpu-manager managed pci=noats$/m,
        'GRUB drop-in has the ownership marker');
    like(read_file($dropin), qr/\bpci=noats\b/, 'GRUB drop-in has the exact noats token');
    is(read_file($default), $original, 'the user GRUB file remains byte-for-byte unchanged');
    is(scalar(log_lines($log)), 1, 'enable refreshes GRUB once');

    my $dropin_after_enable = read_file($dropin);
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'repeated GRUB enable succeeds');
    $state = parse_kv($output);
    is($state->{changed}, '0', 'repeated enable is a no-op');
    is(read_file($dropin), $dropin_after_enable, 'repeated enable does not duplicate the drop-in');
    is(scalar(log_lines($log)), 1, 'repeated enable does not refresh GRUB again');

    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    is($exit, 0, 'GRUB disable succeeds');
    $state = parse_kv($output);
    is($state->{persistent_noats}, '0', 'disable reports no persistent policy');
    is($state->{managed}, '0', 'disable reports no package ownership');
    is($state->{changed}, '1', 'disable reports a change');
    ok(!-e $dropin, 'disable removes only the package-owned drop-in');
    is(read_file($default), $original, 'disable leaves the user GRUB file unchanged');
    is(scalar(log_lines($log)), 2, 'disable refreshes GRUB once');

    write_file($default, "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet pci=noats\"\n");
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'GRUB enable accepts an external policy');
    write_file($dropin,
        "# pve-gpu-manager managed pci=noats\n" .
        "GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} pci=noats\"\n");
    unlink($log) if -e $log;
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    is($exit, 0, 'GRUB disable removes an owned drop-in while preserving an external policy');
    $state = parse_kv($output);
    is($state->{persistent_noats}, '1',
        'GRUB disable reports the remaining external noats policy');
    is($state->{managed}, '0',
        'GRUB disable clears only package ownership');
    ok(!-e $dropin, 'owned GRUB drop-in is removed in the mixed-policy case');
    like(read_file($default), qr/\bpci=noats\b/,
        'external GRUB noats policy is preserved');

    write_file($default, $original);

    write_file($default, "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet pci=noats\"\n");
    unlink($dropin) if -e $dropin;
    unlink($log) if -e $log;
    ($output, $exit) = run_capture($policy_script, ['status'], \%env);
    $state = parse_kv($output);
    is($state->{persistent_noats}, '1', 'status detects an external GRUB noats policy');
    is($state->{managed}, '0', 'external GRUB policy is not claimed');
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'enable accepts an external GRUB policy as a no-op');
    $state = parse_kv($output);
    is($state->{managed}, '0', 'external no-op remains unmanaged');
    is($state->{changed}, '0', 'external no-op reports no change');
    ok(!-e $dropin, 'external policy does not create a package drop-in');
    ok(!-e $log, 'external policy does not refresh GRUB');
    my $external_grub = read_file($default);
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    isnt($exit, 0, 'disable refuses to remove an external GRUB policy');
    $state = parse_kv($output);
    is($state->{error}, 'external_policy', 'external GRUB disable reports the ownership error');
    is(read_file($default), $external_grub, 'external GRUB policy remains unchanged');

    write_file($default, $original);
    write_file($dropin, "# user-owned file\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet pci=noats\"\n");
    my $conflicting_dropin = read_file($dropin);
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    isnt($exit, 0, 'pre-existing unmarked package-path drop-in is rejected');
    $state = parse_kv($output);
    is($state->{error}, 'dropin_conflict', 'unmarked drop-in reports a conflict');
    is(read_file($dropin), $conflicting_dropin, 'unmarked drop-in is not modified by enable');
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    isnt($exit, 0, 'disable also rejects an unowned package-path drop-in');
    is(read_file($dropin), $conflicting_dropin, 'disable does not delete an unowned drop-in');
    unlink($dropin);

    $env{PVE_GPU_FAIL_REFRESH} = 1;
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    isnt($exit, 0, 'GRUB enable reports a refresh failure');
    $state = parse_kv($output);
    is($state->{error}, 'refresh_failed', 'GRUB refresh failure is machine-readable');
    ok(!-e $dropin, 'failed GRUB enable rolls back a newly created drop-in');
    is(read_file($default), $original, 'failed GRUB enable preserves the original GRUB file');

    $env{PVE_GPU_FAIL_REFRESH} = 0;
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'GRUB enable succeeds after refresh recovery');
    my $owned_dropin = read_file($dropin);
    $env{PVE_GPU_FAIL_REFRESH} = 1;
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    isnt($exit, 0, 'GRUB disable reports a refresh failure');
    $state = parse_kv($output);
    is($state->{error}, 'refresh_failed', 'GRUB disable refresh failure is machine-readable');
    is(read_file($dropin), $owned_dropin, 'failed GRUB disable restores the owned drop-in');
    $env{PVE_GPU_FAIL_REFRESH} = 0;
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    is($exit, 0, 'GRUB disable succeeds after rollback');
    ok(!-e $dropin, 'owned drop-in can be removed after rollback');

    write_file($default, $original);
    unlink($dropin) if -e $dropin;
    write_file($current, "root=/dev/vda quiet\n");
    ($output, $exit) = run_capture($policy_script, ['enable'], { %env, PVE_GPU_BOOT_MODE => 'invalid' });
    is($exit, 2, 'invalid boot mode is rejected without touching GRUB');
    ok(!-e $dropin, 'invalid boot mode creates no drop-in');
};

subtest 'proxmox-boot-tool and systemd-boot preserve cmdline tokens and rollback' => sub {
    my $fake = tempdir(CLEANUP => 1);
    my $cmdline = "$fake/etc/kernel/cmdline";
    my $marker = "$fake/var/lib/pve-gpu-manager/ats-noats.managed";
    my $current = "$fake/proc/cmdline";
    my $atsctl = "$fake/sys/module/pci/parameters/disable_ats";
    my $log = "$fake/state/refresh.log";
    my $pbt = "$fake/bin/proxmox-boot-tool";
    my $original = "root=/dev/mapper/pve-root quiet console=ttyS0,115200n8\n";

    make_path("$fake/tmp", "$fake/state");
    write_file($cmdline, $original);
    write_file($current, "root=/dev/mapper/pve-root quiet\n");
    write_file($atsctl, "1\n");
    shell_command($pbt, 'proxmox-boot-tool');

    my %env = (
        PATH                       => "$fake/bin:/usr/bin:/bin",
        PVE_GPU_ROOT               => $fake,
        PVE_GPU_BOOT_MODE          => 'proxmox-boot-tool',
        PVE_GPU_KERNEL_CMDLINE     => $cmdline,
        PVE_GPU_ATS_MARKER         => $marker,
        PVE_GPU_PROXMOX_BOOT_TOOL_CMD => $pbt,
        PVE_GPU_TEST_LOG           => $log,
        PVE_GPU_CURRENT_CMDLINE    => $current,
        PVE_GPU_ATSCTL_FILE        => $atsctl,
        PVE_GPU_ATS_TMPDIR         => "$fake/tmp",
    );

    my ($output, $exit) = run_capture($policy_script, ['status'], \%env);
    is($exit, 0, 'initial proxmox-boot-tool status succeeds');
    my $state = parse_kv($output);
    is($state->{boot_mode}, 'proxmox-boot-tool', 'status reports proxmox-boot-tool mode');
    is($state->{persistent_noats}, '0', 'initial cmdline has no noats token');
    is($state->{managed}, '0', 'initial marker is absent');
    is($state->{atsctl}, 'disabled', 'status maps disable_ats=1 to ATS disabled');
    ok(!-e $log, 'status does not refresh proxmox boot entries');

    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'proxmox-boot-tool enable succeeds');
    $state = parse_kv($output);
    is($state->{persistent_noats}, '1', 'proxmox enable reports persistent noats');
    is($state->{managed}, '1', 'proxmox enable reports marker ownership');
    is($state->{changed}, '1', 'proxmox enable reports a change');
    like(read_file($cmdline), qr/^root=\/dev\/mapper\/pve-root quiet console=ttyS0,115200n8 pci=noats\n$/,
        'proxmox enable preserves all existing kernel arguments');
    is(scalar(() = read_file($cmdline) =~ /(?<!\S)pci=noats(?!\S)/g), 1,
        'proxmox enable appends exactly one noats token');
    is(read_file($marker), "pve-gpu-manager managed pci=noats\n", 'proxmox marker records ownership');
    is_deeply([log_lines($log)], ['proxmox-boot-tool refresh'],
        'proxmox enable refreshes exactly once');

    my $cmdline_after_enable = read_file($cmdline);
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'repeated proxmox enable succeeds');
    $state = parse_kv($output);
    is($state->{changed}, '0', 'repeated proxmox enable is a no-op');
    is(read_file($cmdline), $cmdline_after_enable, 'repeated proxmox enable does not duplicate the token');
    is(scalar(log_lines($log)), 1, 'repeated proxmox enable does not refresh again');

    my $marker_after_enable = read_file($marker);
    my $without_newline = $cmdline_after_enable;
    $without_newline =~ s/\n\z//;
    for my $duplicate (
        "pci=noats $cmdline_after_enable",
        "$without_newline pci=noats\n",
    ) {
        write_file($cmdline, $duplicate);
        ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
        isnt($exit, 0, 'disable refuses an ambiguous duplicate noats token');
        $state = parse_kv($output);
        is($state->{error}, 'token_conflict',
            'duplicate noats reports an ownership conflict');
        is(read_file($cmdline), $duplicate,
            'duplicate-token rejection leaves the cmdline unchanged');
        is(read_file($marker), $marker_after_enable,
            'duplicate-token rejection preserves the ownership marker');
        is(scalar(log_lines($log)), 1,
            'duplicate-token rejection does not refresh boot entries');
    }
    write_file($cmdline, $cmdline_after_enable);

    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    is($exit, 0, 'proxmox disable succeeds');
    $state = parse_kv($output);
    is($state->{persistent_noats}, '0', 'proxmox disable clears persistence');
    is($state->{managed}, '0', 'proxmox disable clears ownership');
    is($state->{changed}, '1', 'proxmox disable reports a change');
    is(read_file($cmdline), $original, 'proxmox disable restores unrelated cmdline arguments exactly');
    ok(!-e $marker, 'proxmox disable removes only its marker');
    is(scalar(log_lines($log)), 2, 'proxmox disable refreshes once');

    write_file($cmdline, "root=/dev/mapper/pve-root pci=noats quiet\n");
    unlink($marker) if -e $marker;
    unlink($log) if -e $log;
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'external proxmox policy enable is a no-op');
    $state = parse_kv($output);
    is($state->{managed}, '0', 'external proxmox token is not claimed');
    is($state->{changed}, '0', 'external proxmox enable reports no change');
    ok(!-e $marker, 'external proxmox policy does not create a marker');
    ok(!-e $log, 'external proxmox policy does not refresh');
    my $external_cmdline = read_file($cmdline);
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    isnt($exit, 0, 'proxmox disable refuses an external token');
    $state = parse_kv($output);
    is($state->{error}, 'external_policy', 'external proxmox disable reports ownership error');
    is(read_file($cmdline), $external_cmdline, 'external proxmox token remains unchanged');

    write_file($cmdline, $original);
    write_file($marker, "unrelated marker\n");
    my $conflicting_marker = read_file($marker);
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    isnt($exit, 0, 'pre-existing unowned proxmox marker is rejected');
    $state = parse_kv($output);
    is($state->{error}, 'marker_conflict', 'unowned marker reports a conflict');
    is(read_file($marker), $conflicting_marker, 'unowned marker is not overwritten');
    unlink($marker);

    $env{PVE_GPU_FAIL_REFRESH} = 1;
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    isnt($exit, 0, 'proxmox enable reports a refresh failure');
    $state = parse_kv($output);
    is($state->{error}, 'refresh_failed', 'proxmox refresh failure is machine-readable');
    is(read_file($cmdline), $original, 'failed proxmox enable restores the original cmdline');
    ok(!-e $marker, 'failed proxmox enable restores marker absence');

    $env{PVE_GPU_FAIL_REFRESH} = 0;
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    is($exit, 0, 'proxmox enable succeeds after rollback');
    my $owned_cmdline = read_file($cmdline);
    my $owned_marker = read_file($marker);
    $env{PVE_GPU_FAIL_REFRESH} = 1;
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    isnt($exit, 0, 'proxmox disable reports a refresh failure');
    $state = parse_kv($output);
    is($state->{error}, 'refresh_failed', 'proxmox disable refresh failure is machine-readable');
    is(read_file($cmdline), $owned_cmdline, 'failed proxmox disable restores cmdline');
    is(read_file($marker), $owned_marker, 'failed proxmox disable restores marker');
    $env{PVE_GPU_FAIL_REFRESH} = 0;
    ($output, $exit) = run_capture($policy_script, ['disable'], \%env);
    is($exit, 0, 'proxmox disable succeeds after rollback');
    is(read_file($cmdline), $original, 'final proxmox disable restores original cmdline');
    ok(!-e $marker, 'final proxmox disable removes marker');

    unlink($cmdline);
    unlink($log) if -e $log;
    $env{PVE_GPU_BOOT_MODE} = 'systemd-boot';
    ($output, $exit) = run_capture($policy_script, ['enable'], \%env);
    isnt($exit, 0, 'explicit systemd-boot mode rejects a missing cmdline file');
    $state = parse_kv($output);
    is($state->{boot_mode}, 'systemd-boot', 'systemd-boot mode is reported distinctly');
    is($state->{error}, 'cmdline_missing', 'missing systemd-boot cmdline reports a safe error');
    ok(!-e $cmdline, 'missing cmdline is not guessed or created');
    ok(!-e $marker, 'missing cmdline failure creates no ownership marker');
    ok(!-e $log, 'missing cmdline failure does not refresh boot entries');
};

subtest 'automatic boot-mode detection follows the configured boot source' => sub {
    my $fake = tempdir(CLEANUP => 1);
    my $default = "$fake/etc/default/grub";
    my $cmdline = "$fake/etc/kernel/cmdline";
    my $uuids = "$fake/etc/kernel/proxmox-boot-uuids";
    my $pbt = "$fake/bin/proxmox-boot-tool";
    my $current = "$fake/proc/cmdline";
    my $atsctl = "$fake/sys/module/pci/parameters/disable_ats";

    make_path("$fake/tmp", "$fake/etc/kernel");
    write_file($default, "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\n");
    write_file($cmdline, "root=/dev/mapper/pve-root quiet\n");
    write_file($current, "root=/dev/mapper/pve-root quiet\n");
    write_file($atsctl, "0\n");
    shell_command($pbt, 'proxmox-boot-tool');

    my %env = (
        PATH                          => "$fake/bin:/usr/bin:/bin",
        PVE_GPU_ROOT                  => $fake,
        PVE_GPU_BOOT_MODE             => 'auto',
        PVE_GPU_PROXMOX_BOOT_TOOL_CMD => $pbt,
        PVE_GPU_PROXMOX_BOOT_UUIDS    => $uuids,
        PVE_GPU_CURRENT_CMDLINE       => $current,
        PVE_GPU_ATSCTL_FILE           => $atsctl,
        PVE_GPU_ATS_TMPDIR            => "$fake/tmp",
    );

    my ($output, $exit) = run_capture($policy_script, ['status'], \%env);
    is($exit, 0, 'auto status succeeds when stale kernel cmdline exists on GRUB');
    my $state = parse_kv($output);
    is($state->{boot_mode}, 'grub',
        'a stale /etc/kernel/cmdline without configured PBT ESPs does not override GRUB');

    write_file($uuids, "1111-2222\n");
    ($output, $exit) = run_capture($policy_script, ['status'], \%env);
    is($exit, 0, 'auto status succeeds with configured PBT ESPs');
    $state = parse_kv($output);
    is($state->{boot_mode}, 'proxmox-boot-tool',
        'a non-empty PBT ESP list selects the proxmox boot source');
};

subtest 'VFIO boot binder gates only AMD Intel e212 PFs before writes' => sub {
    my $fake = tempdir(CLEANUP => 1);
    my $pf = '0000:01:00.0';
    my $other = '0000:02:00.0';
    my $vf = '0000:01:00.1';
    my $config = "$fake/etc/pve-gpu-vfio.conf";
    my $cmdline = "$fake/proc/cmdline";
    my $cpuinfo = "$fake/proc/cpuinfo";
    my $probe = "$fake/sys/bus/pci/drivers_probe";
    my $lspci = "$fake/bin/lspci";
    my $lspci_log = "$fake/state/lspci.log";
    my $test_log = "$fake/state/binder.log";
    my $policy = "$fake/bin/manage-ats-policy.sh";

    make_path("$fake/bin", "$fake/tmp", "$fake/state", "$fake/sys/bus/pci/drivers");
    write_file($probe, "probe-sentinel\n");
    write_file($cpuinfo, "vendor_id : AuthenticAMD\nflags : svm\n");
    write_file($cmdline, "root=/dev/vda quiet\n");
    write_file($lspci, <<'LSPCI');
#!/bin/sh
printf '%s\n' "$*" >> "$PVE_GPU_LSPCI_LOG"
printf 'Capabilities: [a0] ATS+\nATSCtl: Enable-, Smallest Translation Unit: 00\n'
LSPCI
    make_executable($lspci);
    write_file($policy, "#!/bin/sh\nprintf '%s\\n' \"persistent_noats=0\"\n");
    make_executable($policy);

    my $pf_path = setup_vfio_device($fake, $pf, '0x8086', '0xe212', 'xe');
    my $other_path = setup_vfio_device($fake, $other, '0x10de', '0x1abc', 'xe');
    my $vf_path = setup_vfio_device($fake, $vf, '0x8086', '0xe212', 'vfio-pci');
    replace_symlink($pf_path, "$vf_path/physfn");
    write_file($config, "$other\n$pf\n");

    my %env = (
        PATH                 => "$fake/bin:/usr/bin:/bin",
        PVE_GPU_SYSFS_ROOT   => $fake,
        PVE_GPU_VFIO_CONF    => $config,
        PVE_GPU_PROC_CMDLINE => $cmdline,
        PVE_GPU_CPUINFO      => $cpuinfo,
        PVE_GPU_LSPCI_CMD    => $lspci,
        PVE_GPU_LSPCI_LOG    => $lspci_log,
        PVE_GPU_ATS_POLICY_HELPER => $policy,
        PVE_GPU_TEST_LOG     => $test_log,
    );

    my ($output, $exit) = run_capture($vfio_script, [], \%env);
    isnt($exit, 0, 'unsafe e212 PF fails before the binder writes any driver attribute');
    like($output, qr/exact pci=noats/, 'missing exact noats token explains the fail-closed result');
    is(read_file("$pf_path/driver_override"), "sentinel-$pf\n",
        'unsafe PF driver_override is untouched');
    is(read_file("$other_path/driver_override"), "sentinel-$other\n",
        'safe earlier device is also untouched by all-or-nothing preflight');
    is(read_file($probe), "probe-sentinel\n", 'drivers_probe is untouched on a preflight failure');
    ok(!-e $lspci_log, 'lspci is not needed when the exact noats token is absent');

    write_file($cmdline, "root=/dev/vda pci=noats quiet\n");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    isnt($exit, 0, 'active-only noats policy fails closed without future persistence');
    like($output, qr/persistent_noats=1/, 'missing persistent policy explains active-only rejection');
    is(read_file("$pf_path/driver_override"), "sentinel-$pf\n",
        'active-only policy leaves PF driver_override untouched');
    write_file($policy, "#!/bin/sh\nprintf '%s\\n' \"persistent_noats=1\"\n");
    make_executable($policy);

    unlink($cpuinfo);
    write_file($config, "$pf\n");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    isnt($exit, 0, 'missing CPU identity fails closed for an e212 PF');
    like($output, qr/guard status 2/, 'missing CPU identity is reported as unknown');
    is(read_file("$pf_path/driver_override"), "sentinel-$pf\n",
        'missing CPU identity leaves PF driver_override untouched');
    write_file($cpuinfo, "vendor_id : AuthenticAMD\nflags : svm\n");

    write_file($cpuinfo, "vendor_id : GenuineAlien\nflags : unknown\n");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    isnt($exit, 0, 'unrecognized CPU identity fails closed');
    like($output, qr/guard status 2/, 'unrecognized CPU identity is reported as unknown');
    write_file($cpuinfo, "vendor_id : AuthenticAMD\nflags : svm\n");

    unlink("$pf_path/vendor");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    isnt($exit, 0, 'missing PCI vendor identity fails closed');
    like($output, qr/guard status 2/, 'missing PCI vendor identity is reported as unknown');
    is(read_file("$pf_path/driver_override"), "sentinel-$pf\n",
        'missing vendor identity leaves PF driver_override untouched');
    write_pci_attr($fake, $pf, 'vendor', "0x8086\n");

    unlink("$pf_path/device");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    isnt($exit, 0, 'missing PCI device identity fails closed');
    like($output, qr/guard status 2/, 'missing PCI device identity is reported as unknown');
    is(read_file("$pf_path/driver_override"), "sentinel-$pf\n",
        'missing device identity leaves PF driver_override untouched');
    write_pci_attr($fake, $pf, 'device', "0xe212\n");

    write_file($cpuinfo, "vendor_id : GenuineIntel\nflags : vmx\n");
    replace_symlink("$fake/sys/bus/pci/drivers/vfio-pci", "$pf_path/driver");
    write_file("$pf_path/driver_override", "sentinel-$pf\n");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    is($exit, 0, 'GenuineIntel is the only explicitly recognized non-AMD CPU exemption');
    like($output, qr/VFIO binding complete/, 'GenuineIntel e212 PF is not ATS-gated');
    write_file($cpuinfo, "vendor_id : AuthenticAMD\nflags : svm\n");
    replace_symlink("$fake/sys/bus/pci/drivers/xe", "$pf_path/driver");
    write_file("$pf_path/driver_override", "sentinel-$pf\n");

    write_file($cmdline, "root=/dev/vda pci=noats quiet\n");
    write_file($lspci, <<'LSPCI_ENABLE');
#!/bin/sh
printf '%s\n' "$*" >> "$PVE_GPU_LSPCI_LOG"
printf 'ATSCtl: Enable+, Smallest Translation Unit: 00\n'
LSPCI_ENABLE
    make_executable($lspci);
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    isnt($exit, 0, 'e212 PF with ATS still enabled fails closed');
    like($output, qr/ATSCtl Enable-/, 'ATSCtl Enable- is required by the safety gate');
    is(read_file("$pf_path/driver_override"), "sentinel-$pf\n",
        'ATSCtl failure still occurs before PF driver writes');
    is(read_file($probe), "probe-sentinel\n", 'ATSCtl failure leaves drivers_probe untouched');

    write_file($lspci_log, '');
    replace_symlink("$fake/sys/bus/pci/drivers/vfio-pci", "$pf_path/driver");
    write_file("$pf_path/driver_override", "sentinel-$pf\n");
    write_file($lspci, <<'LSPCI_OK');
#!/bin/sh
printf '%s\n' "$*" >> "$PVE_GPU_LSPCI_LOG"
printf 'ATSCtl: Enable-, Smallest Translation Unit: 00\n'
LSPCI_OK
    make_executable($lspci);
    write_file($config, "$pf\n");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    is($exit, 0, 'e212 PF passes only with exact noats and ATSCtl Enable-');
    like($output, qr/VFIO binding complete/, 'successful guarded binding reaches completion');
    is(read_file("$pf_path/driver_override"), "\n", 'successful binding clears the temporary override');

    write_file($cmdline, "root=/dev/vda quiet\n");
    write_file($config, "$vf\n");
    write_file("$vf_path/driver_override", "sentinel-$vf\n");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    is($exit, 0, 'e212 VF with a physfn is not blocked by the PF safety gate');
    like($output, qr/VFIO binding complete/, 'VF binding completes without a noats cmdline');

    replace_symlink("$fake/sys/bus/pci/drivers/vfio-pci", "$other_path/driver");
    write_file($config, "$other\n");
    write_file("$other_path/driver_override", "sentinel-$other\n");
    ($output, $exit) = run_capture($vfio_script, [], \%env);
    is($exit, 0, 'other PCI devices are not blocked by the e212 PF gate');
    like($output, qr/VFIO binding complete/, 'other-device binding completes without a noats cmdline');
};

subtest 'pve-guests binder preflight propagates failed oneshots without removal coupling' => sub {
    my $fake = tempdir(CLEANUP => 1);
    my $systemctl = "$fake/bin/systemctl";
    my $log = "$fake/state/systemctl.log";
    my $vfio_conf = "$fake/etc/pve-gpu-vfio.conf";
    make_path("$fake/bin", "$fake/state", "$fake/etc");
    write_file($systemctl, <<'SYSTEMCTL');
#!/bin/sh
printf '%s\n' "$*" >> "$PVE_GPU_SYSTEMCTL_LOG"
unit=$3
case "$unit" in
    pve-gpu-vfio.service) [ "${PVE_GPU_VFIO_STATE:-inactive}" = active ] ;;
    pve-gpu-sriov.service) [ "${PVE_GPU_SRIOV_STATE:-inactive}" = active ] ;;
    *) exit 2 ;;
esac
SYSTEMCTL
    make_executable($systemctl);

    my %env = (
        PATH                  => "$fake/bin:/usr/bin:/bin",
        PVE_GPU_VFIO_CONF     => $vfio_conf,
        PVE_GPU_SYSTEMCTL_LOG => $log,
        PVE_GPU_VFIO_STATE    => 'active',
        PVE_GPU_SRIOV_STATE   => 'active',
    );
    my ($output, $exit) = run_capture($binder_check_script, [], \%env);
    is($exit, 0, 'active VFIO and SR-IOV oneshots pass the pve-guests preflight');

    write_file($vfio_conf, "0000:01:00.0\n");
    $env{PVE_GPU_VFIO_STATE} = 'failed';
    ($output, $exit) = run_capture($binder_check_script, [], \%env);
    isnt($exit, 0, 'a failed configured VFIO binder blocks pve-guests');

    unlink($vfio_conf);
    ($output, $exit) = run_capture($binder_check_script, [], \%env);
    is($exit, 0, 'an absent optional VFIO policy does not block pve-guests');

    $env{PVE_GPU_SRIOV_STATE} = 'failed';
    ($output, $exit) = run_capture($binder_check_script, [], \%env);
    isnt($exit, 0, 'a failed SR-IOV restore binder blocks pve-guests');
};

done_testing();
