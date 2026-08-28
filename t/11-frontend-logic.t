#!/usr/bin/perl
use strict;
use warnings;

use FindBin;
use Test::More;

my $source_path = "$FindBin::Bin/../src/js/pve-gpu-plugin.js";
open(my $fh, '<', $source_path) or die "Cannot read $source_path: $!";
local $/;
my $source = <$fh>;
close($fh) or die "Cannot close $source_path: $!";

sub class_source {
    my ($name) = @_;
    my $marker = "Ext.define('$name'";
    my $start = index($source, $marker);
    die "Missing frontend class $name" if $start < 0;
    my $next = index($source, "Ext.define('", $start + length($marker));
    $next = length($source) if $next < 0;
    return substr($source, $start, $next - $start);
}

my $vfio = class_source('PVE.window.GpuVfioDialog');
like($vfio, qr/var\s+pfAssigned\s*=.*get\('pf_assigned'\)/s,
    'VFIO dialog reads whole-PF VM assignment state');
like($vfio, qr/var\s+blocked\s*=\s*pfAssigned\s*\|\|/,
    'whole-PF assignment disables VFIO apply');

my $device_grid = class_source('PVE.grid.GpuDeviceGrid');
like($device_grid, qr/var\s+driver\s*=\s*record\.get\('driver'\).*?gettext\('Live'\)/s,
    'VFIO cell labels the live driver from the driver field');
like($device_grid, qr/gettext\('Boot VFIO'\).*val\s*\?\s*gettext\('Yes'\)/s,
    'VFIO cell labels boot persistence separately');
like($device_grid, qr/var\s+requestId\s*=\s*\+\+me\.reloadRequestId/,
    'device refresh has a latest-request token');
like($device_grid, qr/var\s+currentSelection\s*=.*?var\s+desiredBdf\s*=\s*currentBdf\s*\|\|\s*selectedBdf/s,
    'device refresh preserves a selection made while the request was running');
like($device_grid, qr/latest\[0\]\.get\('bdf'\)\s*!==\s*desiredBdf/,
    'deferred first-device selection does not overwrite a newer click');
like($device_grid, qr/deselectAll\(\).*?fireEvent\('deviceselect',\s*me,\s*null\)/s,
    'an empty device list explicitly clears the selected device');

my $telemetry = class_source('PVE.panel.GpuTelemetryCard');
like($telemetry, qr/var\s+bdf\s*=\s*me\.currentBdf.*?var\s+requestId\s*=\s*\+\+me\.telemetryRequestId/s,
    'telemetry request captures its BDF and request token');
like($telemetry, qr/requestId\s*!==\s*me\.telemetryRequestId\s*\|\|\s*me\.currentBdf\s*!==\s*bdf/,
    'stale telemetry responses cannot update another GPU');
like($telemetry, qr/updateDisplay:\s*function\(telemetry\)\s*\{.*?me\.clearDisplay\(\)/s,
    'each telemetry render clears fields missing from the new response');
like($telemetry, qr/memRange\.setText\('0\s+\\u2015\s+0'\)/,
    'clearing telemetry also clears the memory range label');

my $prechecks = class_source('PVE.panel.GpuPrecheckBar');
like($prechecks, qr/var\s+checks\s*=\s*prechecks\s*&&\s*prechecks\.checks/,
    'precheck UI consumes the backend checks object');
like($prechecks, qr/checks\s*&&\s*checks\[definition\.name\]/,
    'precheck UI maps named backend checks to their cards');
like($prechecks, qr/if\s*\(check\.pass\)/,
    'precheck UI reads the backend pass field');
like($prechecks, qr/check\.detail\s*\|\|\s*gettext\('Failed'\)/,
    'precheck failures display the backend detail');

my $modify = class_source('PVE.window.ModifyVfsDialog');
like($modify, qr/var\s+persistEnabled\s*=\s*status\.persisted_config\s*!==\s*undefined/s,
    'persist checkbox is initialized from SR-IOV status');
like($modify, qr/Number\(persisted\.persist\s*\|\|\s*0\)\s*===\s*1/,
    'persist checkbox follows the explicit persisted policy, not section presence');
like($modify, qr/checked:\s*persistEnabled/,
    'persist checkbox uses the current persisted state');
unlike($modify, qr/itemId:\s*'persistCb'.{0,180}checked:\s*true/s,
    'persist checkbox is not hard-coded on');
like($modify, qr/if\s*\(me\.hasAssignedConsumer\).*?persistField\.setValue\(true\).*?persistField\.setDisabled\(me\.hasAssignedConsumer\)/s,
    'VM consumers keep persistence enabled');

my $sriov = class_source('PVE.panel.GpuSriovPanel');
like($sriov, qr/requestId\s*!==\s*me\.sriovRequestId\s*\|\|\s*!me\.isCurrentDevice\(bdf\)/,
    'stale SR-IOV status responses are ignored');
like($sriov, qr/requestId\s*!==\s*me\.vfRequestId\s*\|\|\s*!me\.isCurrentDevice\(bdf\)/,
    'stale VF-list responses are ignored');
like($sriov, qr/isCurrentDevice:\s*function\(bdf\).*?deviceRecord\.get\('bdf'\)\s*===\s*bdf/s,
    'SR-IOV response ownership is based on the selected device BDF');
like($sriov, qr/xtype:\s*'gpuPrecheckBar'.*?itemId:\s*'precheckBar'/s,
    'SR-IOV panel includes the prerequisites bar');
like($sriov, qr/precheckBar'\)\.loadPrechecks\(data\.prechecks\)/,
    'SR-IOV status is rendered through the prerequisites bar');
like($sriov, qr/celldblclick:.*?dataIndex\s*===\s*'vmid'.*?openVfAssignmentDialog\(record\)/s,
    'double-clicking the VM column opens VF assignment');
like($sriov, qr/assignmentPersistent\s*=\s*Number\(persisted\.persist\s*\|\|\s*0\)\s*===\s*1/,
    'VF assignment derives eligibility from the persisted profile');
like($sriov, qr/if\s*\(!assignmentPersistent\s*&&\s*!currentVmid\).*?Persistent profile required/s,
    'an unassigned non-persistent VF is blocked before the assignment dialog');
like($sriov, qr/assignmentPersistent:\s*assignmentPersistent/,
    'VF assignment policy is passed into the dialog');

my $assign = class_source('PVE.window.AssignVfDialog');
like($assign, qr/var\s+initialRows\s*=\s*\[\{\s*vmid:\s*0/s,
    'the rescue assignment store always includes None');
like($assign, qr/assignmentPersistent\s*=\s*me\.getAssignmentPersistent\(\).*?if\s*\(currentVmid\s*&&\s*!assignmentPersistent\).*?vmid:\s*currentVmid/s,
    'a non-persistent assigned VF retains its current VM and None choices');
like($assign, qr/if\s*\(assignmentPersistent\).*?me\.loadVms\(\)/s,
    'only persistent profiles load target VM choices');
like($assign, qr/method:\s*'PUT'.*?params:\s*\{\s*vmid:\s*targetVmid\s*\}/s,
    'VF assignment submits the selected VM ID to the assignment endpoint');

my $detail = class_source('PVE.panel.GpuDeviceDetail');
like($detail, qr/if\s*\(!record\).*?propsCard'\)\.loadRecord\(null\).*?telemetryCard'\)\.loadDevice\(null\).*?sriovPanel'\)\.loadDevice\(null\)/s,
    'clearing device selection clears properties, telemetry, and SR-IOV state');

my $node;
for my $dir (split(/:/, $ENV{PATH} // '')) {
    my $candidate = "$dir/node";
    if (-x $candidate && !-d $candidate) {
        $node = $candidate;
        last;
    }
}

SKIP: {
    skip 'node is unavailable for JavaScript syntax validation', 1 if !defined($node);
    is(system($node, '--check', $source_path), 0, 'frontend JavaScript passes node --check');
}

done_testing();
