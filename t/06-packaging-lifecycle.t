#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

my $root = File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__), '..'));
my $patch_script = File::Spec->catfile($root, 'src', 'scripts', 'reapply-patches.sh');

sub slurp {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "Cannot read $path: $!";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

sub write_file {
    my ($path, $data) = @_;
    open(my $fh, '>', $path) or die "Cannot write $path: $!";
    print {$fh} $data;
    close($fh);
}

sub occurrences {
    my ($text, $needle) = @_;
    my $count = 0;
    $count++ while $text =~ /\Q$needle\E/g;
    return $count;
}

sub native_pci_fixture {
    return <<'PCI';
package PVE::QemuServer::PCI;
use strict;
use warnings;
sub prepare_pci_device {
    my ($vmid, $pciid, $index, $device) = @_;
    return {};
}
1;
PCI
}

sub native_qemu_server_fixture {
    return <<'QEMUSERVER';
package PVE::QemuServer;
use strict;
use warnings;
sub vm_start_nolock {
    my ($storecfg, $vmid, $conf) = @_;
    ($cmd, $spice_port, my $pci_devices, $conf) = config_to_command(
        $storecfg,
        $vmid,
        $conf,
    );

    my $memory = get_current_memory($conf->{memory});
    PVE::QemuServer::PCI::reserve_pci_usage([], $vmid, 10);
    for my $device (values %$pci_devices) {
        for my $pci ($device->{ids}->@*) {
            PVE::QemuServer::PCI::prepare_pci_device($vmid, $pci->{id}, 0, $device);
        }
    }
}
1;
QEMUSERVER
}

sub ensure_native_fixtures {
    my ($index) = @_;
    my $directory = dirname($index);
    my $pci = File::Spec->catfile($directory, 'PCI.pm');
    my $qemu_server = File::Spec->catfile($directory, 'QemuServer.pm');
    write_file($pci, native_pci_fixture()) if !-e $pci;
    write_file($qemu_server, native_qemu_server_fixture()) if !-e $qemu_server;
    return ($pci, $qemu_server);
}

sub run_patch_script {
    my ($index, $hardware, $nodes, $action) = @_;
    my ($pci, $qemu_server) = ensure_native_fixtures($index);
    local %ENV = %ENV;
    $ENV{PVE_GPU_INDEX_TPL} = $index;
    $ENV{PVE_GPU_HARDWARE_PM} = $hardware;
    $ENV{PVE_GPU_NODES_PM} = $nodes;
    $ENV{PVE_GPU_QEMU_PCI_PM} = $pci;
    $ENV{PVE_GPU_QEMU_SERVER_PM} = $qemu_server;
    $ENV{PVE_GPU_NO_RESTART} = 1;
    return system($patch_script, $action) == 0;
}

my $index_fixture = <<'INDEX';
<!doctype html>
<html><head><title>Proxmox VE</title></head><body></body></html>
INDEX

my $hardware_fixture = <<'HARDWARE';
package PVE::API2::Hardware;

use strict;
use warnings;
use PVE::API2::Hardware::PCI;
use PVE::API2::Hardware::USB;

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    code => sub {
        return [
            { type => 'pci' },
            { type => 'usb' },
        ];
    },
});

1;
HARDWARE

my $nodes_fixture = <<'NODES';
package PVE::API2::Nodes;
use strict;
use PVE::API2::Hardware::GPU;
1;
NODES

my $current_pve_hardware_fixture = <<'CURRENT_PVE';
package PVE::API2::Hardware;

use strict;
use warnings;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::API2::Hardware::PCI;
use PVE::API2::Hardware::USB;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    code => sub {
        my $res = [
            { type => 'pci' }, { type => 'usb' },
        ];
        return $res;
    },
});
CURRENT_PVE

{
    my $tmp = tempdir(CLEANUP => 1);
    my $index = File::Spec->catfile($tmp, 'index.html.tpl');
    my $hardware = File::Spec->catfile($tmp, 'Hardware.pm');
    my $nodes = File::Spec->catfile($tmp, 'Nodes.pm');
    my $bin = File::Spec->catdir($tmp, 'bin');
    my $runtime = File::Spec->catdir($tmp, 'systemd-runtime');
    my $systemctl_log = File::Spec->catfile($tmp, 'systemctl.log');
    make_path($bin, $runtime);
    write_file($index, $index_fixture);
    write_file($hardware, $hardware_fixture);
    write_file($nodes, $nodes_fixture);
    write_file(
        File::Spec->catfile($bin, 'systemctl'),
        "#!/bin/sh\n" .
        "printf '%s\\n' \"\$*\" >> \"\$PVE_GPU_SYSTEMCTL_LOG\"\n" .
        "if [ -n \"\${PVE_GPU_SYSTEMCTL_FAIL:-}\" ] && " .
            "[ \"\$*\" = \"\$PVE_GPU_SYSTEMCTL_FAIL\" ]; then exit 1; fi\n",
    );
    chmod(0755, File::Spec->catfile($bin, 'systemctl'))
        or die "Cannot make systemctl shim executable: $!";

    ok(run_patch_script($index, $hardware, $nodes, '--apply'),
        'restart fixture is patched once before the package-only upgrade simulation');
    my ($pci, $qemu_server) = ensure_native_fixtures($index);

    {
        local %ENV = %ENV;
        $ENV{PATH} = "$bin:$ENV{PATH}";
        $ENV{PVE_GPU_INDEX_TPL} = $index;
        $ENV{PVE_GPU_HARDWARE_PM} = $hardware;
        $ENV{PVE_GPU_NODES_PM} = $nodes;
        $ENV{PVE_GPU_QEMU_PCI_PM} = $pci;
        $ENV{PVE_GPU_QEMU_SERVER_PM} = $qemu_server;
        $ENV{PVE_GPU_SYSTEMD_RUNTIME_DIR} = $runtime;
        $ENV{PVE_GPU_SYSTEMCTL_LOG} = $systemctl_log;
        ok(system($patch_script, '--apply', '--force-restart') == 0,
            'forced upgrade apply succeeds when integration markers are unchanged');
    }
    is(slurp($systemctl_log),
        "restart pvedaemon\nrestart pveproxy\ntry-restart pve-ha-lrm\n",
        'forced upgrade apply restarts PVE daemons and refreshes the active HA loader despite unchanged markers');

    write_file($systemctl_log, '');
    {
        local %ENV = %ENV;
        $ENV{PATH} = "$bin:$ENV{PATH}";
        $ENV{PVE_GPU_INDEX_TPL} = $index;
        $ENV{PVE_GPU_HARDWARE_PM} = $hardware;
        $ENV{PVE_GPU_NODES_PM} = $nodes;
        $ENV{PVE_GPU_QEMU_PCI_PM} = $pci;
        $ENV{PVE_GPU_QEMU_SERVER_PM} = $qemu_server;
        $ENV{PVE_GPU_SYSTEMD_RUNTIME_DIR} = $runtime;
        $ENV{PVE_GPU_SYSTEMCTL_LOG} = $systemctl_log;
        ok(system($patch_script, '--apply', '--force-restart', '--no-restart') == 0,
            'explicit no-restart apply succeeds');
    }
    is(slurp($systemctl_log), '',
        'explicit --no-restart overrides the package-upgrade force flag');

    for my $failed_command ('restart pvedaemon', 'try-restart pve-ha-lrm') {
        write_file($systemctl_log, '');
        local %ENV = %ENV;
        $ENV{PATH} = "$bin:$ENV{PATH}";
        $ENV{PVE_GPU_INDEX_TPL} = $index;
        $ENV{PVE_GPU_HARDWARE_PM} = $hardware;
        $ENV{PVE_GPU_NODES_PM} = $nodes;
        $ENV{PVE_GPU_QEMU_PCI_PM} = $pci;
        $ENV{PVE_GPU_QEMU_SERVER_PM} = $qemu_server;
        $ENV{PVE_GPU_SYSTEMD_RUNTIME_DIR} = $runtime;
        $ENV{PVE_GPU_SYSTEMCTL_LOG} = $systemctl_log;
        $ENV{PVE_GPU_SYSTEMCTL_FAIL} = $failed_command;
        ok(system($patch_script, '--apply', '--force-restart') != 0,
            "forced marker replay fails when '$failed_command' fails");
        is(slurp($systemctl_log),
            "restart pvedaemon\nrestart pveproxy\ntry-restart pve-ha-lrm\n",
            'restart failure still attempts to reload every VM-start process');
    }
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $bin = File::Spec->catdir($tmp, 'bin');
    my $state = File::Spec->catdir($tmp, 'state');
    my $maint_log = File::Spec->catfile($tmp, 'maint.log');
    my $patch = File::Spec->catfile($tmp, 'reapply-patches.sh');
    my $sriov = File::Spec->catfile($tmp, 'apply-sriov-config.sh');
    my $grub = File::Spec->catfile($state, 'grub');
    my $pve_guests_dropin = File::Spec->catfile($state, '10-pve-gpu-manager.conf');
    my $legacy_modprobe = File::Spec->catfile($state, 'pve-gpu-vfio.modprobe');
    my $legacy_modules = File::Spec->catfile($state, 'pve-gpu-vfio.modules');
    make_path($bin, $state);

    for my $command (qw(update-grub update-initramfs)) {
        my $path = File::Spec->catfile($bin, $command);
        write_file(
            $path,
            "#!/bin/sh\nprintf '$command %s\\n' \"\$*\" >> \"\$PVE_GPU_MAINT_LOG\"\n",
        );
        chmod(0755, $path) or die "Cannot make $path executable: $!";
    }
    write_file(File::Spec->catfile($bin, 'systemctl'), <<'SYSTEMCTL');
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$PVE_GPU_MAINT_LOG"
if [ -n "${PVE_GPU_SYSTEMCTL_FAIL:-}" ] &&
   [ "$*" = "$PVE_GPU_SYSTEMCTL_FAIL" ]; then
    exit 1
fi
if [ "$*" = 'cat pve-guests.service' ] &&
   [ "${PVE_GPU_SYSTEMCTL_BAD_CAT:-0}" != 1 ]; then
    printf '%s\n' \
        'ExecStartPre=/usr/lib/pve-gpu/check-pve-gpu-binders.sh' \
        'ExecStartPre=/usr/lib/pve-gpu/reapply-patches.sh --check-native'
fi
SYSTEMCTL
    chmod(0755, File::Spec->catfile($bin, 'systemctl'))
        or die "Cannot make systemctl shim executable: $!";
    write_file($pve_guests_dropin,
        "ExecStartPre=/usr/lib/pve-gpu/check-pve-gpu-binders.sh\n" .
        "ExecStartPre=/usr/lib/pve-gpu/reapply-patches.sh --check-native\n");
    write_file(
        $patch,
        "#!/bin/sh\nprintf 'patch %s\\n' \"\$*\" >> \"\$PVE_GPU_MAINT_LOG\"\n" .
        "[ \"\${PVE_GPU_PATCH_FAIL:-0}\" != 1 ]\n",
    );
    write_file(
        $sriov,
        "#!/bin/sh\nprintf 'sriov %s\\n' \"\$*\" >> \"\$PVE_GPU_MAINT_LOG\"\n",
    );
    chmod(0755, $patch, $sriov) or die "Cannot make maintainer-script shims executable: $!";

    my $postinst = File::Spec->catfile($root, 'debian', 'postinst');
    my $owned_grub = <<'GRUB';
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt vfio-pci.ids=8086:e212"
GRUB_CMDLINE_LINUX="vfio-pci.ids=10de:1abc"
GRUB
    write_file($grub, $owned_grub);

    my $run_postinst = sub {
        my (@arguments) = @_;
        local %ENV = %ENV;
        $ENV{PATH} = "$bin:/usr/bin:/bin";
        $ENV{PVE_GPU_PATCH_SCRIPT} = $patch;
        $ENV{PVE_GPU_SRIOV_SCRIPT} = $sriov;
        $ENV{PVE_GPU_LEGACY_MODPROBE_CONF} = $legacy_modprobe;
        $ENV{PVE_GPU_LEGACY_MODULES_CONF} = $legacy_modules;
        $ENV{PVE_GPU_GRUB_DEFAULT} = $grub;
        $ENV{PVE_GPU_PVE_GUESTS_DROPIN} = $pve_guests_dropin;
        $ENV{PVE_GPU_MAINT_LOG} = $maint_log;
        return system('/bin/sh', $postinst, @arguments) == 0;
    };

    ok($run_postinst->('configure', '1.1.0-3'),
        'upgrade from an affected package version cleans its orphaned GRUB policy');
    my $cleaned_grub = slurp($grub);
    unlike($cleaned_grub, qr/^GRUB_CMDLINE_LINUX_DEFAULT=.*vfio-pci\.ids=/m,
        'affected upgrade removes the package-owned vfio-pci.ids argument without legacy files');
    like($cleaned_grub, qr/^GRUB_CMDLINE_LINUX="vfio-pci\.ids=10de:1abc"$/m,
        'cleanup leaves an independent GRUB_CMDLINE_LINUX VFIO policy unchanged');
    like(slurp($maint_log), qr/^update-grub\s*$/m,
        'affected upgrade regenerates GRUB after removing the package-owned argument');
    unlike(slurp($maint_log), qr/^update-initramfs/m,
        'GRUB-only legacy cleanup does not rebuild initramfs');
    like(slurp($maint_log), qr/^patch --apply --force-restart$/m,
        'affected upgrade still uses forced PVE daemon restart semantics');

    write_file($maint_log, '');
    ok($run_postinst->('configure', '1.1.0-3'),
        'repeating the affected upgrade cleanup succeeds');
    unlike(slurp($maint_log), qr/^update-grub/m,
        'repeated cleanup does not regenerate an already-clean GRUB configuration');
    is(slurp($grub), $cleaned_grub,
        'repeated package-owned GRUB cleanup is byte-for-byte idempotent');

    write_file($maint_log, '');
    write_file($grub, $owned_grub);
    ok($run_postinst->('configure'), 'fresh install lifecycle succeeds with an existing user GRUB policy');
    is(slurp($grub), $owned_grub,
        'fresh install does not claim or remove an independent vfio-pci.ids configuration');
    unlike(slurp($maint_log), qr/^update-grub/m,
        'fresh install does not regenerate unchanged user GRUB configuration');

    write_file($maint_log, '');
    write_file($grub, <<'USER_GRUB');
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt vfio-pci.ids=10de:1abc"
USER_GRUB
    ok($run_postinst->('configure', '1.1.0-3'),
        'affected-version upgrade accepts a non-package VFIO policy');
    like(slurp($grub), qr/vfio-pci\.ids=10de:1abc/,
        'affected-version cleanup does not remove non-Intel user VFIO IDs');

    {
        local $ENV{PVE_GPU_SYSTEMCTL_FAIL} = 'daemon-reload';
        ok(!$run_postinst->('configure'),
            'configure fails when systemd cannot load the pve-guests safety drop-in');
    }
    {
        local $ENV{PVE_GPU_SYSTEMCTL_BAD_CAT} = 1;
        ok(!$run_postinst->('configure'),
            'configure fails when the effective pve-guests unit lacks the safety preflights');
    }
    {
        local $ENV{PVE_GPU_PATCH_FAIL} = 1;
        ok(!$run_postinst->('triggered'),
            'dpkg trigger remains failed when native marker replay cannot complete');
    }
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $bin = File::Spec->catdir($tmp, 'bin');
    my $state = File::Spec->catdir($tmp, 'state');
    my $maint_log = File::Spec->catfile($tmp, 'maint.log');
    make_path($bin, $state);
    for my $command (qw(update-grub update-initramfs systemctl)) {
        my $path = File::Spec->catfile($bin, $command);
        write_file(
            $path,
            "#!/bin/sh\nprintf '$command %s\\n' \"\$*\" >> \"\$PVE_GPU_MAINT_LOG\"\n",
        );
        chmod(0755, $path) or die "Cannot make $path executable: $!";
    }

    my %paths = (
        sriov => File::Spec->catfile($state, 'gpu-sriov.conf'),
        template => File::Spec->catfile($state, 'gpu-vf-templates.conf'),
        modprobe => File::Spec->catfile($state, 'pve-gpu-vfio.modprobe'),
        modules => File::Spec->catfile($state, 'pve-gpu-vfio.modules'),
        vfio => File::Spec->catfile($state, 'pve-gpu-vfio.conf'),
        sysfs => File::Spec->catfile($state, 'pve-gpu-sysfs-root'),
        grub => File::Spec->catfile($state, 'grub'),
        index_backup => File::Spec->catfile($state, 'index.pre-gpu'),
        hardware_backup => File::Spec->catfile($state, 'Hardware.pm.pre-gpu'),
        nodes_backup => File::Spec->catfile($state, 'Nodes.pm.pre-gpu'),
    );
    write_file($_, "managed\n") for @paths{qw(sriov template modprobe modules vfio sysfs index_backup hardware_backup nodes_backup)};
    write_file($paths{grub}, <<'PURGE_GRUB');
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt vfio-pci.ids=8086:e212"
GRUB_CMDLINE_LINUX="vfio-pci.ids=10de:1abc"
PURGE_GRUB

    my $postrm = File::Spec->catfile($root, 'debian', 'postrm');
    my $run_postrm = sub {
        local %ENV = %ENV;
        $ENV{PATH} = "$bin:/usr/bin:/bin";
        $ENV{PVE_GPU_SRIOV_CONF} = $paths{sriov};
        $ENV{PVE_GPU_TEMPLATE_CONF} = $paths{template};
        $ENV{PVE_GPU_LEGACY_MODPROBE_CONF} = $paths{modprobe};
        $ENV{PVE_GPU_LEGACY_MODULES_CONF} = $paths{modules};
        $ENV{PVE_GPU_VFIO_CONF} = $paths{vfio};
        $ENV{PVE_GPU_SYSFS_ROOT_CONF} = $paths{sysfs};
        $ENV{PVE_GPU_GRUB_DEFAULT} = $paths{grub};
        $ENV{PVE_GPU_INDEX_BACKUP} = $paths{index_backup};
        $ENV{PVE_GPU_HARDWARE_BACKUP} = $paths{hardware_backup};
        $ENV{PVE_GPU_NODES_BACKUP} = $paths{nodes_backup};
        $ENV{PVE_GPU_MAINT_LOG} = $maint_log;
        return system('/bin/sh', $postrm, 'purge') == 0;
    };

    ok($run_postrm->(), 'purge lifecycle removes package-owned legacy policy');
    my @managed_paths = @paths{qw(sriov template modprobe modules vfio sysfs index_backup hardware_backup nodes_backup)};
    ok(!grep({ -e $_ } @managed_paths),
        'purge removes every package-managed configuration and stale backup fixture');
    unlike(slurp($paths{grub}), qr/^GRUB_CMDLINE_LINUX_DEFAULT=.*vfio-pci\.ids=/m,
        'purge removes package-owned legacy GRUB VFIO IDs');
    like(slurp($paths{grub}), qr/^GRUB_CMDLINE_LINUX="vfio-pci\.ids=10de:1abc"$/m,
        'purge preserves an independent GRUB_CMDLINE_LINUX VFIO policy');
    like(slurp($maint_log), qr/^update-grub\s*$/m,
        'purge regenerates GRUB after owned-policy removal');
    like(slurp($maint_log), qr/^update-initramfs -u$/m,
        'purge rebuilds initramfs after legacy files are removed');

    my $purged_grub = slurp($paths{grub});
    write_file($maint_log, '');
    ok($run_postrm->(), 'repeated purge lifecycle succeeds');
    is(slurp($paths{grub}), $purged_grub,
        'repeated purge leaves the GRUB configuration unchanged');
    unlike(slurp($maint_log), qr/^update-(?:grub|initramfs)/m,
        'repeated purge performs no legacy boot-policy regeneration');

    write_file($paths{grub}, <<'UNOWNED_GRUB');
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt vfio-pci.ids=8086:e212"
UNOWNED_GRUB
    write_file($maint_log, '');
    ok($run_postrm->(), 'purge without a package ownership marker succeeds');
    like(slurp($paths{grub}), qr/vfio-pci\.ids=8086:e212/,
        'purge does not remove an unowned GRUB VFIO argument when legacy files are absent');
}

ok(-x $patch_script, 'marker patch script is executable');

{
    my $tmp = tempdir(CLEANUP => 1);
    my $index = File::Spec->catfile($tmp, 'index.html.tpl');
    my $hardware = File::Spec->catfile($tmp, 'Hardware.pm');
    my $nodes = File::Spec->catfile($tmp, 'Nodes.pm');
    write_file($index, $index_fixture);
    write_file($hardware, $hardware_fixture);
    write_file($nodes, $nodes_fixture);

    ok(run_patch_script($index, $hardware, $nodes, '--apply'), 'apply succeeds on representative PVE files');

    my $patched_index = slurp($index);
    my $patched_hardware = slurp($hardware);
    is(occurrences($patched_index, '<!-- BEGIN PVE GPU MANAGER -->'), 1,
        'index contains one owned marker block');
    is(occurrences($patched_index, '<script src="/pve2/js/pve-gpu-plugin.js?ver=1.1.0-12"></script>'), 1,
        'index contains one versioned plugin script tag');
    is(occurrences($patched_hardware, '# BEGIN PVE GPU MANAGER HARDWARE '), 3,
        'Hardware.pm contains three owned marker blocks');
    is(occurrences($patched_hardware, 'use PVE::API2::Hardware::GPU;'), 1,
        'Hardware.pm imports GPU module once');
    is(occurrences($patched_hardware, q({ type => 'gpu' },)), 1,
        'Hardware.pm index lists GPU once');
    is(occurrences($patched_hardware, 'subclass => "PVE::API2::Hardware::GPU"'), 1,
        'Hardware.pm registers GPU subclass once');
    unlike(slurp($nodes), qr/PVE::API2::Hardware::GPU/,
        'legacy Nodes.pm import is removed');

    ok(run_patch_script($index, $hardware, $nodes, '--apply'), 'second apply succeeds');
    is(slurp($index), $patched_index, 'index patch is byte-for-byte idempotent');
    is(slurp($hardware), $patched_hardware, 'Hardware.pm patch is byte-for-byte idempotent');

    my $upgraded_hardware = slurp($hardware);
    $upgraded_hardware =~ s/use warnings;/use warnings;\nuse PVE::API2::Hardware::UpgradeSentinel;/;
    write_file($hardware, $upgraded_hardware);

    ok(run_patch_script($index, $hardware, $nodes, '--remove'), 'remove succeeds');
    is(slurp($index), $index_fixture, 'remove restores index content without a backup');
    unlike(slurp($hardware), qr/PVE GPU MANAGER|PVE::API2::Hardware::GPU|type\s*=>\s*['"]gpu/,
        'remove deletes only owned GPU integration');
    like(slurp($hardware), qr/PVE::API2::Hardware::UpgradeSentinel/,
        'remove preserves a simulated Proxmox upgrade change');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $index = File::Spec->catfile($tmp, 'index.html.tpl');
    my $hardware = File::Spec->catfile($tmp, 'Hardware.pm');
    my $nodes = File::Spec->catfile($tmp, 'Nodes.pm');
    my $upgraded_index = $index_fixture;
    my $old_blocks = <<'OLD_BLOCKS';
<!-- BEGIN PVE GPU MANAGER -->
<script src="/pve2/js/pve-gpu-plugin.js?ver=1.1.0-8"></script>
<!-- END PVE GPU MANAGER -->
<!-- BEGIN PVE GPU MANAGER --><script src="/pve2/js/pve-gpu-plugin.js?ver=1.1.0-9"></script><!-- END PVE GPU MANAGER --><!-- BEGIN PVE GPU MANAGER --><script src="/pve2/js/pve-gpu-plugin.js?ver=1.1.0-10"></script><!-- END PVE GPU MANAGER -->
<script src="/pve2/js/pve-gpu-plugin.js?ver=1.1.0-7"></script>
OLD_BLOCKS
    $upgraded_index =~ s{</head>}{$old_blocks</head>};
    write_file($index, $upgraded_index);
    write_file($hardware, $hardware_fixture);
    write_file($nodes, $nodes_fixture);

    ok(run_patch_script($index, $hardware, $nodes, '--apply'),
        'upgrade replaces multiline, adjacent, and unmarked old-version script tags');
    my $patched_index = slurp($index);
    is(occurrences($patched_index, 'pve-gpu-plugin.js'), 1,
        'upgrade leaves exactly one GPU plugin script tag');
    is(occurrences($patched_index, '<!-- BEGIN PVE GPU MANAGER -->'), 1,
        'upgrade leaves exactly one owned index marker block');
    like($patched_index, qr/pve-gpu-plugin[.]js[?]ver=1[.]1[.]0-12/,
        'upgrade installs only the current cache version');
    unlike($patched_index, qr/pve-gpu-plugin[.]js[?]ver=1[.]1[.]0-(?:7|8|9|10)/,
        'upgrade removes every stale versioned plugin reference');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $index = File::Spec->catfile($tmp, 'index.html.tpl');
    my $hardware = File::Spec->catfile($tmp, 'Hardware.pm');
    my $nodes = File::Spec->catfile($tmp, 'Nodes.pm');
    write_file($index, $index_fixture);
    write_file($hardware, $current_pve_hardware_fixture);
    write_file($nodes, "package PVE::API2::Nodes;\n1;\n");

    ok(run_patch_script($index, $hardware, $nodes, '--apply'),
        'apply supports current upstream Hardware.pm layout');
    my $patched = slurp($hardware);
    is(occurrences($patched, q({ type => 'gpu' },)), 1,
        'current inline PCI/USB index receives GPU entry');
    is(occurrences($patched, 'subclass => "PVE::API2::Hardware::GPU"'), 1,
        'current module without final 1 receives subclass registration');
    ok(run_patch_script($index, $hardware, $nodes, '--apply'),
        'current upstream layout remains idempotent');
    is(slurp($hardware), $patched, 'current upstream layout is byte-for-byte idempotent');
    ok(run_patch_script($index, $hardware, $nodes, '--remove'),
        'current upstream layout removes cleanly');
    is(slurp($hardware), $current_pve_hardware_fixture,
        'current upstream layout is restored without whole-file backup');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $index = File::Spec->catfile($tmp, 'index.html.tpl');
    my $hardware = File::Spec->catfile($tmp, 'Hardware.pm');
    my $nodes = File::Spec->catfile($tmp, 'Nodes.pm');

    my $legacy_index = $index_fixture;
    $legacy_index =~ s{</head>}{<script src="/pve2/js/pve-gpu-plugin.js"></script>\n</head>};
    my $legacy_hardware = $hardware_fixture;
    $legacy_hardware =~ s{use PVE::API2::Hardware::USB;}{use PVE::API2::Hardware::USB;\nuse PVE::API2::Hardware::GPU;};
    $legacy_hardware =~ s{            \{ type => 'usb' \},}{            { type => 'usb' },\n            { type => 'gpu' },};
    $legacy_hardware =~ s{\n1;}{\n__PACKAGE__->register_method({\n    subclass => "PVE::API2::Hardware::GPU",\n    path => 'gpu',\n});\n\n1;};

    write_file($index, $legacy_index);
    write_file($hardware, $legacy_hardware);
    write_file($nodes, "package PVE::API2::Nodes;\n1;\n");

    ok(run_patch_script($index, $hardware, $nodes, '--apply'), 'legacy unmarked install migrates to markers');
    is(occurrences(slurp($index), '<script src="/pve2/js/pve-gpu-plugin.js?ver=1.1.0-12"></script>'), 1,
        'legacy index tag is replaced by one versioned tag');
    is(occurrences(slurp($index), '<script src="/pve2/js/pve-gpu-plugin.js"></script>'), 0,
        'legacy unversioned script tag is removed');
    is(occurrences(slurp($hardware), 'use PVE::API2::Hardware::GPU;'), 1,
        'legacy Hardware.pm import is not duplicated');
    ok(run_patch_script($index, $hardware, $nodes, '--remove'), 'migrated legacy install removes cleanly');
    unlike(slurp($hardware), qr/PVE::API2::Hardware::GPU|type\s*=>\s*['"]gpu/,
        'no legacy GPU integration remains after removal');
}

{
    my $makefile = slurp(File::Spec->catfile($root, 'Makefile'));
    for my $source (
        'src/PVE/API2/Hardware/GPU.pm',
        'src/PVE/API2/Hardware/GPU/Intel.pm',
        'src/PVE/GPU/SRIOV.pm',
        'src/PVE/GPU/Power.pm',
        'src/js/pve-gpu-plugin.js',
        'src/scripts/apply-sriov-config.sh',
        'src/scripts/apply-vfio-config.sh',
        'src/scripts/manage-ats-policy.sh',
        'src/scripts/check-pve-gpu-binders.sh',
        'src/scripts/reapply-patches.sh',
        'src/systemd/pve-gpu-sriov.service',
        'src/systemd/pve-gpu-vfio.service',
        'src/systemd/pve-guests.service.d/10-pve-gpu-manager.conf',
        'config/99-pve-gpu-reapply',
    ) {
        like($makefile, qr/\Q$source\E/, "install manifest contains $source");
    }
    unlike($makefile, qr{GPU/Nvidia\.pm},
        'install manifest does not ship an unregistered Nvidia backend');
    unlike($makefile, qr{rm -f \.\./\*\.deb}, 'clean does not delete every sibling deb');

    my $rules = slurp(File::Spec->catfile($root, 'debian', 'rules'));
    like($rules, qr/\$\(MAKE\) install DESTDIR=/,
        'debian/rules delegates to the single install manifest');
    like($rules, qr/dh_installsystemd --no-start --no-stop-on-upgrade/,
        'debhelper neither runs nor deactivates the GPU topology services');

    my $control = slurp(File::Spec->catfile($root, 'debian', 'control'));
    like($control, qr/\$\{perl:Depends\}/,
        'generated Perl dependency is consumed by package metadata');
    like($control, qr/Depends:.*\bqemu-server \(>= 8\.0\)/,
        'native VM-start guard has an explicit qemu-server dependency');

    my $postinst = slurp(File::Spec->catfile($root, 'debian', 'postinst'));
    like($postinst, qr/"\$PATCH_SCRIPT" --apply/, 'postinst delegates marker application');
    like($postinst, qr/"\$SRIOV_SCRIPT" --migrate-only/,
        'postinst migrates legacy SR-IOV persistence before enabling boot restore');
    like($postinst, qr/\[ -n "\$\{2:-\}" \].*?--force-restart/s,
        'postinst forces daemon restart specifically on configured-package upgrades');
    like($postinst, qr{/etc/modprobe\.d/pve-gpu-vfio\.conf},
        'postinst removes the legacy global driver blacklist');
    like($postinst, qr{/etc/modules-load\.d/pve-gpu-vfio\.conf},
        'postinst removes the legacy global VFIO modules-load policy');
    like($postinst, qr{vfio-pci\\?\.ids=.*?update-grub}s,
        'postinst removes the legacy vfio-pci.ids kernel argument and refreshes GRUB');
    like($postinst, qr/1\.0\.0-1\|1\.1\.0-1\|1\.1\.0-2\|1\.1\.0-3/,
        'postinst scopes orphaned GRUB ownership to package versions that can carry the old policy');
    like($postinst, qr/update-initramfs -u/,
        'postinst refreshes initramfs when legacy boot policy was removed');
    unlike($postinst, qr/\.pre-gpu|patch_index_html|patch_hardware_pm/,
        'postinst has no whole-file backup or duplicate patch implementation');
    like($postinst, qr/systemctl enable pve-gpu-vfio\.service/,
        'postinst enables the guarded VFIO service');
    like($postinst, qr/systemctl enable pve-gpu-sriov\.service/,
        'postinst enables the boot-time SR-IOV restore service');
    unlike($postinst, qr/systemctl start pve-gpu-(?:sriov|vfio)\.service/,
        'install and upgrade never mutate live PCI topology by starting services');
    like($postinst, qr/triggered\).*?--apply --force-restart/s,
        'dpkg triggers reapply overwritten native PVE markers and reload start paths');
    like(slurp(File::Spec->catfile($root, 'src', 'scripts', 'reapply-patches.sh')),
        qr/systemctl try-restart pve-ha-lrm/,
        'marker replay reloads an already-running HA VM-start process');
    like(slurp(File::Spec->catfile($root, 'src', 'scripts', 'reapply-patches.sh')),
        qr/--check-native/,
        'native ATS health gate has a read-only check action');

    for my $service (qw(pve-gpu-vfio.service pve-gpu-sriov.service)) {
        my $unit = slurp(File::Spec->catfile($root, 'src', 'systemd', $service));
        like($unit, qr/Before=.*pve-guests\.service/s,
            "$service is ordered before pve-guests");
        like($unit, qr/RemainAfterExit=yes/,
            "$service exposes a durable successful oneshot state");
    }
    my $pve_guests_dropin = slurp(File::Spec->catfile(
        $root, 'src', 'systemd', 'pve-guests.service.d', '10-pve-gpu-manager.conf'));
    like($pve_guests_dropin, qr/Wants=.*pve-gpu-vfio\.service.*pve-gpu-sriov\.service/s,
        'pve-guests starts both persisted PCI binders in its transaction');
    like($pve_guests_dropin, qr/After=.*pve-gpu-vfio\.service.*pve-gpu-sriov\.service/s,
        'pve-guests starts only after both persisted PCI binders');
    like($pve_guests_dropin, qr/ExecStartPre=.*reapply-patches\.sh --check-native/,
        'every pve-guests start performs an independent native ATS health check');
    like($pve_guests_dropin, qr/ExecStartPre=.*check-pve-gpu-binders\.sh/,
        'pve-guests propagates a failed persisted binder through a preflight');
    like(slurp(File::Spec->catfile($root, 'src', 'systemd', 'pve-gpu-vfio.service')),
        qr/RemainAfterExit=yes/,
        'VFIO binder remains active for the pve-guests preflight');

    my $triggers = slurp(File::Spec->catfile($root, 'debian', 'triggers'));
    like($triggers, qr{interest-await /usr/share/perl5/PVE/QemuServer\.pm},
        'qemu-server main module replacement activates an awaited replay trigger');
    like($triggers, qr{interest-await /usr/share/perl5/PVE/QemuServer/PCI\.pm},
        'qemu-server PCI module replacement activates an awaited replay trigger');

    my $prerm = slurp(File::Spec->catfile($root, 'debian', 'prerm'));
    like($prerm, qr/remove\|deconfigure\).*?--remove/s,
        'prerm removes markers only for removal/deconfiguration');
    like($prerm, qr/remove\|deconfigure\).*?-s "\$POWER_STATE".*?exit 1.*?--remove/s,
        'package removal is blocked while runtime deep idle protects absent VFs');
    like($prerm, qr/upgrade\).*?Keep the integration/s,
        'prerm preserves integration during upgrade');
    unlike($prerm, qr/\.pre-gpu|restore_backup/,
        'prerm never restores a whole-file backup');
    unlike($prerm, qr{rm\s+-f\s+/etc/},
        'ordinary removal retains user configuration');

    my $postrm = slurp(File::Spec->catfile($root, 'debian', 'postrm'));
    like($postrm, qr/remove\|upgrade.*?systemctl daemon-reload/s,
        'normal removal reloads systemd after deleting the pve-guests drop-in');
    like($postrm, qr/purge\).*?rm -f "\$SRIOV_CONF"/s,
        'purge removes generated SR-IOV configuration');
    like($postrm, qr/purge\).*?rm -f "\$POWER_STATE"/s,
        'purge removes stale runtime power state after guarded removal');
    like($postrm, qr/purge\).*?vfio-pci\\?\.ids=.*?update-grub/s,
        'purge also removes a package-owned legacy vfio-pci.ids argument');

    my $e2e = slurp(File::Spec->catfile($root, 'scripts', 'e2e.sh'));
    unlike($e2e, qr/playwright test[^\n]*\) \|\| true/,
        'Playwright command is not forced to pass');
    like($e2e, qr/\|\| PW_RESULT=\$\?/,
        'Playwright exit status is captured');

    my $gpu_api = slurp(File::Spec->catfile(
        $root, 'src', 'PVE', 'API2', 'Hardware', 'GPU.pm'));
    like($gpu_api, qr/sub _set_pf_driver/,
        'full-PF driver switching is implemented behind a guarded transaction');
    like($gpu_api, qr/Remove all active VFs before switching the physical GPU driver/,
        'full-PF driver switching rejects active VF topology');
    like($gpu_api, qr/VFIO persistence verification failed/,
        'full-PF driver switching verifies its persistent policy');
    like($gpu_api, qr{pci-id-reservations\.lock},
        'SR-IOV transactions interlock with PVE PCI reservations');
    like($gpu_api, qr/sub _assert_power_mode_normal.*?Exit Power Saving/s,
        'conflicting API access has one actionable deep-idle guard');
    like($gpu_api, qr/sub _configure_sriov_v2.*?_assert_power_mode_normal\(\$bdf, 'change SR-IOV state'\)/s,
        'direct SR-IOV mutations are blocked while power saving is active');
    like($gpu_api, qr/name\s*=>\s*'sriov_status'.*?_with_gpu_lock.*?_assert_power_mode_normal/s,
        'SR-IOV status is serialized and cannot wake a sleeping GPU');
    like($gpu_api, qr/sub _ats_policy_status.*?_with_gpu_lock.*?_assert_power_mode_normal/s,
        'ATS status is serialized and cannot wake a sleeping GPU');
    like($gpu_api, qr/name\s*=>\s*'list_devices'.*?_with_gpu_lock.*?_enumerate_devices/s,
        'periodic telemetry is serialized with power transitions');

    my $boot_restore = slurp(File::Spec->catfile(
        $root, 'src', 'scripts', 'apply-sriov-config.sh'));
    unlike($boot_restore, qr/Multi-PF persistent restore is not supported transactionally/,
        'boot restore accepts multi-PF configurations for transactional application');
    like($boot_restore, qr/rollback_completed_devices/,
        'boot restore rolls back previously applied PFs after a later PF fails');
    like($boot_restore, qr/APPLIED_DEVICES/,
        'boot restore tracks successfully applied PFs for rollback');
    like($boot_restore, qr/Current scheduler profile is inconsistent across PF\/VFs/,
        'boot rollback snapshot requires one consistent PF and all-VF scheduler');

    ok(!-e File::Spec->catfile($root, 'debian', 'pve-xpu-manager.postrm.debhelper'),
        'stale pve-xpu-manager postrm helper is absent');
    ok(!-e File::Spec->catfile($root, 'debian', 'pve-xpu-manager.substvars'),
        'stale pve-xpu-manager substvars is absent');
}

done_testing();
