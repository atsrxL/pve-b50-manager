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
my $vfio_config = "$root/etc/pve-gpu-vfio.conf";
my $power_state = "$root/run/pve-gpu/power-state.conf";
my $sriov_lock = "$root/sriov.lock";
my $pci_lock = "$root/pci-id-reservations.lock";
make_path(dirname($sriov_config), $qemu_dir);

$ENV{PVE_GPU_SYSFS_ROOT} = $root;
$ENV{PVE_GPU_SRIOV_CONF} = $sriov_config;
$ENV{PVE_GPU_VFIO_CONF} = $vfio_config;
$ENV{PVE_GPU_QEMU_CONF_DIR} = $qemu_dir;
$ENV{PVE_GPU_SRIOV_LOCK} = $sriov_lock;
$ENV{PVE_GPU_PCI_RESERVATION_LOCK} = $pci_lock;
$ENV{PVE_GPU_POWER_STATE} = $power_state;

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
write_file("$root/proc/cpuinfo", "vendor_id : GenuineIntel\nflags: vmx\n");
write_file("$pf_path/sriov_admin/pf/profile/sched_priority", '0');
write_file("$pf_path/sriov_admin/.bulk_profile/sched_priority", '0');
write_file("$root/sys/kernel/debug/dri/$pf/sriov/restore_auto_provisioning", '0');
write_file("$pf_path/power/control", 'auto');
write_file("$pf_path/power/autosuspend_delay_ms", '1000');
write_file("$pf_path/power/runtime_status", 'suspended');
write_file("$pf_path/power/runtime_usage", '0');
write_file("$pf_path/power_state", 'D3cold');
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
    write_file("$pf_path/sriov_admin/vf$index/profile/sched_priority", '0');

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
my $mock_pf_driver = 'xe';
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
    unlink($vfio_config) if -e $vfio_config;
    unlink($power_state) if -e $power_state;
    %vm_config = ();
    %running = ();
    %fail_write = ();
    %mock_driver = map { $_ => '' } @vf_bdfs;
    $mock_pf_driver = 'xe';
    write_file("$root/sys/bus/pci/devices/$_/driver_override", '(null)') for @vf_bdfs;
    write_file("$pf_path/driver_override", '(null)');
    write_file("$pf_path/sriov_numvfs", '2');
    write_file("$pf_path/sriov_drivers_autoprobe", '0');
    write_file("$pf_path/power/control", 'auto');
    write_file("$pf_path/power/autosuspend_delay_ms", '1000');
    write_file("$pf_path/power/runtime_status", 'suspended');
    write_file("$pf_path/power/runtime_usage", '0');
    write_file("$pf_path/power_state", 'D3cold');
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

sub switch_pf {
    my ($bdf, $vmid) = @_;
    my ($result, $error);
    {
        local $@;
        my $ok = eval {
            $result = PVE::API2::Hardware::GPU::_switch_to_pf_passthrough(
                $bdf,
                $vmid,
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
        return $mock_pf_driver if $bdf eq $pf;
        return $mock_driver{$bdf} // '';
    };

    *PVE::API2::Hardware::GPU::_set_vf_driver_state = sub {
        my ($bdf, $driver) = @_;
        my $autoprobe = read_file("$pf_path/sriov_drivers_autoprobe");
        $autoprobe =~ s/\s+\z//;
        push @driver_autoprobe_seen, $autoprobe;
        if ($bdf eq $pf) {
            $mock_pf_driver = $driver // '';
        } else {
            $mock_driver{$bdf} = $driver // '';
        }
        write_file("$root/sys/bus/pci/devices/$bdf/driver_override", '(null)');
        return 1;
    };

    *PVE::API2::Hardware::GPU::_restore_vf_driver_state = sub {
        my ($bdf, $driver, $override) = @_;
        if ($bdf eq $pf) {
            $mock_pf_driver = $driver // '';
        } else {
            $mock_driver{$bdf} = $driver // '';
        }
        write_file(
            "$root/sys/bus/pci/devices/$bdf/driver_override",
            defined($override) ? $override : '(null)',
        );
        return 1;
    };

    *PVE::API2::Hardware::GPU::_bind_vf_driver = sub {
        my ($bdf, $driver) = @_;
        $mock_driver{$bdf} = $driver // '';
        write_file("$root/sys/bus/pci/devices/$bdf/driver_override", '(null)');
        return 1;
    };

    *PVE::API2::Hardware::GPU::_unbind_vf = sub {
        my ($bdf) = @_;
        $mock_driver{$bdf} = '';
        write_file("$root/sys/bus/pci/devices/$bdf/driver_override", '(null)');
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

subtest 'whole-PF convenience transaction rejects unsafe VM state and mappings' => sub {
    reset_vms();
    write_valid_sriov_config();
    set_vm(1001, { hostpci0 => "$vf_bdfs[0],rombar=0" });
    set_vm(1002, { machine => 'q35' });
    $running{1001} = 1;
    my ($got, $why) = switch_pf($pf, 1002);
    ok(!$got, 'a running VF consumer blocks the whole-PF transaction');
    like($why, qr/Stop VM 1001/, 'the running consumer is identified');
    is(read_file("$pf_path/sriov_numvfs"), '2',
        'unsafe VM state is rejected before the VF topology changes');
    is($mock_pf_driver, 'xe',
        'unsafe VM state is rejected before the PF driver changes');

    reset_vms();
    write_valid_sriov_config();
    set_vm(1003, { hostpci0 => "mapping=b50-vf" });
    set_vm(1004, {});
    {
        no warnings 'redefine';
        local *PVE::API2::Hardware::GPU::_resolve_hostpci_bdfs = sub {
            my ($value, $strict) = @_;
            return ($vf_bdfs[0]) if $value =~ /mapping=b50-vf/;
            return PVE::API2::Hardware::GPU::_normalise_bdf(
                ($value =~ /^([^,]+)/)[0],
            );
        };
        ($got, $why) = switch_pf($pf, 1004);
    }
    ok(!$got, 'a mapping-backed VF assignment is not deleted automatically');
    like($why, qr/PCI mapping/, 'mapping rejection gives an actionable reason');
    is(read_file("$pf_path/sriov_numvfs"), '2',
        'mapping rejection leaves the VF topology unchanged');
};

subtest 'whole-PF transaction rolls back VM, topology, drivers, and policies' => sub {
    reset_vms();
    write_valid_sriov_config();
    write_file($vfio_config, "0000:0a:00.0\n");
    set_vm(1101, {
        hostpci0 => '0000:70:00.0',
        hostpci3 => "$vf_bdfs[0],rombar=0",
    });
    set_vm(1102, {
        machine => 'q35',
        hostpci2 => '0000:71:00.0',
    });
    $mock_driver{$vf_bdfs[0]} = 'vfio-pci';
    $mock_driver{$vf_bdfs[1]} = 'xe';
    write_file("$root/sys/bus/pci/devices/$vf_bdfs[0]/driver_override", 'xe');

    my $source_before = read_file(_vm_conf_path(1101));
    my $target_before = read_file(_vm_conf_path(1102));
    my $sriov_before = read_file($sriov_config);
    my $vfio_before = read_file($vfio_config);
    $fail_write{1102} = 1;
    my ($got, $why) = switch_pf($pf, 1102);

    ok(!$got, 'an injected target VM write failure aborts whole-PF passthrough');
    like($why, qr/injected write failure/, 'the transaction reports its original failure');
    is(read_file(_vm_conf_path(1101)), $source_before,
        'rollback restores the VF source VM configuration');
    is(read_file(_vm_conf_path(1102)), $target_before,
        'rollback restores the target VM configuration');
    is(read_file("$pf_path/sriov_numvfs"), '2',
        'rollback recreates the original VF topology');
    is($mock_pf_driver, 'xe', 'rollback restores the PF xe driver');
    is($mock_driver{$vf_bdfs[0]}, 'vfio-pci',
        'rollback restores the first VF driver');
    is($mock_driver{$vf_bdfs[1]}, 'xe',
        'rollback restores the second VF driver');
    is(read_file("$root/sys/bus/pci/devices/$vf_bdfs[0]/driver_override"), 'xe',
        'rollback restores the exact VF driver_override value');
    is(read_file($sriov_config), $sriov_before,
        'rollback restores the complete SR-IOV persistence file');
    is(read_file($vfio_config), $vfio_before,
        'rollback restores the VFIO policy without losing unrelated BDFs');
};

subtest 'whole-PF transaction, running no-op, and stopped move' => sub {
    reset_vms();
    write_valid_sriov_config();
    write_file($vfio_config, "0000:0a:00.0\n");
    set_vm(1201, {
        hostpci0 => '0000:72:00.0',
        hostpci4 => "$vf_bdfs[0],rombar=0",
    });
    set_vm(1202, { hostpci1 => "host=$vf_bdfs[1],rombar=0" });
    set_vm(1203, {
        machine => 'q35',
        hostpci2 => '0000:73:00.0',
    });
    $mock_driver{$vf_bdfs[0]} = 'vfio-pci';
    $mock_driver{$vf_bdfs[1]} = 'vfio-pci';

    my ($got, $why) = switch_pf($pf, 1203);
    ok($got && !$why, 'stopped VF consumers are replaced by one whole-PF assignment')
        or diag($why);
    ok($got && ${$got->{changed}}, 'the first whole-PF switch reports changed=true');
    is_deeply($got->{detached_vmids}, [1201, 1202],
        'the response identifies every detached VF consumer VM');
    ok(!exists($vm_config{1201}{hostpci4}),
        'the first VF hostpci entry is removed');
    is($vm_config{1201}{hostpci0}, '0000:72:00.0',
        'unrelated source PCI devices remain configured');
    ok(!exists($vm_config{1202}{hostpci1}),
        'the second VF hostpci entry is removed');
    is($vm_config{1203}{hostpci0}, "$pf,pcie=1",
        'q35 receives the exact PF function with pcie=1 and no ROM-Bar or x-vga flags');
    is($vm_config{1203}{hostpci2}, '0000:73:00.0',
        'unrelated target PCI devices remain configured');
    is(read_file("$pf_path/sriov_numvfs"), '0',
        'all VFs are removed');
    is($mock_pf_driver, 'vfio-pci', 'the PF is bound to vfio-pci');
    my $sriov_after = PVE::API2::Hardware::GPU::parse_ini_config(
        $sriov_config,
        1,
    );
    ok(!exists($sriov_after->{$pf}) &&
       !(grep { /^\Q$pf\E\/vf\d+$/ } keys %$sriov_after),
        'the PF and all VF boot profiles are removed');
    is(read_file($vfio_config), "0000:0a:00.0\n$pf\n",
        'the PF boot policy is added while an unrelated VFIO BDF is preserved');

    $vm_config{1203}{pending} = { delete => 'hostpci0' };
    my $writes_before_pending = $write_calls;
    ($got, $why) = switch_pf($pf, 1203);
    ok(!$got, 'same-target verification rejects a pending PF removal');
    like($why, qr/pending PCI/, 'the pending same-target change is identified');
    is($write_calls, $writes_before_pending,
        'pending same-target rejection does not rewrite a VM config');
    delete $vm_config{1203}{pending};

    my $writes_before_noop = $write_calls;
    $running{1203} = 1;
    ($got, $why) = switch_pf($pf, 1203);
    ok($got && !$why, 'the already-correct running target is accepted as a pure no-op')
        or diag($why);
    ok($got && !${$got->{changed}}, 'the running same-target call reports changed=false');
    is($write_calls, $writes_before_noop,
        'the running same-target no-op does not rewrite a VM config');

    $running{1203} = 0;
    set_vm(1204, { machine => 'q35' });
    ($got, $why) = switch_pf($pf, 1204);
    ok($got && !$why, 'an existing stopped PF assignment moves to another stopped VM')
        or diag($why);
    ok(!exists($vm_config{1203}{hostpci0}),
        'the old whole-PF assignment is removed');
    is($vm_config{1204}{hostpci0}, "$pf,pcie=1",
        'the new target receives the canonical whole-PF hostpci value');
    is($mock_pf_driver, 'vfio-pci',
        'moving an existing PF assignment does not disturb the live VFIO driver');
    is(read_file($vfio_config), "0000:0a:00.0\n$pf\n",
        'moving the PF preserves the existing boot policy');
};

subtest 'whole-PF transaction rejects a consumer outside the VM lock set' => sub {
    reset_vms();
    write_valid_sriov_config();
    set_vm(1301, { machine => 'q35' });

    my $real_scan = \&PVE::API2::Hardware::GPU::_scan_qemu_pci_consumers;
    my $injected = 0;
    my ($got, $why);
    {
        no warnings 'redefine';
        local *PVE::API2::Hardware::GPU::_all_qemu_vmids = sub { return (1301) };
        local *PVE::API2::Hardware::GPU::_scan_qemu_pci_consumers = sub {
            if (!$injected++) {
                set_vm(1302, { hostpci0 => "$vf_bdfs[0],rombar=0" });
            }
            return $real_scan->(@_);
        };
        ($got, $why) = switch_pf($pf, 1301);
    }

    ok(!$got, 'a late VF consumer outside the VM lock set is rejected');
    like($why, qr/after the VM lock set was acquired/,
        'late-consumer rejection identifies the lock-set race');
    ok(!(grep { $_ eq 'vm:1302' } @lock_events),
        'the fixture proves the late consumer was never locked');
    is(read_file("$pf_path/sriov_numvfs"), '2',
        'late-consumer rejection occurs before VF topology mutation');
    is($mock_pf_driver, 'xe',
        'late-consumer rejection occurs before PF driver mutation');
};

subtest 'AMD B50 ATS policy gates PF writes and exposes helper actions' => sub {
    my $old_cpuinfo = read_file("$root/proc/cpuinfo");
    my $old_cmdline = -e "$root/proc/cmdline"
        ? read_file("$root/proc/cmdline")
        : undef;
    my $helper = "$root/manage-ats-policy.sh";
    my $helper_persistent = 0;
    my $helper_managed = 1;
    my $helper_boot_mode = 'grub';
    my $helper_failure = 0;
    my $lspci_failure = 0;
    my $lspci_output = "ATSCtl: Enable+\n";
    my @ats_commands;

    {
        no warnings 'redefine';
        local $ENV{PVE_GPU_ATS_POLICY_HELPER} = $helper;
        local *PVE::API2::Hardware::GPU::_get_device_name = sub {
            return 'B50 test fixture';
        };
        local *PVE::API2::Hardware::GPU::_ats_command_capture = sub {
            my ($command) = @_;
            push @ats_commands, [@$command];
            if ($command->[0] eq 'lspci') {
                return {
                    success => 0,
                    exit_code => 1,
                    stdout => $lspci_output,
                    stderr => '',
                    error => 'injected lspci failure',
                } if $lspci_failure;
                return {
                    success => 1,
                    exit_code => 0,
                    stdout => $lspci_output,
                    stderr => '',
                    error => undef,
                };
            }
            if ($command->[0] eq $helper && $command->[1] eq 'status') {
                return {
                    success => 0,
                    exit_code => 1,
                    stdout => '',
                    stderr => '',
                    error => 'injected helper status failure',
                } if $helper_failure;
                return {
                    success => 1,
                    exit_code => 0,
                    stdout => "boot_mode=$helper_boot_mode\n" .
                        "persistent_noats=$helper_persistent\n" .
                        "managed=$helper_managed\n",
                    stderr => '',
                    error => undef,
                };
            }
            if ($command->[0] eq $helper && $command->[1] eq 'enable') {
                return {
                    success => 0,
                    exit_code => 1,
                    stdout => '',
                    stderr => '',
                    error => 'injected helper enable failure',
                } if $helper_failure;
                $helper_persistent = 1;
                return { success => 1, exit_code => 0, stdout => '', stderr => '', error => undef };
            }
            if ($command->[0] eq $helper && $command->[1] eq 'disable') {
                return {
                    success => 0,
                    exit_code => 1,
                    stdout => '',
                    stderr => '',
                    error => 'injected helper disable failure',
                } if $helper_failure;
                $helper_persistent = 0;
                return { success => 1, exit_code => 0, stdout => '', stderr => '', error => undef };
            }
            die "unexpected ATS command: " . join(' ', @$command) . "\n";
        };

        write_file("$root/proc/cpuinfo", "vendor_id : AuthenticAMD\nflags: svm\n");
        write_file("$root/proc/cmdline", "root=/dev/fake\n");
        $helper_failure = 0;
        $helper_persistent = 0;
        $lspci_output = "ATSCtl: Enable+\n";
        my $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(${$status->{affected}}, 'B50 PF on AuthenticAMD is affected');
        ok(!$status->{safe} || !${$status->{safe}},
            'unconfigured no-ATS policy is unsafe');
        like($status->{reason}, qr/pci=noats.*reboot.*retry/i,
            'unsafe status explains enabling pci=noats and rebooting');

        reset_vms();
        write_valid_sriov_config();
        set_vm(1401, { machine => 'q35' });
        my $writes_before = $write_calls;
        my ($got, $why) = switch_pf($pf, 1401);
        ok(!$got, 'unconfigured AMD ATS policy blocks whole-PF passthrough');
        like($why, qr/pci=noats.*reboot.*retry/i,
            'whole-PF rejection is actionable');
        is($write_calls, $writes_before,
            'whole-PF rejection makes no VM configuration write');
        is(read_file("$pf_path/sriov_numvfs"), '2',
            'whole-PF rejection makes no VF topology write');
        is($mock_pf_driver, 'xe',
            'whole-PF rejection makes no PF driver write');

        # A persistent policy which is not in the running kernel still needs
        # a reboot before any dangerous PF operation is allowed.
        $helper_persistent = 1;
        $lspci_output = "ATSCtl: Enable-\n";
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(!$status->{safe} || !${$status->{safe}},
            'persistent but inactive no-ATS policy remains unsafe');
        ok(${$status->{reboot_required}},
            'persistent but inactive policy explicitly requires reboot');
        like($status->{reason}, qr/reboot/i,
            'persistent but inactive status explains reboot requirement');

        # The current boot may have pci=noats while the future boot is not
        # protected.  This is also unsafe until the helper persists it.
        write_file("$root/proc/cmdline", "root=/dev/fake pci=noats\n");
        $helper_persistent = 0;
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(!$status->{safe} || !${$status->{safe}},
            'active-only no-ATS policy remains unsafe');
        ok(${$status->{reboot_required}},
            'active-only policy reports that current and future boot state differ');
        like($status->{reason}, qr/persistent/i,
            'active-only status explains persistence requirement');

        # All three independent conditions are required for the gate.
        $helper_persistent = 1;
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(${$status->{safe}},
            'active, persistent, explicitly disabled ATS is safe');
        my $safe_state = PVE::API2::Hardware::GPU::_assert_ats_safe_for_pf($pf);
        ok($safe_state->{safe}, 'safe policy allows the PF guard to return');

        # Output alone is not enough: an lspci command which exits non-zero
        # must remain unsafe even if its partial output says Enable-.
        $lspci_failure = 1;
        $lspci_output = "ATSCtl: Enable-\n";
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(!$status->{safe} || !${$status->{safe}},
            'lspci failure keeps an otherwise complete policy unsafe');
        like($status->{reason}, qr/lspci failed/i,
            'lspci failure is included in the ATS safety reason');
        eval { PVE::API2::Hardware::GPU::_assert_ats_safe_for_pf($pf) };
        like($@, qr/lspci failed.*pci=noats.*reboot.*retry/i,
            'lspci failure blocks the PF guard with an actionable remedy');
        $lspci_failure = 0;

        # Intel hosts are outside this workaround and remain safe even when
        # the optional helper is unavailable.
        write_file("$root/proc/cpuinfo", "vendor_id : GenuineIntel\nflags: vmx\n");
        $helper_failure = 1;
        @ats_commands = ();
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(!$status->{affected} || !${$status->{affected}},
            'B50 PF on a known non-AMD CPU is not affected');
        ok(${$status->{safe}}, 'non-AMD status is safe');
        ok((grep { $_->[0] eq 'lspci' } @ats_commands),
            'non-AMD status still reports lspci ATS state');
        ok((grep { $_->[0] eq $helper && $_->[1] eq 'status' } @ats_commands),
            'non-AMD status still parses helper state without gating the device');

        # Only AuthenticAMD and GenuineIntel are known CPU identities.  A
        # malformed/unknown vendor must not be treated as a harmless host.
        write_file("$root/proc/cpuinfo", "vendor_id : UnknownVendor\nflags: svm\n");
        write_file("$root/proc/cmdline", "root=/dev/fake pci=noats\n");
        $helper_failure = 0;
        $helper_persistent = 1;
        $lspci_output = "ATSCtl: Enable-\n";
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(${$status->{affected}}, 'unknown CPU vendor keeps B50 in the affected set');
        ok(!$status->{safe} || !${$status->{safe}},
            'unknown CPU vendor keeps the ATS gate unsafe');
        like($status->{reason}, qr/CPU vendor/i,
            'unknown CPU vendor is reported as an identity error');
        eval { PVE::API2::Hardware::GPU::_assert_ats_safe_for_pf($pf) };
        like($@, qr/CPU vendor.*pci=noats.*reboot.*retry/i,
            'unknown CPU vendor blocks PF operations with an actionable remedy');

        # Restore the affected identity for the driver-path checks.
        write_file("$root/proc/cpuinfo", "vendor_id : AuthenticAMD\nflags: svm\n");
        write_file("$root/proc/cmdline", "root=/dev/fake\n");
        $helper_failure = 0;
        $helper_persistent = 0;
        $lspci_output = "ATSCtl: Enable+\n";
        reset_vms();
        write_valid_sriov_config();
        my $driver_before = $mock_pf_driver;
        my $vf_count_before = read_file("$pf_path/sriov_numvfs");
        eval { PVE::API2::Hardware::GPU::_set_pf_driver($pf, 'vfio-pci') };
        $why = $@;
        ok($why, 'unsafe ATS policy blocks PF vfio bind');
        like($why, qr/pci=noats.*reboot.*retry/i,
            'PF vfio bind rejection explains the required policy');
        is($mock_pf_driver, $driver_before,
            'blocked PF vfio bind does not change the driver');
        is(read_file("$pf_path/sriov_numvfs"), $vf_count_before,
            'blocked PF vfio bind does not change VF topology');

        # Unbinding to xe is intentionally retained as the recovery path.
        write_file("$pf_path/sriov_numvfs", '0');
        $mock_pf_driver = 'vfio-pci';
        write_file($vfio_config, "$pf\n");
        my $unbound = eval {
            PVE::API2::Hardware::GPU::_set_pf_driver($pf, 'xe');
            1;
        };
        $why = $@;
        ok($unbound && !$why, 'unsafe ATS policy still allows PF unbind to xe')
            or diag($why);
        is($mock_pf_driver, 'xe', 'PF recovery binds xe');

        # Helper status parsing and the two mutating API operations use only
        # the helper; neither operation performs a reboot.
        write_file("$root/proc/cmdline", "root=/dev/fake pci=noats\n");
        $helper_persistent = 0;
        $lspci_output = "ATSCtl: Enable-\n";
        @ats_commands = ();
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        is($status->{cpu_vendor}, 'AuthenticAMD', 'status reports CPU vendor');
        is($status->{boot_mode}, 'grub', 'status parses helper boot_mode');
        ok(!$status->{persistent_noats} || !${$status->{persistent_noats}},
            'status parses helper persistent_noats=0');
        ok(${$status->{managed}}, 'status parses helper managed=1');

        $helper_boot_mode = 'bogus';
        $helper_persistent = 'true';
        $helper_managed = 'yes';
        my $malformed_state = PVE::API2::Hardware::GPU::_ats_policy_state($pf);
        ok(!$malformed_state->{safe},
            'non-canonical helper status keeps the internal ATS gate unsafe');
        ok(!$malformed_state->{helper_ok},
            'non-canonical helper values make internal helper status invalid');
        like($malformed_state->{helper_error},
            qr/canonical persistent_noats.*canonical managed.*invalid boot_mode/i,
            'internal helper status reports every invalid canonical field');
        $status = PVE::API2::Hardware::GPU::_ats_policy_status($pf);
        ok(!$status->{safe} || !${$status->{safe}},
            'public API reports non-canonical helper status as unsafe');
        like($status->{reason},
            qr/canonical persistent_noats.*canonical managed.*invalid boot_mode/i,
            'public API reason exposes the malformed helper status');
        $helper_boot_mode = 'grub';
        $helper_persistent = 0;
        $helper_managed = 1;

        my $enabled = PVE::API2::Hardware::GPU::_enable_ats_policy($pf);
        ok($enabled && ${$enabled->{persistent_noats}},
            'POST-equivalent helper enable persists the policy');
        ok((grep { $_->[0] eq $helper && $_->[1] eq 'enable' } @ats_commands),
            'POST-equivalent action invokes helper enable');

        reset_vms();
        @ats_commands = ();
        my $disabled = PVE::API2::Hardware::GPU::_disable_ats_policy($pf);
        ok($disabled && !${$disabled->{persistent_noats}},
            'DELETE-equivalent helper disable removes the policy');
        ok(${$disabled->{reboot_required}},
            'DELETE reports that a reboot is required to restore ATS');
        ok((grep { $_->[0] eq $helper && $_->[1] eq 'disable' } @ats_commands),
            'DELETE-equivalent action invokes helper disable');

        # DELETE refuses to remove a policy while the PF is still assigned.
        $helper_persistent = 1;
        set_vm(1402, { hostpci0 => $pf });
        @ats_commands = ();
        eval { PVE::API2::Hardware::GPU::_disable_ats_policy($pf) };
        $why = $@;
        like($why, qr/PF.*consumed.*VM 1402/i,
            'DELETE rejects an active PF VM consumer');
        ok(!(grep { $_->[0] eq $helper && $_->[1] eq 'disable' } @ats_commands),
            'PF-consumer rejection does not call helper disable');

        reset_vms();
        write_file($vfio_config, "$pf\n");
        @ats_commands = ();
        eval { PVE::API2::Hardware::GPU::_disable_ats_policy($pf) };
        $why = $@;
        like($why, qr/VFIO.*persistent/i,
            'DELETE rejects an active PF VFIO persistence entry');
        ok(!(grep { $_->[0] eq $helper && $_->[1] eq 'disable' } @ats_commands),
            'VFIO-policy rejection does not call helper disable');

        # Removing pci=noats is host-wide.  A second PF whose identity cannot
        # be read might itself be another B50, so it must make DELETE fail
        # closed before invoking the helper.
        write_file($vfio_config, '');
        my $unknown_pf_bdf = '0000:0d:00.0';
        my $unknown_pf_path = "$root/sys/bus/pci/devices/$unknown_pf_bdf";
        make_path($unknown_pf_path);
        write_file("$unknown_pf_path/device", '0xe212');
        @ats_commands = ();
        eval { PVE::API2::Hardware::GPU::_disable_ats_policy($pf) };
        $why = $@;
        like($why, qr/host-wide no-ATS policy.*identity is unknown.*0d:00\.0/i,
            'DELETE fails closed when another PCI PF identity is unreadable');
        ok(!(grep { $_->[0] eq $helper && $_->[1] eq 'disable' } @ats_commands),
            'unknown second PF rejection does not call helper disable');
        write_file("$unknown_pf_path/vendor", '0x10de');
        write_file("$unknown_pf_path/device", '0x1b80');

        # The initial target probe can race with a disappearing or unreadable
        # sysfs PCI directory.  Host-wide policy removal must still fail closed
        # rather than assuming that no second affected PF exists.
        {
            no warnings 'redefine';
            my $devices_dir = "$root/sys/bus/pci/devices";
            my $hidden_devices_dir = "$root/sys/bus/pci/devices.hidden";
            local *PVE::API2::Hardware::GPU::_with_gpu_lock = sub {
                my ($code) = @_;
                rename($devices_dir, $hidden_devices_dir)
                    or die "Cannot hide PCI fixture directory: $!";
                my $result = eval { $code->() };
                my $error = $@;
                rename($hidden_devices_dir, $devices_dir)
                    or die "Cannot restore PCI fixture directory: $!";
                die $error if $error;
                return $result;
            };
            @ats_commands = ();
            eval { PVE::API2::Hardware::GPU::_disable_ats_policy($pf) };
            $why = $@;
            like($why, qr/host-wide no-ATS policy.*PCI devices cannot be enumerated/i,
                'DELETE fails closed when the PCI device directory disappears');
            ok(!(grep { $_->[0] eq $helper && $_->[1] eq 'disable' } @ats_commands),
                'PCI enumeration failure does not call helper disable');
        }

        # A helper failure is surfaced and does not touch the GPU/VM state.
        reset_vms();
        $helper_failure = 1;
        @ats_commands = ();
        my $writes_before_failure = $write_calls;
        eval { PVE::API2::Hardware::GPU::_enable_ats_policy($pf) };
        $why = $@;
        like($why, qr/helper.*failed/i,
            'helper enable failure is reported');
        is($write_calls, $writes_before_failure,
            'helper failure makes no VM configuration write');
        is(read_file("$pf_path/sriov_numvfs"), '2',
            'helper failure makes no VF topology write');
        is($mock_pf_driver, 'xe',
            'helper failure makes no PF driver write');

        # A host-wide policy must never be changed through an unrelated GPU
        # endpoint, even when that device is otherwise safe for passthrough.
        my $other_bdf = '0000:0c:00.0';
        my $other_path = "$root/sys/bus/pci/devices/$other_bdf";
        write_file("$other_path/vendor", '0x10de');
        write_file("$other_path/device", '0x1b80');
        @ats_commands = ();
        eval { PVE::API2::Hardware::GPU::_enable_ats_policy($other_bdf) };
        $why = $@;
        like($why, qr/only available.*B50.*AuthenticAMD/i,
            'POST-equivalent enable rejects an unrelated GPU');
        eval { PVE::API2::Hardware::GPU::_disable_ats_policy($other_bdf) };
        $why = $@;
        like($why, qr/only available.*B50.*AuthenticAMD/i,
            'DELETE-equivalent disable rejects an unrelated GPU');
        ok(!(grep { $_->[0] eq $helper && $_->[1] =~ /^(?:enable|disable)$/ } @ats_commands),
            'unrelated ATS policy requests do not invoke the helper');
    }

    write_file("$root/proc/cpuinfo", $old_cpuinfo);
    if (defined($old_cmdline)) {
        write_file("$root/proc/cmdline", $old_cmdline);
    } else {
        unlink("$root/proc/cmdline");
    }
};

# Runtime-only B50 deep idle keeps VM hostpci and the persistent VF profile,
# while refusing entry until every consumer has stopped.
reset_vms();
write_valid_sriov_config();
set_vm(1202, { machine => 'q35' });
($result, $error) = assign_vf($pf, 1, 1202);
ok(!$error, 'deep-idle fixture assigns VF1 through the guarded path') or diag($error);
$running{1202} = 1;
{
    local $@;
    eval { PVE::API2::Hardware::GPU::_enter_deep_idle($pf) };
    $error = $@;
}
like($error, qr/Cannot enter B50 deep idle.*Stop every VM/i,
    'deep idle rejects a running VF consumer');
is(read_file("$pf_path/sriov_numvfs"), '2',
    'running-consumer rejection leaves the VF topology intact');
ok(!-e $power_state,
    'running-consumer rejection does not publish runtime power state');

$running{1202} = 0;
my $vm_before_power = read_file(_vm_conf_path(1202));
my $profile_before_power = read_file($sriov_config);
{
    local $@;
    $result = eval { PVE::API2::Hardware::GPU::_enter_deep_idle($pf) };
    $error = $@;
}
ok(!$error, 'stopped persistent VF consumer can enter runtime deep idle') or diag($error);
is($result->{mode}, 'deep-idle', 'entry response reports deep-idle mode');
ok(${$result->{effective}}, 'entry response verifies the parked topology and 10ms policy');
is(read_file("$pf_path/sriov_numvfs"), '0',
    'deep idle temporarily removes every live VF');
is(read_file("$pf_path/power/autosuspend_delay_ms"), '10',
    'deep idle applies the tested 10ms autosuspend delay');
is(read_file(_vm_conf_path(1202)), $vm_before_power,
    'deep idle preserves the VM hostpci configuration byte-for-byte');
is(read_file($sriov_config), $profile_before_power,
    'deep idle preserves the persistent VF profile byte-for-byte');
ok(-f $power_state, 'deep idle publishes a runtime-only recovery record');

{
    local $@;
    my $start_ok = eval {
        PVE::GPU::Power::assert_vm_start_allowed($vm_config{1202}, 1202);
        1;
    };
    $error = $@;
    ok(!$start_ok, 'native start guard blocks a VM whose VF is parked');
}
like($error, qr/Exit Power Saving/i,
    'parked-VF start rejection directs the operator to the power dialog');

{
    local $@;
    eval {
        PVE::API2::Hardware::GPU::_configure_sriov_v2($pf, { num_vfs => 1 });
    };
    $error = $@;
}
like($error, qr/Cannot change SR-IOV state.*Exit Power Saving/i,
    'direct SR-IOV API writes are blocked while the B50 is sleeping');
is(read_file("$pf_path/sriov_numvfs"), '0',
    'blocked direct SR-IOV write cannot recreate a VF');

{
    local $@;
    eval { PVE::API2::Hardware::GPU::_ats_policy_status($pf) };
    $error = $@;
}
like($error, qr/Cannot read ATS policy.*Exit Power Saving/i,
    'ATS status cannot wake a B50 managed by power saving');

$running{1202} = 1;
{
    local $@;
    eval { PVE::API2::Hardware::GPU::_exit_deep_idle($pf) };
    $error = $@;
}
like($error, qr/Cannot restore B50 VF topology.*running/i,
    'deep-idle exit refuses to recreate VFs while a recorded consumer is running');
is(read_file("$pf_path/sriov_numvfs"), '0',
    'running-consumer exit rejection keeps the parked topology');
ok(-f $power_state,
    'running-consumer exit rejection keeps the recovery record');
$running{1202} = 0;

my $saved_power_record = PVE::GPU::Power::power_state_for_bdf($pf);
my $invalid_power_record = dclone($saved_power_record);
$invalid_power_record->{vf_bdfs} = $vf_bdfs[0];
PVE::GPU::Power::set_power_state_for_bdf($pf, $invalid_power_record);
{
    local $@;
    eval { PVE::API2::Hardware::GPU::_exit_deep_idle($pf) };
    $error = $@;
}
like($error, qr/Saved VF BDF count mismatch/i,
    'deep-idle exit rejects an incomplete recovery record before hardware writes');
is(read_file("$pf_path/sriov_numvfs"), '0',
    'invalid recovery state cannot create a partial VF topology');
PVE::GPU::Power::set_power_state_for_bdf($pf, $saved_power_record);

{
    local $@;
    $result = eval { PVE::API2::Hardware::GPU::_exit_deep_idle($pf) };
    $error = $@;
}
ok(!$error, 'exiting deep idle restores the verified VF topology') or diag($error);
is($result->{mode}, 'normal', 'exit response returns to normal mode');
is(read_file("$pf_path/sriov_numvfs"), '2',
    'exit restores the original VF count');
is(read_file("$pf_path/power/autosuspend_delay_ms"), '1000',
    'exit restores the original autosuspend delay');
is($mock_driver{$vf_bdfs[0]}, 'vfio-pci',
    'exit restores VF1 to its persisted vfio-pci driver');
is(read_file(_vm_conf_path(1202)), $vm_before_power,
    'exit still preserves the VM hostpci configuration');
is(read_file($sriov_config), $profile_before_power,
    'exit still preserves the persistent VF profile');
ok(!-e $power_state, 'verified exit clears the runtime recovery record');

reset_vms();
write_file($sriov_config, '');
{
    local $@;
    eval { PVE::API2::Hardware::GPU::_enter_deep_idle($pf) };
    $error = $@;
}
like($error, qr/persistent SR-IOV profile/i,
    'live VFs without a restorable profile cannot enter deep idle');
is(read_file("$pf_path/sriov_numvfs"), '2',
    'missing-profile rejection leaves the live topology unchanged');
ok(!-e $power_state,
    'missing-profile rejection leaves no stale runtime state');

write_valid_sriov_config();

done_testing();
