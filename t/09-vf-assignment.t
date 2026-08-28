#!/usr/bin/perl
use strict;
use warnings;

use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Glob qw(bsd_glob);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use Storable qw(dclone);
use Test::More;

no warnings 'once';

delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';

my $root = tempdir(CLEANUP => 1);
my $qemu_dir = "$root/etc/pve/qemu-server";
my $sriov_config = "$root/etc/pve/local/gpu-sriov.conf";
my $sriov_lock = "$root/sriov.lock";
my $pci_lock = "$root/pci-id-reservations.lock";
make_path(dirname($sriov_config), $qemu_dir);

$ENV{PVE_GPU_SYSFS_ROOT} = $root;
$ENV{PVE_GPU_SRIOV_CONF} = $sriov_config;
$ENV{PVE_GPU_QEMU_CONF_DIR} = $qemu_dir;
$ENV{PVE_GPU_SRIOV_LOCK} = $sriov_lock;
$ENV{PVE_GPU_PCI_RESERVATION_LOCK} = $pci_lock;

my ($safe_lib) = "$FindBin::Bin/../src" =~ m{\A([A-Za-z0-9_./:+\-]+)\z};
die "Unsafe test library path\n" if !defined($safe_lib);
unshift @INC, $safe_lib;
eval { require PVE::API2::Hardware::GPU; 1 }
    or plan skip_all => "PVE Perl modules are unavailable: $@";

my $pf = '0000:0b:00.0';
my @vf_bdfs = ('0000:0b:00.1', '0000:0b:00.2');
my $pf_path = "$root/sys/bus/pci/devices/$pf";

sub write_file {
    my ($path, $value) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot create $path: $!";
    print {$fh} $value;
    close($fh) or die "Cannot close $path: $!";
}

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot read $path: $!";
    local $/;
    my $value = <$fh> // '';
    close($fh) or die "Cannot close $path: $!";
    return $value;
}

sub replace_symlink {
    my ($target, $link) = @_;
    unlink($link) if -e $link || -l $link;
    symlink($target, $link) or die "Cannot symlink $link -> $target: $!";
}

sub write_valid_sriov_config {
    write_file($sriov_config, <<"SRIOV_CONFIG");
[$pf]
allow_unsafe_scheduler = 0
api_version = 2
device_id = 0xe212
drivers_autoprobe = 0
family = bmg
num_vfs = 2
persist = 1
sched_priority = low

[$pf/vf1]
contexts_mode = auto
doorbells_mode = auto
driver =
exec_quantum_ms_mode = auto
ggtt_mode = auto
preempt_timeout_us_mode = auto
vram_mode = auto

[$pf/vf2]
contexts_mode = auto
doorbells_mode = auto
driver =
exec_quantum_ms_mode = auto
ggtt_mode = auto
preempt_timeout_us_mode = auto
vram_mode = auto
SRIOV_CONFIG
}

# A minimal xe/BMG PF and two VFs.  Assignment only needs the live VF
# topology, but the resource directories are present so the response's VF
# record can be built without touching a real debugfs tree.
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
make_path("$root/sys/module/xe", "$root/sys/class/drm/card0");
replace_symlink("$root/sys/module/xe", "$pf_path/driver");
replace_symlink($pf_path, "$root/sys/class/drm/card0/device");
write_file("$root/proc/cpuinfo", "flags: vmx\n");
write_valid_sriov_config();

for my $index (1 .. 2) {
    my $vf_bdf = $vf_bdfs[$index - 1];
    my $vf_path = "$root/sys/bus/pci/devices/$vf_bdf";
    make_path($vf_path);
    for my $pair (
        [vendor => '0x8086'],
        [device => '0xe212'],
        [subsystem_vendor => '0x8086'],
        [subsystem_device => '0x0000'],
    ) {
        write_file("$vf_path/$pair->[0]", $pair->[1]);
    }
    replace_symlink($pf_path, "$vf_path/physfn");
    replace_symlink($vf_path, "$pf_path/virtfn" . ($index - 1));

    my $tile = "$root/sys/kernel/debug/dri/$pf/sriov/vf$index/tile0";
    write_file("$tile/vram_quota", 1024 ** 3);
    write_file("$tile/ggtt_quota", 1024 ** 3);
    for my $gt (0 .. 1) {
        write_file("$tile/gt$gt/contexts_quota", 1024);
        write_file("$tile/gt$gt/doorbells_quota", 8);
        write_file("$tile/gt$gt/exec_quantum_ms", 0);
        write_file("$tile/gt$gt/preempt_timeout_us", 0);
        write_file("$tile/gt$gt/sched_priority", 0);
    }
}

my %vm_config;
my %running;
my %fail_write;
my %mock_driver = map { $_ => '' } @vf_bdfs;
my @driver_autoprobe_seen;
my @lock_events;
my @lock_args;
my $write_calls = 0;
my $parse_calls = 0;
my $pci_hook;

sub _vm_conf_path {
    my ($vmid) = @_;
    return "$qemu_dir/$vmid.conf";
}

sub _write_vm_file {
    my ($vmid, $conf) = @_;
    my @lines;
    for my $key (sort keys %$conf) {
        next if ref($conf->{$key});
        next if !defined($conf->{$key});
        next if $key !~ /^(?:hostpci\d+|machine|template|lock|name)$/;
        push @lines, "$key: $conf->{$key}\n";
    }
    write_file(_vm_conf_path($vmid), join('', @lines));
}

sub set_vm {
    my ($vmid, $conf) = @_;
    $vm_config{$vmid} = dclone($conf);
    _write_vm_file($vmid, $vm_config{$vmid});
}

sub reset_vms {
    unlink($_) for bsd_glob("$qemu_dir/*.conf");
    %vm_config = ();
    %running = ();
    %fail_write = ();
    %mock_driver = map { $_ => '' } @vf_bdfs;
    write_file("$root/sys/bus/pci/devices/$_/driver_override", '(null)') for @vf_bdfs;
    write_file("$pf_path/sriov_drivers_autoprobe", '0');
    @driver_autoprobe_seen = ();
    @lock_events = ();
    @lock_args = ();
    $write_calls = 0;
    $parse_calls = 0;
    $pci_hook = undef;
}

sub assign_vf {
    my ($bdf, $vf_index, $vmid) = @_;
    my ($result, $error);
    {
        local $@;
        my $ok = eval {
            $result = PVE::API2::Hardware::GPU::_set_vf_assignment(
                $bdf, $vf_index, $vmid,
            );
            1;
        };
        $error = $@ if !$ok;
    }
    return ($result, $error // '');
}

{
    no warnings 'redefine';

    # Return copies so the production code can mutate loaded configurations
    # without mutating the fixture's source of truth before write_config.
    *PVE::QemuConfig::load_config = sub {
        my ($class, $vmid) = @_;
        die "mock VM $vmid does not exist\n" if !exists($vm_config{$vmid});
        return dclone($vm_config{$vmid});
    };

    *PVE::QemuConfig::write_config = sub {
        my ($class, $vmid, $conf) = @_;
        $write_calls++;
        if ($fail_write{$vmid}) {
            $fail_write{$vmid}--;
            die "injected write failure for VM $vmid\n";
        }
        $vm_config{$vmid} = dclone($conf);
        _write_vm_file($vmid, $vm_config{$vmid});
        return 1;
    };

    *PVE::QemuConfig::lock_config_full = sub {
        my ($class, $vmid, $timeout, $code, @args) = @_;
        push @lock_events, "vm:$vmid";
        push @lock_args, [$vmid, $timeout];
        die "injected VM lock failure for VM $vmid\n"
            if $vmid eq '__lock_failure__';
        return $code->(@args);
    };

    *PVE::QemuConfig::parse_pending_delete = sub {
        my ($class, $value) = @_;
        $value = $class if @_ == 1;
        return {} if !defined($value) || $value eq '';
        return $value if ref($value) eq 'HASH';
        my %result;
        $result{$_} = 1 for grep { /^hostpci\d+$/ } split(/[;,\s]+/, $value);
        return \%result;
    };

    *PVE::QemuServer::Helpers::vm_running_locally = sub {
        my ($vmid) = @_;
        return $running{$vmid} ? 1 : 0;
    };

    *PVE::QemuServer::Machine::machine_type_is_q35 = sub {
        my ($conf) = @_;
        return ref($conf) eq 'HASH' && ($conf->{machine} // '') =~ /^q35/ ? 1 : 0;
    };

    # The real parser is intentionally replaced in this fixture.  It still
    # rejects non-scalar/empty hostpci values and records every validation so
    # the transaction cannot silently skip the native validation phase.
    *PVE::QemuServer::PCI::parse_hostpci_devices = sub {
        my ($conf) = @_;
        $parse_calls++;
        for my $key (grep { /^hostpci\d+$/ } keys %$conf) {
            my $value = $conf->{$key};
            die "mock invalid $key\n" if ref($value) || !defined($value) || $value eq '';
        }
        return {};
    };

    *PVE::API2::Hardware::GPU::_pci_driver = sub {
        my ($bdf) = @_;
        return 'xe' if $bdf eq $pf;
        return $mock_driver{$bdf} // '';
    };

    *PVE::API2::Hardware::GPU::_set_vf_driver_state = sub {
        my ($bdf, $driver) = @_;
        my $autoprobe = read_file("$pf_path/sriov_drivers_autoprobe");
        $autoprobe =~ s/\s+\z//;
        push @driver_autoprobe_seen, $autoprobe;
        $mock_driver{$bdf} = $driver // '';
        write_file("$root/sys/bus/pci/devices/$bdf/driver_override", '(null)');
        return 1;
    };

    *PVE::API2::Hardware::GPU::_restore_vf_driver_state = sub {
        my ($bdf, $driver, $override) = @_;
        $mock_driver{$bdf} = $driver // '';
        write_file(
            "$root/sys/bus/pci/devices/$bdf/driver_override",
            defined($override) ? $override : '(null)',
        );
        return 1;
    };

    # Keep a real exclusive file lock, while exposing order and the exact
    # reservation path to the assertions below.  The hook models a VM config
    # appearing after the initial VM-lock set was collected.
    *PVE::Tools::lock_file = sub {
        my ($path, $timeout, $code, @args) = @_;
        push @lock_events, "pci:$path";
        open(my $fh, '>>', $path) or die "Cannot create mock lock $path: $!";
        flock($fh, LOCK_EX) or die "Cannot lock mock lock $path: $!";
        if ($pci_hook) {
            my $hook = $pci_hook;
            $pci_hook = undef;
            $hook->();
        }
        my ($result, $error);
        my $ok = eval {
            $result = $code->(@args);
            1;
        };
        $error = $@ if !$ok;
        close($fh) or die "Cannot close mock lock $path: $!";
        die $error if !$ok;
        return $result;
    };
}

my $max_slots = int($PVE::QemuServer::PCI::MAX_HOSTPCI_DEVICES // 16);
$max_slots = 16 if $max_slots < 1;

# Basic assignment also verifies the lock order.  All existing VM locks are
# acquired numerically before the native PCI reservation lock.
reset_vms();
set_vm(3, {});
set_vm(20, {});
set_vm(101, {
    machine  => 'q35',
    hostpci0 => '0000:22:00.0',
    hostpci2 => '0000:23:00.0',
    name     => 'slot-test',
});
my ($result, $error) = assign_vf($pf, 1, 101);
ok(!$error, 'assigning an unassigned VF to a stopped VM succeeds') or diag($error);
ok($result && ${$result->{success}}, 'assignment response reports success');
ok($result && ${$result->{changed}}, 'first assignment reports changed=true');
is($result->{assignment}{vmid}, 101, 'assignment response reports target VM');
is($result->{assignment}{hostpci}, 'hostpci1', 'first free hostpci slot fills the hole');
like($vm_config{101}{hostpci1}, qr/^0000:0b:00\.1,rombar=0,pcie=1$/,
    'q35 assignment uses the canonical VF BDF and pcie=1');
is($mock_driver{$vf_bdfs[0]}, 'vfio-pci',
    'assignment explicitly binds an autoprobe-disabled VF to vfio-pci');
is(PVE::API2::Hardware::GPU::_persisted_vf_driver($pf, 1), 'vfio-pci',
    'assignment persists vfio-pci for boot-time VF restoration');
is($parse_calls, 1, 'native PCI hostpci validation is invoked before commit');
is_deeply(\@lock_events, [
    'vm:3', 'vm:20', 'vm:101', "pci:$pci_lock",
], 'VM locks are ordered numerically and precede PCI reservation lock');
is_deeply(\@lock_args, [[3, 10], [20, 10], [101, 10]],
    'lock_config_full receives VMID, ten-second timeout, and callback');
ok(-e $pci_lock, 'assignment creates/uses the configured PCI reservation lock');

my $assigned_file = read_file(_vm_conf_path(101));
my $writes_before = $write_calls;
($result, $error) = assign_vf($pf, 1, 101);
ok(!$error, 'repeating the same assignment succeeds idempotently') or diag($error);
ok($result && !${$result->{changed}}, 'repeating the same assignment reports changed=false');
is($write_calls, $writes_before, 'idempotent assignment does not write the VM config');
is(read_file(_vm_conf_path(101)), $assigned_file,
    'idempotent assignment leaves the serialized config byte-for-byte unchanged');

reset_vms();
set_vm(102, { machine => 'q35' });
write_file("$pf_path/sriov_drivers_autoprobe", '1');
($result, $error) = assign_vf($pf, 1, 102);
ok(!$error, 'assignment succeeds when PF driver autoprobe starts enabled') or diag($error);
is_deeply(\@driver_autoprobe_seen, ['0'],
    'VF driver mutation runs only after sriov_drivers_autoprobe is forced off');
is(read_file("$pf_path/sriov_drivers_autoprobe"), '1',
    'assignment restores the original driver autoprobe state');

# A move removes only the exact source entry and chooses the target's lowest
# free slot, preserving unrelated passthrough devices on both VMs.
reset_vms();
set_vm(201, {
    hostpci0 => '0000:30:00.0',
    hostpci3 => '0000:0b:00.1,rombar=0',
});
set_vm(202, {
    hostpci2 => '0000:31:00.0',
});
($result, $error) = assign_vf($pf, 1, 202);
ok(!$error, 'moving a stopped VF from one VM to another succeeds') or diag($error);
ok($result && ${$result->{changed}}, 'move reports changed=true');
is($result->{assignment}{vmid}, 202, 'move response names the new owner');
is($result->{assignment}{hostpci}, 'hostpci0', 'move chooses the target lowest free slot');
ok(!exists($vm_config{201}{hostpci3}), 'move deletes the exact source hostpci entry');
is($vm_config{201}{hostpci0}, '0000:30:00.0', 'move preserves source unrelated PCI entry');
is($vm_config{202}{hostpci2}, '0000:31:00.0', 'move preserves target unrelated PCI entry');
like($vm_config{202}{hostpci0}, qr/^0000:0b:00\.1,rombar=0$/,
    'move writes the VF at the target slot');

my $target_before_clear = read_file(_vm_conf_path(202));
($result, $error) = assign_vf($pf, 1, 0);
ok(!$error, 'clearing an existing VF assignment succeeds') or diag($error);
ok($result && ${$result->{changed}}, 'first clear reports changed=true');
ok(!exists($vm_config{202}{hostpci0}), 'clear removes only the VF source entry');
is($mock_driver{$vf_bdfs[0]}, '', 'clear leaves the VF explicitly unbound');
is(PVE::API2::Hardware::GPU::_persisted_vf_driver($pf, 1), '',
    'clear removes the persisted VF driver binding');
is($vm_config{202}{hostpci2}, '0000:31:00.0', 'clear preserves other hostpci entries');
my $writes_after_clear = $write_calls;
($result, $error) = assign_vf($pf, 1, 0);
ok(!$error, 'clearing an already-clear VF is idempotent') or diag($error);
ok($result && !${$result->{changed}}, 'idempotent clear reports changed=false');
is($write_calls, $writes_after_clear, 'idempotent clear does not write a VM config');
is(read_file(_vm_conf_path(202)), $target_before_clear =~ s/hostpci0:.*\n//r,
    'clear leaves the serialized unrelated target configuration intact');

# Exact matching is required before removal.  A multi-function hostpci entry
# must fail closed rather than deleting a device which merely contains the VF.
reset_vms();
set_vm(203, {
    hostpci0 => '0000:40:00.0',
    hostpci4 => 'host=0000:0b:00.1,rombar=0',
});
($result, $error) = assign_vf($pf, 1, 0);
ok(!$error, 'clear accepts an exact host= VF source entry') or diag($error);
ok(!exists($vm_config{203}{hostpci4}), 'exact source entry is removed');
is($vm_config{203}{hostpci0}, '0000:40:00.0', 'exact clear preserves unrelated source entry');

reset_vms();
set_vm(204, {
    hostpci0 => '0000:41:00.0',
    hostpci1 => '0000:0b:00.1;0000:0b:00.2',
});
my $multi_before = read_file(_vm_conf_path(204));
($result, $error) = assign_vf($pf, 1, 0);
ok(!$result, 'clear rejects a source entry resolving to multiple PCI functions');
like($error, qr/exactly VF/i, 'multi-function source rejection explains exact-match failure');
is(read_file(_vm_conf_path(204)), $multi_before,
    'rejected exact-match clear does not mutate the source config');

# Safety guards are checked while the VM lock is held and must reject without
# any write.  Pending hostpci and pending-delete state are both unsafe.
subtest 'VM state rejection' => sub {
    my @cases = (
        [301, { }, 'running', qr/Stop VM 301/],
        [302, { template => 1 }, 'template', qr/template/],
        [303, { lock => 'backup' }, 'locked', qr/locked/],
        [304, { pending => { hostpci0 => '0000:42:00.0' } }, 'pending hostpci', qr/pending PCI/],
        [305, { pending => { delete => 'hostpci0' } }, 'pending hostpci deletion', qr/pending PCI/],
    );

    for my $case (@cases) {
        reset_vms();
        my ($vmid, $conf, $label, $pattern) = @$case;
        set_vm($vmid, $conf);
        $running{$vmid} = 1 if $label eq 'running';
        my $before = read_file(_vm_conf_path($vmid));
        my $before_writes = $write_calls;
        my ($got, $why) = assign_vf($pf, 1, $vmid);
        ok(!$got, "$label VM assignment is rejected");
        like($why, $pattern, "$label rejection identifies the unsafe state");
        is($write_calls, $before_writes, "$label rejection performs no write");
        is(read_file(_vm_conf_path($vmid)), $before, "$label rejection preserves config");
    }

    reset_vms();
    set_vm(306, { hostpci5 => '0000:0b:00.1,rombar=0' });
    $running{306} = 1;
    my $before = read_file(_vm_conf_path(306));
    my ($got, $why) = assign_vf($pf, 1, 0);
    ok(!$got, 'clearing a running VM VF assignment is rejected');
    like($why, qr/Stop VM 306/, 'running source rejection identifies the VM');
    is(read_file(_vm_conf_path(306)), $before, 'running source rejection preserves config');
};

# A whole-PF consumer blocks VF assignment.  This is distinct from an
# existing VF owner: the PF and VFs cannot be safely mixed in this endpoint.
reset_vms();
set_vm(401, { hostpci0 => "$pf,rombar=0" });
set_vm(402, {});
my $pf_target_before = read_file(_vm_conf_path(402));
($result, $error) = assign_vf($pf, 1, 402);
ok(!$result, 'VF assignment is rejected while the PF is assigned to another VM');
like($error, qr/PF|whole.?GPU|assigned/i,
    'PF consumer rejection explains the conflicting whole-device assignment');
is(read_file(_vm_conf_path(402)), $pf_target_before,
    'PF consumer rejection does not mutate the target VM');

# There are only MAX_HOSTPCI_DEVICES native slots; a full target must fail
# before write_config and must not overwrite an existing passthrough device.
reset_vms();
my %full_slots;
for my $slot (0 .. $max_slots - 1) {
    $full_slots{"hostpci$slot"} = sprintf('0000:%02x:00.0', 0x50 + $slot);
}
set_vm(501, \%full_slots);
my $full_before = read_file(_vm_conf_path(501));
($result, $error) = assign_vf($pf, 1, 501);
ok(!$result, 'assignment rejects a target VM with all hostpci slots occupied');
like($error, qr/No free hostpci slot/i, 'full-slot rejection identifies the slot limit');
is($write_calls, 0, 'full-slot rejection performs no write');
is(read_file(_vm_conf_path(501)), $full_before,
    'full-slot rejection preserves every existing hostpci entry');

# PF/VF input and live topology checks fail closed before a VM config write.
reset_vms();
set_vm(601, {});
($result, $error) = assign_vf($pf, 3, 601);
ok(!$result, 'VF index above sriov_numvfs is rejected');
like($error, qr/out of range/i, 'out-of-range VF rejection is explicit');
($result, $error) = assign_vf($vf_bdfs[0], 1, 601);
ok(!$result, 'passing a VF BDF where a PF is required is rejected');
like($error, qr/not found|supported GPU/i, 'VF-as-PF rejection is explicit');

unlink("$pf_path/virtfn1");
($result, $error) = assign_vf($pf, 2, 601);
ok(!$result, 'a missing live virtfn link is rejected');
like($error, qr/Cannot resolve VF/i, 'missing virtfn rejection is explicit');
replace_symlink($root . '/sys/bus/pci/devices/' . $vf_bdfs[1], "$pf_path/virtfn1");

# If a move fails after the source config is written, both source and target
# snapshots must be restored.  The serialized files are the same files read
# by the strict consumer scan, so this also proves rollback restores scanner
# visibility rather than only an in-memory hash.
reset_vms();
set_vm(701, {
    hostpci0 => '0000:70:00.0',
    hostpci4 => '0000:0b:00.1,rombar=0',
});
set_vm(702, {
    hostpci2 => '0000:71:00.0',
});
my $source_before_rollback = read_file(_vm_conf_path(701));
my $target_before_rollback = read_file(_vm_conf_path(702));
$fail_write{702} = 1;
($result, $error) = assign_vf($pf, 1, 702);
ok(!$result, 'a post-source write failure makes the move fail');
like($error, qr/injected write failure/, 'move returns the write failure');
is(read_file(_vm_conf_path(701)), $source_before_rollback,
    'rollback restores the source VM configuration');
is(read_file(_vm_conf_path(702)), $target_before_rollback,
    'rollback restores the target VM configuration');
my $after_rollback = PVE::API2::Hardware::GPU::check_vf_vm_assignments(
    $pf, 'card0', 2, 1,
);
is(scalar(grep { $_->{vf_index} == 1 && $_->{vmid} == 701 } @$after_rollback), 1,
    'strict consumer scan sees the restored source assignment after rollback');

# A VM appearing after the initial lock set is detected before any config
# mutation.  This guards ownership races between the VM inventory scan and
# the strict consumer check.
reset_vms();
set_vm(801, {});
$pci_hook = sub { set_vm(802, {}) };
($result, $error) = assign_vf($pf, 1, 801);
ok(!$result, 'a VM inventory change during reservation locking is rejected');
like($error, qr/QEMU VM set changed/i, 'VM inventory race is reported explicitly');
ok(!exists($vm_config{801}{hostpci0}), 'VM inventory race performs no target write');

# VM assignment is a persistent operation.  Its profile must be the same
# complete, boot-restorable state that apply-sriov-config accepts.
subtest 'assignment requires a boot-restorable PF/VF profile' => sub {
    my @invalid_profiles = (
        [
            'persistence is disabled',
            sub { $_[0]->{$pf}{persist} = 0 },
            qr/persistent SR-IOV profile/,
        ],
        [
            'API version is stale',
            sub { $_[0]->{$pf}{api_version} = 1 },
            qr/api_version=2/,
        ],
        [
            'persisted VF topology differs from live topology',
            sub { $_[0]->{$pf}{num_vfs} = 1 },
            qr/does not match the live VF topology/,
        ],
        [
            'driver autoprobe policy is missing',
            sub { delete $_[0]->{$pf}{drivers_autoprobe} },
            qr/invalid drivers_autoprobe/,
        ],
        [
            'normal scheduler lacks its acknowledgement',
            sub { $_[0]->{$pf}{sched_priority} = 'normal' },
            qr/invalid scheduler policy/,
        ],
        [
            'persisted family is not the live BMG family',
            sub { $_[0]->{$pf}{family} = 'flex' },
            qr/supported BMG family/,
        ],
        [
            'another live VF has an incomplete resource profile',
            sub { delete $_[0]->{"$pf/vf2"}{contexts_mode} },
            qr/VF2 resource 'contexts' mode/,
        ],
        [
            'a BMG VF requests the legacy i915 driver',
            sub { $_[0]->{"$pf/vf2"}{driver} = 'i915' },
            qr/VF2 has unsupported driver 'i915'/,
        ],
    );

    for my $case (@invalid_profiles) {
        my ($label, $mutate, $pattern) = @$case;
        reset_vms();
        set_vm(901, {});
        write_valid_sriov_config();
        my $profile = PVE::API2::Hardware::GPU::parse_ini_config(
            $sriov_config,
            1,
        );
        $mutate->($profile);
        PVE::API2::Hardware::GPU::write_ini_config($sriov_config, $profile);

        my ($got, $why) = assign_vf($pf, 1, 901);
        ok(!$got, "$label is rejected");
        like($why, $pattern, "$label reports the profile invariant");
        ok(!exists($vm_config{901}{hostpci0}),
            "$label leaves the VM config unchanged");
    }

    reset_vms();
    set_vm(902, {});
    write_valid_sriov_config();
    my ($assigned, $assign_error) = assign_vf($pf, 1, 902);
    ok($assigned && !$assign_error, 'fixture VF is assigned before clear test')
        or diag($assign_error);
    my $profile = PVE::API2::Hardware::GPU::parse_ini_config($sriov_config, 1);
    $profile->{$pf}{persist} = 0;
    PVE::API2::Hardware::GPU::write_ini_config($sriov_config, $profile);
    my ($cleared, $clear_error) = assign_vf($pf, 1, 0);
    ok($cleared && !$clear_error,
        'unassignment remains available after persistence is disabled')
        or diag($clear_error);
    ok(!exists($vm_config{902}{hostpci0}),
        'recovery unassignment removes the VM hostpci entry');
    is($mock_driver{$vf_bdfs[0]}, '',
        'recovery unassignment leaves the VF unbound');
    my $after_clear = PVE::API2::Hardware::GPU::parse_ini_config(
        $sriov_config,
        1,
    );
    is($after_clear->{$pf}{persist}, 0,
        'recovery unassignment does not rewrite the invalid profile');
    is($after_clear->{"$pf/vf1"}{driver}, 'vfio-pci',
        'recovery unassignment skips persistence mutation for an invalid profile');
};

write_valid_sriov_config();

done_testing();
