#!/usr/bin/perl
use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

my $root = tempdir(CLEANUP => 1);
$ENV{PVE_GPU_POWER_STATE} = "$root/run/pve-gpu/power-state.conf";

use FindBin;
use lib "$FindBin::Bin/../src";
use PVE::GPU::Power qw(
    assert_vm_start_allowed
    clear_power_state_for_bdf
    is_deep_idle
    power_state_for_bdf
    read_power_state
    set_power_state_for_bdf
    write_power_state
);

my $pf = '0000:0b:00.0';
my $vf1 = '0000:0b:00.1';
my $vf2 = '0000:0b:00.2';

ok(!is_deep_idle($pf), 'missing runtime state means normal telemetry is allowed');
ok(assert_vm_start_allowed({ hostpci0 => $vf1 }, 201),
    'missing runtime state does not block a VM start');

my $record = {
    api_version => 1,
    mode => 'deep-idle',
    restore_count => 2,
    restore_autoprobe => 0,
    restore_scheduler => 'low',
    restore_control => 'auto',
    restore_delay => 1000,
    vf_bdfs => "$vf1,$vf2",
    consumer_vmids => '201,202',
};
ok(set_power_state_for_bdf($pf, $record), 'deep-idle state is written atomically');
ok(-f $ENV{PVE_GPU_POWER_STATE}, 'runtime state file exists');
ok(is_deep_idle($pf), 'deep-idle state suppresses wake-up telemetry');
is(power_state_for_bdf($pf)->{restore_count}, 2,
    'saved VF count round-trips through the state file');

my ($ok, $error);
{
    local $@;
    $ok = eval { assert_vm_start_allowed({}, 201); 1 };
    $error = $@;
}
ok(!$ok, 'a recorded consumer VM is blocked even while its VF is absent');
like($error, qr/VM 201.*deep-idle.*Exit Power Saving/is,
    'recorded-consumer rejection is actionable');

{
    local $@;
    $ok = eval { assert_vm_start_allowed({ hostpci3 => "$vf2,pcie=1" }, 303); 1 };
    $error = $@;
}
ok(!$ok, 'a newly configured full-domain VF BDF is blocked');
like($error, qr/VM 303.*$pf/is, 'BDF rejection identifies the sleeping PF');

{
    local $@;
    $ok = eval {
        assert_vm_start_allowed({ pending => { hostpci7 => $vf1 } }, 309);
        1;
    };
    $error = $@;
}
ok(!$ok, 'a pending hostpci change which names a parked VF is also blocked');

{
    local $@;
    $ok = eval { assert_vm_start_allowed({ hostpci0 => '0b:00.1,rombar=0' }, 304); 1 };
    $error = $@;
}
ok(!$ok, 'a domain-short VF BDF is normalised and blocked');
ok(assert_vm_start_allowed({ hostpci0 => '0000:0c:00.0' }, 305),
    'an unrelated PCI device remains startable');

my $valid_mode = $record->{mode};
$record->{mode} = 'future-unknown-mode';
set_power_state_for_bdf($pf, $record);
ok(is_deep_idle($pf), 'an unknown runtime mode still suppresses wake-up telemetry');
{
    local $@;
    $ok = eval { assert_vm_start_allowed({ hostpci0 => '0000:0c:00.0' }, 308); 1 };
    $error = $@;
}
ok(!$ok, 'an unknown runtime mode fails closed even for an unrelated VM');
like($error, qr/unknown-mode.*Exit Power Saving/is,
    'unknown-mode start rejection identifies the protected recovery state');
$record->{mode} = $valid_mode;
set_power_state_for_bdf($pf, $record);

{
    no warnings 'redefine';
    local $INC{'PVE/INotify.pm'} = __FILE__;
    local $INC{'PVE/Mapping/PCI.pm'} = __FILE__;
    local *PVE::INotify::nodename = sub { return 'pve-test' };
    local *PVE::Mapping::PCI::config = sub { return {} };
    local *PVE::Mapping::PCI::get_node_mapping = sub {
        my ($config, $mapping_id, $node) = @_;
        return [{ path => $mapping_id eq 'sleeping-vf' ? $vf1 : '0000:0c:00.0' }];
    };

    {
        local $@;
        $ok = eval {
            assert_vm_start_allowed({ hostpci0 => 'mapping=sleeping-vf,pcie=1' }, 306);
            1;
        };
        $error = $@;
    }
    ok(!$ok, 'a PCI mapping which resolves to a parked VF is blocked');
    like($error, qr/VM 306.*Exit Power Saving/is,
        'mapped-VF rejection uses the same actionable start error');
    ok(assert_vm_start_allowed({ hostpci0 => 'mapping=unrelated-device' }, 307),
        'a PCI mapping to an unrelated device remains startable');
}

$record->{mode} = 'restored';
set_power_state_for_bdf($pf, $record);
ok(is_deep_idle($pf), 'restored-but-not-cleared state still suppresses telemetry');
{
    local $@;
    $ok = eval { assert_vm_start_allowed({}, 202); 1 };
    $error = $@;
}
ok(!$ok, 'restored-but-not-cleared state remains fail-closed for VM start');

my $other_pf = '0000:0d:00.0';
set_power_state_for_bdf($other_pf, {
    %$record,
    mode => 'deep-idle',
    restore_count => 0,
    vf_bdfs => '',
    consumer_vmids => '404',
});
is(scalar(keys %{read_power_state()}), 2,
    'updating one PF preserves another PF runtime record');
clear_power_state_for_bdf($pf);
ok(!is_deep_idle($pf), 'clearing one PF returns it to normal mode');
ok(is_deep_idle($other_pf), 'clearing one PF preserves another deep-idle PF');
clear_power_state_for_bdf($other_pf);
ok(!-e $ENV{PVE_GPU_POWER_STATE}, 'clearing the final PF removes the state file');

set_power_state_for_bdf($pf, $record);
my $before = read_power_state();
{
    local $@;
    $ok = eval {
        set_power_state_for_bdf($other_pf, {
            mode => "deep-idle\ninvalid",
        });
        1;
    };
    $error = $@;
}
ok(!$ok, 'newline injection in a state value is rejected');
like($error, qr/newline/i, 'invalid value error identifies the newline');
is_deeply(read_power_state(), $before,
    'a failed atomic state update preserves the previous file');

open(my $fh, '>', $ENV{PVE_GPU_POWER_STATE}) or die "Cannot corrupt state fixture: $!";
print {$fh} "[$pf]\nmode = deep-idle\nmode = entering\n";
close($fh) or die "Cannot close corrupt state fixture: $!";
ok(is_deep_idle($pf), 'malformed active state suppresses telemetry fail-closed');
{
    local $@;
    $ok = eval { assert_vm_start_allowed({}, 500); 1 };
    $error = $@;
}
ok(!$ok, 'malformed active state blocks native VM start');
like($error, qr/Duplicate GPU power state key/i,
    'malformed-state rejection preserves the parser evidence');

done_testing();
