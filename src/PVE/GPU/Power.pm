package PVE::GPU::Power;

use strict;
use warnings;

use Exporter qw(import);
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use File::Basename qw(dirname);
use File::Path qw(make_path);

our @EXPORT_OK = qw(
    assert_vm_start_allowed
    clear_power_state_for_bdf
    is_deep_idle
    power_state_for_bdf
    power_state_path
    read_power_state
    set_power_state_for_bdf
    write_power_state
);

my $BDF_RE = qr/[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]/;
my $BDF_SCAN_RE = qr/(?<![0-9a-f])(?:[0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-7](?![0-9a-f])/i;

sub _safe_absolute_path {
    my ($path, $label) = @_;
    $label //= 'path';
    die "Missing $label\n" if !defined($path) || $path eq '';
    my ($clean) = $path =~ m{\A(/[A-Za-z0-9_./:+\-]+)\z};
    die "Unsafe $label\n" if !defined($clean);
    die "Unsafe $label contains a relative path component\n"
        if $clean =~ m{(?:\A|/)\.{1,2}(?:/|\z)};
    return $clean;
}

sub power_state_path {
    return _safe_absolute_path(
        $ENV{PVE_GPU_POWER_STATE} // '/run/pve-gpu/power-state.conf',
        'GPU power state path',
    );
}

sub _normalise_bdf {
    my ($bdf) = @_;
    return undef if !defined($bdf);
    $bdf = lc($bdf);
    $bdf =~ s/^\s+|\s+\z//g;
    $bdf = "0000:$bdf" if $bdf =~ /^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/;
    return $bdf =~ /^$BDF_RE$/o ? $bdf : undef;
}

sub _validate_value {
    my ($value, $label) = @_;
    die "Missing $label\n" if !defined($value);
    $value = "$value";
    die "Invalid newline in $label\n" if $value =~ /[\r\n]/;
    return $value;
}

sub read_power_state {
    my $path = power_state_path();
    return {} if !-e $path;

    open(my $fh, '<', $path)
        or die "Cannot read GPU power state '$path': $!\n";
    my %state;
    my $section;
    my $line_number = 0;
    while (my $line = <$fh>) {
        $line_number++;
        chomp($line);
        $line =~ s/\r\z//;
        $line =~ s/^\s+|\s+\z//g;
        next if $line eq '' || $line =~ /^#/;

        if ($line =~ /^\[([^]]+)\]$/) {
            my $bdf = _normalise_bdf($1);
            die "Invalid GPU BDF in '$path' at line $line_number\n"
                if !defined($bdf);
            die "Duplicate GPU power state section '$bdf' in '$path'\n"
                if exists($state{$bdf});
            $state{$bdf} = {};
            $section = $bdf;
            next;
        }

        die "GPU power state key outside a section in '$path' at line $line_number\n"
            if !defined($section);
        die "Malformed GPU power state '$path' at line $line_number\n"
            if $line !~ /^([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*)$/;
        my ($key, $value) = ($1, $2);
        die "Duplicate GPU power state key '$key' in section '$section'\n"
            if exists($state{$section}{$key});
        $state{$section}{$key} = $value;
    }
    close($fh) or die "Cannot close GPU power state '$path': $!\n";
    return \%state;
}

sub write_power_state {
    my ($state) = @_;
    die "GPU power state must be an object\n" if ref($state) ne 'HASH';
    my $path = power_state_path();

    my @sections = sort keys %$state;
    if (!@sections) {
        unlink($path) or die "Cannot remove GPU power state '$path': $!\n"
            if -e $path;
        return 1;
    }

    my $directory = _safe_absolute_path(dirname($path), 'GPU power state directory');
    make_path($directory, { mode => 0755 }) if !-d $directory;
    die "GPU power state directory '$directory' is unavailable\n" if !-d $directory;

    my $tmp = "$path.tmp.$$";
    sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or die "Cannot create GPU power state '$tmp': $!\n";
    my $ok = eval {
        for my $raw_bdf (@sections) {
            my $bdf = _normalise_bdf($raw_bdf);
            die "Invalid GPU power state section '$raw_bdf'\n" if !defined($bdf);
            my $record = $state->{$raw_bdf};
            die "GPU power state section '$bdf' must be an object\n"
                if ref($record) ne 'HASH';
            print {$fh} "[$bdf]\n"
                or die "Cannot write GPU power state '$tmp': $!\n";
            for my $key (sort keys %$record) {
                die "Invalid GPU power state key '$key'\n"
                    if $key !~ /^[A-Za-z][A-Za-z0-9_]*$/;
                my $value = _validate_value($record->{$key}, "GPU power state '$key'");
                print {$fh} "$key = $value\n"
                    or die "Cannot write GPU power state '$tmp': $!\n";
            }
            print {$fh} "\n"
                or die "Cannot finish GPU power state '$tmp': $!\n";
        }
        close($fh) or die "Cannot close GPU power state '$tmp': $!\n";
        rename($tmp, $path)
            or die "Cannot publish GPU power state '$path': $!\n";
        1;
    };
    my $error = $@;
    if (!$ok) {
        eval { close($fh) };
        unlink($tmp) if -e $tmp;
        die $error;
    }
    return 1;
}

sub power_state_for_bdf {
    my ($bdf) = @_;
    $bdf = _normalise_bdf($bdf);
    die "Invalid GPU BDF for power state\n" if !defined($bdf);
    my $state = read_power_state();
    return $state->{$bdf};
}

sub set_power_state_for_bdf {
    my ($bdf, $record) = @_;
    $bdf = _normalise_bdf($bdf);
    die "Invalid GPU BDF for power state\n" if !defined($bdf);
    die "GPU power state record must be an object\n" if ref($record) ne 'HASH';
    my $state = read_power_state();
    $state->{$bdf} = { %$record };
    return write_power_state($state);
}

sub clear_power_state_for_bdf {
    my ($bdf) = @_;
    $bdf = _normalise_bdf($bdf);
    die "Invalid GPU BDF for power state\n" if !defined($bdf);
    my $state = read_power_state();
    delete $state->{$bdf};
    return write_power_state($state);
}

sub is_deep_idle {
    my ($bdf) = @_;
    my $path = power_state_path();
    return 0 if !-e $path;
    my $record;
    my $ok = eval {
        $record = power_state_for_bdf($bdf);
        1;
    };
    # A malformed active-state file must suppress wake-up telemetry until an
    # administrator can inspect it.  Native VM starts fail closed separately.
    return 1 if !$ok;
    # Runtime records exist only while a PF is being protected.  An unknown
    # future/corrupt mode must remain non-waking until explicit recovery or a
    # reboot clears /run; treating it as normal would be the unsafe choice.
    return ref($record) eq 'HASH' ? 1 : 0;
}

sub _split_list {
    my ($value) = @_;
    return () if !defined($value) || $value eq '';
    return grep { $_ ne '' } map {
        my $item = $_;
        $item =~ s/^\s+|\s+\z//g;
        $item;
    } split(/,/, $value);
}

sub _blocked_start_error {
    my ($vmid, $pf_bdf, $mode) = @_;
    $mode //= 'deep-idle';
    return "VM $vmid cannot start because Intel B50 $pf_bdf is in PGM " .
        "$mode power-saving state. Exit Power Saving under Node > GPU and retry.\n";
}

sub _mapping_bdfs {
    my ($mapping_id) = @_;
    die "Invalid PCI mapping identifier while GPU power saving is active\n"
        if !defined($mapping_id) || $mapping_id !~ /^[A-Za-z0-9_.:+-]+$/;

    my $loaded = eval {
        require PVE::INotify;
        require PVE::Mapping::PCI;
        1;
    };
    die "Cannot validate PCI mapping '$mapping_id' while GPU power saving is active: $@"
        if !$loaded;

    my ($mapping, $node, $entries);
    my $ok = eval {
        $mapping = PVE::Mapping::PCI::config();
        $node = PVE::INotify::nodename();
        $entries = PVE::Mapping::PCI::get_node_mapping($mapping, $mapping_id, $node);
        1;
    };
    die "Cannot resolve PCI mapping '$mapping_id' while GPU power saving is active: $@"
        if !$ok;
    die "PCI mapping '$mapping_id' has no entry for this node while GPU power saving is active\n"
        if ref($entries) ne 'ARRAY' || !@$entries;

    my @bdfs;
    for my $entry (@$entries) {
        die "PCI mapping '$mapping_id' contains an invalid node entry\n"
            if ref($entry) ne 'HASH';
        for my $raw (split(/;/, $entry->{path} // '')) {
            my $bdf = _normalise_bdf($raw);
            die "PCI mapping '$mapping_id' contains invalid BDF '$raw'\n"
                if !defined($bdf);
            push @bdfs, $bdf;
        }
    }
    my %seen;
    return grep { !$seen{$_}++ } @bdfs;
}

sub assert_vm_start_allowed {
    my ($conf, $vmid) = @_;
    $vmid = defined($vmid) ? $vmid : 'unknown';
    my $state = read_power_state();
    return 1 if !%$state;

    my %configured_bdfs;
    if (ref($conf) eq 'HASH') {
        my @configs = ($conf);
        push @configs, $conf->{pending} if ref($conf->{pending}) eq 'HASH';
        for my $candidate (@configs) {
            for my $key (grep { /^hostpci\d+$/ } keys %$candidate) {
                my $value = $candidate->{$key};
                next if !defined($value) || ref($value);
                my ($mapping_id) = $value =~ /(?:^|,)mapping=([^,\s]+)/;
                if (defined($mapping_id)) {
                    $configured_bdfs{$_} = 1 for _mapping_bdfs($mapping_id);
                    next;
                }
                while ($value =~ /($BDF_SCAN_RE)/g) {
                    my $bdf = _normalise_bdf($1);
                    $configured_bdfs{$bdf} = 1 if defined($bdf);
                }
            }
        }
    }

    for my $pf_bdf (sort keys %$state) {
        my $record = $state->{$pf_bdf};
        die "Invalid GPU power state record for $pf_bdf\n"
            if ref($record) ne 'HASH';
        my $mode = $record->{mode} // '';
        die _blocked_start_error($vmid, $pf_bdf, $mode || 'unknown')
            if ($record->{api_version} // '') ne '1' ||
               $mode !~ /^(?:entering|deep-idle|exiting|restored)$/ ||
               ($record->{restore_count} // '') !~ /^\d+$/;

        my %blocked_bdfs = ($pf_bdf => 1);
        my @saved_vfs;
        for my $raw (_split_list($record->{vf_bdfs})) {
            my $bdf = _normalise_bdf($raw);
            die _blocked_start_error($vmid, $pf_bdf, $mode)
                if !defined($bdf) || $blocked_bdfs{$bdf};
            $blocked_bdfs{$bdf} = 1;
            push @saved_vfs, $bdf;
        }
        die _blocked_start_error($vmid, $pf_bdf, $mode)
            if @saved_vfs != int($record->{restore_count});

        my %consumer_vmids;
        for my $consumer (_split_list($record->{consumer_vmids})) {
            die _blocked_start_error($vmid, $pf_bdf, $mode)
                if $consumer !~ /^\d+$/ || $consumer_vmids{$consumer}++;
        }
        die _blocked_start_error($vmid, $pf_bdf, $mode)
            if $consumer_vmids{"$vmid"};

        for my $bdf (keys %configured_bdfs) {
            die _blocked_start_error($vmid, $pf_bdf, $mode)
                if $blocked_bdfs{$bdf};
        }
    }

    return 1;
}

1;
