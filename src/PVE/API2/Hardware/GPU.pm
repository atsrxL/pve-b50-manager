package PVE::API2::Hardware::GPU;

use strict;
use warnings;
use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::RESTHandler);
use Fcntl qw(O_WRONLY O_RDONLY O_TRUNC :flock);
use File::Basename;
use File::Glob ':bsd_glob';
use Storable qw(dclone);
use Time::HiRes qw(usleep);
use PVE::Tools qw(run_command file_get_contents file_set_contents);
use PVE::QemuConfig;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Machine;
use PVE::QemuServer::PCI;
use PVE::INotify;
use PVE::Mapping::PCI;
use PVE::RPCEnvironment;
use PVE::GPU::SRIOV qw(
    active_sched_priority
    decode_vf_profiles
    effective_max_vfs
    normalise_resource_profile
    untaint_sysfs_write_path
    validate_vf_profiles
);
use PVE::GPU::Power qw(
    clear_power_state_for_bdf
    is_deep_idle
    power_state_for_bdf
    read_power_state
    set_power_state_for_bdf
    write_power_state
);

# ---------------------------------------------------------------------------
# Vendor plugin registry
# ---------------------------------------------------------------------------
my %VENDOR_PLUGINS;

sub register_vendor {
    my ($vendor_id, $plugin) = @_;
    $VENDOR_PLUGINS{lc($vendor_id)} = $plugin;
}

sub get_vendor_plugin {
    my ($vendor_id) = @_;
    $vendor_id =~ s/^0x//;
    return $VENDOR_PLUGINS{lc($vendor_id)};
}

# Load vendor plugins (they register themselves on use)
use PVE::API2::Hardware::GPU::Intel;

# BDF format regex
my $BDF_RE = '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]';

# Config paths
my $GPU_SRIOV_CONF      = $ENV{PVE_GPU_SRIOV_CONF}
    // '/etc/pve/local/gpu-sriov.conf';
my $QEMU_CONF_DIR       = $ENV{PVE_GPU_QEMU_CONF_DIR}
    // '/etc/pve/qemu-server';
my $PCI_RESERVATION_LOCK = $ENV{PVE_GPU_PCI_RESERVATION_LOCK}
    // '/run/qemu-server/pci-id-reservations.lock';
my $B50_DEEP_IDLE_DELAY_MS = 10;

sub _bool_value {
    my ($value) = @_;
    return 0 if !defined($value);
    return $$value ? 1 : 0 if ref($value) eq 'SCALAR';
    return $value ? 1 : 0;
}

sub _assert_power_mode_normal {
    my ($bdf, $operation) = @_;
    $operation //= 'access this GPU';
    return 1 if !is_deep_idle($bdf);

    my $mode = 'unknown';
    my $record = eval { power_state_for_bdf($bdf) };
    $mode = $record->{mode}
        if ref($record) eq 'HASH' && defined($record->{mode}) && $record->{mode} ne '';
    die "Cannot $operation while $bdf is in PGM '$mode' power-saving state. " .
        "Exit Power Saving under Node > GPU and retry.\n";
}

# ---------------------------------------------------------------------------
# Fake sysfs helper
# ---------------------------------------------------------------------------
my $_sysfs_root_cache;
my $_sysfs_root_conf = '/etc/pve-gpu-sysfs-root';

sub _get_sysfs_root {
    return $_sysfs_root_cache if defined $_sysfs_root_cache;

    # Check env var first (works for CLI tools, tests)
    if (my $root = $ENV{PVE_GPU_SYSFS_ROOT}) {
        $root =~ s{/$}{};
        $_sysfs_root_cache = $root;
        return $root;
    }

    # Fallback: read from config file (works inside pvedaemon which clears env)
    if (-f $_sysfs_root_conf) {
        if (open(my $fh, '<', $_sysfs_root_conf)) {
            my $root = <$fh>;
            close($fh);
            if (defined $root) {
                chomp $root;
                $root =~ s{/$}{};
                if ($root ne '' && -d $root) {
                    $_sysfs_root_cache = $root;
                    return $root;
                }
            }
        }
    }

    $_sysfs_root_cache = '';
    return '';
}

sub sysfs_path {
    my ($path) = @_;
    my $root = _get_sysfs_root();
    return "$root$path" if $root;
    return $path;
}

# ---------------------------------------------------------------------------
# Sysfs I/O helpers
# ---------------------------------------------------------------------------
sub read_sysfs {
    my ($path) = @_;
    my $full = sysfs_path($path);
    return undef unless -e $full;
    open(my $fh, '<', $full) or return undef;
    my $val = <$fh>;
    close($fh);
    return undef unless defined $val;
    chomp $val;
    return $val;
}

sub _read_uint_sysfs {
    my ($path, $label) = @_;
    my $value = read_sysfs($path);
    $label //= $path;
    die "Cannot read a valid non-negative integer for $label from '$path'\n"
        if !defined($value) || $value !~ /^\d+$/;
    return int($value);
}

sub _read_sriov_numvfs {
    my ($bdf, $label) = @_;
    $label //= "VF count for $bdf";
    return _read_uint_sysfs(
        "/sys/bus/pci/devices/$bdf/sriov_numvfs",
        $label,
    );
}

sub write_sysfs {
    my ($path, $value) = @_;
    my $root = _get_sysfs_root();
    my $full = sysfs_path($path);
    $full = untaint_sysfs_write_path($full, $root);
    my $flags = O_WRONLY;
    # Real sysfs/debugfs attributes must not be truncated.  The fake root is
    # backed by ordinary files, where truncation is required for faithful
    # read-after-write tests.
    $flags |= O_TRUNC if $root ne '';
    sysopen(my $fh, $full, $flags)
        or die "Cannot open sysfs '$full' for writing: $!\n";
    my $payload = defined($value) ? "$value" : '';
    # A zero-byte write does not clear driver_override; the kernel expects an
    # empty line for that operation.
    $payload = "\n" if $payload eq '';
    print $fh $payload
        or die "Cannot write to sysfs '$full': $!\n";
    close($fh)
        or die "Cannot close sysfs '$full': $!\n";
    return 1;
}

# ---------------------------------------------------------------------------
# Resolve DRM card name from BDF
# ---------------------------------------------------------------------------
sub resolve_drm_card {
    my ($bdf) = @_;
    # BDF comes in domain:bus:dev.fn form, e.g. 0000:03:00.0
    # The symlink in /sys/class/drm/card*/device resolves to a PCI path
    # whose last component is the BDF (without domain in some kernels).
    my $base = sysfs_path('/sys/class/drm');
    my @cards = bsd_glob("$base/card*/device");
    for my $link (@cards) {
        my $target = readlink($link);
        next unless defined $target;
        # Normalise: strip leading path components
        my $dev_bdf = basename($target);
        if ($dev_bdf eq $bdf) {
            # Return just "cardN"
            my $card_path = dirname($link);
            return basename($card_path);
        }
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Run pre-flight checks
# ---------------------------------------------------------------------------
sub run_prechecks {
    my ($bdf, $card, $vendor_id) = @_;

    my %checks;
    my $all_pass = 1;

    # 1. CPU virtualisation (vmx = Intel VT-x, svm = AMD-V)
    {
        my $cpuinfo = '';
        eval { $cpuinfo = file_get_contents(sysfs_path('/proc/cpuinfo')) // '' };
        my $pass = ($cpuinfo =~ /\b(vmx|svm)\b/) ? 1 : 0;
        $all_pass = 0 unless $pass;
        $checks{cpu_virtualization} = {
            pass   => $pass ? \1 : \0,
            detail => $pass
                ? 'CPU virtualization extensions present'
                : 'No vmx/svm flag found in /proc/cpuinfo',
        };
    }

    # 2. IOMMU: at least one entry under /sys/class/iommu/
    {
        my @iommu = bsd_glob(sysfs_path('/sys/class/iommu') . '/*');
        my $pass = (@iommu > 0) ? 1 : 0;
        $all_pass = 0 unless $pass;
        $checks{iommu} = {
            pass   => $pass ? \1 : \0,
            detail => $pass
                ? sprintf('%d IOMMU group(s) found', scalar @iommu)
                : 'No IOMMU groups found — enable IOMMU in BIOS/kernel',
        };
    }

    # 3. SR-IOV BIOS support: sriov_maxvfs > 0
    {
        my $totalvfs_path = "/sys/bus/pci/devices/$bdf/sriov_totalvfs";
        my $totalvfs = read_sysfs($totalvfs_path) // 0;
        my $pass = ($totalvfs > 0) ? 1 : 0;
        $all_pass = 0 unless $pass;
        $checks{sriov_bios} = {
            pass   => $pass ? \1 : \0,
            detail => $pass
                ? "sriov_maxvfs=$totalvfs"
                : 'sriov_maxvfs is 0 — SR-IOV not supported by firmware',
        };
    }

    # 4. GPU kernel driver bound — delegate to vendor plugin
    {
        my $driver_link = sysfs_path("/sys/bus/pci/devices/$bdf/driver");
        my $driver = '';
        if (-l $driver_link) {
            $driver = basename(readlink($driver_link) // '');
        }

        my $plugin = get_vendor_plugin($vendor_id);
        if ($plugin) {
            my $driver_check = $plugin->run_prechecks($bdf, $card, $driver);
            $all_pass = 0 unless _bool_value($driver_check->{pass});
            $checks{gpu_driver} = $driver_check;
        } else {
            # Fallback: just report the driver
            $checks{gpu_driver} = {
                pass   => $driver ne '' ? \1 : \0,
                detail => $driver ne '' ? "$driver driver bound" : 'No driver bound',
            };
            $all_pass = 0 unless $driver ne '';
        }
    }

    return {
        checks   => \%checks,
        all_pass => $all_pass ? \1 : \0,
    };
}

# ---------------------------------------------------------------------------
# INI config helpers
# ---------------------------------------------------------------------------
sub parse_ini_config {
    my ($path, $strict) = @_;
    my %data;
    return \%data unless -f $path;

    my $fh;
    if (!open($fh, '<', $path)) {
        die "Cannot read configuration '$path': $!\n" if $strict;
        return \%data;
    }
    my $section = '__global__';
    my $line_number = 0;
    while (my $line = <$fh>) {
        $line_number++;
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        next if $line =~ /^#/;
        if ($line =~ /^\[(.+)\]$/) {
            $section = $1;
            die "Duplicate section '$section' in '$path' at line $line_number\n"
                if $strict && exists($data{$section});
            $data{$section} //= {};
        } elsif ($line =~ /^([^=]+?)\s*=\s*(.*)$/) {
            die "Duplicate key '$1' in section '$section' of '$path' at line $line_number\n"
                if $strict && exists($data{$section}{$1});
            $data{$section}{$1} = $2;
        } elsif ($strict) {
            close($fh);
            die "Malformed configuration '$path' at line $line_number\n";
        }
    }
    my $closed = close($fh);
    die "Cannot close configuration '$path': $!\n" if !$closed && $strict;
    return \%data;
}

sub write_ini_config {
    my ($path, $data) = @_;
    my $tmp = "$path.tmp.$$";
    open(my $fh, '>', $tmp)
        or die "Cannot write config to '$tmp': $!\n";

    my $ok = eval {
        for my $section (sort keys %$data) {
            next if $section eq '__global__';
            print {$fh} "[$section]\n"
                or die "Cannot write section '$section' to '$tmp': $!\n";
            for my $key (sort keys %{$data->{$section}}) {
                print {$fh} "$key = $data->{$section}{$key}\n"
                    or die "Cannot write key '$key' to '$tmp': $!\n";
            }
            print {$fh} "\n"
                or die "Cannot finish section '$section' in '$tmp': $!\n";
        }
        close($fh)
            or die "Cannot close config '$tmp': $!\n";
        rename($tmp, $path)
            or die "Cannot rename '$tmp' to '$path': $!\n";
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

sub _persistent_device_enabled {
    my ($config, $bdf) = @_;
    return ref($config->{$bdf}) eq 'HASH' &&
        ($config->{$bdf}{persist} // '') eq '1';
}

# ---------------------------------------------------------------------------
# Get VF quota file paths — delegated to vendor plugin
# ---------------------------------------------------------------------------
sub get_vf_paths {
    my ($family, $card, $bdf, $vf_index, $tile, $vendor_id) = @_;

    my $plugin = get_vendor_plugin($vendor_id);
    return $plugin->get_vf_paths($family, $card, $bdf, $vf_index, $tile) if $plugin;
    return undef;
}

sub get_vf_resource_paths {
    my ($family, $card, $bdf, $vf_index, $tile, $vendor_id) = @_;

    my $plugin = get_vendor_plugin($vendor_id);
    return undef if !$plugin;
    return $plugin->get_vf_resource_paths($family, $card, $bdf, $vf_index, $tile)
        if $plugin->can('get_vf_resource_paths');

    my $legacy = $plugin->get_vf_paths($family, $card, $bdf, $vf_index, $tile);
    return {
        vram               => [$legacy->{lmem_quota}],
        ggtt               => [$legacy->{ggtt_quota}],
        contexts           => [],
        doorbells          => [],
        exec_quantum_ms    => [$legacy->{exec_quantum_ms}],
        preempt_timeout_us => [$legacy->{preempt_timeout_us}],
    };
}

# ---------------------------------------------------------------------------
# Resolve PCI references with Proxmox's mapping parser.  Every value returned
# here is a canonical, lower-case, domain-qualified BDF.
# ---------------------------------------------------------------------------
sub _normalise_bdf {
    my ($bdf) = @_;
    return undef if !defined($bdf);
    $bdf = lc($bdf);
    $bdf = "0000:$bdf" if $bdf =~ /^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/;
    $bdf .= '.0' if $bdf =~ /^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}$/;
    return $bdf =~ /^$BDF_RE$/o ? $bdf : undef;
}

sub _resolve_hostpci_bdfs {
    my ($value, $strict) = @_;
    my @bdfs;

    my ($mapping_id) = $value =~ /(?:^|,)mapping=([^,\s]+)/;
    my ($explicit_host) = $value =~ /(?:^|,)host=([^,\s]+)/;
    die "Cannot set both 'host' and 'mapping' in hostpci value '$value'\n"
        if $strict && defined($mapping_id) && defined($explicit_host);

    if (defined($mapping_id)) {
        my $mapping_cfg = eval { PVE::Mapping::PCI::config() };
        my $mapping_error = $@;
        die "Cannot load PCI mapping configuration for '$mapping_id': $mapping_error"
            if $strict && $mapping_error;
        my $node = eval { PVE::INotify::nodename() };
        my $node_error = $@;
        die "Cannot determine the local node for PCI mapping '$mapping_id': $node_error"
            if $strict && $node_error;
        if ($mapping_cfg && $node) {
            my $entries = eval {
                PVE::Mapping::PCI::get_node_mapping($mapping_cfg, $mapping_id, $node)
            };
            my $mapping_error = $@;
            die "Cannot resolve PCI mapping '$mapping_id' on node '$node': $mapping_error"
                if $strict && $mapping_error;
            $entries //= [];
            for my $entry (@$entries) {
                for my $path (split(';', $entry->{path} // '')) {
                    my $normalised = _normalise_bdf($path);
                    die "PCI mapping '$mapping_id' contains invalid BDF '$path'\n"
                        if $strict && !defined($normalised);
                    push @bdfs, $normalised if defined $normalised;
                }
            }
        } elsif ($strict) {
            die "Cannot resolve PCI mapping '$mapping_id' on this node\n";
        }
    } else {
        my ($raw) = $value =~ /(?:^|,)host=([^,\s]+)/;
        ($raw) = $value =~ /^([^,\s]+)/ if !defined($raw);
        for my $path (split(';', $raw // '')) {
            my $normalised = _normalise_bdf($path);
            die "Invalid hostpci BDF '$path' in '$value'\n"
                if $strict && !defined($normalised);
            push @bdfs, $normalised if defined $normalised;
        }
    }

    my %seen;
    return grep { !$seen{$_}++ } @bdfs;
}

sub _vm_is_running {
    my ($vmid) = @_;
    return PVE::QemuServer::Helpers::vm_running_locally($vmid) ? 1 : 0;
}

sub _scan_qemu_pci_consumers {
    my ($targets, $strict) = @_;
    my @consumers;
    my @conf_files = bsd_glob("$QEMU_CONF_DIR/*.conf");

    for my $conf (@conf_files) {
        my ($vmid) = basename($conf) =~ /^(\d+)\.conf$/;
        next if !defined($vmid);
        my @hostpci;

        if ($QEMU_CONF_DIR eq '/etc/pve/qemu-server') {
            my $vm_config = eval { PVE::QemuConfig->load_config($vmid) };
            my $load_error = $@;
            die "Cannot safely inspect VM $vmid PCI configuration: $load_error"
                if $strict && $load_error;
            die "Cannot safely inspect VM $vmid PCI configuration: invalid parsed result\n"
                if $strict && ref($vm_config) ne 'HASH';
            if ($vm_config) {
                for my $key (sort grep { /^hostpci\d+$/ } keys %$vm_config) {
                    push @hostpci, [$key, $vm_config->{$key}];
                }
                my $pending = $vm_config->{pending};
                if (ref($pending) eq 'HASH') {
                    for my $key (sort grep { /^hostpci\d+$/ } keys %$pending) {
                        push @hostpci, [$key, $pending->{$key}];
                    }
                }
            }
        }

        # Test fixtures and a parse-failure fallback use only top-level lines.
        # Ignore snapshot/pending sections rather than treating historical
        # snapshot hostpci entries as live consumers.
        if (!@hostpci) {
            my $fh;
            if (!open($fh, '<', $conf)) {
                die "Cannot safely inspect VM $vmid PCI configuration '$conf': $!\n"
                    if $strict;
                next;
            }
            while (my $line = <$fh>) {
                last if $line =~ /^\s*\[/;
                next if $line !~ /^(hostpci\d+):\s*(.+)/;
                my ($key, $value) = ($1, $2);
                chomp($value);
                push @hostpci, [$key, $value];
            }
            close($fh);
        }

        for my $entry (@hostpci) {
            my ($key, $value) = @$entry;
            if (!defined($value) || ref($value)) {
                die "Cannot safely parse VM $vmid $key PCI configuration\n" if $strict;
                next;
            }
            for my $resolved_bdf (_resolve_hostpci_bdfs($value, $strict)) {
                next if !$targets->{$resolved_bdf};
                push @consumers, {
                    bdf     => $resolved_bdf,
                    vmid    => int($vmid),
                    key     => $key,
                    running => _vm_is_running($vmid) ? 1 : 0,
                };
            }
        }
    }

    my %seen;
    @consumers = grep {
        my $identity = join('|', $_->{vmid}, $_->{key}, $_->{bdf});
        !$seen{$identity}++;
    } @consumers;
    return \@consumers;
}

# Returns the first VM using a PF, for the device grid compatibility fields.
sub _find_bdf_vm_assignment {
    my ($target_bdf) = @_;
    $target_bdf = _normalise_bdf($target_bdf);
    return undef if !defined($target_bdf);
    my $consumers = _scan_qemu_pci_consumers({ $target_bdf => 1 });
    return @$consumers ? $consumers->[0]{vmid} : undef;
}

# ---------------------------------------------------------------------------
# Check VF→VM assignments
# Returns arrayref of { vf_index, bdf, vmid } for assigned VFs
# ---------------------------------------------------------------------------
sub check_vf_vm_assignments {
    my ($bdf, $card, $num_vfs, $strict) = @_;

    # Collect all VF BDFs
    my %vf_bdf_to_index;
    for my $vf_index (1 .. $num_vfs) {
        my $virtfn_link = sysfs_path(
            "/sys/bus/pci/devices/$bdf/virtfn" . ($vf_index - 1)
        );
        my $vf_target = readlink($virtfn_link);
        next unless defined $vf_target;
        my $vf_bdf = _normalise_bdf(basename($vf_target));
        next if !defined($vf_bdf);
        $vf_bdf_to_index{$vf_bdf} = $vf_index;
    }
    my $normalised_pf = _normalise_bdf($bdf);
    my %targets = (%vf_bdf_to_index, $normalised_pf => 1);
    my $consumers = _scan_qemu_pci_consumers(\%targets, $strict);
    for my $consumer (@$consumers) {
        $consumer->{vf_index} = $consumer->{bdf} eq $normalised_pf
            ? 0
            : $vf_bdf_to_index{$consumer->{bdf}};
    }
    return $consumers;
}

# ---------------------------------------------------------------------------
# Internal helper: get device name via lspci, fallback to static map
# ---------------------------------------------------------------------------
sub _get_device_name {
    my ($bdf, $device_id, $vendor_id) = @_;
    my $name;
    eval {
        my $output = '';
        run_command(['lspci', '-s', $bdf, '-mm'],
            outfunc => sub { $output .= $_[0] . "\n" },
            errfunc => sub { },
        );
        # lspci -mm output: "Slot" "Class" "Vendor" "Device" ...
        # Fields are double-quoted and tab/newline separated
        if ($output =~ /"Device"\s+"([^"]+)"/ ||
            $output =~ /^[^\n]*\t[^\n]*\t[^\n]*\t"?([^"\n]+)"?/m) {
            $name = $1;
        }
    };
    return $name if defined $name && $name ne '';

    my $plugin = get_vendor_plugin($vendor_id);
    if ($plugin && $plugin->can('device_name_fallback')) {
        return $plugin->device_name_fallback($device_id);
    }
    return "GPU ($device_id)";
}

# ---------------------------------------------------------------------------
# Internal helper: check if device has SR-IOV capability via lspci
# ---------------------------------------------------------------------------
sub _has_sriov_cap {
    my ($bdf) = @_;

    # First check sriov_maxvfs in sysfs — works for both i915 and xe drivers
    my $totalvfs = read_sysfs("/sys/bus/pci/devices/$bdf/sriov_totalvfs");
    return 1 if defined $totalvfs && $totalvfs =~ /^\d+$/ && $totalvfs > 0;

    # Fallback: check lspci for SR-IOV capability
    my $found = 0;
    eval {
        run_command(['lspci', '-vs', $bdf],
            outfunc => sub {
                $found = 1 if $_[0] =~ /Single Root I\/O Virtualization/i;
            },
            errfunc => sub { },
        );
    };
    return $found;
}

# ---------------------------------------------------------------------------
# Internal: collect full device record from sysfs for a given BDF
# Returns undef if device is not found or not an Intel GPU
# ---------------------------------------------------------------------------
sub _collect_device {
    my ($bdf, $with_telemetry) = @_;

    my $base = "/sys/bus/pci/devices/$bdf";

    # Skip SR-IOV Virtual Functions — they share the PF's device ID
    # but must not appear as standalone GPU devices.
    return undef if -l sysfs_path("$base/physfn");

    my $vendor_id  = read_sysfs("$base/vendor")    // '';
    my $plugin = get_vendor_plugin($vendor_id);
    return undef unless defined $plugin;

    my $device_id  = read_sysfs("$base/device")    // '';
    my $info = $plugin->identify_device($device_id);
    return undef unless defined $info;
    my $deep_idle = is_deep_idle($bdf);
    my $power_state = $deep_idle ? eval { power_state_for_bdf($bdf) } : undef;

    my $card = resolve_drm_card($bdf);

    my $subsystem_vendor = read_sysfs("$base/subsystem_vendor") // '';
    my $subsystem_device = read_sysfs("$base/subsystem_device") // '';
    my $numa_node        = read_sysfs("$base/numa_node")        // -1;
    my $sriov_maxvfs   = read_sysfs("$base/sriov_totalvfs")   // 0;
    my $sriov_numvfs     = _read_sriov_numvfs($bdf);

    my $driver = '';
    my $driver_link = sysfs_path("$base/driver");
    if (-l $driver_link) {
        $driver = basename(readlink($driver_link) // '');
    }

    my $render_node = undef;
    if (defined $card) {
        # renderD* usually sits alongside card* in /sys/class/drm
        my $render_base = sysfs_path('/sys/class/drm');
        my @renders = bsd_glob("$render_base/renderD*");
        for my $rlink (@renders) {
            my $rtarget = readlink("$rlink/device");
            if (defined $rtarget && basename($rtarget) eq $bdf) {
                $render_node = basename($rlink);
                last;
            }
        }
    }

    my $norm_device_id = lc($device_id);
    $norm_device_id = "0x$norm_device_id" unless $norm_device_id =~ /^0x/;
    # lspci and debugfs reads can runtime-resume a sleeping B50.  Once PGM has
    # placed a PF in deep idle, use the static identity already available from
    # sysfs and leave all wake-up telemetry to an explicit mode exit.
    my $device_name = $deep_idle && $plugin->can('device_name_fallback')
        ? $plugin->device_name_fallback($norm_device_id)
        : _get_device_name($bdf, $norm_device_id, $vendor_id);

    # Check persistence
    my $persist_config = parse_ini_config($GPU_SRIOV_CONF);
    my $persisted = _persistent_device_enabled($persist_config, $bdf) ? \1 : \0;

    my $sriov_capable = _has_sriov_cap($bdf) ? \1 : \0;

    my $effective_max_vfs = effective_max_vfs($info->{max_vfs}, $sriov_maxvfs);

    my $record = {
        bdf              => $bdf,
        vendor_id        => $vendor_id,
        device_id        => $norm_device_id,
        subsystem_vendor => $subsystem_vendor,
        subsystem_device => $subsystem_device,
        device_name      => $device_name,
        family           => $info->{family},
        max_vfs          => $effective_max_vfs,
        tiles            => $info->{tiles},
        driver           => $driver,
        numa_node        => int($numa_node),
        sriov_capable    => $sriov_capable,
        sriov_maxvfs     => int($sriov_maxvfs),
        sriov_numvfs     => int($sriov_numvfs),
        drm_card         => $card // '',
        render_node      => $render_node // '',
        persisted        => $persisted,
        power_mode       => $deep_idle && ref($power_state) eq 'HASH'
            ? ($power_state->{mode} // 'deep-idle')
            : ($deep_idle ? 'deep-idle' : 'normal'),
    };

    # Check VFIO persistence file for this device's BDF
    my $vfio_bdfs = _read_vfio_bdfs();
    $record->{vfio_configured} = (grep { $_ eq $bdf } @$vfio_bdfs) ? \1 : \0;

    # Check if PF itself is assigned to a VM (whole-GPU passthrough)
    my $pf_vm = _find_bdf_vm_assignment($bdf);
    $record->{pf_assigned} = defined $pf_vm ? \1 : \0;
    $record->{pf_vmid} = $pf_vm;

    # Get VMs assigned to this GPU's VFs
    if (int($sriov_numvfs) > 0 && defined $card) {
        my $assigned = check_vf_vm_assignments($bdf, $card, int($sriov_numvfs));
        my %seen;
        # Include PF VM if assigned
        $seen{$pf_vm} = 1 if defined $pf_vm;
        my @vm_ids = defined $pf_vm ? ($pf_vm) : ();
        push @vm_ids, grep { !$seen{$_}++ } map { $_->{vmid} } @$assigned;
        $record->{assigned_vms} = \@vm_ids;
    } else {
        my %seen;
        my @vm_ids = defined($pf_vm) ? ($pf_vm) : ();
        $seen{$pf_vm} = 1 if defined($pf_vm);
        if ($deep_idle && ref($power_state) eq 'HASH') {
            for my $vmid (_power_state_list($power_state->{consumer_vmids})) {
                push @vm_ids, int($vmid) if $vmid =~ /^\d+$/ && !$seen{$vmid}++;
            }
        }
        $record->{assigned_vms} = \@vm_ids;
    }

    # Read firmware version from vendor plugin
    if (defined($bdf) && !$deep_idle) {
        $record->{firmware_version} = $plugin->read_firmware_version($bdf) // '';
    } else {
        $record->{firmware_version} = '';
    }

    if ($with_telemetry && defined $card) {
        $record->{telemetry} = $plugin->read_telemetry($card, $bdf, $driver);
    }

    return $record;
}

# ---------------------------------------------------------------------------
# Internal: enumerate all supported GPU devices on the system
# ---------------------------------------------------------------------------
sub _enumerate_devices {
    my @devices;
    my @pci_devs = bsd_glob(sysfs_path('/sys/bus/pci/devices') . '/*');
    for my $dev_path (@pci_devs) {
        my $bdf = basename($dev_path);
        next unless $bdf =~ /^$BDF_RE$/o;
        my $rec = _collect_device($bdf, 1);
        push @devices, $rec if defined $rec;
    }
    return sort { $a->{bdf} cmp $b->{bdf} } @devices;
}

# ---------------------------------------------------------------------------
# Internal: read available resources for a PF tile
# ---------------------------------------------------------------------------
sub _read_pf_available {
    my ($rec, $tile) = @_;
    my $plugin = get_vendor_plugin($rec->{vendor_id});
    return {
        vram_spare => 0,
        ggtt_spare => 0,
        contexts_spare => [],
        doorbells_spare => [],
        gt_count => 0,
    } if !$plugin || !$plugin->can('read_pf_available');

    return $plugin->read_pf_available(
        $rec->{family},
        $rec->{drm_card},
        $rec->{bdf},
        $tile,
    );
}

# ---------------------------------------------------------------------------
# SR-IOV v2 helpers
# ---------------------------------------------------------------------------
my @VF_RESOURCE_NAMES = qw(
    vram
    ggtt
    contexts
    doorbells
    exec_quantum_ms
    preempt_timeout_us
);

sub _vf_bdf {
    my ($pf_bdf, $vf_index) = @_;
    my $link = sysfs_path(
        "/sys/bus/pci/devices/$pf_bdf/virtfn" . ($vf_index - 1)
    );
    my $target = readlink($link);
    return undef if !defined($target);
    return _normalise_bdf(basename($target));
}

sub _pci_driver {
    my ($bdf) = @_;
    my $link = sysfs_path("/sys/bus/pci/devices/$bdf/driver");
    return '' if !-l $link;
    return basename(readlink($link) // '');
}

sub _read_scheduler_priority {
    my ($rec) = @_;
    my $plugin = get_vendor_plugin($rec->{vendor_id});
    return undef if !$plugin || !$plugin->can('read_scheduler_priority');
    my $count = _read_sriov_numvfs(
        $rec->{bdf},
        "scheduler VF count for $rec->{bdf}",
    );
    my %priorities;
    for my $function (0 .. $count) {
        my $priority = $plugin->read_scheduler_priority($rec->{bdf}, $function);
        return undef if !defined($priority);
        $priorities{$priority} = 1;
    }
    return 'mixed' if scalar(keys %priorities) != 1;
    return (keys %priorities)[0];
}

sub _device_capabilities {
    my ($rec) = @_;
    my $plugin = get_vendor_plugin($rec->{vendor_id});
    my $caps = {};
    if ($plugin && $plugin->can('get_sriov_capabilities')) {
        $caps = $plugin->get_sriov_capabilities(
            $rec->{family},
            $rec->{drm_card},
            $rec->{bdf},
            int($rec->{sriov_numvfs}),
        );
    }
    $caps->{effective_max_vfs} = int($rec->{max_vfs});
    $caps->{vf_vm_assignment} = \1;
    return $caps;
}

sub _resource_paths_for_vf {
    my ($rec, $vf_index) = @_;
    my %result = map { $_ => [] } @VF_RESOURCE_NAMES;
    for my $tile (0 .. (int($rec->{tiles}) - 1)) {
        my $paths = get_vf_resource_paths(
            $rec->{family},
            $rec->{drm_card},
            $rec->{bdf},
            $vf_index,
            $tile,
            $rec->{vendor_id},
        );
        next if !$paths;
        for my $name (@VF_RESOURCE_NAMES) {
            push @{$result{$name}}, @{$paths->{$name} // []};
        }
    }
    return \%result;
}

sub _read_vf_resources {
    my ($rec, $vf_index, $persist_config) = @_;
    my $paths = _resource_paths_for_vf($rec, $vf_index);
    my $section = "$rec->{bdf}/vf$vf_index";
    my $persisted = _persistent_device_enabled($persist_config, $rec->{bdf})
        ? ($persist_config->{$section} // {})
        : {};
    my %resources;

    for my $name (@VF_RESOURCE_NAMES) {
        my @values;
        my $all_writable = @{$paths->{$name}} ? 1 : 0;
        for my $path (@{$paths->{$name}}) {
            my $value = read_sysfs($path);
            push @values, int($value) if defined($value) && $value =~ /^\d+$/;
            $all_writable = 0 if !-w sysfs_path($path);
        }
        my %unique = map { $_ => 1 } @values;
        my $effective = @values && scalar(keys %unique) == 1 ? $values[0] : undef;
        my $mode = $persisted->{"${name}_mode"} // 'unknown';
        $mode = 'unknown' if $mode !~ /^(?:auto|custom|unchanged)$/;
        $resources{$name} = {
            mode      => $mode,
            configured => $mode eq 'custom'
                ? int($persisted->{"${name}_quota"} // 0)
                : undef,
            effective => $effective,
            values    => \@values,
            mixed     => scalar(keys %unique) > 1 ? \1 : \0,
            writable  => $all_writable ? \1 : \0,
        };
    }

    return \%resources;
}

sub _snapshot_state {
    my ($rec) = @_;
    my $count = _read_sriov_numvfs($rec->{bdf});
    my %path_values;
    my @drivers;

    my $autoprobe = read_sysfs(
        "/sys/bus/pci/devices/$rec->{bdf}/sriov_drivers_autoprobe"
    );
    die "Cannot snapshot sriov_drivers_autoprobe for $rec->{bdf}\n"
        if !defined($autoprobe) || $autoprobe !~ /^[01]$/;

    for my $vf (1 .. $count) {
        my $paths = _resource_paths_for_vf($rec, $vf);
        for my $name (@VF_RESOURCE_NAMES) {
            die "Cannot snapshot VF$vf resource '$name': no control paths were found\n"
                if !@{$paths->{$name}};
            for my $path (@{$paths->{$name}}) {
                my $value = read_sysfs($path);
                die "Cannot snapshot VF$vf resource '$name' at '$path'\n"
                    if !defined($value) || $value !~ /^\d+$/;
                $path_values{$path} = int($value);
            }
        }
        my $vf_bdf = _vf_bdf($rec->{bdf}, $vf);
        push @drivers, {
            vf_index => $vf,
            bdf => $vf_bdf,
            driver => defined($vf_bdf) ? _pci_driver($vf_bdf) : '',
        };
    }

    my $scheduler = _read_scheduler_priority($rec);
    if ($rec->{family} =~ /^bmg(?:_12vf)?$/ &&
        (!defined($scheduler) || $scheduler eq 'mixed')) {
        die "Cannot snapshot a consistent BMG scheduler profile for $rec->{bdf}\n";
    }

    my $config_snapshot = { exists => -f $GPU_SRIOV_CONF ? 1 : 0, contents => '' };
    if ($config_snapshot->{exists}) {
        open(my $config_fh, '<', $GPU_SRIOV_CONF)
            or die "Cannot snapshot '$GPU_SRIOV_CONF': $!\n";
        local $/;
        $config_snapshot->{contents} = <$config_fh> // '';
        close($config_fh)
            or die "Cannot close '$GPU_SRIOV_CONF' after snapshot: $!\n";
    }

    return {
        count => $count,
        autoprobe => int($autoprobe),
        scheduler => $scheduler,
        path_values => \%path_values,
        drivers => \@drivers,
        config => $config_snapshot,
    };
}

sub _with_gpu_lock {
    my ($code) = @_;
    my $lock_path = $ENV{PVE_GPU_SRIOV_LOCK} // '/run/lock/pve-gpu-sriov.lock';
    open(my $lock_fh, '>>', $lock_path)
        or die "Cannot open SR-IOV lock '$lock_path': $!\n";
    flock($lock_fh, LOCK_EX)
        or die "Cannot lock SR-IOV lock '$lock_path': $!\n";
    my $wantarray = wantarray;
    my (@result, $result);
    my $ok = eval {
        if ($wantarray) {
            @result = $code->();
        } elsif (defined($wantarray)) {
            $result = $code->();
        } else {
            $code->();
        }
        1;
    };
    my $error = $@;
    close($lock_fh);
    die $error if !$ok;
    return $wantarray ? @result : $result;
}

sub _with_pci_reservation_lock {
    my ($code) = @_;
    my $result = PVE::Tools::lock_file(
        $PCI_RESERVATION_LOCK,
        10,
        sub { return $code->() },
    );
    my $error = $@;
    die $error if $error;
    return $result;
}

sub _with_vm_locks {
    my ($vmids, $code) = @_;
    my %seen;
    my @ordered = sort { $a <=> $b } grep { !$seen{$_}++ } @$vmids;
    my $wrapped = $code;
    for my $vmid (reverse @ordered) {
        my $next = $wrapped;
        $wrapped = sub {
            return PVE::QemuConfig->lock_config_full($vmid, 10, $next);
        };
    }
    return $wrapped->();
}

sub _all_qemu_vmids {
    my @vmids;
    for my $conf (bsd_glob("$QEMU_CONF_DIR/*.conf")) {
        my ($vmid) = basename($conf) =~ /^(\d+)\.conf$/;
        push @vmids, int($vmid) if defined($vmid);
    }
    return @vmids;
}

sub _snapshot_file {
    my ($path) = @_;
    my $snapshot = { exists => -e $path ? 1 : 0, contents => '' };
    return $snapshot if !$snapshot->{exists};

    open(my $fh, '<', $path) or die "Cannot snapshot '$path': $!\n";
    local $/;
    $snapshot->{contents} = <$fh> // '';
    close($fh) or die "Cannot close '$path' after snapshot: $!\n";
    return $snapshot;
}

sub _restore_file_snapshot {
    my ($path, $snapshot) = @_;
    if ($snapshot->{exists}) {
        file_set_contents($path, $snapshot->{contents});
    } elsif (-e $path) {
        unlink($path) or die "Cannot remove newly-created '$path': $!\n";
    }
}

sub _persisted_vf_driver {
    my ($pf_bdf, $vf_index) = @_;
    my $config = parse_ini_config($GPU_SRIOV_CONF, 1);
    my $section = "$pf_bdf/vf$vf_index";
    return undef if !exists($config->{$pf_bdf}) || !exists($config->{$section});
    return $config->{$section}{driver} // '';
}

sub _validated_persisted_vf_driver {
    my ($rec, $vf_index) = @_;
    my $pf_bdf = $rec->{bdf};
    my $config = parse_ini_config($GPU_SRIOV_CONF, 1);
    my $device = $config->{$pf_bdf};

    die "VF assignment requires a persistent SR-IOV profile for $pf_bdf\n"
        if ref($device) ne 'HASH' || ($device->{persist} // '') ne '1';
    die "VF assignment requires an api_version=2 SR-IOV profile for $pf_bdf\n"
        if ($device->{api_version} // '') ne '2';
    my $configured_count = $device->{num_vfs};
    die "Persistent SR-IOV profile for $pf_bdf does not match the live VF topology\n"
        if !defined($configured_count) || $configured_count !~ /^\d+$/ ||
           int($configured_count) != int($rec->{sriov_numvfs});
    die "Persistent SR-IOV profile for $pf_bdf has an invalid drivers_autoprobe value\n"
        if ($device->{drivers_autoprobe} // '') !~ /^(?:0|1)$/;
    my $scheduler = $device->{sched_priority} // 'low';
    my $unsafe_scheduler = $device->{allow_unsafe_scheduler} // '0';
    die "Persistent SR-IOV profile for $pf_bdf has an invalid scheduler policy\n"
        if $scheduler !~ /^(?:low|normal)$/ || $unsafe_scheduler !~ /^(?:0|1)$/ ||
           ($scheduler eq 'normal' && $unsafe_scheduler ne '1');
    die "Persistent SR-IOV profile for $pf_bdf does not match the supported BMG family\n"
        if ($device->{family} // '') ne $rec->{family};
    if (defined($device->{device_id}) && $device->{device_id} ne '') {
        my $configured_device = lc($device->{device_id});
        $configured_device = "0x$configured_device"
            if $configured_device !~ /^0x/;
        die "Persistent SR-IOV profile for $pf_bdf does not match the live PCI device\n"
            if $configured_device ne $rec->{device_id};
    }

    my $target_driver;
    for my $profile_index (1 .. int($configured_count)) {
        my $profile = $config->{"$pf_bdf/vf$profile_index"};
        die "Persistent SR-IOV profile for $pf_bdf is missing VF$profile_index\n"
            if ref($profile) ne 'HASH';
        for my $name (@VF_RESOURCE_NAMES) {
            my $mode = $profile->{"${name}_mode"};
            die "Persistent VF$profile_index resource '$name' mode must be auto or custom\n"
                if !defined($mode) || $mode !~ /^(?:auto|custom)$/;
            my $resource = { mode => $mode };
            $resource->{quota} = $profile->{"${name}_quota"} if $mode eq 'custom';
            normalise_resource_profile($name, $resource);
        }

        my $driver = $profile->{driver} // '';
        die "Persistent VF$profile_index has unsupported driver '$driver'\n"
            if $driver !~ /^(?:|vfio-pci|xe)$/;
        $target_driver = $driver if $profile_index == $vf_index;
    }
    return $target_driver;
}

sub _set_persisted_vf_driver {
    my ($pf_bdf, $vf_index, $driver) = @_;
    my $config = parse_ini_config($GPU_SRIOV_CONF, 1);
    my $section = "$pf_bdf/vf$vf_index";
    return 0 if !exists($config->{$pf_bdf}) || !exists($config->{$section});
    my $current = $config->{$section}{driver} // '';
    return 0 if $current eq $driver;
    $config->{$section}{driver} = $driver;
    write_ini_config($GPU_SRIOV_CONF, $config);
    return 1;
}

sub _validate_vf_bdf {
    my ($rec, $vf_index) = @_;
    die "Refusing to treat a PCI VF as a physical GPU PF\n"
        if -l sysfs_path("/sys/bus/pci/devices/$rec->{bdf}/physfn");

    my $vf_bdf = _vf_bdf($rec->{bdf}, $vf_index);
    die "Cannot resolve VF $vf_index for $rec->{bdf}\n" if !defined($vf_bdf);
    my $vf_path = "/sys/bus/pci/devices/$vf_bdf";
    die "Resolved VF $vf_index ($vf_bdf) does not exist\n"
        if !-d sysfs_path($vf_path);

    my $physfn_target = readlink(sysfs_path("$vf_path/physfn"));
    my $physfn_bdf = defined($physfn_target)
        ? _normalise_bdf(basename($physfn_target))
        : undef;
    die "VF $vf_index ($vf_bdf) does not point back to PF $rec->{bdf}\n"
        if !defined($physfn_bdf) || $physfn_bdf ne $rec->{bdf};

    my $vendor = read_sysfs("$vf_path/vendor");
    my $device = read_sysfs("$vf_path/device");
    die "VF $vf_index ($vf_bdf) has unreadable PCI identity\n"
        if !defined($vendor) || $vendor !~ /^0x[0-9a-fA-F]{4}$/ ||
           !defined($device) || $device !~ /^0x[0-9a-fA-F]{4}$/;
    die "VF $vf_index ($vf_bdf) vendor '$vendor' does not match PF vendor '$rec->{vendor_id}'\n"
        if lc($vendor) ne lc($rec->{vendor_id});
    return $vf_bdf;
}

sub _pending_hostpci_changes {
    my ($conf) = @_;
    my $pending = ref($conf->{pending}) eq 'HASH' ? $conf->{pending} : {};
    my @changes = sort grep { /^hostpci\d+$/ } keys %$pending;

    my $deletions = eval {
        PVE::QemuConfig->parse_pending_delete($pending->{delete});
    };
    my $parse_error = $@;
    die "Cannot safely parse pending VM configuration: $parse_error"
        if $parse_error;
    if (ref($deletions) eq 'HASH') {
        push @changes, sort grep { /^hostpci\d+$/ } keys %$deletions;
    }

    my %seen;
    return grep { !$seen{$_}++ } @changes;
}

sub _assert_vm_can_change_vf {
    my ($vmid, $conf) = @_;
    die "VM $vmid configuration is unavailable\n" if ref($conf) ne 'HASH';
    die "Cannot assign a VF to VM $vmid because it is a template\n"
        if _bool_value($conf->{template});
    die "Cannot change VF assignment while VM $vmid is locked ($conf->{lock})\n"
        if defined($conf->{lock}) && $conf->{lock} ne '';
    die "Stop VM $vmid before changing its VF assignment\n"
        if _vm_is_running($vmid);

    my @pending = _pending_hostpci_changes($conf);
    die "Resolve pending PCI changes for VM $vmid first (" . join(', ', @pending) . ")\n"
        if @pending;
}

sub _assert_exact_vf_hostpci_entry {
    my ($vmid, $key, $value, $vf_bdf) = @_;
    die "Cannot remove VM $vmid $key because it is a PCI mapping; remove the mapping-backed device in the VM Hardware panel\n"
        if defined($value) && $value =~ /(?:^|,)mapping=/;
    my @resolved = _resolve_hostpci_bdfs($value // '', 1);
    die "Cannot safely change VM $vmid $key: it does not resolve to exactly VF $vf_bdf\n"
        if @resolved != 1 || $resolved[0] ne $vf_bdf;
}

sub _assert_exact_gpu_hostpci_entry {
    my ($vmid, $key, $value, $gpu_bdfs) = @_;
    die "Cannot remove VM $vmid $key because it is a PCI mapping; remove the mapping-backed device in the VM Hardware panel\n"
        if defined($value) && $value =~ /(?:^|,)mapping=/;
    my @resolved = _resolve_hostpci_bdfs($value // '', 1);
    die "Cannot safely change VM $vmid $key: the entry contains PCI functions outside this GPU\n"
        if !@resolved || grep { !$gpu_bdfs->{$_} } @resolved;
}

sub _first_free_hostpci_key {
    my ($conf) = @_;
    for my $index (0 .. $PVE::QemuServer::PCI::MAX_HOSTPCI_DEVICES - 1) {
        my $key = "hostpci$index";
        return $key if !exists($conf->{$key});
    }
    die "No free hostpci slot is available in the target VM\n";
}

sub _format_vf_hostpci_value {
    my ($conf, $vf_bdf) = @_;
    my $value = "$vf_bdf,rombar=0";
    $value .= ',pcie=1' if PVE::QemuServer::Machine::machine_type_is_q35($conf);
    return $value;
}

sub _format_pf_hostpci_value {
    my ($conf, $pf_bdf) = @_;
    my $value = $pf_bdf;
    $value .= ',pcie=1' if PVE::QemuServer::Machine::machine_type_is_q35($conf);
    return $value;
}

sub _validate_qemu_hostpci_config {
    my ($vmid, $conf) = @_;
    eval { PVE::QemuServer::PCI::parse_hostpci_devices($conf) };
    my $error = $@;
    die "Invalid PCI configuration for VM $vmid: $error" if $error;
}

sub _rollback_qemu_configs {
    my ($snapshots, $vmids) = @_;
    my @errors;
    for my $vmid (reverse @$vmids) {
        eval { PVE::QemuConfig->write_config($vmid, dclone($snapshots->{$vmid})) };
        push @errors, "VM $vmid: $@" if $@;
    }
    return @errors;
}

sub _set_vf_assignment {
    my ($pf_bdf, $vf_index, $target_vmid) = @_;
    $pf_bdf = _normalise_bdf($pf_bdf);
    die "Invalid physical GPU BDF\n" if !defined($pf_bdf);
    $vf_index = int($vf_index // 0);
    $target_vmid = int($target_vmid // 0);
    die "VF index must be at least 1\n" if $vf_index < 1;
    die "VM ID must be 0 (None) or a valid QEMU VM ID\n"
        if $target_vmid < 0;

    return _with_gpu_lock(sub {
        _assert_power_mode_normal($pf_bdf, 'change a VF assignment');
        my @vmids = _all_qemu_vmids();
        my %known_vmid = map { $_ => 1 } @vmids;
        die "QEMU VM $target_vmid does not exist on this node\n"
            if $target_vmid && !$known_vmid{$target_vmid};

        return _with_vm_locks(\@vmids, sub {
            return _with_pci_reservation_lock(sub {
                my $rec = _collect_device($pf_bdf, 0);
                die "Device '$pf_bdf' not found or not a supported GPU\n"
                    if !defined($rec);
                my $num_vfs = _read_sriov_numvfs($rec->{bdf});
                die "VF index $vf_index out of range (1..$num_vfs)\n"
                    if $vf_index > $num_vfs;
                my $vf_bdf = _validate_vf_bdf($rec, $vf_index);

                my @current_vmids = _all_qemu_vmids();
                die "The QEMU VM set changed while preparing the VF assignment; retry the operation\n"
                    if join(',', @current_vmids) ne join(',', @vmids);

                my $consumers = check_vf_vm_assignments(
                    $rec->{bdf},
                    $rec->{drm_card},
                    $num_vfs,
                    1,
                );
                my @pf_consumers = grep { $_->{vf_index} == 0 } @$consumers;
                die "Physical GPU $rec->{bdf} is assigned to a VM; detach the PF before assigning any VF\n"
                    if @pf_consumers;
                my @vf_consumers = grep { $_->{vf_index} == $vf_index } @$consumers;
                die "VF $vf_index ($vf_bdf) has multiple VM consumers; resolve the duplicate hostpci configuration first\n"
                    if @vf_consumers > 1;
                my $source = @vf_consumers ? $vf_consumers[0] : undef;
                my $source_vmid = $source ? int($source->{vmid}) : 0;

                my %configs;
                for my $vmid (grep { $_ } ($source_vmid, $target_vmid)) {
                    next if exists($configs{$vmid});
                    $configs{$vmid} = PVE::QemuConfig->load_config($vmid);
                    _assert_vm_can_change_vf($vmid, $configs{$vmid});
                }

                my $same_assignment = $source && $source_vmid == $target_vmid;
                if ($source) {
                    die "VM $source_vmid no longer contains $source->{key}; retry the operation\n"
                        if !exists($configs{$source_vmid}{$source->{key}});
                    _assert_exact_vf_hostpci_entry(
                        $source_vmid,
                        $source->{key},
                        $configs{$source_vmid}{$source->{key}},
                        $vf_bdf,
                    );
                }

                my %snapshots;
                my @changed_vmids;
                if ($source && !$same_assignment) {
                    my $source_conf = $configs{$source_vmid};
                    my $source_key = $source->{key};
                    $snapshots{$source_vmid} = dclone($source_conf);
                    delete $source_conf->{$source_key};
                    push @changed_vmids, $source_vmid;
                }

                if ($target_vmid && !$same_assignment) {
                    my $target_conf = $configs{$target_vmid};
                    $snapshots{$target_vmid} //= dclone($target_conf);
                    my $target_key = _first_free_hostpci_key($target_conf);
                    $target_conf->{$target_key} = _format_vf_hostpci_value(
                        $target_conf,
                        $vf_bdf,
                    );
                    push @changed_vmids, $target_vmid
                        if !grep { $_ == $target_vmid } @changed_vmids;
                }

                _validate_qemu_hostpci_config($_, $configs{$_}) for @changed_vmids;

                my $desired_driver = $target_vmid ? 'vfio-pci' : '';
                my $current_driver = _pci_driver($vf_bdf);
                my $current_override = read_sysfs(
                    "/sys/bus/pci/devices/$vf_bdf/driver_override"
                );
                die "Cannot snapshot driver_override for VF $vf_bdf\n"
                    if !defined($current_override);
                my $normal_override = $current_override eq '(null)' ? '' : $current_override;
                my $driver_needs_change =
                    $current_driver ne $desired_driver || $normal_override ne '';
                my ($persisted_driver, $persistence_profile_valid);
                if ($target_vmid) {
                    $persisted_driver = _validated_persisted_vf_driver(
                        $rec,
                        $vf_index,
                    );
                    $persistence_profile_valid = 1;
                } else {
                    $persistence_profile_valid = eval {
                        $persisted_driver = _validated_persisted_vf_driver(
                            $rec,
                            $vf_index,
                        );
                        1;
                    } ? 1 : 0;
                }
                my $persistence_needs_change =
                    $persistence_profile_valid &&
                    $persisted_driver ne $desired_driver;
                my $original_autoprobe = _read_uint_sysfs(
                    "/sys/bus/pci/devices/$rec->{bdf}/sriov_drivers_autoprobe",
                    "driver autoprobe state for $rec->{bdf}",
                );
                die "Invalid driver autoprobe state '$original_autoprobe' for $rec->{bdf}\n"
                    if $original_autoprobe !~ /^[01]$/;

                if (!@changed_vmids && !$driver_needs_change &&
                    !$persistence_needs_change) {
                    my $vfs = _vf_records($rec);
                    my ($vf) = grep { $_->{vf_index} == $vf_index } @$vfs;
                    return {
                        success => \1,
                        changed => \0,
                        assignment => $vf,
                    };
                }

                my $persist_snapshot = $persistence_needs_change
                    ? _snapshot_file($GPU_SRIOV_CONF)
                    : undef;
                my ($driver_touched, $persistence_touched, $autoprobe_touched) =
                    (0, 0, 0);

                my $ok = eval {
                    if ($driver_needs_change) {
                        if ($original_autoprobe != 0) {
                            $autoprobe_touched = 1;
                            _set_autoprobe($rec->{bdf}, 0);
                        }
                        $driver_touched = 1;
                        _set_vf_driver_state($vf_bdf, $desired_driver);
                    }
                    PVE::QemuConfig->write_config($_, $configs{$_}) for @changed_vmids;

                    my $after = check_vf_vm_assignments(
                        $rec->{bdf},
                        $rec->{drm_card},
                        $num_vfs,
                        1,
                    );
                    my @after_consumers = grep { $_->{vf_index} == $vf_index } @$after;
                    if ($target_vmid) {
                        die "VF assignment verification failed for VM $target_vmid\n"
                            if @after_consumers != 1 ||
                               int($after_consumers[0]{vmid}) != $target_vmid;
                    } else {
                        die "VF unassignment verification failed\n" if @after_consumers;
                    }
                    my $actual_driver = _pci_driver($vf_bdf);
                    die "VF driver verification failed: expected '" .
                        ($desired_driver || 'unbound') . "', found '" .
                        ($actual_driver || 'unbound') . "'\n"
                        if $actual_driver ne $desired_driver;
                    if ($autoprobe_touched) {
                        _set_autoprobe($rec->{bdf}, $original_autoprobe);
                        $autoprobe_touched = 0;
                        my $after_autoprobe_driver = _pci_driver($vf_bdf);
                        die "VF driver changed while restoring sriov_drivers_autoprobe: expected '" .
                            ($desired_driver || 'unbound') . "', found '" .
                            ($after_autoprobe_driver || 'unbound') . "'\n"
                            if $after_autoprobe_driver ne $desired_driver;
                    }
                    if ($persistence_needs_change) {
                        $persistence_touched = 1;
                        _set_persisted_vf_driver(
                            $rec->{bdf},
                            $vf_index,
                            $desired_driver,
                        );
                        my $actual_persisted = _validated_persisted_vf_driver(
                            $rec,
                            $vf_index,
                        );
                        die "Persisted VF driver verification failed\n"
                            if !defined($actual_persisted) ||
                               $actual_persisted ne $desired_driver;
                    }
                    1;
                };
                if (!$ok) {
                    my $error = $@ || 'unknown VF assignment failure';
                    my @rollback_errors = _rollback_qemu_configs(
                        \%snapshots,
                        \@changed_vmids,
                    );
                    if ($persistence_touched) {
                        eval {
                            _restore_file_snapshot(
                                $GPU_SRIOV_CONF,
                                $persist_snapshot,
                            )
                        };
                        push @rollback_errors, "VF driver persistence: $@" if $@;
                    }
                    if ($driver_touched) {
                        eval { _set_autoprobe($rec->{bdf}, 0) };
                        push @rollback_errors, "VF autoprobe guard: $@" if $@;
                        eval {
                            _restore_vf_driver_state(
                                $vf_bdf,
                                $current_driver,
                                $current_override,
                            )
                        };
                        push @rollback_errors, "VF driver: $@" if $@;
                        eval {
                            _set_autoprobe($rec->{bdf}, $original_autoprobe)
                        };
                        push @rollback_errors, "VF autoprobe restore: $@" if $@;
                    } elsif ($autoprobe_touched) {
                        eval { _set_autoprobe($rec->{bdf}, $original_autoprobe) };
                        push @rollback_errors, "VF autoprobe: $@" if $@;
                    }
                    $error .= "Rollback also failed: " . join('; ', @rollback_errors) . "\n"
                        if @rollback_errors;
                    die $error;
                }

                my $vfs = _vf_records($rec);
                my ($vf) = grep { $_->{vf_index} == $vf_index } @$vfs;
                return {
                    success => \1,
                    changed => \1,
                    assignment => $vf,
                };
            });
        });
    });
}

sub _format_consumers {
    my ($consumers) = @_;
    return join(', ', map {
        sprintf('VF%d/VM%d%s', $_->{vf_index}, $_->{vmid}, $_->{running} ? ' (running)' : '')
    } @$consumers);
}

sub _unbind_vf {
    my ($vf_bdf) = @_;
    my $driver = _pci_driver($vf_bdf);
    return if $driver eq '';
    write_sysfs("/sys/bus/pci/devices/$vf_bdf/driver/unbind", $vf_bdf);
    my $actual = _pci_driver($vf_bdf);
    die "Failed to unbind VF '$vf_bdf' from '$driver' (found '$actual')\n"
        if $actual ne '';
}

sub _unbind_all_vfs {
    my ($pf_bdf, $count) = @_;
    for my $vf (1 .. $count) {
        my $vf_bdf = _vf_bdf($pf_bdf, $vf);
        _unbind_vf($vf_bdf) if defined($vf_bdf);
    }
}

sub _bind_vf_driver {
    my ($vf_bdf, $driver) = @_;
    return if !defined($vf_bdf) || !defined($driver) || $driver eq '';
    die "Refusing to restore unsupported VF driver '$driver'\n"
        if $driver !~ /^(?:vfio-pci|xe|i915)$/;

    my $override_path = "/sys/bus/pci/devices/$vf_bdf/driver_override";
    my $current = _pci_driver($vf_bdf);
    if ($current eq $driver) {
        write_sysfs($override_path, '');
        my $override = read_sysfs($override_path);
        die "Failed to clear driver_override for VF $vf_bdf\n"
            if !defined($override) || ($override ne '' && $override ne '(null)');
        return;
    }
    if (_get_sysfs_root() eq '') {
        run_command(['modprobe', $driver]);
    }
    write_sysfs($override_path, $driver);
    my $override = read_sysfs($override_path);
    die "Failed to set driver_override '$driver' for VF $vf_bdf\n"
        if !defined($override) || $override ne $driver;
    _unbind_vf($vf_bdf) if $current ne '';
    write_sysfs('/sys/bus/pci/drivers_probe', $vf_bdf);
    my $actual = _pci_driver($vf_bdf);
    die "Failed to restore VF $vf_bdf driver '$driver' (found '${actual}')\n"
        if $actual ne $driver;
    write_sysfs($override_path, '');
    $override = read_sysfs($override_path);
    die "Failed to clear driver_override for VF $vf_bdf\n"
        if !defined($override) || ($override ne '' && $override ne '(null)');
}

sub _set_vf_driver_state {
    my ($vf_bdf, $driver) = @_;
    if (!defined($driver) || $driver eq '') {
        _unbind_vf($vf_bdf);
        write_sysfs("/sys/bus/pci/devices/$vf_bdf/driver_override", '');
        my $actual = _pci_driver($vf_bdf);
        die "Failed to leave VF $vf_bdf unbound (found '$actual')\n"
            if $actual ne '';
        return;
    }
    _bind_vf_driver($vf_bdf, $driver);
    write_sysfs("/sys/bus/pci/devices/$vf_bdf/driver_override", '');
    my $override = read_sysfs("/sys/bus/pci/devices/$vf_bdf/driver_override");
    die "Failed to clear driver_override for VF $vf_bdf\n"
        if !defined($override) || ($override ne '' && $override ne '(null)');
}

sub _restore_vf_driver_state {
    my ($vf_bdf, $driver, $override) = @_;
    _set_vf_driver_state($vf_bdf, $driver);
    $override //= '';
    $override = '' if $override eq '(null)';
    die "Refusing to restore unsupported driver_override '$override' for $vf_bdf\n"
        if $override ne '' && $override !~ /^(?:vfio-pci|xe|i915)$/;
    my $override_path = "/sys/bus/pci/devices/$vf_bdf/driver_override";
    write_sysfs($override_path, $override);
    my $actual_override = read_sysfs($override_path);
    die "Cannot verify restored driver_override for $vf_bdf\n"
        if !defined($actual_override);
    $actual_override = '' if $actual_override eq '(null)';
    die "Failed to restore driver_override for $vf_bdf: expected '" .
        ($override || '(null)') . "', found '" .
        ($actual_override || '(null)') . "'\n"
        if $actual_override ne $override;
}

sub _set_autoprobe {
    my ($bdf, $value) = @_;
    my $path = "/sys/bus/pci/devices/$bdf/sriov_drivers_autoprobe";
    die "sriov_drivers_autoprobe is unavailable for '$bdf'\n"
        if !-e sysfs_path($path);
    write_sysfs($path, $value ? 1 : 0);
    my $actual = read_sysfs($path);
    die "Autoprobe verification failed for '$bdf': requested " .
        ($value ? 1 : 0) . ", found '" .
        (defined($actual) ? $actual : 'unreadable') . "'\n"
        if !defined($actual) || $actual !~ /^[01]$/ || int($actual) != ($value ? 1 : 0);
}

sub _restore_reprovisioned_drivers {
    my ($rec, $snapshot, $target, $autoprobe) = @_;
    my %old_driver = map { $_->{vf_index} => ($_->{driver} // '') }
        @{$snapshot->{drivers}};
    my $native_driver = $rec->{driver} // '';
    $native_driver = '' if $native_driver !~ /^(?:xe|i915)$/;

    for my $vf (1 .. $target) {
        my $driver = $old_driver{$vf} // '';
        $driver = $native_driver if $driver eq '' && $autoprobe;
        next if $driver eq '';
        my $vf_bdf = _vf_bdf($rec->{bdf}, $vf);
        die "Cannot resolve reprovisioned VF$vf for $rec->{bdf}\n"
            if !defined($vf_bdf);
        _bind_vf_driver($vf_bdf, $driver);
    }
}

sub _wait_for_vfs {
    my ($rec, $profiles, $timeout_ms) = @_;
    $timeout_ms //= 10_000;
    my $elapsed = 0;
    while ($elapsed <= $timeout_ms) {
        my $ready = 1;
        for my $profile (@$profiles) {
            my $vf = $profile->{vf_index};
            $ready = 0 if !defined(_vf_bdf($rec->{bdf}, $vf));
            my $paths = _resource_paths_for_vf($rec, $vf);
            for my $name (@VF_RESOURCE_NAMES) {
                # Auto provisioning still has to expose the complete control
                # tree before the transaction can be considered durable.
                $ready = 0 if !@{$paths->{$name}};
                for my $path (@{$paths->{$name}}) {
                    $ready = 0 if !-e sysfs_path($path);
                }
            }
        }
        return 1 if $ready;
        usleep(100_000);
        $elapsed += 100;
    }
    die "Timed out waiting for VF PCI functions and resource files\n";
}

sub _prepare_auto_provisioning {
    my ($rec) = @_;
    my $plugin = get_vendor_plugin($rec->{vendor_id});
    return 1 if !$plugin || !$plugin->can('prepare_auto_provisioning');
    return $plugin->prepare_auto_provisioning($rec->{family}, $rec->{bdf});
}

sub _set_scheduler_priority {
    my ($rec, $priority) = @_;
    return if !defined($priority) || $priority eq 'unchanged';
    my $current = _read_scheduler_priority($rec);
    return if defined($current) && $current eq $priority;
    my $plugin = get_vendor_plugin($rec->{vendor_id});
    die "Scheduler control is unavailable on $rec->{bdf}\n"
        if !$plugin || !$plugin->can('set_scheduler_priority');
    $plugin->set_scheduler_priority($rec->{bdf}, $priority);
    my $actual = _read_scheduler_priority($rec);
    die "Scheduler verification failed: requested '$priority', found '" .
        (defined($actual) ? $actual : 'unknown') . "'\n"
        if !defined($actual) || $actual ne $priority;
}

sub _scheduler_for_transaction {
    my ($requested, $topology_changed, $snapshot, $target) = @_;
    my $effective = $requested;
    if ($topology_changed && $requested eq 'unchanged') {
        $effective = $snapshot->{scheduler};
        die "Cannot preserve an unreadable or mixed scheduler during VF reprovision\n"
            if !defined($effective) || $effective eq 'mixed';
    }
    die "Cannot apply unsupported scheduler profile '$effective'\n"
        if $target > 0 && $effective !~ /^(?:unchanged|low|normal)$/;
    return $effective;
}

sub _apply_profiles {
    my ($rec, $profiles) = @_;
    my @writes;
    for my $profile (@$profiles) {
        my $paths = _resource_paths_for_vf($rec, $profile->{vf_index});
        for my $name (@VF_RESOURCE_NAMES) {
            my $resource = $profile->{resources}{$name};
            next if $resource->{mode} ne 'custom';
            die "VF$profile->{vf_index} resource '$name' is unavailable\n"
                if !@{$paths->{$name}};
            for my $path (@{$paths->{$name}}) {
                die "VF$profile->{vf_index} resource '$name' path '$path' is unavailable\n"
                    if !-e sysfs_path($path);
                my $old = read_sysfs($path);
                push @writes, {
                    path => $path,
                    value => int($resource->{quota}),
                    old => defined($old) && $old =~ /^\d+$/ ? int($old) : undef,
                };
            }
        }
    }

    # Reductions first avoid a transient over-allocation when moving quota
    # from one VF to another.
    @writes = sort {
        my $a_grows = !defined($a->{old}) || $a->{value} > $a->{old};
        my $b_grows = !defined($b->{old}) || $b->{value} > $b->{old};
        $a_grows <=> $b_grows
    } @writes;

    for my $write (@writes) {
        write_sysfs($write->{path}, $write->{value});
        my $actual = read_sysfs($write->{path});
        die "Resource verification failed for '$write->{path}': requested $write->{value}, found '" .
            (defined($actual) ? $actual : 'unreadable') . "'\n"
            if !defined($actual) || $actual !~ /^\d+$/ || int($actual) != $write->{value};
    }
}

sub _profiles_have_unchanged {
    my ($profiles) = @_;
    for my $profile (@$profiles) {
        for my $name (@VF_RESOURCE_NAMES) {
            return 1 if $profile->{resources}{$name}{mode} eq 'unchanged';
        }
    }
    return 0;
}

sub _rollback_state {
    my ($rec, $snapshot, $topology_changed) = @_;
    my @errors;

    if ($topology_changed) {
        eval {
            my $current = _read_sriov_numvfs(
                $rec->{bdf},
                "rollback VF count for $rec->{bdf}",
            );
            _unbind_all_vfs($rec->{bdf}, $current) if $current > 0;
            write_sysfs("/sys/bus/pci/devices/$rec->{bdf}/sriov_numvfs", 0)
                if $current > 0;
            write_sysfs(
                "/sys/bus/pci/devices/$rec->{bdf}/sriov_drivers_autoprobe",
                0,
            );
            if ($snapshot->{count} > 0) {
                _prepare_auto_provisioning($rec);
                write_sysfs(
                    "/sys/bus/pci/devices/$rec->{bdf}/sriov_numvfs",
                    $snapshot->{count},
                );
                my @rollback_profiles = map {
                    {
                        vf_index => $_,
                        resources => { map { $_ => { mode => 'unchanged' } } @VF_RESOURCE_NAMES },
                    }
                } 1 .. $snapshot->{count};
                _wait_for_vfs($rec, \@rollback_profiles, 10_000);
            }
        };
        push @errors, "topology rollback: $@" if $@;
    }

    my @resource_restores = map {
        my $path = $_;
        my $current = read_sysfs($path);
        +{
            path => $path,
            target => $snapshot->{path_values}{$path},
            current => defined($current) && $current =~ /^\d+$/ ? int($current) : undef,
        }
    } keys %{$snapshot->{path_values}};
    @resource_restores = sort {
        my $a_grows = !defined($a->{current}) || $a->{target} > $a->{current};
        my $b_grows = !defined($b->{current}) || $b->{target} > $b->{current};
        $a_grows <=> $b_grows || $a->{path} cmp $b->{path}
    } @resource_restores;

    for my $restore (@resource_restores) {
        eval {
            write_sysfs($restore->{path}, $restore->{target});
            my $actual = read_sysfs($restore->{path});
            die "readback mismatch\n"
                if !defined($actual) || $actual !~ /^\d+$/ ||
                   int($actual) != $restore->{target};
        };
        push @errors, "resource rollback $restore->{path}: $@" if $@;
    }

    if (defined($snapshot->{scheduler})) {
        eval { _set_scheduler_priority($rec, $snapshot->{scheduler}) };
        push @errors, "scheduler rollback: $@" if $@;
    }

    if ($topology_changed && $snapshot->{count} > 0) {
        for my $old (@{$snapshot->{drivers}}) {
            next if !$old->{driver} && !exists($old->{override});
            my $vf_bdf = _vf_bdf($rec->{bdf}, $old->{vf_index});
            eval {
                if (exists($old->{override})) {
                    _restore_vf_driver_state(
                        $vf_bdf,
                        $old->{driver},
                        $old->{override},
                    );
                } else {
                    _bind_vf_driver($vf_bdf, $old->{driver});
                }
            };
            push @errors, "driver rollback VF$old->{vf_index}: $@" if $@;
        }
    }

    eval { _set_autoprobe($rec->{bdf}, $snapshot->{autoprobe}) };
    push @errors, "autoprobe rollback: $@" if $@;

    if ($snapshot->{config}) {
        eval {
            if ($snapshot->{config}{exists}) {
                file_set_contents(
                    $GPU_SRIOV_CONF,
                    $snapshot->{config}{contents},
                );
            } elsif (-e $GPU_SRIOV_CONF) {
                unlink($GPU_SRIOV_CONF)
                    or die "Cannot remove newly-created '$GPU_SRIOV_CONF': $!\n";
            }
        };
        push @errors, "persistence rollback: $@" if $@;
    }

    return \@errors;
}

sub _remove_persisted_device {
    my ($config, $bdf) = @_;
    delete $config->{$bdf};
    for my $section (keys %$config) {
        delete $config->{$section} if $section =~ /^\Q$bdf\E\/vf\d+$/;
    }
}

sub _persist_profiles {
    my ($rec, $profiles, $scheduler, $autoprobe, $persist, $allow_unsafe_scheduler,
        $requested_scheduler) = @_;
    # A topology rebuild resolves an unchanged request before the old VFs are
    # destroyed.  The caller passes that resolved value in $scheduler so this
    # persistence step never re-reads a potentially different post-rebuild
    # default.  Keep the requested value separately for compatibility checks
    # (notably the acknowledgement carried by an unchanged normal profile).
    $requested_scheduler = $scheduler if !defined($requested_scheduler);
    my $config = parse_ini_config($GPU_SRIOV_CONF, 1);
    my $previous = _persistent_device_enabled($config, $rec->{bdf})
        ? $config->{$rec->{bdf}}
        : {};
    _remove_persisted_device($config, $rec->{bdf});

    if ($persist) {
        die "Persistent configuration requires explicit auto/custom modes for every resource\n"
            if _profiles_have_unchanged($profiles);
        my $active_scheduler = $scheduler eq 'unchanged'
            ? _read_scheduler_priority($rec)
            : $scheduler;
        die "Cannot persist an unreadable or mixed scheduler profile\n"
            if !defined($active_scheduler) || $active_scheduler eq 'mixed';
        die "Cannot persist unsupported scheduler profile '$active_scheduler'\n"
            if $active_scheduler !~ /^(?:low|normal)$/;
        my $unsafe_ack = $allow_unsafe_scheduler ? 1 : 0;
        $unsafe_ack = 1
            if $requested_scheduler eq 'unchanged' &&
               ($previous->{sched_priority} // '') eq 'normal' &&
               ($previous->{allow_unsafe_scheduler} // 0);
        die "Persisting the experimental normal scheduler requires allow_unsafe_scheduler=1\n"
            if $active_scheduler eq 'normal' && !$unsafe_ack;
        $config->{$rec->{bdf}} = {
            persist => 1,
            api_version => 2,
            num_vfs => scalar(@$profiles),
            drivers_autoprobe => $autoprobe,
            sched_priority => $active_scheduler,
            allow_unsafe_scheduler =>
                ($active_scheduler eq 'normal' && $unsafe_ack) ? 1 : 0,
            family => $rec->{family},
            device_id => $rec->{device_id},
        };
        for my $profile (@$profiles) {
            my $vf = $profile->{vf_index};
            my %section;
            for my $name (@VF_RESOURCE_NAMES) {
                my $resource = $profile->{resources}{$name};
                $section{"${name}_mode"} = $resource->{mode};
                $section{"${name}_quota"} = $resource->{quota}
                    if $resource->{mode} eq 'custom';
            }
            my $vf_bdf = _vf_bdf($rec->{bdf}, $vf);
            my $driver = defined($vf_bdf) ? _pci_driver($vf_bdf) : '';
            die "Cannot persist unsupported BMG VF$vf driver '$driver'\n"
                if $driver !~ /^(?:|vfio-pci|xe)$/;
            $section{driver} = $driver;
            $config->{"$rec->{bdf}/vf$vf"} = \%section;
        }
    }

    write_ini_config($GPU_SRIOV_CONF, $config);
}

sub _legacy_profiles {
    my ($param, $num_vfs, $reprovision) = @_;
    my %legacy_key = (
        vram => 'lmem_per_vf',
        ggtt => 'ggtt_per_vf',
        contexts => 'contexts_per_vf',
        doorbells => 'doorbells_per_vf',
        exec_quantum_ms => 'exec_quantum_ms',
        preempt_timeout_us => 'preempt_timeout_us',
    );
    my @profiles;
    for my $vf (1 .. $num_vfs) {
        my %resources;
        for my $name (@VF_RESOURCE_NAMES) {
            my $key = $legacy_key{$name};
            $resources{$name} = defined($param->{$key})
                ? { mode => 'custom', quota => int($param->{$key}) }
                : { mode => $reprovision ? 'auto' : 'unchanged' };
        }
        push @profiles, { vf_index => $vf, resources => \%resources };
    }
    return validate_vf_profiles(\@profiles, $num_vfs);
}

sub _profiles_require_auto_reprovision {
    my ($rec, $profiles, $persist_config) = @_;
    my $persisted = _persistent_device_enabled($persist_config, $rec->{bdf});
    for my $profile (@$profiles) {
        my $section = $persist_config->{"$rec->{bdf}/vf$profile->{vf_index}"} // {};
        for my $name (@VF_RESOURCE_NAMES) {
            next if $profile->{resources}{$name}{mode} ne 'auto';
            return 1 if !$persisted;
            return 1 if ($section->{"${name}_mode"} // '') ne 'auto';
        }
    }
    return 0;
}

sub _vf_records {
    my ($rec) = @_;
    my $num_vfs = _read_sriov_numvfs($rec->{bdf});
    return [] if $num_vfs == 0;

    my $persist_config = parse_ini_config($GPU_SRIOV_CONF);
    my $consumers = check_vf_vm_assignments(
        $rec->{bdf},
        $rec->{drm_card},
        $num_vfs,
    );
    my %consumer_by_vf = map { $_->{vf_index} => $_ } grep { $_->{vf_index} > 0 } @$consumers;
    my @records;

    for my $vf (1 .. $num_vfs) {
        my $vf_bdf = _vf_bdf($rec->{bdf}, $vf) // '';
        my $resources = _read_vf_resources($rec, $vf, $persist_config);
        my $consumer = $consumer_by_vf{$vf};
        push @records, {
            vf_index => $vf,
            bdf => $vf_bdf,
            driver => $vf_bdf ne '' ? _pci_driver($vf_bdf) : '',
            vmid => $consumer ? $consumer->{vmid} : undef,
            hostpci => $consumer ? $consumer->{key} : undef,
            assigned => $consumer ? \1 : \0,
            running => $consumer && $consumer->{running} ? \1 : \0,
            resources => $resources,
            # Flat aliases retained for older readers.  vram is the canonical
            # xe/BMG name; lmem is kept only as a compatibility alias.
            vram_quota => $resources->{vram}{effective},
            lmem_quota => $resources->{vram}{effective},
            ggtt_quota => $resources->{ggtt}{effective},
            contexts => $resources->{contexts}{effective},
            doorbells => $resources->{doorbells}{effective},
            exec_quantum_ms => $resources->{exec_quantum_ms}{effective},
            preempt_timeout_us => $resources->{preempt_timeout_us}{effective},
        };
    }
    return \@records;
}

sub _calculate_persistence_drift {
    my ($rec, $persist_config, $vfs, $scheduler) = @_;
    my $bdf = $rec->{bdf};
    my $current_count = $rec->{sriov_numvfs};
    die "Cannot use an invalid non-negative integer for VF count of $bdf\n"
        if !defined($current_count) || $current_count !~ /^\d+$/;
    $current_count = int($current_count);
    my $has_section = exists($persist_config->{$bdf});
    my $has_device = _persistent_device_enabled($persist_config, $bdf);
    my $persisted = $persist_config->{$bdf} // {};
    my @profile_sections = grep { /^\Q$bdf\E\/vf\d+$/ } keys %$persist_config;
    my @issues;
    my @resource_drift;

    push @issues, 'persistent device section is disabled'
        if $has_section && !$has_device;
    push @issues, 'live VFs have no enabled persistent device section'
        if $current_count > 0 && !$has_device;
    push @issues, 'VF profile sections exist without an enabled persistent device section'
        if !$has_device && @profile_sections;
    push @issues, 'persistent configuration exists while no live VFs exist'
        if $current_count == 0 && ($has_device || @profile_sections);

    my $count_drift = 0;
    if ($has_device) {
        push @issues, 'persistent api_version is missing or unsupported'
            if ($persisted->{api_version} // '') ne '2';
        push @issues, 'persistent drivers_autoprobe is missing or invalid'
            if ($persisted->{drivers_autoprobe} // '') !~ /^(?:0|1)$/;
        push @issues, 'persistent device family does not match the live BMG device'
            if ($persisted->{family} // '') ne $rec->{family};
        if (defined($persisted->{device_id}) && $persisted->{device_id} ne '') {
            my $configured_device = lc($persisted->{device_id});
            $configured_device = "0x$configured_device"
                if $configured_device !~ /^0x/;
            push @issues, 'persistent PCI device ID does not match the live device'
                if $configured_device ne $rec->{device_id};
        }
        if (!defined($persisted->{num_vfs}) || $persisted->{num_vfs} !~ /^\d+$/) {
            $count_drift = 1;
            push @issues, 'persistent num_vfs is missing or invalid';
        } elsif (int($persisted->{num_vfs}) != $current_count) {
            $count_drift = 1;
        }
    } elsif ($current_count > 0) {
        $count_drift = 1;
    }

    my $scheduler_unreadable = 0;
    my $scheduler_drift = 0;
    if ($has_device && $current_count > 0) {
        my $unsafe_scheduler = $persisted->{allow_unsafe_scheduler} // '0';
        if ($unsafe_scheduler !~ /^(?:0|1)$/) {
            $scheduler_drift = 1;
            push @issues, 'persistent unsafe scheduler acknowledgement is invalid';
        }
        if (!defined($persisted->{sched_priority}) ||
            $persisted->{sched_priority} !~ /^(?:low|normal)$/) {
            $scheduler_drift = 1;
            push @issues, 'persistent scheduler profile is missing or invalid';
        } elsif (!defined($scheduler) || $scheduler eq 'mixed') {
            $scheduler_drift = 1;
            $scheduler_unreadable = 1;
            push @issues, defined($scheduler)
                ? 'live scheduler profiles are mixed across PF/VFs'
                : 'live scheduler profile is unreadable';
        } elsif ($persisted->{sched_priority} ne $scheduler) {
            $scheduler_drift = 1;
        }
        if (($persisted->{sched_priority} // '') eq 'normal' &&
            $unsafe_scheduler ne '1') {
            $scheduler_drift = 1;
            push @issues, 'persistent normal scheduler lacks the required unsafe acknowledgement';
        }
    }

    my %live_by_vf = map { $_->{vf_index} => $_ } @$vfs;
    for my $vf (1 .. $current_count) {
        my $section_name = "$bdf/vf$vf";
        my $section = $persist_config->{$section_name};
        if (!$has_device || ref($section) ne 'HASH') {
            push @issues, "persistent profile for VF$vf is missing" if $has_device;
            next;
        }
        my $driver = $section->{driver} // '';
        if ($driver !~ /^(?:|vfio-pci|xe)$/) {
            push @issues, "persistent driver for VF$vf is unsupported ('$driver')";
        } else {
            my $live_driver = $live_by_vf{$vf}{driver} // '';
            push @issues, "live driver for VF$vf differs from the persistent profile"
                if $live_driver ne $driver;
        }
        for my $name (@VF_RESOURCE_NAMES) {
            my $mode = $section->{"${name}_mode"};
            if (!defined($mode) || $mode !~ /^(?:auto|custom)$/) {
                push @resource_drift, {
                    vf_index => $vf,
                    resource => $name,
                    expected => 'auto/custom mode',
                    actual => defined($mode) ? $mode : undef,
                    reason => 'persistent mode is missing or invalid',
                };
                next;
            }
            next if $mode eq 'auto';
            my $wanted = $section->{"${name}_quota"};
            my $valid_quota = eval {
                normalise_resource_profile($name, {
                    mode => 'custom',
                    quota => $wanted,
                });
                1;
            };
            if (!$valid_quota) {
                push @resource_drift, {
                    vf_index => $vf,
                    resource => $name,
                    expected => 'valid custom quota',
                    actual => $wanted,
                    reason => 'persistent custom quota is missing or invalid',
                };
                next;
            }
            my $live = $live_by_vf{$vf}{resources}{$name}{effective};
            if (!defined($live) || int($live) != int($wanted)) {
                push @resource_drift, {
                    vf_index => $vf,
                    resource => $name,
                    expected => int($wanted),
                    actual => $live,
                    reason => 'live value differs from persistent custom quota',
                };
            }
        }
    }

    for my $section (@profile_sections) {
        my ($vf) = $section =~ /\/vf(\d+)$/;
        push @issues, "stale persistent profile for VF$vf"
            if defined($vf) && ($vf < 1 || $vf > $current_count);
    }

    my $persistence_drift = @issues ? 1 : 0;
    my $has_drift = $count_drift || $scheduler_drift ||
        $persistence_drift || @resource_drift;
    return {
        has_drift => $has_drift ? 1 : 0,
        count => $count_drift ? 1 : 0,
        scheduler => $scheduler_drift ? 1 : 0,
        scheduler_unreadable => $scheduler_unreadable ? 1 : 0,
        persistence => $persistence_drift ? 1 : 0,
        resources => \@resource_drift,
        issues => \@issues,
    };
}

sub _remove_persisted_config {
    my ($bdf) = @_;
    my $config = parse_ini_config($GPU_SRIOV_CONF, 1);
    _remove_persisted_device($config, $bdf);
    write_ini_config($GPU_SRIOV_CONF, $config);
}

sub _configure_sriov_v2 {
    my ($bdf, $param) = @_;

    return _with_gpu_lock(sub {
        _assert_power_mode_normal($bdf, 'change SR-IOV state');
        my $rec = _collect_device($bdf, 0);
        die "Device '$bdf' not found or not a supported GPU\n" if !defined($rec);

        my $target = int($param->{num_vfs});
        my $current = _read_sriov_numvfs($bdf, "current VF count for $bdf");
        my $max_vfs = _read_uint_sysfs(
            "/sys/bus/pci/devices/$bdf/sriov_totalvfs",
            "live VF limit for $bdf",
        );
        die "Requested $target VFs exceeds live device maximum $max_vfs\n"
            if $target > $max_vfs;

        my $force_reprovision = $param->{force_reprovision} ? 1 : 0;
        my $topology_changed = ($target != $current || $force_reprovision) ? 1 : 0;
        my $persist = defined($param->{persist}) ? ($param->{persist} ? 1 : 0) : 1;
        my $autoprobe = defined($param->{drivers_autoprobe})
            ? ($param->{drivers_autoprobe} ? 1 : 0)
            : _read_uint_sysfs(
                "/sys/bus/pci/devices/$bdf/sriov_drivers_autoprobe",
                "driver autoprobe state for $bdf",
            );
        die "Invalid driver autoprobe state '$autoprobe' for $bdf\n"
            if $autoprobe !~ /^[01]$/;
        my $scheduler = lc($param->{sched_priority} // 'unchanged');
        my $allow_unsafe_scheduler = $param->{allow_unsafe_scheduler} ? 1 : 0;
        die "Scheduler priority must be unchanged, low, or normal\n"
            if $scheduler !~ /^(?:unchanged|low|normal)$/;
        die "The experimental normal scheduler requires allow_unsafe_scheduler=1\n"
            if $scheduler eq 'normal' && !$allow_unsafe_scheduler;

        my $persist_config = parse_ini_config($GPU_SRIOV_CONF, 1);
        my $profiles = [];
        if ($target > 0) {
            $profiles = defined($param->{vf_profiles})
                ? decode_vf_profiles($param->{vf_profiles}, $target)
                : _legacy_profiles($param, $target, $topology_changed);
            die "A VF topology rebuild cannot use unchanged resource modes\n"
                if $topology_changed && _profiles_have_unchanged($profiles);
            die "Switching a resource to auto requires force_reprovision=1\n"
                if !$topology_changed &&
                   _profiles_require_auto_reprovision($rec, $profiles, $persist_config);
            die "Persistent configuration requires explicit auto/custom modes for every resource\n"
                if $persist && _profiles_have_unchanged($profiles);
        }

        # Lock every existing QEMU configuration on this node, not only the
        # consumers found by the first scan.  This prevents another existing VM
        # from acquiring one of these PCI functions while the transaction is in
        # progress.  A second scan below also rejects a newly-created VM that
        # appeared after this list was built.
        my @vmids = _all_qemu_vmids();
        my %locked_vmids = map { $_ => 1 } @vmids;
        my %guarded_bdfs = ($bdf => 1);
        for my $vf (1 .. $current) {
            my $vf_bdf = _vf_bdf($bdf, $vf);
            $guarded_bdfs{$vf_bdf} = 1 if defined($vf_bdf);
        }

        my $apply = sub {
            my $assert_consumers_safe = sub {
                my ($vf_count) = @_;
                my $consumers = check_vf_vm_assignments(
                    $bdf,
                    $rec->{drm_card},
                    $vf_count,
                    1,
                );
                my @unlocked = grep { !$locked_vmids{$_->{vmid}} } @$consumers;
                die "VM PCI configuration changed while locks were acquired; retry the request: " .
                    _format_consumers(\@unlocked) . "\n"
                    if @unlocked;
                die "Cannot disable SR-IOV persistence while PF/VF PCI assignments exist: " .
                    _format_consumers($consumers) . "\n"
                    if !$persist && @$consumers;
                if ($topology_changed && @$consumers) {
                    die "Cannot rebuild VF topology while PCI functions are configured on VM(s): " .
                        _format_consumers($consumers) . ". Detach them first.\n";
                }
                my @running = grep { $_->{running} } @$consumers;
                die "Cannot change VF resources while a consumer VM is running: " .
                    _format_consumers(\@running) . "\n"
                    if @running;
                my @pf_consumers = grep { $_->{vf_index} == 0 } @$consumers;
                die "Cannot modify SR-IOV while the PF is assigned to a VM: " .
                    _format_consumers(\@pf_consumers) . "\n"
                    if @pf_consumers;
                die "The experimental normal scheduler cannot be enabled while any VF is assigned\n"
                    if $scheduler eq 'normal' && @$consumers;
                return $consumers;
            };

            # The first authoritative scan happens while every pre-existing VM
            # configuration lock is held.
            $assert_consumers_safe->($current);

            if ($topology_changed && $target > 0) {
                my $prechecks = run_prechecks($bdf, $rec->{drm_card}, $rec->{vendor_id});
                if (!_bool_value($prechecks->{all_pass})) {
                    my @failures;
                    for my $name (sort keys %{$prechecks->{checks}}) {
                        my $check = $prechecks->{checks}{$name};
                        push @failures, "$name: $check->{detail}"
                            if !_bool_value($check->{pass});
                    }
                    die "Pre-flight checks failed: " . join('; ', @failures) . "\n";
                }
            }

            my $snapshot = _snapshot_state($rec);
            my $live_count = _read_sriov_numvfs(
                $bdf,
                "pre-mutation VF count for $bdf",
            );
            die "VF topology changed concurrently (expected $current, found $live_count); retry the request\n"
                if $live_count != $current;

            # Narrow the remaining race window to the sysfs write itself.  VM
            # starts and configuration edits for all existing VMs remain
            # blocked by their locks for the rest of the transaction.
            $assert_consumers_safe->($current);
            my $scheduler_to_apply = _scheduler_for_transaction(
                $scheduler,
                $topology_changed,
                $snapshot,
                $target,
            );
            my $topology_mutated = 0;
            my $ok = eval {
                if ($topology_changed) {
                    # Always create VFs unbound.  Resource quotas and scheduler
                    # state must be complete before a native driver can probe a
                    # newly-created function.
                    _set_autoprobe($bdf, 0);
                    $topology_mutated = 1 if $current > 0 || $target > 0;
                    _unbind_all_vfs($bdf, $current) if $current > 0;
                    if ($current > 0) {
                        write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0);
                        my $zero = _read_sriov_numvfs(
                            $bdf,
                            "VF reset verification count for $bdf",
                        );
                        die "VF reset verification failed: sriov_numvfs=$zero\n" if $zero != 0;
                    }

                    if ($target > 0) {
                        _prepare_auto_provisioning($rec);
                        write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", $target);
                        _wait_for_vfs($rec, $profiles, 10_000);
                        for my $vf (1 .. $target) {
                            my $vf_bdf = _vf_bdf($bdf, $vf);
                            $guarded_bdfs{$vf_bdf} = 1 if defined($vf_bdf);
                        }
                    }
                }

                if ($target > 0) {
                    _apply_profiles($rec, $profiles);
                    _set_scheduler_priority($rec, $scheduler_to_apply);

                    if ($topology_changed) {
                        _restore_reprovisioned_drivers(
                            $rec,
                            $snapshot,
                            $target,
                            $autoprobe,
                        );
                    }
                }

                _set_autoprobe($bdf, $autoprobe);

                my $actual = _read_uint_sysfs(
                    "/sys/bus/pci/devices/$bdf/sriov_numvfs",
                    "post-mutation VF count for $bdf",
                );
                die "VF count verification failed: requested $target, found $actual\n"
                    if $actual != $target;

                # Detect a VM config created after the all-VM lock set was
                # captured.  Existing VM edits are still blocked by their
                # config locks, and VM PCI starts are blocked by the PVE
                # reservation lock held around this callback.
                if ($topology_changed) {
                    my $late = _scan_qemu_pci_consumers(\%guarded_bdfs, 1);
                    if (@$late) {
                        my $detail = join(', ', map {
                            sprintf('%s/VM%d%s', $_->{bdf}, $_->{vmid},
                                $_->{running} ? ' (running)' : '')
                        } @$late);
                        die "VM PCI configuration changed during VF reprovision; rolling back: $detail\n";
                    }
                } else {
                    $assert_consumers_safe->($target);
                }

                if ($target == 0) {
                    _remove_persisted_config($bdf);
                } else {
                    _persist_profiles(
                        $rec,
                        $profiles,
                        $scheduler_to_apply,
                        $autoprobe,
                        $persist,
                        $allow_unsafe_scheduler,
                        $scheduler,
                    );
                }
                1;
            };
            my $error = $@;
            if (!$ok) {
                my $rollback_errors = _rollback_state($rec, $snapshot, $topology_mutated);
                my $detail = @$rollback_errors
                    ? " Rollback also reported: " . join(' | ', @$rollback_errors)
                    : '';
                die "SR-IOV change failed: $error$detail\n";
            }

            # Refresh the record after topology and persistence changes.
            my $updated = _collect_device($bdf, 0) // $rec;
            return {
                success => \1,
                bdf => $bdf,
                sriov_numvfs => $target,
                scheduler_priority => $target > 0 ? _read_scheduler_priority($updated) : undef,
                persisted => $target > 0 && $persist ? \1 : \0,
                vfs => _vf_records($updated),
            };
        };

        return _with_vm_locks(\@vmids, sub {
            # This is the same advisory lock used by PVE's PCI reservation
            # machinery.  Holding it prevents a passthrough VM start from
            # reserving a PF/VF in the middle of this sysfs transaction.
            return _with_pci_reservation_lock($apply);
        });
    });
}

# ---------------------------------------------------------------------------
# B50 runtime deep-idle policy
# ---------------------------------------------------------------------------

sub _is_b50_power_device {
    my ($rec) = @_;
    return 0 if ref($rec) ne 'HASH';
    my $vendor = lc($rec->{vendor_id} // '');
    my $device = lc($rec->{device_id} // '');
    $vendor =~ s/^0x//;
    $device =~ s/^0x//;
    return $vendor eq '8086' && $device eq 'e212' ? 1 : 0;
}

sub _power_runtime_attributes {
    my ($bdf) = @_;
    my $base = "/sys/bus/pci/devices/$bdf";
    my $usage = read_sysfs("$base/power/runtime_usage");
    my $delay = read_sysfs("$base/power/autosuspend_delay_ms");
    return {
        control => read_sysfs("$base/power/control"),
        autosuspend_delay_ms =>
            defined($delay) && $delay =~ /^-?\d+$/ ? int($delay) : undef,
        runtime_status => read_sysfs("$base/power/runtime_status"),
        runtime_usage =>
            defined($usage) && $usage =~ /^\d+$/ ? int($usage) : undef,
        pci_power_state => read_sysfs("$base/power_state"),
    };
}

sub _write_power_attribute {
    my ($bdf, $name, $value) = @_;
    my $path = "/sys/bus/pci/devices/$bdf/power/$name";
    write_sysfs($path, $value);
    my $actual = read_sysfs($path);
    die "Power attribute verification failed for '$path': requested '$value', found '" .
        (defined($actual) ? $actual : 'unreadable') . "'\n"
        if !defined($actual) || "$actual" ne "$value";
}

sub _restore_power_attributes {
    my ($bdf, $state) = @_;
    my $delay = $state->{restore_delay};
    my $control = $state->{restore_control};
    die "Saved autosuspend delay is invalid for $bdf\n"
        if !defined($delay) || $delay !~ /^-?\d+$/;
    die "Saved runtime power control is invalid for $bdf\n"
        if !defined($control) || $control !~ /^(?:auto|on)$/;
    _write_power_attribute($bdf, 'autosuspend_delay_ms', int($delay));
    _write_power_attribute($bdf, 'control', $control);
}

sub _set_deep_idle_power_attributes {
    my ($bdf) = @_;
    _write_power_attribute($bdf, 'control', 'auto');
    _write_power_attribute($bdf, 'autosuspend_delay_ms', $B50_DEEP_IDLE_DELAY_MS);
}

sub _wait_for_deep_idle {
    my ($bdf, $timeout_ms) = @_;
    $timeout_ms //= 5_000;
    my $elapsed = 0;
    my $last = {};
    while ($elapsed <= $timeout_ms) {
        $last = _power_runtime_attributes($bdf);
        my $usage_idle = defined($last->{runtime_usage}) && $last->{runtime_usage} == 0;
        my $runtime_suspended = ($last->{runtime_status} // '') eq 'suspended';
        my $pci_state = $last->{pci_power_state};
        my $pci_suspended = !defined($pci_state) || $pci_state eq '' || $pci_state =~ /^D3/i;
        return $last if $usage_idle && $runtime_suspended && $pci_suspended;
        usleep(100_000);
        $elapsed += 100;
    }
    die "B50 did not enter runtime suspend within ${timeout_ms}ms: runtime_status='" .
        ($last->{runtime_status} // 'unknown') . "', runtime_usage='" .
        (defined($last->{runtime_usage}) ? $last->{runtime_usage} : 'unknown') .
        "', PCI power='" . ($last->{pci_power_state} // 'unknown') .
        "'. A process may still be polling the GPU.\n";
}

sub _power_state_list {
    my ($value) = @_;
    return () if !defined($value) || $value eq '';
    return grep { $_ ne '' } map {
        my $item = $_;
        $item =~ s/^\s+|\s+$//g;
        $item;
    } split(/,/, $value);
}

sub _saved_power_vf_bdfs {
    my ($state) = @_;
    my @bdfs;
    my %seen;
    for my $raw (_power_state_list($state->{vf_bdfs})) {
        my $bdf = _normalise_bdf($raw);
        die "Invalid VF BDF '$raw' in B50 power state\n" if !defined($bdf);
        die "Duplicate VF BDF '$bdf' in B50 power state\n" if $seen{$bdf}++;
        push @bdfs, $bdf;
    }
    return @bdfs;
}

sub _validate_power_state_record {
    my ($rec, $state) = @_;
    die "B50 power state for $rec->{bdf} is unavailable\n"
        if ref($state) ne 'HASH';
    die "Unsupported B50 power-state format for $rec->{bdf}\n"
        if ($state->{api_version} // '') ne '1';
    die "Unknown B50 power state '" . ($state->{mode} // '') . "' for $rec->{bdf}\n"
        if ($state->{mode} // '') !~ /^(?:entering|deep-idle|exiting|restored)$/;

    my $count = $state->{restore_count};
    die "Saved VF restore count is invalid for $rec->{bdf}\n"
        if !defined($count) || $count !~ /^\d+$/;
    $count = int($count);
    die "Saved VF restore count exceeds the device limit for $rec->{bdf}\n"
        if $count > int($rec->{max_vfs} // 0);

    die "Saved driver-autoprobe state is invalid for $rec->{bdf}\n"
        if ($state->{restore_autoprobe} // '') !~ /^[01]$/;
    die "Saved scheduler state is invalid for $rec->{bdf}\n"
        if ($state->{restore_scheduler} // '') !~ /^(?:|low|normal)$/;
    die "Saved runtime power control is invalid for $rec->{bdf}\n"
        if ($state->{restore_control} // '') !~ /^(?:auto|on)$/;
    die "Saved autosuspend delay is invalid for $rec->{bdf}\n"
        if ($state->{restore_delay} // '') !~ /^-?\d+$/;

    my @saved_bdfs = _saved_power_vf_bdfs($state);
    die "Saved VF BDF count mismatch for $rec->{bdf}: expected $count, found " .
        scalar(@saved_bdfs) . "\n"
        if @saved_bdfs != $count;

    my %vmids;
    for my $vmid (_power_state_list($state->{consumer_vmids})) {
        die "Invalid consumer VMID '$vmid' in B50 power state for $rec->{bdf}\n"
            if $vmid !~ /^\d+$/ || int($vmid) < 100;
        die "Duplicate consumer VMID '$vmid' in B50 power state for $rec->{bdf}\n"
            if $vmids{int($vmid)}++;
    }
    return $state;
}

sub _persisted_power_profiles {
    my ($rec, $expected_count) = @_;
    my $config = parse_ini_config($GPU_SRIOV_CONF, 1);
    my $device = $config->{$rec->{bdf}};
    die "Deep idle requires a persistent SR-IOV profile for $rec->{bdf}\n"
        if ref($device) ne 'HASH' || ($device->{persist} // '') ne '1';
    die "Persistent SR-IOV profile for $rec->{bdf} has an invalid VF count\n"
        if ($device->{num_vfs} // '') !~ /^\d+$/;
    die "Persistent SR-IOV profile count changed for $rec->{bdf}: expected " .
        "$expected_count, found $device->{num_vfs}\n"
        if int($device->{num_vfs}) != $expected_count;

    my $configured_device = lc($device->{device_id} // '');
    $configured_device = "0x$configured_device"
        if $configured_device ne '' && $configured_device !~ /^0x/;
    die "Persistent SR-IOV profile identity does not match $rec->{bdf}\n"
        if $configured_device ne '' && $configured_device ne lc($rec->{device_id} // '');
    die "Persistent SR-IOV family does not match $rec->{bdf}\n"
        if defined($device->{family}) && $device->{family} ne '' &&
           $device->{family} ne ($rec->{family} // '');

    my $autoprobe = $device->{drivers_autoprobe};
    die "Persistent driver-autoprobe state is invalid for $rec->{bdf}\n"
        if !defined($autoprobe) || $autoprobe !~ /^[01]$/;
    my $scheduler = lc($device->{sched_priority} // '');
    die "Persistent scheduler profile is invalid for $rec->{bdf}\n"
        if $scheduler !~ /^(?:low|normal)$/;
    die "Persistent normal scheduler lacks its safety acknowledgement for $rec->{bdf}\n"
        if $scheduler eq 'normal' && !($device->{allow_unsafe_scheduler} // 0);

    my @profiles;
    my %drivers;
    for my $vf (1 .. $expected_count) {
        my $section = $config->{"$rec->{bdf}/vf$vf"};
        die "Persistent profile for VF$vf of $rec->{bdf} is missing\n"
            if ref($section) ne 'HASH';
        my %resources;
        for my $name (@VF_RESOURCE_NAMES) {
            my $mode = lc($section->{"${name}_mode"} // '');
            die "Persistent VF$vf resource '$name' has an invalid mode\n"
                if $mode !~ /^(?:auto|custom)$/;
            $resources{$name} = { mode => $mode };
            if ($mode eq 'custom') {
                my $quota = $section->{"${name}_quota"};
                die "Persistent VF$vf resource '$name' has an invalid quota\n"
                    if !defined($quota) || $quota !~ /^\d+$/;
                $resources{$name}{quota} = int($quota);
            }
        }
        my $driver = $section->{driver} // '';
        die "Persistent VF$vf driver '$driver' is unsupported\n"
            if $driver !~ /^(?:|vfio-pci|xe)$/;
        $drivers{$vf} = $driver;
        push @profiles, { vf_index => $vf, resources => \%resources };
    }

    return {
        config => $config,
        profiles => $expected_count > 0
            ? validate_vf_profiles(\@profiles, $expected_count)
            : [],
        drivers => \%drivers,
        autoprobe => int($autoprobe),
        scheduler => $scheduler,
    };
}

sub _power_consumers {
    my ($rec, $state) = @_;
    my $count = int($rec->{sriov_numvfs} // 0);
    return check_vf_vm_assignments($rec->{bdf}, $rec->{drm_card}, $count, 1)
        if $count > 0;

    my %targets = ($rec->{bdf} => 1);
    my %index = ($rec->{bdf} => 0);
    my @saved = ref($state) eq 'HASH' ? _saved_power_vf_bdfs($state) : ();
    for my $offset (0 .. $#saved) {
        $targets{$saved[$offset]} = 1;
        $index{$saved[$offset]} = $offset + 1;
    }
    my $consumers = _scan_qemu_pci_consumers(\%targets, 1);
    $_->{vf_index} = $index{$_->{bdf}} for @$consumers;
    return $consumers;
}

sub _power_blocker {
    my ($code, $detail) = @_;
    return { code => $code, detail => $detail };
}

sub _power_policy_status {
    my ($bdf) = @_;
    my $rec = _collect_device($bdf, 0);
    die "Device '$bdf' not found or not a supported GPU\n" if !defined($rec);
    my $state = power_state_for_bdf($bdf);
    _validate_power_state_record($rec, $state) if ref($state) eq 'HASH';
    my $mode = ref($state) eq 'HASH' ? ($state->{mode} // 'unknown') : 'normal';
    my $runtime = _power_runtime_attributes($bdf);
    my $consumers = _power_consumers($rec, $state);
    my @running = grep { $_->{running} } @$consumers;
    my @pf_consumers = grep { ($_->{vf_index} // 0) == 0 } @$consumers;
    my @blockers;
    my $supported = _is_b50_power_device($rec);
    push @blockers, _power_blocker(
        'unsupported_device',
        'Deep idle is currently limited to the Intel Arc Pro B50 PF (8086:e212).',
    ) if !$supported;
    push @blockers, _power_blocker(
        'driver',
        "The B50 PF must be bound to xe (current: " . ($rec->{driver} || 'unbound') . ').',
    ) if $supported && ($rec->{driver} // '') ne 'xe';
    push @blockers, _power_blocker(
        'pf_assignment',
        'The physical GPU is assigned to a VM; release whole-GPU passthrough first.',
    ) if @pf_consumers;
    push @blockers, _power_blocker(
        'running_consumer',
        'Stop every VM using this GPU: ' . _format_consumers(\@running),
    ) if @running;

    my $persistent_profile = 0;
    my $config_drift = 0;
    my $profile_error = '';
    my $profile_count = $mode eq 'normal'
        ? int($rec->{sriov_numvfs})
        : int($state->{restore_count} // 0);
    if ($profile_count > 0) {
        my $profile;
        my $ok = eval {
            $profile = _persisted_power_profiles($rec, $profile_count);
            1;
        };
        if ($ok) {
            $persistent_profile = 1;
            if ($mode eq 'normal') {
                my $vfs = _vf_records($rec);
                my $scheduler = _read_scheduler_priority($rec);
                my $drift = _calculate_persistence_drift(
                    $rec,
                    $profile->{config},
                    $vfs,
                    $scheduler,
                );
                $config_drift = $drift->{has_drift} ? 1 : 0;
                $profile_error = join('; ', @{$drift->{issues}}) if $config_drift;
            }
        } else {
            $profile_error = $@;
            $profile_error =~ s/\s+\z//;
        }
        if ($mode eq 'normal' && (!$persistent_profile || $config_drift)) {
            push @blockers, _power_blocker(
                'persistent_profile',
                $profile_error || 'Save and verify the current VF profile before entering deep idle.',
            );
        }
    }

    my $effective = $mode ne 'normal' &&
        int($rec->{sriov_numvfs}) == 0 &&
        ($runtime->{control} // '') eq 'auto' &&
        defined($runtime->{autosuspend_delay_ms}) &&
        $runtime->{autosuspend_delay_ms} == $B50_DEEP_IDLE_DELAY_MS;
    my $can_exit = $mode ne 'normal' && $supported && !@running && !@pf_consumers &&
        ($rec->{driver} // '') eq 'xe' &&
        ($profile_count == 0 || $persistent_profile);

    return {
        api_version => 1,
        bdf => $bdf,
        supported => $supported ? \1 : \0,
        mode => $mode,
        effective => $effective ? \1 : \0,
        sleeping => ($runtime->{runtime_status} // '') eq 'suspended' ? \1 : \0,
        runtime_only => \1,
        driver => $rec->{driver},
        active_vfs => int($rec->{sriov_numvfs}),
        saved_vfs => $profile_count,
        persistent_profile => $persistent_profile ? \1 : \0,
        config_drift => $config_drift ? \1 : \0,
        assignments => [map {
            +{
                %$_,
                running => $_->{running} ? \1 : \0,
            }
        } @$consumers],
        blockers => \@blockers,
        can_enter => $mode eq 'normal' && !@blockers ? \1 : \0,
        can_exit => $can_exit ? \1 : \0,
        autosuspend_delay_ms => $runtime->{autosuspend_delay_ms},
        runtime_status => $runtime->{runtime_status},
        runtime_usage => $runtime->{runtime_usage},
        pci_power_state => $runtime->{pci_power_state},
        power_control => $runtime->{control},
        target_autosuspend_delay_ms => $B50_DEEP_IDLE_DELAY_MS,
        profile_error => $profile_error,
    };
}

sub _enter_deep_idle {
    my ($bdf) = @_;
    return _with_gpu_lock(sub {
        my @vmids = _all_qemu_vmids();
        return _with_vm_locks(\@vmids, sub {
            return _with_pci_reservation_lock(sub {
                my $status = _power_policy_status($bdf);
                return $status if $status->{mode} eq 'deep-idle';
                if (!_bool_value($status->{can_enter})) {
                    my $detail = join('; ', map { $_->{detail} } @{$status->{blockers}});
                    die "Cannot enter B50 deep idle: " . ($detail || 'safety state is unavailable') . "\n";
                }

                my $rec = _collect_device($bdf, 0);
                my $count = _read_sriov_numvfs($bdf, "deep-idle VF count for $bdf");
                my $consumers = _power_consumers($rec, undef);
                my @running = grep { $_->{running} } @$consumers;
                die "Cannot enter deep idle while a GPU consumer is running: " .
                    _format_consumers(\@running) . "\n" if @running;

                my $snapshot = _snapshot_state($rec);
                my $runtime = _power_runtime_attributes($bdf);
                die "Runtime power control is unavailable for $bdf\n"
                    if !defined($runtime->{control}) || $runtime->{control} !~ /^(?:auto|on)$/;
                die "Runtime autosuspend delay is unavailable for $bdf\n"
                    if !defined($runtime->{autosuspend_delay_ms});
                my @vf_bdfs = map { $_->{bdf} // '' } @{$snapshot->{drivers}};
                die "Cannot snapshot every VF BDF for $bdf\n"
                    if grep { $_ eq '' } @vf_bdfs;
                my %consumer_vmids = map { $_->{vmid} => 1 } @$consumers;
                my $old_power_state = read_power_state();
                my $state = {
                    api_version => 1,
                    mode => 'entering',
                    restore_count => $count,
                    restore_autoprobe => $snapshot->{autoprobe},
                    restore_scheduler => $snapshot->{scheduler} // '',
                    restore_control => $runtime->{control},
                    restore_delay => $runtime->{autosuspend_delay_ms},
                    vf_bdfs => join(',', @vf_bdfs),
                    consumer_vmids => join(',', sort { $a <=> $b } keys %consumer_vmids),
                };

                set_power_state_for_bdf($bdf, $state);
                my $topology_mutated = 0;
                my $ok = eval {
                    _set_autoprobe($bdf, 0);
                    if ($count > 0) {
                        _unbind_all_vfs($bdf, $count);
                        $topology_mutated = 1;
                        write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0);
                        my $zero = _read_sriov_numvfs($bdf, "deep-idle VF removal for $bdf");
                        die "Deep-idle VF removal verification failed: sriov_numvfs=$zero\n"
                            if $zero != 0;
                    }
                    _set_deep_idle_power_attributes($bdf);
                    _wait_for_deep_idle($bdf, 5_000);
                    $state->{mode} = 'deep-idle';
                    set_power_state_for_bdf($bdf, $state);
                    1;
                };
                my $error = $@;
                if (!$ok) {
                    my @rollback_errors;
                    my $sriov_errors = _rollback_state($rec, $snapshot, $topology_mutated);
                    push @rollback_errors, @$sriov_errors;
                    eval {
                        _write_power_attribute(
                            $bdf,
                            'autosuspend_delay_ms',
                            $runtime->{autosuspend_delay_ms},
                        );
                        _write_power_attribute($bdf, 'control', $runtime->{control});
                    };
                    push @rollback_errors, "power attributes: $@" if $@;
                    eval { write_power_state($old_power_state) };
                    push @rollback_errors, "power state file: $@" if $@;
                    my $detail = @rollback_errors
                        ? ' Rollback also reported: ' . join(' | ', @rollback_errors)
                        : '';
                    die "Entering B50 deep idle failed: $error$detail\n";
                }
                return _power_policy_status($bdf);
            });
        });
    });
}

sub _verify_restored_power_topology {
    my ($rec, $state, $profile) = @_;
    my $expected = int($state->{restore_count} // 0);
    my $actual = _read_sriov_numvfs($rec->{bdf}, "restored VF count for $rec->{bdf}");
    die "Restored VF count mismatch: expected $expected, found $actual\n"
        if $actual != $expected;
    my @saved_bdfs = _saved_power_vf_bdfs($state);
    die "Saved VF BDF count mismatch for $rec->{bdf}: expected $expected, found " .
        scalar(@saved_bdfs) . "\n"
        if @saved_bdfs != $expected;
    for my $vf (1 .. $expected) {
        my $actual_bdf = _vf_bdf($rec->{bdf}, $vf);
        die "Restored VF$vf is unavailable for $rec->{bdf}\n" if !defined($actual_bdf);
        die "Restored VF$vf BDF changed: expected $saved_bdfs[$vf - 1], found $actual_bdf\n"
            if $actual_bdf ne $saved_bdfs[$vf - 1];
        my $expected_driver = $profile->{drivers}{$vf} // '';
        my $actual_driver = _pci_driver($actual_bdf);
        die "Restored VF$vf driver mismatch: expected '" .
            ($expected_driver || 'unbound') . "', found '" .
            ($actual_driver || 'unbound') . "'\n"
            if $actual_driver ne $expected_driver;
    }
    if ($expected > 0) {
        my $updated = _collect_device($rec->{bdf}, 0) // $rec;
        my $vfs = _vf_records($updated);
        my $scheduler = _read_scheduler_priority($updated);
        my $drift = _calculate_persistence_drift(
            $updated,
            $profile->{config},
            $vfs,
            $scheduler,
        );
        die "Restored VF profile verification failed: " . join('; ', @{$drift->{issues}}) . "\n"
            if $drift->{has_drift};
    }
    return 1;
}

sub _rollback_exit_to_deep_idle {
    my ($rec, $state) = @_;
    my @errors;
    eval {
        my $count = _read_sriov_numvfs($rec->{bdf}, "failed-exit VF count for $rec->{bdf}");
        _set_autoprobe($rec->{bdf}, 0);
        if ($count > 0) {
            _unbind_all_vfs($rec->{bdf}, $count);
            write_sysfs("/sys/bus/pci/devices/$rec->{bdf}/sriov_numvfs", 0);
            my $zero = _read_sriov_numvfs($rec->{bdf}, "failed-exit VF removal for $rec->{bdf}");
            die "sriov_numvfs=$zero after failed-exit cleanup\n" if $zero != 0;
        }
    };
    push @errors, "topology: $@" if $@;
    eval { _set_deep_idle_power_attributes($rec->{bdf}) };
    push @errors, "power attributes: $@" if $@;
    eval {
        $state->{mode} = 'deep-idle';
        set_power_state_for_bdf($rec->{bdf}, $state);
    };
    push @errors, "power state file: $@" if $@;
    return \@errors;
}

sub _exit_deep_idle {
    my ($bdf) = @_;
    return _with_gpu_lock(sub {
        my @vmids = _all_qemu_vmids();
        return _with_vm_locks(\@vmids, sub {
            return _with_pci_reservation_lock(sub {
                my $state = power_state_for_bdf($bdf);
                return _power_policy_status($bdf) if ref($state) ne 'HASH';
                my $mode = $state->{mode} // '';
                die "Unknown B50 power state '$mode' for $bdf\n"
                    if $mode !~ /^(?:entering|deep-idle|exiting|restored)$/;
                my $rec = _collect_device($bdf, 0);
                die "Device '$bdf' not found or not a supported GPU\n" if !defined($rec);
                die "Power saving exit is only supported for an Intel B50 PF\n"
                    if !_is_b50_power_device($rec);
                die "Power saving exit requires the B50 PF to remain on xe\n"
                    if ($rec->{driver} // '') ne 'xe';
                _validate_power_state_record($rec, $state);
                my $restore_count = $state->{restore_count};
                $restore_count = int($restore_count);
                my $consumers = _power_consumers($rec, $state);
                my @running = grep { $_->{running} } @$consumers;
                die "Cannot restore B50 VF topology while a GPU consumer is running: " .
                    _format_consumers(\@running) . "\n" if @running;
                my @pf_consumers = grep { ($_->{vf_index} // 0) == 0 } @$consumers;
                die "Cannot restore B50 VF topology while the physical GPU is assigned: " .
                    _format_consumers(\@pf_consumers) . "\n" if @pf_consumers;
                my $profile = $restore_count > 0
                    ? _persisted_power_profiles($rec, $restore_count)
                    : {
                        config => parse_ini_config($GPU_SRIOV_CONF, 1),
                        profiles => [],
                        drivers => {},
                        autoprobe => int($state->{restore_autoprobe} // 0),
                        scheduler => $state->{restore_scheduler} // '',
                    };

                if ($mode eq 'restored') {
                    _verify_restored_power_topology($rec, $state, $profile);
                    _restore_power_attributes($bdf, $state);
                    clear_power_state_for_bdf($bdf);
                    return _power_policy_status($bdf);
                }

                my $ok = eval {
                    $state->{mode} = 'exiting';
                    set_power_state_for_bdf($bdf, $state);
                    my $current = _read_sriov_numvfs($bdf, "pre-restore VF count for $bdf");
                    _set_autoprobe($bdf, 0);
                    if ($current > 0) {
                        _unbind_all_vfs($bdf, $current);
                        write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0);
                        my $zero = _read_sriov_numvfs($bdf, "pre-restore cleanup for $bdf");
                        die "Cannot reset partial VF topology before restore: sriov_numvfs=$zero\n"
                            if $zero != 0;
                    }

                    if ($restore_count > 0) {
                        _prepare_auto_provisioning($rec);
                        write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", $restore_count);
                        _wait_for_vfs($rec, $profile->{profiles}, 10_000);
                        _apply_profiles($rec, $profile->{profiles});
                        _set_scheduler_priority($rec, $profile->{scheduler});
                        for my $vf (1 .. $restore_count) {
                            my $vf_bdf = _vf_bdf($bdf, $vf);
                            die "Cannot resolve restored VF$vf for $bdf\n" if !defined($vf_bdf);
                            _bind_vf_driver($vf_bdf, $profile->{drivers}{$vf})
                                if ($profile->{drivers}{$vf} // '') ne '';
                        }
                    }
                    _set_autoprobe($bdf, $profile->{autoprobe});
                    _verify_restored_power_topology($rec, $state, $profile);
                    _restore_power_attributes($bdf, $state);
                    $state->{mode} = 'restored';
                    set_power_state_for_bdf($bdf, $state);
                    clear_power_state_for_bdf($bdf);
                    1;
                };
                my $error = $@;
                if (!$ok) {
                    my $rollback_errors = _rollback_exit_to_deep_idle($rec, $state);
                    my $detail = @$rollback_errors
                        ? ' Rollback also reported: ' . join(' | ', @$rollback_errors)
                        : '';
                    die "Exiting B50 deep idle failed: $error$detail\n";
                }
                return _power_policy_status($bdf);
            });
        });
    });
}

# ---------------------------------------------------------------------------
# API endpoint definitions
# ---------------------------------------------------------------------------

__PACKAGE__->register_method({
    name        => 'list_devices',
    path        => '',
    method      => 'GET',
    description => 'List Intel discrete GPU devices on this node.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type  => 'array',
        items => { type => 'object' },
        links => [{ rel => 'child', href => '{bdf}' }],
    },
    code => sub {
        my ($param) = @_;
        return _with_gpu_lock(sub {
            my @devices = _enumerate_devices();
            return \@devices;
        });
    },
});

__PACKAGE__->register_method({
    name        => 'device_detail',
    path        => '{bdf}',
    method      => 'GET',
    description => 'Get detailed information for a specific GPU device, including telemetry.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI Bus:Device.Function address (e.g. 0000:03:00.0)',
                pattern     => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $bdf = $param->{bdf};
        return _with_gpu_lock(sub {
            my $rec = _collect_device($bdf, 1);
            die "Device '$bdf' not found or not a supported GPU\n" unless defined $rec;
            return $rec;
        });
    },
});

__PACKAGE__->register_method({
    name        => 'sriov_status',
    path        => '{bdf}/sriov',
    method      => 'GET',
    description => 'Get live SR-IOV state, capabilities, consumers, and persistence drift.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address',
                pattern => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $bdf = $param->{bdf};
        return _with_gpu_lock(sub {
            _assert_power_mode_normal($bdf, 'read SR-IOV status');
            my $rec = _collect_device($bdf, 0);
            die "Device '$bdf' not found or not a supported GPU\n" if !defined($rec);

        my $prechecks = run_prechecks($bdf, $rec->{drm_card}, $rec->{vendor_id});
        my @tile_resources;
        for my $tile (0 .. (int($rec->{tiles}) - 1)) {
            my $available = _read_pf_available($rec, $tile);
            $available->{tile} = $tile;
            push @tile_resources, $available;
        }

        my $persist_config = parse_ini_config($GPU_SRIOV_CONF);
        my $persisted = $persist_config->{$bdf} // {};
        my $current_count = int($rec->{sriov_numvfs});
        my $vfs = _vf_records($rec);
        my $consumers = check_vf_vm_assignments(
            $bdf,
            $rec->{drm_card},
            $current_count,
        );
        my @running = grep { $_->{running} } @$consumers;
        my @assignment_view = map {
            +{
                %$_,
                running => $_->{running} ? \1 : \0,
            }
        } @$consumers;

        my $scheduler = _read_scheduler_priority($rec);
        my $drift = _calculate_persistence_drift(
            $rec,
            $persist_config,
            $vfs,
            $scheduler,
        );

            return {
            api_version => 3,
            bdf => $bdf,
            prechecks => $prechecks,
            capabilities => _device_capabilities($rec),
            sriov_numvfs => $current_count,
            sriov_maxvfs => int($rec->{max_vfs}),
            tile_resources => \@tile_resources,
            scheduler_priority => $scheduler,
            vfs => $vfs,
            assignments => \@assignment_view,
            persisted_config => $persisted,
            persisted_profiles => {
                map {
                    my $prefix = "$bdf/vf";
                    my $index = substr($_, length($prefix));
                    $index => $persist_config->{$_}
                } grep { /^\Q$bdf\E\/vf\d+$/ } keys %$persist_config
            },
            drift => {
                has_drift => $drift->{has_drift} ? \1 : \0,
                count => $drift->{count} ? \1 : \0,
                scheduler => $drift->{scheduler} ? \1 : \0,
                scheduler_unreadable => $drift->{scheduler_unreadable} ? \1 : \0,
                persistence => $drift->{persistence} ? \1 : \0,
                resources => $drift->{resources},
                issues => $drift->{issues},
            },
            config_drift => $drift->{has_drift} ? \1 : \0,
            change_blocked => {
                topology => @$consumers ? \1 : \0,
                resources => @running ? \1 : \0,
                topology_reason => @$consumers
                    ? 'Detach all PF/VF hostpci assignments before rebuilding the topology'
                    : '',
                resources_reason => @running
                    ? 'Stop all consumer VMs before changing VF resources'
                    : '',
            },
            };
        });
    },
});

__PACKAGE__->register_method({
    name        => 'create_vfs',
    path        => '{bdf}/sriov',
    method      => 'POST',
    description => 'Create, reprovision, or update SR-IOV VFs transactionally.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address',
                pattern => $BDF_RE,
            },
            num_vfs => {
                type => 'integer',
                description => 'Number of VFs (0 removes all VFs and their persisted configuration)',
                minimum => 0,
            },
            vf_profiles => {
                type => 'string',
                description => 'JSON array of per-VF auto/custom/unchanged resource profiles',
                optional => 1,
                maxLength => 65536,
            },
            sched_priority => {
                type => 'string',
                description => 'Device-wide xe VF scheduler profile',
                enum => ['unchanged', 'low', 'normal'],
                optional => 1,
                default => 'unchanged',
            },
            allow_unsafe_scheduler => {
                type => 'boolean',
                description => 'Required acknowledgement for the experimental normal scheduler',
                optional => 1,
                default => 0,
            },
            force_reprovision => {
                type => 'boolean',
                description => 'Destroy and recreate the VF topology even when the count is unchanged',
                optional => 1,
                default => 0,
            },
            drivers_autoprobe => {
                type => 'boolean',
                description => 'Automatically probe drivers for newly-created VFs',
                optional => 1,
                default => 0,
            },
            persist => {
                type => 'boolean',
                description => 'Persist the verified configuration for boot-time restore',
                optional => 1,
                default => 1,
            },

            # Legacy uniform fields are accepted for API compatibility.  The
            # v2 UI always sends vf_profiles and never falls back silently.
            lmem_per_vf => {
                type => 'integer',
                description => 'Legacy uniform VRAM quota in bytes',
                optional => 1,
            },
            ggtt_per_vf => {
                type => 'integer',
                description => 'Legacy uniform GGTT quota in bytes',
                optional => 1,
            },
            contexts_per_vf => {
                type => 'integer',
                description => 'Legacy uniform context quota',
                optional => 1,
            },
            doorbells_per_vf => {
                type => 'integer',
                description => 'Legacy uniform doorbell quota',
                optional => 1,
            },
            exec_quantum_ms => {
                type => 'integer',
                description => 'Legacy uniform execution quantum',
                optional => 1,
            },
            preempt_timeout_us => {
                type => 'integer',
                description => 'Legacy uniform preemption timeout',
                optional => 1,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        return _configure_sriov_v2($param->{bdf}, $param);
    },
});

__PACKAGE__->register_method({
    name        => 'remove_vfs',
    path        => '{bdf}/sriov',
    method      => 'DELETE',
    description => 'Remove all SR-IOV VFs after verifying that no VM consumes them.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address',
                pattern => $BDF_RE,
            },
            remove_persist => {
                type => 'boolean',
                description => 'Remove the boot-time configuration (must remain enabled)',
                optional => 1,
                default => 1,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        die "Refusing to leave a boot configuration that would recreate deleted VFs\n"
            if !$param->{remove_persist};
        return _configure_sriov_v2($param->{bdf}, {
            %$param,
            num_vfs => 0,
            persist => 0,
            force_reprovision => 0,
            sched_priority => 'unchanged',
        });
    },
});

# ---------------------------------------------------------------------------
# Full-PF VFIO persistence and verified live driver switching
# ---------------------------------------------------------------------------
my $VFIO_CONF = $ENV{PVE_GPU_VFIO_CONF} // '/etc/pve-gpu-vfio.conf';

sub _assert_vm_can_change_pf_passthrough {
    my ($vmid, $conf) = @_;
    die "VM $vmid configuration is unavailable\n" if ref($conf) ne 'HASH';
    die "Cannot assign a physical GPU to VM $vmid because it is a template\n"
        if _bool_value($conf->{template});
    die "Cannot change physical GPU passthrough while VM $vmid is locked ($conf->{lock})\n"
        if defined($conf->{lock}) && $conf->{lock} ne '';
    die "Stop VM $vmid before changing physical GPU passthrough\n"
        if _vm_is_running($vmid);

    my @pending = _pending_hostpci_changes($conf);
    die "Resolve pending PCI changes for VM $vmid first (" . join(', ', @pending) . ")\n"
        if @pending;
}

sub _assert_vm_can_verify_pf_passthrough {
    my ($vmid, $conf) = @_;
    die "VM $vmid configuration is unavailable\n" if ref($conf) ne 'HASH';
    die "Cannot use a template as a whole-GPU passthrough target (VM $vmid)\n"
        if _bool_value($conf->{template});
    my @pending = _pending_hostpci_changes($conf);
    die "Resolve pending PCI changes for VM $vmid first (" . join(', ', @pending) . ")\n"
        if @pending;
}

sub _snapshot_pf_passthrough_gpu_state {
    my ($rec, $count) = @_;
    if ($count > 0) {
        my $snapshot = _snapshot_state($rec);
        for my $vf (@{$snapshot->{drivers}}) {
            die "Cannot resolve VF$vf->{vf_index} while snapshotting driver state\n"
                if !defined($vf->{bdf});
            my $override = read_sysfs(
                "/sys/bus/pci/devices/$vf->{bdf}/driver_override"
            );
            die "Cannot snapshot driver_override for VF$vf->{vf_index} ($vf->{bdf})\n"
                if !defined($override);
            $vf->{override} = $override;
        }
        return $snapshot;
    }

    my $autoprobe = _read_uint_sysfs(
        "/sys/bus/pci/devices/$rec->{bdf}/sriov_drivers_autoprobe",
        "driver autoprobe state for $rec->{bdf}",
    );
    die "Invalid driver autoprobe state '$autoprobe' for $rec->{bdf}\n"
        if $autoprobe !~ /^[01]$/;

    return {
        count => 0,
        autoprobe => int($autoprobe),
        scheduler => undef,
        path_values => {},
        drivers => [],
        config => _snapshot_file($GPU_SRIOV_CONF),
    };
}

sub _read_vfio_bdfs {
    my ($strict) = @_;
    return [] unless -f $VFIO_CONF;
    my $fh;
    if (!open($fh, '<', $VFIO_CONF)) {
        die "Cannot read VFIO configuration '$VFIO_CONF': $!\n" if $strict;
        return [];
    }
    my @bdfs;
    my $line_number = 0;
    while (my $line = <$fh>) {
        $line_number++;
        chomp $line;
        $line =~ s/#.*//;
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        my $normalised = _normalise_bdf($line);
        die "Invalid PCI BDF '$line' in '$VFIO_CONF' at line $line_number\n"
            if $strict && !defined($normalised);
        push @bdfs, $normalised // $line;
    }
    my $closed = close($fh);
    die "Cannot close VFIO configuration '$VFIO_CONF': $!\n"
        if $strict && !$closed;
    my %seen;
    @bdfs = grep { !$seen{$_}++ } @bdfs;
    return \@bdfs;
}

# ---------------------------------------------------------------------------
# AMD-IOMMU ATS safety policy
# ---------------------------------------------------------------------------
#
# Battlemage B50 PF passthrough can hang an AMD host when PCI ATS is left
# enabled.  Keep the policy state entirely read-only here: the helper owns
# boot-loader configuration and is the only thing this API invokes for policy
# changes.  In particular, none of the PF/VF or VM transaction code may run
# until _assert_ats_safe_for_pf has returned successfully.
sub _ats_policy_helper_path {
    my $path = $ENV{PVE_GPU_ATS_POLICY_HELPER};
    return defined($path) && $path ne ''
        ? $path
        : '/usr/lib/pve-gpu/manage-ats-policy.sh';
}

sub _read_host_file {
    my ($path) = @_;
    my $full = sysfs_path($path);
    open(my $fh, '<', $full) or return (0, undef, "$!");
    local $/;
    my $contents = <$fh>;
    my $closed = close($fh);
    return (0, undef, "$!") if !$closed;
    return (1, $contents // '', undef);
}

sub _ats_cpu_vendor {
    my ($ok, $contents, $error) = _read_host_file('/proc/cpuinfo');
    return ($contents =~ /^\s*vendor_id\s*:\s*(\S+)/mi)
        ? $1
        : ''
        if $ok;
    return '';
}

sub _ats_bool_from_value {
    my ($value) = @_;
    return undef if !defined($value);
    return 1 if $value eq '1';
    return 0 if $value eq '0';
    return undef;
}

sub _ats_command_capture {
    my ($command) = @_;
    my ($stdout, $stderr, $exit_code) = ('', '', undef);
    my $ok = eval {
        $exit_code = run_command(
            $command,
            # PVE::Tools delivers callbacks one line at a time without the
            # line ending.  Keep a separator so independent lspci/status
            # lines cannot be joined into one token by the parser.  The
            # callback guards also keep test doubles that pass undef benign.
            outfunc => sub {
                $stdout .= $_[0] . "\n" if defined($_[0]);
            },
            errfunc => sub {
                $stderr .= $_[0] . "\n" if defined($_[0]);
            },
            noerr => 1,
        );
        1;
    };
    my $error = $@;
    my $success = $ok && (!defined($exit_code) || $exit_code == 0);
    return {
        success   => $success ? 1 : 0,
        exit_code => $exit_code,
        stdout    => $stdout,
        stderr    => $stderr,
        error     => $error,
    };
}

sub _ats_policy_identity {
    my ($bdf) = @_;
    $bdf = _normalise_bdf($bdf);
    die "Invalid GPU BDF for ATS policy\n" if !defined($bdf);

    my $vendor_raw = read_sysfs("/sys/bus/pci/devices/$bdf/vendor");
    my $device_raw = read_sysfs("/sys/bus/pci/devices/$bdf/device");
    my @identity_errors;
    push @identity_errors, "Cannot read PCI vendor identity for $bdf"
        if !defined($vendor_raw) || $vendor_raw !~ /^(?:0x)?[0-9a-fA-F]{4}$/;
    push @identity_errors, "Cannot read PCI device identity for $bdf"
        if !defined($device_raw) || $device_raw !~ /^(?:0x)?[0-9a-fA-F]{4}$/;

    my $vendor = $vendor_raw // '';
    my $device = $device_raw // '';
    $vendor = lc($vendor);
    $device = lc($device);
    $vendor =~ s/^0x//;
    $device =~ s/^0x//;

    # A VF carries the same PCI device ID as its PF.  ATS policy is a PF
    # policy only; never classify a VF as the affected B50 device.
    my $is_pf = !-l sysfs_path("/sys/bus/pci/devices/$bdf/physfn");
    my $is_b50_pf = $is_pf && $vendor eq '8086' && $device eq 'e212';
    my $cpu_vendor = _ats_cpu_vendor();

    # Missing CPU identity is treated as affected for a known B50 PF, but it
    # also makes the safety state unknown below.  This keeps passthrough
    # fail-closed if /proc/cpuinfo is masked or malformed; a known non-AMD
    # CPU is explicitly outside this workaround.
    my $cpu_is_amd = lc($cpu_vendor) eq 'authenticamd';
    my $cpu_is_intel = lc($cpu_vendor) eq 'genuineintel';
    my $cpu_unknown = !$cpu_is_amd && !$cpu_is_intel;
    push @identity_errors, 'Cannot determine host CPU vendor'
        if $is_b50_pf && $cpu_unknown;

    # An unreadable PCI identity is not evidence that a BDF is harmless.  It
    # is represented as affected so callers that gate writes fail closed;
    # policy mutation still requires the exact known B50+AMD identity below.
    my $hardware_identity_unknown = !defined($vendor_raw) ||
        $vendor_raw !~ /^(?:0x)?[0-9a-fA-F]{4}$/ ||
        !defined($device_raw) ||
        $device_raw !~ /^(?:0x)?[0-9a-fA-F]{4}$/;
    my $affected = (!$is_pf ? 0 : $hardware_identity_unknown)
        || ($is_b50_pf && ($cpu_is_amd || $cpu_unknown));

    return {
        bdf        => $bdf,
        vendor     => $vendor,
        device     => $device,
        is_pf      => $is_pf ? 1 : 0,
        is_b50_pf  => $is_b50_pf ? 1 : 0,
        cpu_vendor => $cpu_vendor,
        identity_error => @identity_errors ? join('; ', @identity_errors) : undef,
        affected   => $affected ? 1 : 0,
    };
}

sub _ats_affected_b50_pfs {
    my ($target_identity) = @_;
    my %bdfs;
    my @identity_errors;

    # The no-ATS policy is host-wide, so disabling it must account for every
    # affected PF, not only the BDF named by the request.  An unreadable PF
    # might itself be another B50, so a host-wide policy removal must fail
    # closed instead of silently excluding it from the consumer/driver scan.
    my $devices = sysfs_path('/sys/bus/pci/devices');
    opendir(my $devices_dh, $devices)
        or die "Cannot safely remove the host-wide no-ATS policy because PCI devices cannot be enumerated at '$devices': $!\n";
    my @device_entries = grep { $_ ne '.' && $_ ne '..' } readdir($devices_dh);
    closedir($devices_dh)
        or die "Cannot safely remove the host-wide no-ATS policy because PCI device enumeration could not be completed at '$devices': $!\n";
    die "Cannot safely remove the host-wide no-ATS policy because PCI device enumeration returned no devices at '$devices'\n"
        if !@device_entries;

    for my $entry (sort @device_entries) {
        my $candidate = _normalise_bdf($entry);
        next if !defined($candidate);
        my $identity = eval { _ats_policy_identity($candidate) };
        if (!$identity) {
            my $detail = $@ || 'identity probe returned no state';
            $detail =~ s/\s+\z//;
            push @identity_errors, "$candidate: $detail";
            next;
        }
        if ($identity->{is_pf} &&
            ($identity->{identity_error} // '') =~ /PCI (?:vendor|device) identity/i) {
            # Unknown CPU identity is relevant only to an exact B50 PF and is
            # already carried by its affected identity.  What makes a second
            # arbitrary PF impossible to classify here is unreadable PCI
            # vendor/device identity.
            push @identity_errors, "$candidate: $identity->{identity_error}";
            next;
        }
        next if !$identity->{is_b50_pf} || !$identity->{affected};
        $bdfs{$identity->{bdf}} = 1;
    }

    die "Cannot safely remove the host-wide no-ATS policy because PCI PF identity is unknown: " .
        join('; ', @identity_errors) . "\n"
        if @identity_errors;

    if ($target_identity && $target_identity->{is_b50_pf} &&
        $target_identity->{affected}) {
        $bdfs{$target_identity->{bdf}} = 1;
    }

    return \%bdfs;
}

sub _ats_active_noats {
    my ($ok, $contents, $error) = _read_host_file('/proc/cmdline');
    my $active = 0;
    if ($ok) {
        $active = scalar(grep { $_ eq 'pci=noats' } split(/\s+/, $contents // ''))
            ? 1 : 0;
    }
    return {
        active => $active,
        error  => $ok ? undef : "Cannot read /proc/cmdline: $error",
    };
}

sub _ats_lspci_state {
    my ($bdf) = @_;
    my $result = _ats_command_capture(['lspci', '-vv', '-s', $bdf]);
    my $output = $result->{stdout} // '';
    my $ats_supported = ($output =~ /^\s*ATSCap\s*:/mi ||
        $output =~ /^\s*ATSCtl\s*:/mi) ? 1 : 0;

    my ($enable, $disable) = (0, 0);
    while ($output =~ /^\s*ATSCtl\s*:\s*([^\r\n]*)/gmi) {
        my $line = $1;
        $enable = 1 if $line =~ /\bEnable\+/i;
        $disable = 1 if $line =~ /\bEnable-/i;
    }

    my $ats_enabled;
    my $explicit_disabled = 0;
    my $state_error;
    if ($enable && !$disable) {
        $ats_enabled = 1;
    } elsif ($disable && !$enable) {
        $ats_enabled = 0;
        $explicit_disabled = 1;
    } elsif ($enable && $disable) {
        $state_error = 'lspci reported both ATSCtl Enable+ and Enable-';
    } else {
        $state_error = 'lspci did not report an explicit ATSCtl Enable+/Enable- state';
    }

    if (!$result->{success}) {
        my $detail = $result->{error} || $result->{stderr} ||
            (defined($result->{exit_code}) ? "exit $result->{exit_code}" : 'unknown failure');
        $detail =~ s/\s+\z//;
        $state_error = "lspci failed: $detail";
    }

    return {
        ats_supported    => $ats_supported,
        ats_enabled      => defined($ats_enabled) ? $ats_enabled : 0,
        explicit_disabled => $explicit_disabled,
        error            => $state_error,
    };
}

sub _ats_helper_status {
    my $helper = _ats_policy_helper_path();
    my $result = _ats_command_capture([$helper, 'status']);
    my %values;
    for my $line (split(/\R/, $result->{stdout} // '')) {
        $line =~ s/\r\z//;
        $line =~ s/^\s+|\s+\z//g;
        next if $line eq '' || $line =~ /^#/;
        next if $line !~ /^([A-Za-z][A-Za-z0-9_.-]*)\s*=\s*(.*?)\s*\z/;
        $values{lc($1)} = $2;
    }

    my $persistent_raw = $values{persistent_noats};
    my $managed_raw = $values{managed};
    my $boot_mode = $values{boot_mode} // '';
    my $persistent = _ats_bool_from_value($persistent_raw);
    my $managed = _ats_bool_from_value($managed_raw);
    my @errors;
    if (!$result->{success}) {
        my $detail = $result->{error} || $result->{stderr} ||
            (defined($result->{exit_code}) ? "exit $result->{exit_code}" : 'unknown failure');
        $detail =~ s/\s+\z//;
        push @errors, "ATS policy helper '$helper status' failed: $detail";
    }
    push @errors, 'ATS policy helper status requires canonical persistent_noats=0 or 1'
        if !defined($persistent);
    push @errors, 'ATS policy helper status requires canonical managed=0 or 1'
        if !defined($managed);
    push @errors, 'ATS policy helper status has an invalid boot_mode'
        if $boot_mode !~ /^(?:grub|proxmox-boot-tool|systemd-boot)$/;

    return {
        boot_mode       => $boot_mode,
        persistent_noats => defined($persistent) ? $persistent : 0,
        managed         => defined($managed) ? $managed : 0,
        helper_ok       => !@errors ? 1 : 0,
        error           => @errors ? join('; ', @errors) : undef,
        values          => \%values,
    };
}

sub _ats_policy_state {
    my ($bdf) = @_;
    my $identity = _ats_policy_identity($bdf);
    my $active = _ats_active_noats();
    my $state = {
        %$identity,
        active_noats => $active->{active},
        active_error => $active->{error},
        ats_supported => 0,
        ats_enabled => 0,
        explicit_disabled => 0,
        boot_mode => '',
        persistent_noats => 0,
        managed => 0,
        helper_ok => 1,
        helper_error => undef,
        lspci_error => undef,
        safe => 1,
        reboot_required => 0,
        reason => 'Device/CPU is outside the AMD ATS affected set',
    };

    my $lspci = _ats_lspci_state($identity->{bdf});
    $state->{ats_supported} = $lspci->{ats_supported};
    $state->{ats_enabled} = $lspci->{ats_enabled};
    $state->{explicit_disabled} = $lspci->{explicit_disabled};
    $state->{lspci_error} = $lspci->{error};

    my $helper = _ats_helper_status();
    $state->{boot_mode} = $helper->{boot_mode};
    $state->{persistent_noats} = $helper->{persistent_noats};
    $state->{managed} = $helper->{managed};
    $state->{helper_ok} = $helper->{helper_ok};
    $state->{helper_error} = $helper->{error};

    $state->{safe} = $state->{active_noats} &&
        $state->{explicit_disabled} &&
        !$state->{lspci_error} &&
        $state->{persistent_noats} &&
        $state->{helper_ok} &&
        !$state->{identity_error} ? 1 : 0;
    # Any difference between the running and future boot policy needs a
    # reboot to converge.  This also covers removing a managed policy while
    # pci=noats is still active in the current kernel.
    $state->{reboot_required} =
        $state->{persistent_noats} != $state->{active_noats} ? 1 : 0;

    # A known non-affected device is always safe for this B50 workaround,
    # but still reports the live cmdline, lspci, and helper fields above so
    # the GET contract is complete.
    if (!$state->{affected}) {
        # Keep the invariant on the internal state as well as the public
        # response.  A failed optional helper probe must not turn an
        # unrelated GPU into an ATS-gated device.
        $state->{safe} = 1;
        return $state;
    }

    my @reasons;
    push @reasons, $state->{identity_error} if $state->{identity_error};
    push @reasons, $state->{active_error} if $state->{active_error};
    push @reasons, $state->{helper_error} if $state->{helper_error};
    if (!$state->{active_noats} && $state->{persistent_noats}) {
        push @reasons, 'persistent pci=noats policy is configured but not active; reboot is required';
    } elsif ($state->{active_noats} && !$state->{persistent_noats}) {
        push @reasons, 'pci=noats is active only for this boot and is not persistent; persist the policy first';
    } elsif (!$state->{persistent_noats}) {
        push @reasons, 'persistent pci=noats policy is not configured';
    }
    push @reasons, $state->{lspci_error} if $state->{lspci_error};
    push @reasons, 'ATS is not explicitly disabled (ATSCtl Enable-)'
        if !$state->{explicit_disabled};

    if (@reasons) {
        $state->{reason} = join('; ', @reasons) .
            '. Enable the persistent no-ATS policy (pci=noats), reboot, and retry.';
    } else {
        $state->{reason} = 'pci=noats is active and persistent; ATS is explicitly disabled (ATSCtl Enable-)';
    }

    return $state;
}

sub _ats_policy_status_unlocked {
    my ($bdf) = @_;
    my $state = _ats_policy_state($bdf);
    my $safe = $state->{affected}
        ? ($state->{safe} ? 1 : 0)
        : 1;
    return {
        affected        => $state->{affected} ? \1 : \0,
        cpu_vendor      => $state->{cpu_vendor},
        active_noats    => $state->{active_noats} ? \1 : \0,
        ats_supported   => $state->{ats_supported} ? \1 : \0,
        ats_enabled     => $state->{ats_enabled} ? \1 : \0,
        boot_mode       => $state->{boot_mode} // '',
        persistent_noats => $state->{persistent_noats} ? \1 : \0,
        managed         => $state->{managed} ? \1 : \0,
        safe            => $safe ? \1 : \0,
        reboot_required => $state->{reboot_required} ? \1 : \0,
        reason          => $state->{affected}
            ? ($state->{reason} // 'ATS safety policy is not verified')
            : 'Device/CPU is outside the AMD ATS affected set',
    };
}

sub _ats_policy_status {
    my ($bdf) = @_;
    return _with_gpu_lock(sub {
        _assert_power_mode_normal($bdf, 'read ATS policy');
        return _ats_policy_status_unlocked($bdf);
    });
}

# Publicly useful aliases for API tests and downstream callers that used the
# older read_* naming while this policy was being developed.
sub _read_ats_policy_status { return _ats_policy_status(@_); }
sub _get_ats_policy_status { return _ats_policy_status(@_); }

sub _assert_ats_safe_for_pf {
    my ($bdf) = @_;
    my $state = _ats_policy_state($bdf);
    return $state if !$state->{affected} || $state->{safe};

    my $reason = $state->{reason} //
        'AMD ATS safety policy is not verified';
    die "Refusing unsafe PF passthrough for $state->{bdf}: $reason\n";
}

sub _run_ats_policy_action {
    my ($action) = @_;
    die "Invalid ATS policy action\n"
        if !defined($action) || $action !~ /^(?:enable|disable)$/;
    my $helper = _ats_policy_helper_path();
    my $result = _ats_command_capture([$helper, $action]);
    return 1 if $result->{success};
    my $detail = $result->{error} || $result->{stderr} ||
        (defined($result->{exit_code}) ? "exit $result->{exit_code}" : 'unknown failure');
    $detail =~ s/\s+\z//;
    die "ATS policy helper '$helper $action' failed: $detail\n";
}

sub _enable_ats_policy {
    my ($bdf) = @_;
    return _with_gpu_lock(sub {
        _assert_power_mode_normal($bdf, 'change ATS policy');
        # Validate the target before invoking a helper so an accidental request
        # cannot modify host boot policy for a malformed/non-PCI identifier.
        my $identity = _ats_policy_identity($bdf);
        die "The no-ATS workaround is only available for an Intel B50 PF (8086:e212) on an AuthenticAMD host\n"
            if !$identity->{is_b50_pf} ||
               lc($identity->{cpu_vendor} // '') ne 'authenticamd';
        _run_ats_policy_action('enable');
        return _ats_policy_status_unlocked($bdf);
    });
}

sub _disable_ats_policy {
    my ($bdf) = @_;

    # Capture and validate the requested endpoint before taking the GPU lock.
    # The host-wide device enumeration below is deliberately repeated while
    # all mutation locks are held.  If sysfs disappears between these two
    # probes, enumeration must report that uncertainty instead of degrading
    # the target into a generic "not a B50" classification.
    _assert_power_mode_normal($bdf, 'change ATS policy');
    my $target_identity = _ats_policy_identity($bdf);
    die "The no-ATS workaround is only available for an Intel B50 PF (8086:e212) on an AuthenticAMD host\n"
        if !$target_identity->{is_b50_pf} ||
           lc($target_identity->{cpu_vendor} // '') ne 'authenticamd';

    return _with_gpu_lock(sub {
        _assert_power_mode_normal($bdf, 'change ATS policy');

        my @vmids = _all_qemu_vmids();
        return _with_vm_locks(\@vmids, sub {
            return _with_pci_reservation_lock(sub {
                my $affected_pfs = _ats_affected_b50_pfs($target_identity);
                my $initial = _ats_policy_state($bdf);

                # The helper controls a host-wide boot argument.  Revalidate
                # the endpoint after enumeration so identity changes cannot
                # authorize removal using the earlier snapshot.
                die "The no-ATS workaround is only available for an Intel B50 PF (8086:e212) on an AuthenticAMD host\n"
                    if !$initial->{is_b50_pf} ||
                       lc($initial->{cpu_vendor} // '') ne 'authenticamd';

                # A failed status probe is not a reason to proceed with a
                # destructive policy change: the helper may be absent,
                # unreadable, or returning a partial status.  No GPU or VM
                # mutation occurs on this path.
                die "Cannot safely disable ATS policy for $initial->{bdf}: " .
                    ($initial->{helper_error} // 'ATS policy status is unavailable') . "\n"
                    if !$initial->{helper_ok};

                if ($initial->{affected}) {
                    my $consumers = _scan_qemu_pci_consumers(
                        $affected_pfs,
                        1,
                    );
                    my @pf_consumers = grep {
                        $affected_pfs->{$_->{bdf}}
                    } @$consumers;
                    if (@pf_consumers) {
                        my $who = join(', ', map {
                            "B50 PF $_->{bdf} consumed by VM $_->{vmid} ($_->{key})"
                        } @pf_consumers);
                        die "Cannot disable ATS policy for $initial->{bdf}: " .
                            "an affected B50 PF is still consumed by $who; detach it first\n";
                    }

                    my $vfio_bdfs = _read_vfio_bdfs(1);
                    my @persistent_pfs = grep { $affected_pfs->{$_} } @$vfio_bdfs;
                    if (@persistent_pfs) {
                        die "Cannot disable ATS policy for $initial->{bdf}: " .
                            "a VFIO persistent policy still names affected B50 PF " .
                            join(', ', @persistent_pfs) .
                            "; unbind it and remove the persistence entry first\n";
                    }

                    for my $affected_bdf (sort keys %$affected_pfs) {
                        my $driver = _pci_driver($affected_bdf);
                        die "Cannot disable ATS policy for $initial->{bdf}: " .
                            "affected B50 PF $affected_bdf is still bound to vfio-pci; " .
                            "bind it back to xe first\n"
                            if $driver eq 'vfio-pci';
                    }
                }

                _run_ats_policy_action('disable');
                return _ats_policy_status_unlocked($initial->{bdf});
            });
        });
    });
}

sub _set_vfio_configured {
    my ($bdf, $enabled) = @_;
    my $snapshot = _snapshot_file($VFIO_CONF);
    my @kept;
    my $found = 0;

    for my $line (split(/\n/, $snapshot->{contents}, -1)) {
        my $effective = $line;
        $effective =~ s/#.*//;
        $effective =~ s/^\s+|\s+$//g;
        if ($effective ne '') {
            my $normalised = _normalise_bdf($effective);
            die "Invalid PCI BDF '$effective' in '$VFIO_CONF'\n"
                if !defined($normalised);
            if ($normalised eq $bdf) {
                $found = 1;
                next;
            }
        }
        push @kept, $line;
    }

    pop @kept while @kept && $kept[-1] eq '';
    push @kept, $bdf if $enabled;
    my $contents = @kept ? join("\n", @kept) . "\n" : '';
    my $old_enabled = $found ? 1 : 0;
    return 0 if $old_enabled == ($enabled ? 1 : 0) &&
        $contents eq $snapshot->{contents};

    file_set_contents($VFIO_CONF, $contents);
    return 1;
}

sub _switch_to_pf_passthrough {
    my ($bdf, $target_vmid) = @_;
    $bdf = _normalise_bdf($bdf);
    die "Invalid physical GPU BDF\n" if !defined($bdf);
    $target_vmid = int($target_vmid // 0);
    die "A valid target QEMU VM ID is required\n" if $target_vmid < 1;

    return _with_gpu_lock(sub {
        _assert_power_mode_normal($bdf, 'enable whole-GPU passthrough');
        my @vmids = _all_qemu_vmids();
        my %known_vmid = map { $_ => 1 } @vmids;
        die "QEMU VM $target_vmid does not exist on this node\n"
            if !$known_vmid{$target_vmid};

        return _with_vm_locks(\@vmids, sub {
            return _with_pci_reservation_lock(sub {
                my $rec = _collect_device($bdf, 0);
                die "Device '$bdf' not found or not a supported GPU\n"
                    if !defined($rec);
                die "Refusing to switch a PCI VF as though it were a physical GPU\n"
                    if -l sysfs_path("/sys/bus/pci/devices/$bdf/physfn");

                # This is deliberately before every topology, driver,
                # persistence, or VM configuration write below.  The check
                # itself is read-only and fails closed for the affected
                # B50/AMD-IOMMU combination.
                _assert_ats_safe_for_pf($bdf);

                my @current_vmids = _all_qemu_vmids();
                die "The QEMU VM set changed while preparing whole-GPU passthrough; retry the operation\n"
                    if join(',', @current_vmids) ne join(',', @vmids);

                my $num_vfs = _read_sriov_numvfs(
                    $bdf,
                    "VF count for $bdf",
                );
                my %gpu_bdfs = ($bdf => 1);
                for my $vf_index (1 .. $num_vfs) {
                    my $vf_bdf = _validate_vf_bdf($rec, $vf_index);
                    $gpu_bdfs{$vf_bdf} = 1;
                }

                my $consumers = _scan_qemu_pci_consumers(\%gpu_bdfs, 1);
                for my $consumer (@$consumers) {
                    die "VM $consumer->{vmid} became a PCI consumer after the VM lock set was acquired; retry the operation\n"
                        if !$known_vmid{$consumer->{vmid}};
                }
                my %affected_vmids = ($target_vmid => 1);
                $affected_vmids{$_->{vmid}} = 1 for @$consumers;

                my (%configs, %snapshots);
                for my $vmid (sort { $a <=> $b } keys %affected_vmids) {
                    my $conf = PVE::QemuConfig->load_config($vmid);
                    $configs{$vmid} = $conf;
                    $snapshots{$vmid} = dclone($conf);
                }

                my %consumer_keys;
                for my $consumer (@$consumers) {
                    my $identity = "$consumer->{vmid}|$consumer->{key}";
                    $consumer_keys{$identity} = {
                        vmid => int($consumer->{vmid}),
                        key => $consumer->{key},
                    };
                }

                for my $entry (values %consumer_keys) {
                    my ($vmid, $key) = @$entry{qw(vmid key)};
                    die "VM $vmid no longer contains $key; retry the operation\n"
                        if !exists($configs{$vmid}{$key});
                    _assert_exact_gpu_hostpci_entry(
                        $vmid,
                        $key,
                        $configs{$vmid}{$key},
                        \%gpu_bdfs,
                    );
                }

                my $preserved_target_key;
                my @pf_consumers = grep { $_->{bdf} eq $bdf } @$consumers;
                if (@pf_consumers == 1 &&
                    int($pf_consumers[0]{vmid}) == $target_vmid) {
                    my $key = $pf_consumers[0]{key};
                    my $value = $configs{$target_vmid}{$key};
                    if (defined($value) && $value !~ /(?:^|,)mapping=/) {
                        my @resolved = _resolve_hostpci_bdfs($value, 1);
                        $preserved_target_key = $key
                            if @resolved == 1 && $resolved[0] eq $bdf;
                    }
                }

                my $current_driver = _pci_driver($bdf);
                die "Refusing to switch physical GPU $bdf from unsupported current driver '" .
                    ($current_driver || 'unbound') . "'\n"
                    if $current_driver !~ /^(?:xe|vfio-pci)$/;
                die "Active VFs on $bdf require the xe PF driver before whole-GPU passthrough\n"
                    if $num_vfs > 0 && $current_driver ne 'xe';

                my $override = read_sysfs(
                    "/sys/bus/pci/devices/$bdf/driver_override"
                );
                die "Cannot snapshot driver_override for physical GPU $bdf\n"
                    if !defined($override);
                my $normal_override = $override eq '(null)' ? '' : $override;
                my $driver_changes = $current_driver ne 'vfio-pci' ||
                    $normal_override ne '';

                my $sriov_config = parse_ini_config($GPU_SRIOV_CONF, 1);
                my @sriov_profiles = grep { /^\Q$bdf\E\/vf\d+$/ } keys %$sriov_config;
                my $sriov_persistence_present =
                    exists($sriov_config->{$bdf}) || @sriov_profiles;
                my $vfio_bdfs = _read_vfio_bdfs(1);
                my $vfio_configured = grep { $_ eq $bdf } @$vfio_bdfs;

                if (defined($preserved_target_key) && @$consumers == 1 &&
                    $num_vfs == 0 && !$driver_changes &&
                    !$sriov_persistence_present && $vfio_configured) {
                    _assert_vm_can_verify_pf_passthrough(
                        $target_vmid,
                        $configs{$target_vmid},
                    );
                    return {
                        success => \1,
                        changed => \0,
                        bdf => $bdf,
                        vmid => $target_vmid,
                        hostpci => $preserved_target_key,
                        driver => 'vfio-pci',
                        sriov_numvfs => 0,
                        vfio_configured => \1,
                        detached_vmids => [],
                        reboot_required => \0,
                    };
                }

                _assert_vm_can_change_pf_passthrough($_, $configs{$_})
                    for sort { $a <=> $b } keys %affected_vmids;

                my (%changed_vmids, %detached_vmids);
                for my $identity (sort keys %consumer_keys) {
                    my $entry = $consumer_keys{$identity};
                    my ($vmid, $key) = @$entry{qw(vmid key)};
                    next if defined($preserved_target_key) &&
                        $vmid == $target_vmid && $key eq $preserved_target_key;
                    delete $configs{$vmid}{$key};
                    $changed_vmids{$vmid} = 1;
                    $detached_vmids{$vmid} = 1;
                }

                my $target_key = $preserved_target_key;
                if (!defined($target_key)) {
                    $target_key = _first_free_hostpci_key($configs{$target_vmid});
                    $configs{$target_vmid}{$target_key} = _format_pf_hostpci_value(
                        $configs{$target_vmid},
                        $bdf,
                    );
                    $changed_vmids{$target_vmid} = 1;
                }

                my @changed_vmids = sort { $a <=> $b } keys %changed_vmids;
                _validate_qemu_hostpci_config($_, $configs{$_}) for @changed_vmids;

                my $gpu_snapshot = _snapshot_pf_passthrough_gpu_state(
                    $rec,
                    $num_vfs,
                );
                my $vfio_snapshot = _snapshot_file($VFIO_CONF);
                my ($gpu_state_touched, $topology_touched, $driver_touched,
                    $vfio_touched) = (0, 0, 0, 0);
                my @vm_write_attempted;

                my $ok = eval {
                    if ($num_vfs > 0) {
                        $gpu_state_touched = 1;
                        $topology_touched = 1;
                        _set_autoprobe($bdf, 0);
                        _unbind_all_vfs($bdf, $num_vfs);
                        write_sysfs("/sys/bus/pci/devices/$bdf/sriov_numvfs", 0);
                        my $actual_count = _read_sriov_numvfs(
                            $bdf,
                            "whole-GPU VF removal verification for $bdf",
                        );
                        die "VF removal verification failed: sriov_numvfs=$actual_count\n"
                            if $actual_count != 0;
                    }

                    if ($sriov_persistence_present) {
                        $gpu_state_touched = 1;
                        _remove_persisted_config($bdf);
                    }

                    if ($driver_changes) {
                        $driver_touched = 1;
                        _set_vf_driver_state($bdf, 'vfio-pci');
                    }
                    if (!$vfio_configured) {
                        $vfio_touched = 1;
                        _set_vfio_configured($bdf, 1);
                    }

                    for my $vmid (@changed_vmids) {
                        push @vm_write_attempted, $vmid;
                        PVE::QemuConfig->write_config($vmid, $configs{$vmid});
                    }

                    my $actual_count = _read_sriov_numvfs(
                        $bdf,
                        "whole-GPU final VF count for $bdf",
                    );
                    die "Whole-GPU passthrough requires sriov_numvfs=0 (found $actual_count)\n"
                        if $actual_count != 0;
                    my $actual_driver = _pci_driver($bdf);
                    die "Physical GPU driver verification failed: expected 'vfio-pci', found '" .
                        ($actual_driver || 'unbound') . "'\n"
                        if $actual_driver ne 'vfio-pci';
                    my $actual_override = read_sysfs(
                        "/sys/bus/pci/devices/$bdf/driver_override"
                    );
                    $actual_override = '' if defined($actual_override) &&
                        $actual_override eq '(null)';
                    die "Physical GPU driver_override was not cleared for $bdf\n"
                        if !defined($actual_override) || $actual_override ne '';

                    my $actual_vfio = _read_vfio_bdfs(1);
                    die "VFIO persistence verification failed for $bdf\n"
                        if !grep { $_ eq $bdf } @$actual_vfio;
                    my $actual_sriov = parse_ini_config($GPU_SRIOV_CONF, 1);
                    my @actual_profiles = grep { /^\Q$bdf\E\/vf\d+$/ } keys %$actual_sriov;
                    die "SR-IOV persistence removal verification failed for $bdf\n"
                        if exists($actual_sriov->{$bdf}) || @actual_profiles;

                    my $after_consumers = _scan_qemu_pci_consumers(\%gpu_bdfs, 1);
                    die "Whole-GPU VM assignment verification failed for VM $target_vmid\n"
                        if @$after_consumers != 1 ||
                           $after_consumers->[0]{bdf} ne $bdf ||
                           int($after_consumers->[0]{vmid}) != $target_vmid ||
                           $after_consumers->[0]{key} ne $target_key;
                    1;
                };

                if (!$ok) {
                    my $error = $@ || 'unknown whole-GPU passthrough failure';
                    my @rollback_errors;
                    if ($driver_touched) {
                        eval {
                            _restore_vf_driver_state(
                                $bdf,
                                $current_driver,
                                $override,
                            )
                        };
                        push @rollback_errors, "GPU driver: $@" if $@;
                    }
                    if ($vfio_touched) {
                        eval { _restore_file_snapshot($VFIO_CONF, $vfio_snapshot) };
                        push @rollback_errors, "VFIO persistence: $@" if $@;
                    }
                    if ($gpu_state_touched) {
                        my $gpu_errors = _rollback_state(
                            $rec,
                            $gpu_snapshot,
                            $topology_touched,
                        );
                        push @rollback_errors, @$gpu_errors;
                    }
                    push @rollback_errors, _rollback_qemu_configs(
                        \%snapshots,
                        \@vm_write_attempted,
                    ) if @vm_write_attempted;
                    $error .= "Rollback also failed: " . join('; ', @rollback_errors) . "\n"
                        if @rollback_errors;
                    die $error;
                }

                return {
                    success => \1,
                    changed => \1,
                    bdf => $bdf,
                    vmid => $target_vmid,
                    hostpci => $target_key,
                    driver => 'vfio-pci',
                    sriov_numvfs => 0,
                    vfio_configured => \1,
                    detached_vmids => [sort { $a <=> $b } keys %detached_vmids],
                    reboot_required => \0,
                };
            });
        });
    });
}

sub _set_pf_driver {
    my ($bdf, $target_driver) = @_;
    $bdf = _normalise_bdf($bdf);
    die "Invalid physical GPU BDF\n" if !defined($bdf);
    die "Unsupported physical GPU driver '$target_driver'\n"
        if $target_driver !~ /^(?:xe|vfio-pci)$/;

    return _with_gpu_lock(sub {
        _assert_power_mode_normal($bdf, 'switch the physical GPU driver');
        my @vmids = _all_qemu_vmids();
        return _with_vm_locks(\@vmids, sub {
            return _with_pci_reservation_lock(sub {
                my $rec = _collect_device($bdf, 0);
                die "Device '$bdf' not found or not a supported GPU\n"
                    if !defined($rec);
                die "Refusing to switch a PCI VF as though it were a physical GPU\n"
                    if -l sysfs_path("/sys/bus/pci/devices/$bdf/physfn");

                # Binding a PF to vfio-pci is just as dangerous as the
                # whole-PF convenience transaction.  Keep unbind-to-xe
                # available as a recovery path, even while ATS is unsafe.
                _assert_ats_safe_for_pf($bdf)
                    if $target_driver eq 'vfio-pci';

                my @current_vmids = _all_qemu_vmids();
                die "The QEMU VM set changed while preparing the driver switch; retry the operation\n"
                    if join(',', @current_vmids) ne join(',', @vmids);

                my $num_vfs = _read_uint_sysfs(
                    "/sys/bus/pci/devices/$bdf/sriov_numvfs",
                    "VF count for $bdf",
                );
                my $consumers = check_vf_vm_assignments(
                    $bdf,
                    $rec->{drm_card},
                    $num_vfs,
                    1,
                );
                my $current_driver = _pci_driver($bdf);
                die "Refusing to switch physical GPU $bdf from unsupported current driver '" .
                    ($current_driver || 'unbound') . "'\n"
                    if $current_driver !~ /^(?:xe|vfio-pci)$/;
                my $driver_changes = $current_driver ne $target_driver;
                if ($driver_changes && @$consumers) {
                    die "Detach every PF/VF hostpci assignment before switching $bdf from '" .
                        ($current_driver || 'unbound') . "' to '$target_driver': " .
                        _format_consumers($consumers) . "\n";
                }
                die "Remove all active VFs before switching the physical GPU driver for $bdf\n"
                    if $driver_changes && $num_vfs > 0;

                if ($target_driver eq 'vfio-pci') {
                    my $sriov_config = parse_ini_config($GPU_SRIOV_CONF, 1);
                    my @profiles = grep { /^\Q$bdf\E\/vf\d+$/ } keys %$sriov_config;
                    die "Remove the persisted SR-IOV profile for $bdf before binding the PF to vfio-pci\n"
                        if exists($sriov_config->{$bdf}) || @profiles;
                }

                my $vfio_bdfs = _read_vfio_bdfs(1);
                my $was_configured = grep { $_ eq $bdf } @$vfio_bdfs;
                my $should_configure = $target_driver eq 'vfio-pci' ? 1 : 0;
                my $persistence_changes = $was_configured != $should_configure;
                my $override = read_sysfs(
                    "/sys/bus/pci/devices/$bdf/driver_override"
                );
                die "Cannot snapshot driver_override for physical GPU $bdf\n"
                    if !defined($override);
                my $normal_override = $override eq '(null)' ? '' : $override;
                my $override_needs_clear = $normal_override ne '' ? 1 : 0;

                if (!$driver_changes && !$persistence_changes && !$override_needs_clear) {
                    return {
                        success => \1,
                        changed => \0,
                        bdf => $bdf,
                        driver => $current_driver,
                        vfio_configured => $was_configured ? \1 : \0,
                        reboot_required => \0,
                    };
                }

                my $config_snapshot = $persistence_changes
                    ? _snapshot_file($VFIO_CONF)
                    : undef;
                my ($driver_touched, $persistence_touched) = (0, 0);
                my $ok = eval {
                    if ($driver_changes || $override_needs_clear) {
                        $driver_touched = 1;
                        _set_vf_driver_state($bdf, $target_driver);
                    }
                    if ($persistence_changes) {
                        $persistence_touched = 1;
                        _set_vfio_configured($bdf, $should_configure);
                    }

                    my $actual_driver = _pci_driver($bdf);
                    die "Physical GPU driver verification failed: expected '$target_driver', found '" .
                        ($actual_driver || 'unbound') . "'\n"
                        if $actual_driver ne $target_driver;
                    my $actual_bdfs = _read_vfio_bdfs(1);
                    my $actual_configured = grep { $_ eq $bdf } @$actual_bdfs;
                    die "VFIO persistence verification failed for $bdf\n"
                        if ($actual_configured ? 1 : 0) != $should_configure;
                    1;
                };
                if (!$ok) {
                    my $error = $@ || 'unknown physical GPU driver switch failure';
                    my @rollback_errors;
                    if ($persistence_touched) {
                        eval { _restore_file_snapshot($VFIO_CONF, $config_snapshot) };
                        push @rollback_errors, "VFIO persistence: $@" if $@;
                    }
                    if ($driver_touched) {
                        eval {
                            _restore_vf_driver_state(
                                $bdf,
                                $current_driver,
                                $override,
                            )
                        };
                        push @rollback_errors, "GPU driver: $@" if $@;
                    }
                    $error .= "Rollback also failed: " . join('; ', @rollback_errors) . "\n"
                        if @rollback_errors;
                    die $error;
                }

                return {
                    success => \1,
                    changed => \1,
                    bdf => $bdf,
                    driver => $target_driver,
                    vfio_configured => $should_configure ? \1 : \0,
                    reboot_required => \0,
                };
            });
        });
    });
}

__PACKAGE__->register_method({
    name        => 'ats_policy_status',
    path        => '{bdf}/ats-policy',
    method      => 'GET',
    description => 'Report the AMD-IOMMU ATS safety policy for a GPU PF.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address',
                pattern => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        return _ats_policy_status($param->{bdf});
    },
});

__PACKAGE__->register_method({
    name        => 'enable_ats_policy',
    path        => '{bdf}/ats-policy',
    method      => 'POST',
    description => 'Persist the no-ATS boot policy; this endpoint never reboots the node.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address',
                pattern => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        die "Only root\@pam may change the ATS policy\n"
            if !defined($authuser) || $authuser ne 'root@pam';
        return _enable_ats_policy($param->{bdf});
    },
});

__PACKAGE__->register_method({
    name        => 'disable_ats_policy',
    path        => '{bdf}/ats-policy',
    method      => 'DELETE',
    description => 'Remove the no-ATS boot policy after checking PF consumers; this endpoint never reboots the node.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address',
                pattern => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        die "Only root\@pam may change the ATS policy\n"
            if !defined($authuser) || $authuser ne 'root@pam';
        return _disable_ats_policy($param->{bdf});
    },
});

__PACKAGE__->register_method({
    name        => 'quick_pf_passthrough',
    path        => '{bdf}/passthrough',
    method      => 'POST',
    description => 'Detach every stopped PF/VF consumer, remove SR-IOV, and assign the whole physical GPU to one stopped QEMU VM transactionally.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI BDF address of the physical GPU',
                pattern     => $BDF_RE,
            },
            vmid => {
                type        => 'integer',
                description => 'Stopped and unlocked target QEMU VM ID',
                minimum     => 1,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        die "Only root\@pam may move raw PF/VF PCI functions between VMs\n"
            if !defined($authuser) || $authuser ne 'root@pam';
        return _switch_to_pf_passthrough($param->{bdf}, $param->{vmid});
    },
});

__PACKAGE__->register_method({
    name        => 'vfio_toggle',
    path        => '{bdf}/vfio',
    method      => 'POST',
    description => 'Switch a physical GPU between xe and vfio-pci with VM, VF, persistence, and rollback guards.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto   => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf  => {
                type        => 'string',
                description => 'PCI BDF address',
                pattern     => $BDF_RE,
            },
            action => {
                type        => 'string',
                description => 'bind or unbind',
                enum        => ['bind', 'unbind'],
            },
            persist => {
                type        => 'boolean',
                description => 'Persist this exact BDF for the boot-time VFIO service',
                optional    => 1,
                default     => 1,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        die "Only root\@pam may switch a raw physical GPU driver\n"
            if !defined($authuser) || $authuser ne 'root@pam';
        die "Physical GPU driver switching must remain persistent across reboot\n"
            if !$param->{persist};
        my $target_driver = $param->{action} eq 'bind' ? 'vfio-pci' : 'xe';
        return _set_pf_driver($param->{bdf}, $target_driver);
    },
});

__PACKAGE__->register_method({
    name        => 'list_vfs',
    path        => '{bdf}/vf',
    method      => 'GET',
    description => 'List active VFs with live resources, drivers, and VM consumers.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address',
                pattern => $BDF_RE,
            },
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object' },
        links => [{ rel => 'child', href => '{vf_index}' }],
    },
    code => sub {
        my ($param) = @_;
        return _with_gpu_lock(sub {
            _assert_power_mode_normal($param->{bdf}, 'read the VF list');
            my $rec = _collect_device($param->{bdf}, 0);
            die "Device '$param->{bdf}' not found or not a supported GPU\n"
                if !defined($rec);
            return _vf_records($rec);
        });
    },
});

__PACKAGE__->register_method({
    name        => 'vf_detail',
    path        => '{bdf}/vf/{vfIndex}',
    method      => 'GET',
    description => 'Get live resources and VM consumer details for one VF.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address of the PF',
                pattern => $BDF_RE,
            },
            vfIndex => {
                type => 'integer',
                description => 'VF index (1-based)',
                minimum => 1,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        return _with_gpu_lock(sub {
            _assert_power_mode_normal($param->{bdf}, 'read VF details');
            my $rec = _collect_device($param->{bdf}, 0);
            die "Device '$param->{bdf}' not found or not a supported GPU\n"
                if !defined($rec);

        my $wanted = int($param->{vfIndex});
        my $vfs = _vf_records($rec);
        my ($vf) = grep { $_->{vf_index} == $wanted } @$vfs;
        die "VF index $wanted out of range (1.." . scalar(@$vfs) . ")\n"
            if !defined($vf);

            return {
                %$vf,
                pf_bdf => $rec->{bdf},
                family => $rec->{family},
                tiles => int($rec->{tiles}),
                scheduler_priority => _read_scheduler_priority($rec),
            };
        });
    },
});

__PACKAGE__->register_method({
    name        => 'set_vf_assignment',
    path        => '{bdf}/vf/{vfIndex}/assignment',
    method      => 'PUT',
    description => 'Assign one SR-IOV VF to a stopped QEMU VM, move it, or remove its VM assignment.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address of the PF',
                pattern => $BDF_RE,
            },
            vfIndex => {
                type => 'integer',
                description => 'VF index (1-based)',
                minimum => 1,
            },
            vmid => {
                type => 'integer',
                description => 'Target QEMU VM ID, or 0 to leave the VF unassigned',
                minimum => 0,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        die "Only root\@pam may assign a raw VF BDF to a VM\n"
            if !defined($authuser) || $authuser ne 'root@pam';

        return _set_vf_assignment(
            $param->{bdf},
            $param->{vfIndex},
            $param->{vmid},
        );
    },
});

__PACKAGE__->register_method({
    name        => 'power_policy_status',
    path        => '{bdf}/power-policy',
    method      => 'GET',
    description => 'Report the runtime-only Intel B50 deep-idle policy and its blockers.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address of the physical GPU',
                pattern => $BDF_RE,
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        return _with_gpu_lock(sub {
            return _power_policy_status($param->{bdf});
        });
    },
});

__PACKAGE__->register_method({
    name        => 'change_power_policy',
    path        => '{bdf}/power-policy',
    method      => 'POST',
    description => 'Enter or exit runtime-only Intel B50 deep idle transactionally.',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Modify']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            bdf => {
                type => 'string',
                description => 'PCI BDF address of the physical GPU',
                pattern => $BDF_RE,
            },
            action => {
                type => 'string',
                description => 'Enter or exit runtime-only deep idle',
                enum => ['enter', 'exit'],
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment->get();
        my $authuser = $rpcenv->get_user();
        die "Only root\@pam may change raw GPU power state\n"
            if !defined($authuser) || $authuser ne 'root@pam';
        return $param->{action} eq 'enter'
            ? _enter_deep_idle($param->{bdf})
            : _exit_deep_idle($param->{bdf});
    },
});

1;
