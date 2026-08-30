#!/usr/bin/perl
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

# Provide only the PVE::Tools primitive used by the new standalone guard.
# The fake retains PVE's line-oriented callback contract.
BEGIN {
    package PVE::Tools;
    our (
        $RUN_OUTPUT, $RUN_STDERR, $RUN_EXIT, $RUN_ERROR,
        $POLICY_OUTPUT, $POLICY_STDERR, $POLICY_EXIT, $POLICY_ERROR,
        @RUN_CALLS,
    );
    sub run_command {
        my ($command, %options) = @_;
        push @RUN_CALLS, [@$command];
        my $is_policy = @$command > 1 && $command->[1] eq 'status';
        my $output = $is_policy ? $POLICY_OUTPUT : $RUN_OUTPUT;
        my $stderr = $is_policy ? $POLICY_STDERR : $RUN_STDERR;
        my $exit = $is_policy ? $POLICY_EXIT : $RUN_EXIT;
        my $error = $is_policy ? $POLICY_ERROR : $RUN_ERROR;
        die $error if defined($error) && $error ne '';
        if ($options{outfunc}) {
            for my $line (split(/\n/, $output // '')) {
                $options{outfunc}->($line);
            }
        }
        if ($options{errfunc}) {
            for my $line (split(/\n/, $stderr // '')) {
                $options{errfunc}->($line);
            }
        }
        return $exit;
    }
    $INC{'PVE/Tools.pm'} = __FILE__;
}

my $repo = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $src = File::Spec->catdir($repo, 'src');
unshift @INC, $src;
require PVE::GPU::ATS;
PVE::GPU::ATS->import(qw(
    assert_safe_for_hostpci_devices
    assert_safe_for_pci_device
    pci_device_state
));

sub write_file {
    my ($path, $contents) = @_;
    make_path(dirname($path));
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $contents or die "Cannot write $path: $!";
    close($fh) or die "Cannot close $path: $!";
}

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot read $path: $!";
    local $/;
    my $contents = <$fh> // '';
    close($fh) or die "Cannot close $path: $!";
    return $contents;
}

my $root = tempdir(CLEANUP => 1);
$ENV{PVE_GPU_SYSFS_ROOT} = $root;
my $pf = '0000:0b:00.0';
my $vf = '0000:0b:00.1';
my $other = '0000:0c:00.0';

sub setup_device {
    my ($bdf, $vendor, $device, $is_vf) = @_;
    my $path = "$root/sys/bus/pci/devices/$bdf";
    write_file("$path/vendor", "$vendor\n");
    write_file("$path/device", "$device\n");
    if ($is_vf) {
        symlink(
            "$root/sys/bus/pci/devices/$pf",
            "$path/physfn",
        ) or die "Cannot create physfn link: $!";
    }
}

setup_device($pf, '0x8086', '0xe212', 0);
setup_device($vf, '0x8086', '0xe212', 1);
setup_device($other, '0x10de', '0x1b80', 0);
write_file("$root/proc/cpuinfo", "vendor_id : AuthenticAMD\nflags: svm\n");
write_file("$root/proc/cmdline", "root=/dev/fake\n");

sub reset_probe {
    $PVE::Tools::RUN_OUTPUT = "ATSCtl: Enable+\n";
    $PVE::Tools::RUN_STDERR = '';
    $PVE::Tools::RUN_EXIT = 0;
    $PVE::Tools::RUN_ERROR = undef;
    $PVE::Tools::POLICY_OUTPUT = "boot_mode=grub\npersistent_noats=0\nmanaged=0\n";
    $PVE::Tools::POLICY_STDERR = '';
    $PVE::Tools::POLICY_EXIT = 0;
    $PVE::Tools::POLICY_ERROR = undef;
    @PVE::Tools::RUN_CALLS = ();
}

reset_probe();
my $state = pci_device_state($pf);
ok($state->{affected}, 'AuthenticAMD Intel B50 PF is affected');
ok(!$state->{safe}, 'unsafe B50 PF is rejected without no-ATS and Enable-');
like($state->{reason}, qr/pci=noats|ATSCtl/i,
    'unsafe state explains the missing condition');

my ($ok, $error);
{
    local $@;
    $ok = eval { assert_safe_for_pci_device($pf, 100); 1 };
    $error = $@;
}
ok(!$ok, 'native guard rejects an unsafe B50 PF');
like($error, qr/VM 100.*pci=noats.*reboot.*retry/i,
    'native rejection gives the no-ATS/reboot remedy');
is_deeply($PVE::Tools::RUN_CALLS[0], ['lspci', '-vv', '-s', $pf],
    'native guard uses the required lspci argument vector');

write_file("$root/proc/cmdline", "root=/dev/fake pci=noats-extra\n");
reset_probe();
$state = pci_device_state($pf);
ok(!$state->{safe}, 'pci=noats-extra does not satisfy the exact token');

write_file("$root/proc/cmdline", "root=/dev/fake pci=noats\n");
$PVE::Tools::RUN_OUTPUT = "Capability: ATS\nATSCtl: Enable-\n";
$state = pci_device_state($pf);
ok(!$state->{safe}, 'active-only noats remains unsafe without future persistence');
$PVE::Tools::POLICY_OUTPUT = "boot_mode=grub\npersistent_noats=1\nmanaged=0\n";
$state = pci_device_state($pf);
ok($state->{safe}, 'exact pci=noats plus ATSCtl Enable- is safe');
ok(assert_safe_for_pci_device($pf), 'native guard allows safe B50 PF');

# VFs and unrelated devices bypass the host-PF guard and do not need live
# command probes.
write_file("$root/proc/cmdline", "root=/dev/fake\n");
$PVE::Tools::RUN_OUTPUT = "ATSCtl: Enable+\n";
@PVE::Tools::RUN_CALLS = ();
$state = pci_device_state($vf);
ok(!$state->{affected} && $state->{safe}, 'B50 VF is not guarded');
$state = pci_device_state($other);
ok(!$state->{affected} && $state->{safe}, 'unrelated device is not guarded');
is(scalar(@PVE::Tools::RUN_CALLS), 0,
    'VF/unrelated checks do not invoke lspci');

# Only the explicitly known CPU vendors are classified.  Unknown CPU
# identity remains fail-closed for a known B50 PF.
write_file("$root/proc/cpuinfo", "vendor_id : GenuineIntel\nflags: vmx\n");
@PVE::Tools::RUN_CALLS = ();
$state = pci_device_state($pf);
ok(!$state->{affected} && $state->{safe}, 'GenuineIntel is outside the guard');
ok(assert_safe_for_pci_device($pf), 'non-AMD B50 PF is not blocked');
is(scalar(@PVE::Tools::RUN_CALLS), 0, 'non-AMD check does not invoke lspci');

write_file("$root/proc/cpuinfo", "vendor_id : UnknownVendor\n");
{
    local $@;
    $ok = eval { assert_safe_for_pci_device($pf); 1 };
    $error = $@;
}
ok(!$ok, 'unknown CPU vendor is fail-closed');
like($error, qr/CPU vendor|pci=noats/i, 'unknown CPU error is actionable');

my $unknown = '0000:0d:00.0';
make_path("$root/sys/bus/pci/devices/$unknown");
write_file("$root/proc/cpuinfo", "vendor_id : AuthenticAMD\n");
@PVE::Tools::RUN_CALLS = ();
{
    local $@;
    $ok = eval { assert_safe_for_pci_device($unknown); 1 };
    $error = $@;
}
ok(!$ok, 'unknown PCI identity is fail-closed');
like($error, qr/identity.*unknown|cannot read PCI/i,
    'unknown PCI identity is explicit');
is(scalar(@PVE::Tools::RUN_CALLS), 0,
    'unknown PCI identity fails before lspci');

# A VM start preflight checks every chosen hostpci function before PVE starts
# preparing any one of them.  The unsafe B50 is deliberately second here to
# cover semicolon/multifunction ordering.
write_file("$root/proc/cpuinfo", "vendor_id : AuthenticAMD\n");
write_file("$root/proc/cmdline", "root=/dev/fake\n");
reset_probe();
{
    local $@;
    $ok = eval {
        assert_safe_for_hostpci_devices({
            hostpci0 => {
                ids => [
                    { id => $other },
                    { id => $pf },
                ],
                driver => 'keep',
            },
        }, 100);
        1;
    };
    $error = $@;
}
ok(!$ok, 'full hostpci preflight rejects an unsafe B50 after a harmless function');
like($error, qr/VM 100.*B50.*pci=noats/i,
    'full preflight reports the affected VM and required policy');

$PVE::Tools::POLICY_OUTPUT = "boot_mode=grub\npersistent_noats=1\nmanaged=1\n";
$PVE::Tools::RUN_OUTPUT = "ATSCtl: Enable-\n";
write_file("$root/proc/cmdline", "root=/dev/fake pci=noats\n");
$ok = eval {
    assert_safe_for_hostpci_devices({
        hostpci0 => {
            ids => [
                { id => $other },
                { id => $pf },
            ],
            driver => 'keep',
        },
    }, 100);
    1;
};
ok($ok, 'full preflight accepts a safe multifunction driver=keep selection')
    or diag($@);

# Verify the exact, idempotent marker integration used by the native PVE
# QemuServer::PCI start path.
my $script = File::Spec->catfile($src, 'scripts', 'reapply-patches.sh');
my $patch_root = tempdir(CLEANUP => 1);
my %fixture = (
    index    => "$patch_root/index.html.tpl",
    hardware => "$patch_root/Hardware.pm",
    nodes    => "$patch_root/Nodes.pm",
    qemu     => "$patch_root/PCI.pm",
    qemu_server => "$patch_root/QemuServer.pm",
);
write_file($fixture{index}, "<html><head></head><body></body></html>\n");
write_file($fixture{hardware}, <<'HARDWARE');
package PVE::API2::Hardware;
use strict;
use warnings;
use PVE::API2::Hardware::PCI;
use PVE::API2::Hardware::USB;
__PACKAGE__->register_method({
    name => 'index',
    path => '',
    code => sub {
        return [
            { type => 'pci' },
            { type => 'usb' },
        ];
    },
});
HARDWARE
write_file($fixture{nodes}, "package PVE::API2::Nodes;\n1;\n");
write_file($fixture{qemu}, <<'PCI');
package PVE::QemuServer::PCI;
use strict;
use warnings;
use PVE::Tools;
sub prepare_pci_device {
    my ($vmid, $pciid, $index, $device) = @_;
    return {};
}
1;
PCI
write_file($fixture{qemu_server}, <<'QEMUSERVER');
package PVE::QemuServer;
use strict;
use warnings;
sub vm_start_nolock {
    my ($storecfg, $vmid, $conf) = @_;
    my ($cmd, $spice_port, $pci_devices);
    ($cmd, $spice_port, my $pci_devices, $conf) = config_to_command(
        $storecfg,
        $vmid,
        $conf,
        {},
        {},
    );

    my $memory = get_current_memory($conf->{memory});
    my $pci_reserve_list = [];
    PVE::QemuServer::PCI::reserve_pci_usage($pci_reserve_list, $vmid, 10);
    for my $id (sort keys %$pci_devices) {
        my $d = $pci_devices->{$id};
        for my $dev ($d->{ids}->@*) {
            PVE::QemuServer::PCI::prepare_pci_device($vmid, $dev->{id}, 0, $d);
        }
    }
}
1;
QEMUSERVER

sub run_patch {
    local %ENV = %ENV;
    $ENV{PVE_GPU_INDEX_TPL} = $fixture{index};
    $ENV{PVE_GPU_HARDWARE_PM} = $fixture{hardware};
    $ENV{PVE_GPU_NODES_PM} = $fixture{nodes};
    $ENV{PVE_GPU_QEMU_PCI_PM} = $fixture{qemu};
    $ENV{PVE_GPU_QEMU_SERVER_PM} = $fixture{qemu_server};
    $ENV{PVE_GPU_NO_RESTART} = 1;
    return system($script, @_) == 0;
}

ok(run_patch('--apply'), 'reapply script installs the native ATS marker');
my $patched = read_file($fixture{qemu});
is(scalar(() = $patched =~ /BEGIN PVE GPU MANAGER ATS PCI USE/g), 1,
    'native import marker appears once');
is(scalar(() = $patched =~ /BEGIN PVE GPU MANAGER ATS PCI GUARD/g), 1,
    'native guard marker appears once');
like($patched, qr/use PVE::GPU::ATS qw\(assert_safe_for_pci_device\);/,
    'native module import is injected');
like($patched, qr/PVE::GPU::ATS::assert_safe_for_pci_device\(\$pciid, \$vmid\);/,
    'native guard call is injected with PCI ID and VMID');
like($patched, qr/my \(\$vmid, \$pciid, \$index, \$device\) = \@_;\n\# BEGIN PVE GPU MANAGER ATS PCI GUARD/s,
    'guard is immediately after prepare_pci_device arguments');
my $patched_server = read_file($fixture{qemu_server});
is(scalar(() = $patched_server =~ /BEGIN PVE GPU MANAGER ATS QEMU USE/g), 1,
    'QemuServer import marker appears once');
is(scalar(() = $patched_server =~ /BEGIN PVE GPU MANAGER ATS QEMU GUARD/g), 1,
    'QemuServer preflight marker appears once');
is(scalar(() = $patched_server =~ /BEGIN PVE GPU MANAGER POWER QEMU GUARD/g), 1,
    'QemuServer power-state preflight marker appears once');
like($patched_server,
    qr/use PVE::GPU::Power qw\(assert_vm_start_allowed\);/,
    'native QemuServer imports the runtime power guard');
like($patched_server,
    qr/PVE::GPU::Power::assert_vm_start_allowed\(\$conf, \$vmid\);.*?config_to_command/s,
    'power-state guard runs before missing VFs can fail config_to_command');
like($patched_server,
    qr/PVE::GPU::ATS::assert_safe_for_hostpci_devices\(\$pci_devices, \$vmid\);.*?reserve_pci_usage.*?prepare_pci_device/s,
    'full hostpci guard runs before every reservation and prepare call');

ok(run_patch('--check-native'),
    'native ATS health check accepts a complete, idempotent guard');
my $health_server_before = read_file($fixture{qemu_server});
my $health_server_unpatched = $health_server_before;
$health_server_unpatched =~ s/\# BEGIN PVE GPU MANAGER ATS QEMU USE\n.*?\# END PVE GPU MANAGER ATS QEMU USE\n//s;
$health_server_unpatched =~ s/\# BEGIN PVE GPU MANAGER ATS QEMU GUARD\n.*?\# END PVE GPU MANAGER ATS QEMU GUARD\n//s;
$health_server_unpatched =~ s/\# BEGIN PVE GPU MANAGER POWER QEMU GUARD\n.*?\# END PVE GPU MANAGER POWER QEMU GUARD\n//s;
write_file($fixture{qemu_server}, $health_server_unpatched);
ok(!run_patch('--check-native'),
    'native ATS health check fails closed after qemu-server is overwritten');
is(read_file($fixture{qemu_server}), $health_server_unpatched,
    'native ATS health check never rewrites an unguarded qemu-server source');
write_file($fixture{qemu_server}, $health_server_before);

# PVE 8.x uses a five-value config_to_command assignment.  The trigger replay
# must accept that layout as well as the newer PVE 9.x four-value form.
my $pve8_server = $health_server_before;
$pve8_server =~ s/\(\$cmd, \$spice_port, my \$pci_devices, \$conf\)/(my \$cmd, my \$vollist, my \$spice_port, my \$pci_devices, \$conf)/;
like($pve8_server, qr/my \$vollist.*config_to_command/s,
    'PVE 8 fixture uses the five-value VM start assignment');
write_file($fixture{qemu_server}, $pve8_server);
ok(run_patch('--apply'), 'native ATS replay accepts the PVE 8 VM start layout');
is(read_file($fixture{qemu_server}), $pve8_server,
    'PVE 8 native marker replay is byte-for-byte idempotent');
write_file($fixture{qemu_server}, $health_server_before);

my $index_before_failed_preflight = read_file($fixture{index});
my $hardware_before_failed_preflight = read_file($fixture{hardware});
my $pci_before_failed_preflight = read_file($fixture{qemu});
my $server_before_failed_preflight = read_file($fixture{qemu_server});
write_file($fixture{qemu_server}, "package Unsupported::QemuServer;\n1;\n");
ok(!run_patch('--apply'), 'unsupported QemuServer layout fails the whole apply preflight');
is(read_file($fixture{index}), $index_before_failed_preflight,
    'failed full preflight leaves the index unchanged');
is(read_file($fixture{hardware}), $hardware_before_failed_preflight,
    'failed full preflight leaves Hardware.pm unchanged');
is(read_file($fixture{qemu}), $pci_before_failed_preflight,
    'failed full preflight leaves PCI.pm unchanged');
write_file($fixture{qemu_server}, $server_before_failed_preflight);
ok(run_patch('--apply'), 'native marker apply is idempotent');
is(read_file($fixture{qemu}), $patched,
    'native PCI source is byte-for-byte stable on repeated apply');
is(read_file($fixture{qemu_server}), $patched_server,
    'native QemuServer source is byte-for-byte stable on repeated apply');

# Marker pairs are typed, and removal is all-or-nothing across every PVE-owned
# source file.  A malformed later file must not leave earlier integrations
# removed after a failed uninstall.
my $mismatched_pci = $patched;
$mismatched_pci =~ s/\# END PVE GPU MANAGER ATS PCI USE/\# END PVE GPU MANAGER ATS PCI GUARD/;
write_file($fixture{qemu}, $mismatched_pci);
my $remove_index_before = read_file($fixture{index});
my $remove_hardware_before = read_file($fixture{hardware});
my $remove_server_before = read_file($fixture{qemu_server});
ok(!run_patch('--remove'),
    'native removal rejects a mismatched PCI marker pair');
is(read_file($fixture{index}), $remove_index_before,
    'mismatched PCI marker leaves index unchanged');
is(read_file($fixture{hardware}), $remove_hardware_before,
    'mismatched PCI marker leaves Hardware.pm unchanged');
is(read_file($fixture{qemu_server}), $remove_server_before,
    'mismatched PCI marker leaves QemuServer.pm unchanged');
write_file($fixture{qemu}, $patched);

my $unmatched_server = $patched_server . "\n# BEGIN PVE GPU MANAGER ATS QEMU USE\n";
write_file($fixture{qemu_server}, $unmatched_server);
my $remove_pci_before = read_file($fixture{qemu});
ok(!run_patch('--remove'),
    'native removal rejects an unmatched later QemuServer marker');
is(read_file($fixture{index}), $remove_index_before,
    'failed QemuServer removal leaves index unchanged');
is(read_file($fixture{hardware}), $remove_hardware_before,
    'failed QemuServer removal leaves Hardware.pm unchanged');
is(read_file($fixture{qemu}), $remove_pci_before,
    'failed QemuServer removal leaves PCI.pm unchanged');
write_file($fixture{qemu_server}, $patched_server);

my $upgraded = read_file($fixture{qemu});
$upgraded =~ s/use warnings;/use warnings;\nuse PVE::QemuServer::UpgradeSentinel;/;
write_file($fixture{qemu}, $upgraded);
my $upgraded_server = read_file($fixture{qemu_server});
$upgraded_server =~ s/use warnings;/use warnings;\nuse PVE::QemuServer::StartUpgradeSentinel;/;
write_file($fixture{qemu_server}, $upgraded_server);
ok(run_patch('--remove'), 'reapply script removes the native ATS marker');
my $removed = read_file($fixture{qemu});
unlike($removed, qr/PVE GPU MANAGER ATS PCI|PVE::GPU::ATS/,
    'native remove strips only the owned guard integration');
like($removed, qr/PVE::QemuServer::UpgradeSentinel/,
    'native remove preserves an upstream source change');
my $removed_server = read_file($fixture{qemu_server});
unlike($removed_server, qr/PVE GPU MANAGER ATS QEMU|PVE::GPU::ATS/,
    'native remove strips only the owned QemuServer preflight integration');
unlike($removed_server, qr/PVE GPU MANAGER POWER QEMU|PVE::GPU::Power/,
    'native remove also strips the owned power-state preflight integration');
like($removed_server, qr/PVE::QemuServer::StartUpgradeSentinel/,
    'QemuServer remove preserves an upstream source change');

my $makefile = read_file(File::Spec->catfile($repo, 'Makefile'));
like($makefile, qr/src\/PVE\/GPU\/ATS\.pm/,
    'Makefile installs the native ATS module');
like($makefile, qr/src\/PVE\/GPU\/Power\.pm/,
    'Makefile installs the native power-state module');

done_testing();
