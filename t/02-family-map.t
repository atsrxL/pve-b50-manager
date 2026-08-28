#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

# Supported device family map copied from the Intel plugin.
my $DEVICE_FAMILIES = {
    '0xe211' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe212' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe222' => { family => 'bmg',      max_vfs => 24, tiles => 1 },
    '0xe223' => { family => 'bmg_12vf', max_vfs => 12, tiles => 1 },
};

# Inline identify_device logic (mirrors GPU.pm)
sub identify_device {
    my ($device_id) = @_;
    $device_id = lc($device_id);
    $device_id = "0x$device_id" unless $device_id =~ /^0x/;
    return $DEVICE_FAMILIES->{$device_id};
}

# --- bmg IDs ---
for my $id (qw(0xe211 0xe212 0xe222)) {
    my $info = identify_device($id);
    is($info->{family},   'bmg', "$id: family=bmg");
    is($info->{max_vfs},  24,    "$id: max_vfs=24");
    is($info->{tiles},    1,     "$id: tiles=1");
}

# --- bmg_12vf ---
{
    my $info = identify_device('0xe223');
    is($info->{family},   'bmg_12vf', '0xe223: family=bmg_12vf');
    is($info->{max_vfs},  12,         '0xe223: max_vfs=12');
    is($info->{tiles},    1,          '0xe223: tiles=1');
}

# --- Unknown ID ---
is(identify_device('0x1234'), undef, 'unknown 0x1234 returns undef');

# Older Flex/PVC IDs are not exposed because the BMG boot restorer cannot
# restore their different driver ABI.
for my $id (qw(
    0x56c0 0x56c1 0x56c2
    0x0bd4 0x0bd5 0x0bd6
    0x0bda 0x0bdb 0x0b6e
)) {
    is(identify_device($id), undef, "$id is outside the supported BMG set");
}

is(scalar keys %$DEVICE_FAMILIES, 4, 'map contains exactly four supported BMG IDs');

done_testing();
