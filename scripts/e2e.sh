#!/bin/bash
# e2e.sh — End-to-end test runner for PVE GPU Manager Plugin
#
# Automates: ISO prep → QEMU VM install → plugin deploy → smoke tests → cleanup
#
# Usage:
#   ./scripts/e2e.sh              # Full run (install PVE if needed, deploy, test)
#   ./scripts/e2e.sh --skip-install  # Skip PVE install (use existing disk)
#   ./scripts/e2e.sh --keep-vm      # Don't shut down VM after tests
#   ./scripts/e2e.sh --cleanup      # Remove all QEMU artifacts
#
# Requirements: qemu-system-x86_64, socat, sshpass, xorriso, netpbm, mkfs.vfat
# Env vars:
#   PVE_ISO_URL   — Override ISO download URL
#   PVE_PASSWORD  — Root password for PVE VM (default: testpassword)
#   WEB_PORT      — PVE web UI port forward (default: 8006)
#   SSH_PORT      — SSH port forward (default: 2222)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QEMU_DIR="$PROJECT_ROOT/test/qemu"
FAKE_SYSFS_SCRIPT="$PROJECT_ROOT/test/fake-sysfs/setup-fake-sysfs.sh"

DISK="$QEMU_DIR/pve-test.qcow2"
EFIVARS="$QEMU_DIR/pve-efivars.fd"
OVMF_CODE="$QEMU_DIR/pve-OVMF_CODE.fd"
ISO_ORIG="$QEMU_DIR/proxmox-ve_9.1-1.iso"
ISO_AUTO="$QEMU_DIR/proxmox-ve_9.1-1-auto.iso"
ANSWER_TOML="$QEMU_DIR/answer.toml"
SERIAL_SOCK="$QEMU_DIR/pve-serial.sock"
MONITOR_SOCK="$QEMU_DIR/pve-monitor.sock"
SYSFS_ROOT_CONF="/etc/pve-gpu-sysfs-root"

PVE_ISO_URL="${PVE_ISO_URL:-https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso}"
PVE_PASSWORD="${PVE_PASSWORD:-testpassword}"
WEB_PORT="${WEB_PORT:-8006}"
SSH_PORT="${SSH_PORT:-2222}"

SKIP_INSTALL=0
KEEP_VM=0
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "=== $* ==="; }
info() { echo "  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

ssh_cmd() {
    sshpass -p "$PVE_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -p "$SSH_PORT" root@localhost "$@" 2>/dev/null
}

scp_cmd() {
    sshpass -p "$PVE_PASSWORD" scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -P "$SSH_PORT" "$@" 2>/dev/null
}

monitor_cmd() {
    echo "$1" | socat - UNIX-CONNECT:"$MONITOR_SOCK" >/dev/null 2>&1
}

run_test() {
    local name="$1"; shift
    echo -n "  TEST: $name ... "
    if ssh_cmd "$@" >/dev/null 2>&1; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL"; FAIL=$((FAIL + 1))
    fi
}

run_test_output() {
    local name="$1" expected="$2"; shift 2
    echo -n "  TEST: $name ... "
    local out
    out=$(ssh_cmd "$@" 2>/dev/null) || true
    if echo "$out" | grep -q "$expected"; then
        echo "PASS"; PASS=$((PASS + 1))
    else
        echo "FAIL (expected '$expected')"
        echo "    got: $(echo "$out" | head -2)"
        FAIL=$((FAIL + 1))
    fi
}

kill_vm() {
    if [ -S "$MONITOR_SOCK" ]; then
        monitor_cmd "quit" 2>/dev/null || true
        sleep 2
    fi
    local pid
    pid=$(pgrep -f "pve-test.qcow2" 2>/dev/null || true)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
    rm -f "$SERIAL_SOCK" "$MONITOR_SOCK"
}

wait_for_api() {
    local timeout="${1:-120}"
    info "Waiting for PVE API (up to ${timeout}s)..."
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -sk "https://localhost:${WEB_PORT}/" >/dev/null 2>&1; then
            info "PVE API ready at ${elapsed}s"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    die "PVE API not ready after ${timeout}s"
}

wait_for_ssh() {
    local timeout="${1:-120}"
    info "Waiting for SSH (up to ${timeout}s)..."
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if ssh_cmd "true" 2>/dev/null; then
            info "SSH ready at ${elapsed}s"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    die "SSH not ready after ${timeout}s"
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --skip-install) SKIP_INSTALL=1 ;;
        --keep-vm)      KEEP_VM=1 ;;
        --cleanup)
            log "Cleaning up QEMU artifacts"
            kill_vm
            rm -f "$DISK" "$EFIVARS" "$OVMF_CODE" "$ISO_AUTO"
            rm -f "$QEMU_DIR"/answer-disk.img
            rm -f "$SERIAL_SOCK" "$MONITOR_SOCK"
            info "Cleaned up. ISO preserved at $ISO_ORIG"
            exit 0
            ;;
        --help|-h)
            head -15 "$0" | grep '^#' | sed 's/^# *//'
            exit 0
            ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
log "Checking prerequisites"
for cmd in qemu-system-x86_64 socat sshpass xorriso mkfs.vfat pnmtopng; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd (install it first)"
done
[ -c /dev/kvm ] || die "KVM not available (/dev/kvm missing)"
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || die "OVMF not installed (apt install ovmf)"
info "All prerequisites OK"

# ---------------------------------------------------------------------------
# Step 1: Download PVE ISO
# ---------------------------------------------------------------------------
if [ ! -f "$ISO_ORIG" ]; then
    log "Downloading PVE 9.1 ISO"
    wget -O "$ISO_ORIG" "$PVE_ISO_URL"
fi

# ---------------------------------------------------------------------------
# Step 2: Prepare auto-install ISO
# ---------------------------------------------------------------------------
if [ ! -f "$ISO_AUTO" ]; then
    log "Preparing auto-install ISO"

    # Create answer.toml if missing
    if [ ! -f "$ANSWER_TOML" ]; then
        cat > "$ANSWER_TOML" << 'EOF'
[global]
keyboard = "en-us"
country = "us"
timezone = "UTC"
fqdn = "pve-test.local"
mailto = "root@pve-test.local"
root_password = "testpassword"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk_list = ["vda"]
EOF
    fi

    # Create auto-installer-mode.toml
    echo 'mode = "iso"' > /tmp/auto-installer-mode.toml

    # Inject into ISO
    xorriso -indev "$ISO_ORIG" \
        -outdev "$ISO_AUTO" \
        -map /tmp/auto-installer-mode.toml /auto-installer-mode.toml \
        -map "$ANSWER_TOML" /answer.toml \
        -boot_image any replay \
        -compliance no_emul_toc \
        -padding 0 \
        2>&1 | tail -3
    rm -f /tmp/auto-installer-mode.toml
    info "Auto-install ISO ready"
fi

# ---------------------------------------------------------------------------
# Step 3: Install PVE in QEMU (if needed)
# ---------------------------------------------------------------------------
if [ "$SKIP_INSTALL" -eq 0 ] && { [ ! -f "$DISK" ] || [ "$(stat -c%s "$DISK" 2>/dev/null || echo 0)" -lt 1000000000 ]; }; then
    log "Installing PVE 9.1 in QEMU (unattended)"

    kill_vm
    rm -f "$DISK" "$EFIVARS"
    qemu-img create -f qcow2 "$DISK" 32G
    cp /usr/share/OVMF/OVMF_CODE_4M.fd "$OVMF_CODE"
    dd if=/dev/zero of="$EFIVARS" bs=1M count=4 2>/dev/null

    qemu-system-x86_64 \
        -enable-kvm -m 2048 -smp 2 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$EFIVARS" \
        -drive file="$DISK",format=qcow2,if=virtio \
        -cdrom "$ISO_AUTO" -boot d \
        -net nic,model=virtio \
        -net "user,hostfwd=tcp::${WEB_PORT}-:8006,hostfwd=tcp::${SSH_PORT}-:22" \
        -vga std \
        -chardev socket,id=serial0,path="$SERIAL_SOCK",server=on,wait=off \
        -serial chardev:serial0 \
        -monitor unix:"$MONITOR_SOCK",server,nowait \
        -vnc :0 -daemonize

    info "QEMU started. Monitoring install progress..."

    # Wait for install to complete (disk grows, then stabilizes, then PVE boots)
    TIMEOUT=900
    ELAPSED=0
    LAST_SIZE=0
    STABLE_COUNT=0
    while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
        CUR_SIZE=$(stat -c%s "$DISK" 2>/dev/null || echo 0)
        if [ "$CUR_SIZE" -gt 1000000000 ] && [ "$CUR_SIZE" = "$LAST_SIZE" ]; then
            STABLE_COUNT=$((STABLE_COUNT + 1))
        else
            STABLE_COUNT=0
        fi
        LAST_SIZE=$CUR_SIZE

        # Check if SSH is up (means PVE booted after install)
        if [ "$STABLE_COUNT" -ge 6 ] && ssh_cmd "true" 2>/dev/null; then
            info "PVE installed and booted at ${ELAPSED}s"
            break
        fi

        if [ $((ELAPSED % 60)) -eq 0 ]; then
            info "[${ELAPSED}s] disk: $(du -h "$DISK" | cut -f1)"
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done

    # Shut down the install VM (it may have booted from ISO again)
    kill_vm
    info "Install complete. Disk: $(du -h "$DISK" | cut -f1)"
else
    info "Using existing PVE disk: $(du -h "$DISK" | cut -f1)"
fi

# ---------------------------------------------------------------------------
# Step 4: Boot PVE from installed disk
# ---------------------------------------------------------------------------
log "Booting PVE from disk"

kill_vm
rm -f "$SERIAL_SOCK" "$MONITOR_SOCK"

qemu-system-x86_64 \
    -enable-kvm -m 2048 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$EFIVARS" \
    -drive file="$DISK",format=qcow2,if=virtio \
    -boot c \
    -net nic,model=virtio \
    -net "user,hostfwd=tcp::${WEB_PORT}-:8006,hostfwd=tcp::${SSH_PORT}-:22" \
    -vga std \
    -chardev socket,id=serial0,path="$SERIAL_SOCK",server=on,wait=off \
    -serial chardev:serial0 \
    -monitor unix:"$MONITOR_SOCK",server,nowait \
    -display none \
    -daemonize

wait_for_ssh 180

# ---------------------------------------------------------------------------
# Step 5: Build and deploy plugin
# ---------------------------------------------------------------------------
log "Building plugin"
cd "$PROJECT_ROOT"
make deb 2>&1 | tail -3
DEB=$(ls -t "$PROJECT_ROOT"/../pve-gpu-manager_*.deb 2>/dev/null | head -1)
[ -f "$DEB" ] || die "No .deb found after build"
info "Built: $(basename "$DEB")"

log "Deploying plugin to VM"
# Purge any existing install first for clean state
ssh_cmd "dpkg -r pve-gpu-manager 2>/dev/null; dpkg --purge pve-gpu-manager 2>/dev/null; true"
sleep 2
scp_cmd "$DEB" root@localhost:/tmp/
ssh_cmd "dpkg -i /tmp/$(basename "$DEB")"
# Wait for postinst service restarts to settle
sleep 5
# Verify install succeeded
ssh_cmd "dpkg -s pve-gpu-manager | grep -q 'Status: install ok installed'" || die "Package install failed"
info "Plugin installed"

# ---------------------------------------------------------------------------
# Step 6: Deploy fake sysfs
# ---------------------------------------------------------------------------
log "Setting up fake sysfs"
scp_cmd "$FAKE_SYSFS_SCRIPT" root@localhost:/tmp/
ssh_cmd "bash /tmp/setup-fake-sysfs.sh" 2>/dev/null
ssh_cmd "echo '/tmp/fake-gpu' > $SYSFS_ROOT_CONF"
ssh_cmd "systemctl restart pvedaemon pveproxy"
sleep 5
info "Fake sysfs deployed, daemons restarted"

# ---------------------------------------------------------------------------
# Step 7: Run smoke tests
# ---------------------------------------------------------------------------
HOSTNAME=$(ssh_cmd "hostname" | tr -d '[:space:]')
log "Running smoke tests (host=$HOSTNAME)"
echo ""

echo "--- Installation ---"
run_test "Perl module exists" "test -f /usr/share/perl5/PVE/API2/Hardware/GPU.pm"
run_test "JS plugin exists" "test -f /usr/share/pve-manager/js/pve-gpu-plugin.js"
run_test "Apply script exists" "test -x /usr/lib/pve-gpu/apply-sriov-config.sh"
run_test "JS patch applied" "grep -q pve-gpu-plugin /usr/share/pve-manager/index.html.tpl"
run_test "Hardware.pm patched" "grep -q 'PVE::API2::Hardware::GPU' /usr/share/perl5/PVE/API2/Hardware.pm"
run_test "Service enabled" "systemctl is-enabled pve-gpu-sriov.service"
run_test "Perl module loads" "perl -MPVE::API2::Hardware::GPU -e 1"

echo ""
echo "--- API endpoints ---"
run_test_output "List supported BMG device" "0000:04:00.0" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu --output-format json"
run_test "Unsupported Flex is not enumerated" \
    "! pvesh get /nodes/$HOSTNAME/hardware/gpu --output-format json | grep -q '0000:03:00.0'"
run_test_output "BMG device detail" "e211" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0 --output-format json"
run_test_output "BMG telemetry (temp)" "43" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0 --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['telemetry']['temperature_c'])\""
run_test_output "SR-IOV v3 status" "3" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0/sriov --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['api_version'])\""
run_test_output "SR-IOV prechecks pass" "True" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0/sriov --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['prechecks']['all_pass'])\""
run_test_output "BMG scheduler status" "low" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0/sriov --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['scheduler_priority'])\""

echo ""
echo "--- VF read-only state ---"
run_test_output "No VFs initially" "0" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0/vf --output-format json | python3 -c \"import sys,json; print(len(json.load(sys.stdin)))\""
run_test_output "Device reports zero VFs" "0" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0 --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['sriov_numvfs'])\""
run_test_output "BMG max VFs is 24" "24" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0/sriov --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['sriov_maxvfs'])\""
run_test_output "Read-only smoke leaves sysfs numvfs=0" "0" \
    "cat /tmp/fake-gpu/sys/bus/pci/devices/0000:04:00.0/sriov_numvfs"

echo ""
echo "--- Fake sysfs integrity ---"
run_test_output "Fake BMG vendor" "0x8086" "cat /tmp/fake-gpu/sys/bus/pci/devices/0000:04:00.0/vendor"
run_test_output "Fake BMG device" "0xe211" "cat /tmp/fake-gpu/sys/bus/pci/devices/0000:04:00.0/device"
run_test_output "Fake BMG temp" "43000" "cat /tmp/fake-gpu/sys/class/drm/card1/device/hwmon/hwmon1/temp1_input"
run_test_output "Fake BMG scheduler" "low" \
    "cat /tmp/fake-gpu/sys/bus/pci/devices/0000:04:00.0/sriov_admin/pf/profile/sched_priority"

echo ""
echo "--- Playwright UI tests ---"
PLAYWRIGHT_DIR="$PROJECT_ROOT/test/e2e"
if [ -f "$PLAYWRIGHT_DIR/package.json" ]; then
    # Install Playwright deps if needed
    if [ ! -d "$PLAYWRIGHT_DIR/node_modules" ]; then
        info "Installing Playwright dependencies..."
        (cd "$PLAYWRIGHT_DIR" && npm install --silent 2>&1 | tail -3)
        (cd "$PLAYWRIGHT_DIR" && npx playwright install chromium 2>&1 | tail -3)
    fi

    # Create auth state directory
    mkdir -p "$PLAYWRIGHT_DIR/.auth"

    # Run Playwright tests against the VM's forwarded web UI
    info "Running Playwright tests against https://localhost:${WEB_PORT}..."
    PW_RESULT=0
    (cd "$PLAYWRIGHT_DIR" && \
        PVE_PASSWORD="$PVE_PASSWORD" \
        npx playwright test --reporter=list 2>&1) || PW_RESULT=$?

    # Count Playwright results without masking a failed test command.
    if [ "$PW_RESULT" -eq 0 ]; then
        info "Playwright tests: ALL PASSED"
    else
        info "Playwright tests: SOME FAILED (see output above)"
        FAIL=$((FAIL + 1))
    fi
else
    info "Playwright tests skipped (no package.json found)"
fi

echo ""
echo "--- Uninstall ---"
run_test "Uninstall plugin" "dpkg -r pve-gpu-manager"
run_test "Module removed" "test ! -f /usr/share/perl5/PVE/API2/Hardware/GPU.pm"
run_test "JS patch reverted" "! grep -q pve-gpu-plugin /usr/share/pve-manager/index.html.tpl"
run_test "Hardware.pm reverted" "! grep -q 'PVE::API2::Hardware::GPU' /usr/share/perl5/PVE/API2/Hardware.pm"

echo ""
echo "--- Post-uninstall PVE health ---"
# Wait for pveproxy to restart after uninstall (prerm restarts it)
sleep 5

# Wait for pveproxy to fully restart after uninstall
sleep 8

# Web UI loads — pveproxy serves the login page without errors
run_test_output "Web UI serves HTML" "Proxmox" \
    "curl -sk https://127.0.0.1:8006/ 2>/dev/null | head -20"

# API responds — authentication endpoint works
run_test_output "API auth endpoint" "ticket" \
    "curl -sk https://127.0.0.1:8006/api2/json/access/ticket -d 'username=root@pam&password=$PVE_PASSWORD' 2>/dev/null"

# Core node API works — version endpoint
run_test_output "API version endpoint" "version" \
    "pvesh get /version --output-format json"

# Node status API — confirms node is healthy
run_test_output "Node status API" "pve-test" \
    "pvesh get /nodes --output-format json"

# Hardware sub-routes still work — PCI listing unaffected
run_test "Hardware PCI endpoint" \
    "pvesh get /nodes/$HOSTNAME/hardware/pci --output-format json"

# Hardware index lists pci and usb but NOT gpu (api route stays)
run_test "Hardware index has pci" \
    "pvesh ls /nodes/$HOSTNAME/hardware 2>&1 | grep -q pci"
run_test "Hardware index has usb" \
    "pvesh ls /nodes/$HOSTNAME/hardware 2>&1 | grep -q usb"
run_test "Hardware index no gpu route" \
    "! pvesh ls /nodes/$HOSTNAME/hardware 2>&1 | grep -q gpu"

# GPU endpoint returns proper error (not a crash)
run_test_output "GPU endpoint gone (404/501)" "not implemented\|No 'get' handler\|not found" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu --output-format json 2>&1 || true"

# pveproxy is running and healthy
run_test "pveproxy running" "systemctl is-active pveproxy"
run_test "pvedaemon running" "systemctl is-active pvedaemon"

# No Perl compilation errors in pveproxy journal after uninstall
run_test "No Perl errors in pveproxy log" \
    "! journalctl -u pveproxy --since '2 minutes ago' --no-pager 2>/dev/null | grep -qi 'compilation error\|can.t locate\|syntax error'"
run_test "No Perl errors in pvedaemon log" \
    "! journalctl -u pvedaemon --since '2 minutes ago' --no-pager 2>/dev/null | grep -qi 'compilation error\|can.t locate\|syntax error'"

# index.html.tpl is valid (no broken script tags left behind)
run_test "index.html.tpl has closing head" \
    "grep -q '</head>' /usr/share/pve-manager/index.html.tpl"
run_test "index.html.tpl has closing html" \
    "grep -q '</html>' /usr/share/pve-manager/index.html.tpl"

# ---------------------------------------------------------------------------
# Step 8: Results
# ---------------------------------------------------------------------------
echo ""
log "Results: $PASS passed, $FAIL failed"

# ---------------------------------------------------------------------------
# Step 9: Cleanup
# ---------------------------------------------------------------------------
if [ "$KEEP_VM" -eq 0 ]; then
    log "Shutting down VM"
    kill_vm
else
    info "VM kept running (SSH on port $SSH_PORT, Web UI on port $WEB_PORT)"
fi

# Exit with failure if any tests failed
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
