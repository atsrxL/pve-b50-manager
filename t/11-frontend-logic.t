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
like($device_grid, qr/stateful:\s*true.*?stateId:\s*'grid-pve-gpu-devices-v1'/s,
    'device column widths use PVE browser-local grid state');
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
like($device_grid, qr/class="pve-gpu-device-info".*?fa fa-info/s,
    'the Device cell exposes a circular information control before the name');
like($device_grid, qr/e\.getTarget\('\.pve-gpu-device-info'\).*?fireEvent\('deviceinfoclick',\s*me,\s*record/s,
    'the information control opens properties for its exact device record');
like($device_grid, qr/itemId:\s*'atsPolicyBtn'.*?text:\s*gettext\('ATS Policy'\).*?fireEvent\('atspolicyclick'/s,
    'ATS policy is an on-demand button in the GPU Devices header');
like($device_grid, qr/itemId:\s*'powerPolicyBtn'.*?text:\s*gettext\('Power Saving'\).*?fireEvent\('powerpolicyclick'/s,
    'B50 power saving is an on-demand button in the GPU Devices header');
like($device_grid, qr/gpuTelemetrySleeping\(telemetry\).*?Telemetry is paused to avoid waking the GPU/s,
    'sleeping telemetry is rendered without pretending that live watts were sampled');
like($device_grid, qr/vfio_configured.*?power_mode.*?Exit Power Saving before changing the PF driver.*?Sleeping/s,
    'the clickable VFIO cell becomes a non-mutating sleeping indicator');
like($device_grid, qr/var\s+powerActive\s*=.*?power_mode.*?atsPolicyBtn'\)\.setDisabled\(!rec\s*\|\|\s*powerActive\)/s,
    'ATS policy access is disabled while the selected GPU is sleeping');
like($device_grid, qr/dataIndex\s*===\s*'vfio_configured'\s*&&.*?power_mode.*?===\s*'normal'.*?fireEvent\('vfioclick'/s,
    'a sleeping device cannot open the PF-driver mutation dialog through its cell');
like($device_grid, qr/header:\s*gettext\('LMEM \/ VRAM'\).*?lmem_total_mb.*?lmem_used_mb/s,
    'the device grid identifies GPU-local memory as LMEM and VRAM');

my $properties_dialog = class_source('PVE.window.GpuDevicePropertiesDialog');
like($properties_dialog, qr/Device Properties: \{0\} \(\{1\}\).*?gpuPropertiesCard/s,
    'the row information control opens device properties in a dedicated dialog');

my $telemetry = class_source('PVE.panel.GpuTelemetryCard');
like($telemetry, qr/var\s+bdf\s*=\s*me\.currentBdf.*?var\s+requestId\s*=\s*\+\+me\.telemetryRequestId/s,
    'telemetry request captures its BDF and request token');
like($telemetry, qr/requestId\s*!==\s*me\.telemetryRequestId\s*\|\|\s*me\.currentBdf\s*!==\s*bdf/,
    'stale telemetry responses cannot update another GPU');
like($telemetry, qr/updateDisplay:\s*function\(telemetry\)\s*\{.*?me\.clearDisplay\(\)/s,
    'each telemetry render clears fields missing from the new response');
like($telemetry, qr/memRange\.setText\('0\s+\\u2015\s+0'\)/,
    'clearing telemetry also clears the memory range label');

my $ats = class_source('PVE.panel.GpuAtsPolicyPanel');
like($ats, qr!/hardware/gpu/'\s*\+\s*encodeURIComponent\(bdf\)\s*\+\s*'/ats-policy'!,
    'ATS policy uses the per-device ats-policy endpoint');
like($ats, qr/var\s+requestId\s*=\s*\+\+me\.policyRequestId.*?isCurrentPolicy\(bdf,\s*requestId\).*?currentBdf\s*!==\s*bdf/s,
    'stale ATS responses are rejected by request id and BDF');
like($source, qr/function\s+gpuAtsPolicyComplete.*?affected.*?active_noats.*?ats_supported.*?ats_enabled.*?persistent_noats.*?managed.*?safe.*?reboot_required.*?reason/s,
    'ATS status requires every backend safety field before it is trusted');
like($ats, qr/Active:.*?Persistent:.*?ATS:/s,
    'active, persistent, and ATS states are visible in the policy panel');
like($ats, qr/IOTLB_INV_TIMEOUT.*?host hard reset.*?pci=noats.*?global/s,
    'unsafe ATS view shows both the reproduced reset risk and global pci=noats impact');
like($ats, qr/Prepare pci=noats.*?Ext\.Msg\.confirm/s,
    'preparing pci=noats requires an explicit second confirmation');
like($ats, qr/ats-policy'.*?method:\s*'POST'/s,
    'Prepare pci=noats submits POST to the ATS policy endpoint');
like($ats, qr/已准备，重启宿主后生效/,
    'successful preparation tells the operator to reboot manually');
like($ats, qr/Remove managed pci=noats.*?Ext\.Msg\.confirm/s,
    'removing managed pci=noats requires an explicit second confirmation');
like($ats, qr/ats-policy'.*?method:\s*'DELETE'/s,
    'Remove managed pci=noats submits DELETE to the ATS policy endpoint');
like($ats, qr/解除整卡\/VFIO.*?重启后才恢复 ATS/s,
    'managed policy removal explains the whole-GPU release and reboot prerequisite');
like($ats, qr/Ext\.Msg\.alert\(gettext\('Error'\),\s*error\s*\|\|\s*response\.htmlStatus\)/,
    'ATS frontend and backend errors are shown without rewriting the message');
like($ats, qr/Ext\.toast\(gettext\('已准备，重启宿主后生效'\)\).*?reloadPolicy\(bdf\)/s,
    'successful ATS actions show the confirmation and reload only the selected BDF');
like($ats, qr/ATS policy status is unknown.*?fail-closed/s,
    'unknown ATS state visibly fails closed');
like($ats, qr/var\s+affected\s*=\s*known\s*&&\s*gpuAtsBoolean\(policy\.affected\).*?canPrepare\s*=\s*affected.*?canRemove\s*=\s*affected/s,
    'host-wide no-ATS actions are offered only for an affected B50/AMD device');

my $power = class_source('PVE.window.GpuPowerPolicyDialog');
like($power, qr!/hardware/gpu/'\s*\+\s*encodeURIComponent\(bdf\)\s*\+\s*'/power-policy'.*?method:\s*'GET'!s,
    'power dialog loads status from the selected BDF endpoint');
like($power, qr/policy\.blockers.*?Cannot enter power saving/s,
    'power dialog renders backend entry blockers instead of silently disabling the header button');
like($power, qr/runtime-only.*?host reboot.*?persistent VF restore/is,
    'power dialog explains that the first version resets to normal on reboot');
like($power, qr/Temporarily remove all VFs.*?hostpci.*?persistent VF profile.*?Telemetry is paused/s,
    'deep-idle confirmation describes topology and telemetry consequences');
like($power, qr!/power-policy'.*?method:\s*'POST'.*?params:\s*\{\s*action:\s*actionName\s*\}!s,
    'power actions use one transactional POST with an explicit enter or exit action');
like($power, qr/actionName\s*===\s*'enter'.*?B50 entered runtime power saving.*?B50 VF topology restored/s,
    'power action completion distinguishes entry from verified topology restoration');
like($power, qr/policy\.blockers.*?deep\s*&&\s*!gpuAtsBoolean\(policy\.can_exit\).*?policy\.profile_error/s,
    'deep-idle restore failures show topology blockers as well as profile errors');

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
like($sriov, qr/itemId:\s*'vfGrid'.*?flex:\s*1.*?minHeight:\s*180/s,
    'the VF list keeps a visible minimum height while filling remaining space');
like($sriov, qr/itemId:\s*'vfGrid'.*?stateful:\s*true.*?stateId:\s*'grid-pve-gpu-vfs-v1'/s,
    'VF column widths use a separate PVE browser-local grid state');
like($sriov, qr/header:\s*gettext\('LMEM'\).*?gpuVfResourceRenderer\('vram'\)/s,
    'per-VF local memory is labelled LMEM while retaining the backend VRAM resource key');

my $node_override = class_source('PVE.node.GpuManagerOverride');
like($node_override, qr/var\s+gpuItem\s*=\s*\{.*?itemId:\s*'gpugpu'.*?me\.insertNodes\s*=\s*function\(items\).*?items\[i\]\.itemId\s*===\s*'summary'.*?items\.splice\(summaryIndex\s*\+\s*1,\s*0,\s*gpuItem\).*?baseInsertNodes\.call\(me,\s*items\).*?me\.callParent\(arguments\)/s,
    'GPU navigation is inserted directly after Summary before TreeStore creation');
unlike($node_override, qr/root\.insertBefore|summaryNode\.nextSibling/,
    'GPU navigation never moves an already-bound ExtJS tree node');

my $assign = class_source('PVE.window.AssignVfDialog');
like($assign, qr/var\s+initialRows\s*=\s*\[\{\s*vmid:\s*0/s,
    'the rescue assignment store always includes None');
like($assign, qr/assignmentPersistent\s*=\s*me\.getAssignmentPersistent\(\).*?if\s*\(currentVmid\s*&&\s*!assignmentPersistent\).*?vmid:\s*currentVmid/s,
    'a non-persistent assigned VF retains its current VM and None choices');
like($assign, qr/if\s*\(assignmentPersistent\).*?me\.loadVms\(\)/s,
    'only persistent profiles load target VM choices');
like($assign, qr/method:\s*'PUT'.*?params:\s*\{\s*vmid:\s*targetVmid\s*\}/s,
    'VF assignment submits the selected VM ID to the assignment endpoint');

my $whole = class_source('PVE.window.WholeGpuPassthroughDialog');
like($whole, qr/title:\s*gettext\('Quick Whole-GPU Passthrough'\)/,
    'whole-GPU quick mode has an explicit dialog');
like($whole, qr/Detach all \{0\} VF VM assignment\(s\).*?Delete all \{0\} active VF\(s\).*?Bind the physical GPU to vfio-pci.*?Assign the whole physical GPU/s,
    'confirmation plan explains every destructive and assignment step');
like($whole, qr/Only this GPU PF and its VFs are changed\. Separate audio or other PCI devices are not moved automatically\./,
    'confirmation explicitly excludes separate audio and unrelated PCI functions');
like($whole, qr/currentPfVmid\s*=.*?get\('pf_vmid'\)/s,
    'whole-GPU dialog identifies an existing PF consumer');
like($whole, qr/vm\.status\s*!==\s*'stopped'\s*\|\|\s*vm\.lock.*?vmid\s*!==\s*me\.currentPfVmid/s,
    'new whole-GPU targets are stopped and unlocked while the current target remains visible');
like($whole, qr/var\s+requestId\s*=\s*\+\+me\.vmRequestId.*?requestId\s*!==\s*me\.vmRequestId\s*\|\|\s*me\.currentBdf\s*!==\s*bdf/s,
    'stale VM-list responses cannot update a dialog for another BDF');
like($whole, qr/var\s+sameTarget\s*=.*?targetVmid\s*===\s*me\.currentPfVmid.*?moveBlocked\s*=.*?!sameTarget\s*&&\s*!sourceStopped/s,
    'same-target verification remains available while a move requires the source VM to stop');
like($whole, qr/A fully consistent state is left unchanged; stop the VM first if repair is required/,
    'same-target confirmation does not promise a no-op when backend reconciliation is required');
like($whole, qr/var\s+vmById\s*=\s*\{\}.*?vmById\[vmid\]\s*=\s*vm.*?me\.assignments.*?vm\.status\s*!==\s*'stopped'\s*\|\|\s*vm\.lock.*?me\.consumerBlockers\s*=\s*Ext\.Object\.getKeys\(blocked\)/s,
    'VM inventory blocks stopped-but-locked and running VF consumers before submission');
like($whole, qr!/hardware/gpu/'\s*\+\s*encodeURIComponent\(bdf\)\s*\+\s*'/passthrough'.*?method:\s*'POST'.*?params:\s*\{\s*vmid:\s*targetVmid\s*\}!s,
    'whole-GPU dialog submits one transactional passthrough request');
like($whole, qr/var\s+requestId\s*=\s*\+\+me\.transactionRequestId.*?requestId\s*!==\s*me\.transactionRequestId\s*\|\|\s*me\.currentBdf\s*!==\s*bdf/s,
    'stale whole-GPU transaction responses cannot refresh another BDF');
like($whole, qr/fireEvent\('wholepassthroughchanged',\s*me,\s*bdf,\s*data\)/,
    'whole-GPU completion reports the captured BDF');
unlike($whole, qr/x-vga|x_vga|primary\s+gpu/i,
    'whole-GPU quick mode does not silently enable a primary-GPU option');

like($sriov, qr/itemId:\s*'wholeGpuBtn'.*?Quick Whole-GPU Passthrough.*?openWholeGpuDialog/s,
    'SR-IOV toolbar exposes the whole-GPU quick mode');
like($sriov, qr/if\s*\(pfAssigned\).*?button\.setDisabled\(false\).*?currently assigned to VM \{0\}/s,
    'quick mode remains available and identifies an existing whole-GPU VM');
like($sriov, qr/if\s*\(pfAssigned\).*?schedulerStatus.*?Unavailable while the PF is bound to vfio-pci/s,
    'PF passthrough state replaces the stale scheduler loading message');
like($sriov, qr/running\.length\s*>\s*0.*?button\.setDisabled\(true\).*?Stop every VF consumer VM/s,
    'running VF consumers disable quick mode');
like($sriov, qr/var\s+atsUnsafe\s*=\s*atsKnown.*?affected.*?safe/s,
    'whole-GPU safety gate uses the affected and safe ATS fields');
like($sriov, qr/if\s*\(!atsKnown\).*?button\.setDisabled\(true\).*?else if\s*\(atsUnsafe\).*?button\.setDisabled\(true\).*?else if\s*\(pfAssigned\).*?button\.setDisabled\(false\)/s,
    'unknown or unsafe ATS blocks only whole-GPU writes while a safe device remains available');
like($sriov, qr/openWholeGpuDialog:\s*function\(\).*?isAtsPolicyKnown\(\).*?native status view/s,
    'programmatic whole-GPU opens are also blocked from unsafe repair writes');
like($sriov, qr/changedBdf\s*!==\s*bdf\s*\|\|\s*!me\.isCurrentDevice\(bdf\).*?fireEvent\('vfschanged',\s*me,\s*bdf,\s*data\)/s,
    'whole-GPU completion refreshes only the owning BDF');

my $detail = class_source('PVE.panel.GpuDeviceDetail');
unlike($detail, qr/gpuPropertiesCard|gpuTelemetryCard|Device Detail/,
    'the permanent workspace no longer duplicates properties or telemetry');
like($detail, qr/xtype:\s*'gpuAtsPolicyPanel'.*?itemId:\s*'atsPolicyProbe'.*?hidden:\s*true/s,
    'ATS continues loading for the safety gate without occupying visible space');
like($detail, qr/atspolicychange.*?setAtsPolicy\(policy,\s*bdf\)/s,
    'ATS responses reach the whole-GPU safety gate with their captured BDF');
like($detail, qr/atsPolicyProbe'\)\.loadDevice\(record\).*?sriovPanel\.loadDevice\(record\)/s,
    'device selection reloads ATS and ordinary SR-IOV state together');
like($detail, qr/power_mode.*?powerMode\s*!==\s*'normal'.*?atsPolicyProbe'\)\.loadDevice\(null\).*?sriovPanel\.loadDevice\(null\).*?sriovPanel\.setVisible\(false\)/s,
    'deep-idle selection cancels hidden ATS and SR-IOV probes before hiding the VF workspace');
like($detail, qr/itemId:\s*'powerSleepNotice'.*?GPU is in power-saving mode.*?restore the VF workspace/s,
    'the parked VF workspace is replaced by a non-polling recovery notice');
like($detail, qr/powerMode\s*!==\s*'normal'.*?return;.*?sriovPanel\.setVisible\(true\).*?atsPolicyProbe'\)\.loadDevice\(record\)/s,
    'normal mode restores the ordinary ATS and VF workspace loads');

my $ats_dialog = class_source('PVE.window.GpuAtsPolicyDialog');
like($ats_dialog, qr/ATS Safety Policy: \{0\}.*?gpuAtsPolicyPanel.*?loadDevice\(record\)/s,
    'the ATS button opens the selected BDF policy in a dedicated dialog');
like($ats_dialog, qr/atspolicychange.*?fireEvent\('atspolicychange',\s*me,\s*bdf,\s*policy\)/s,
    'ATS dialog actions keep the whole-GPU safety gate synchronized');

my $manager = class_source('PVE.node.GpuManager');
like($manager, qr/vfschanged:\s*function\(detail,\s*bdf\).*?deviceGrid'\)\.reload\(bdf\)/s,
    'whole-GPU completion reloads the changed BDF in the device grid');
like($manager, qr/itemId:\s*'deviceGrid'.*?height:\s*166.*?split:\s*false/s,
    'the GPU device area is fixed to the reviewed two-row height');
like($manager, qr/deviceinfoclick:.*?openDevicePropertiesDialog.*?powerpolicyclick:.*?openPowerPolicyDialog.*?atspolicyclick:.*?openAtsPolicyDialog/s,
    'the manager routes properties, power, and ATS dialogs from the compact device grid');
like($manager, qr/powerpolicychange.*?deviceGrid'\)\.reload\(bdf\)/s,
    'a completed power transition refreshes only the selected BDF');

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
