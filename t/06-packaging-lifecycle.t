#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
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

sub run_patch_script {
    my ($index, $hardware, $nodes, $action) = @_;
    local %ENV = %ENV;
    $ENV{PVE_GPU_INDEX_TPL} = $index;
    $ENV{PVE_GPU_HARDWARE_PM} = $hardware;
    $ENV{PVE_GPU_NODES_PM} = $nodes;
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
    is(occurrences($patched_index, '<script src="/pve2/js/pve-gpu-plugin.js"></script>'), 1,
        'index contains one plugin script tag');
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
    is(occurrences(slurp($index), '<script src="/pve2/js/pve-gpu-plugin.js"></script>'), 1,
        'legacy index tag is not duplicated');
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
        'src/PVE/API2/Hardware/GPU/Nvidia.pm',
        'src/PVE/GPU/SRIOV.pm',
        'src/js/pve-gpu-plugin.js',
        'src/scripts/apply-sriov-config.sh',
        'src/scripts/apply-vfio-config.sh',
        'src/scripts/reapply-patches.sh',
        'src/systemd/pve-gpu-sriov.service',
        'src/systemd/pve-gpu-vfio.service',
        'config/99-pve-gpu-reapply',
    ) {
        like($makefile, qr/\Q$source\E/, "install manifest contains $source");
    }
    unlike($makefile, qr{rm -f \.\./\*\.deb}, 'clean does not delete every sibling deb');

    my $rules = slurp(File::Spec->catfile($root, 'debian', 'rules'));
    like($rules, qr/\$\(MAKE\) install DESTDIR=/,
        'debian/rules delegates to the single install manifest');
    like($rules, qr/dh_installsystemd --no-start/,
        'debhelper cannot auto-start the VFIO binder');

    my $control = slurp(File::Spec->catfile($root, 'debian', 'control'));
    like($control, qr/\$\{perl:Depends\}/,
        'generated Perl dependency is consumed by package metadata');

    my $postinst = slurp(File::Spec->catfile($root, 'debian', 'postinst'));
    like($postinst, qr/"\$PATCH_SCRIPT" --apply/, 'postinst delegates marker application');
    unlike($postinst, qr/\.pre-gpu|patch_index_html|patch_hardware_pm/,
        'postinst has no whole-file backup or duplicate patch implementation');
    like($postinst, qr/systemctl enable pve-gpu-vfio\.service/,
        'postinst enables the guarded VFIO service');
    like($postinst, qr/systemctl enable pve-gpu-sriov\.service/,
        'postinst enables the boot-time SR-IOV restore service');
    unlike($postinst, qr/systemctl start pve-gpu-(?:sriov|vfio)\.service/,
        'install and upgrade never mutate live PCI topology by starting services');

    my $prerm = slurp(File::Spec->catfile($root, 'debian', 'prerm'));
    like($prerm, qr/remove\|deconfigure\).*?--remove/s,
        'prerm removes markers only for removal/deconfiguration');
    like($prerm, qr/upgrade\).*?Keep the integration/s,
        'prerm preserves integration during upgrade');
    unlike($prerm, qr/\.pre-gpu|restore_backup/,
        'prerm never restores a whole-file backup');
    unlike($prerm, qr{rm\s+-f\s+/etc/},
        'ordinary removal retains user configuration');

    my $postrm = slurp(File::Spec->catfile($root, 'debian', 'postrm'));
    like($postrm, qr/purge\).*?rm -f \/etc\/pve\/local\/gpu-sriov\.conf/s,
        'purge removes generated SR-IOV configuration');

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

    my $boot_restore = slurp(File::Spec->catfile(
        $root, 'src', 'scripts', 'apply-sriov-config.sh'));
    unlike($boot_restore, qr/Multi-PF persistent restore is not supported transactionally/,
        'boot restore accepts multi-PF configurations for transactional application');
    like($boot_restore, qr/rollback_completed_devices/,
        'boot restore rolls back previously applied PFs after a later PF fails');
    like($boot_restore, qr/APPLIED_DEVICES/,
        'boot restore tracks successfully applied PFs for rollback');
    like($boot_restore, qr/Current scheduler profile is inconsistent across VFs/,
        'boot rollback snapshot requires one consistent all-VF scheduler');

    ok(!-e File::Spec->catfile($root, 'debian', 'pve-xpu-manager.postrm.debhelper'),
        'stale pve-xpu-manager postrm helper is absent');
    ok(!-e File::Spec->catfile($root, 'debian', 'pve-xpu-manager.substvars'),
        'stale pve-xpu-manager substvars is absent');
}

done_testing();
