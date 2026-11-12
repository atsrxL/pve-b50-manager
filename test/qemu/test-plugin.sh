#!/bin/bash
# Run smoke tests against the QEMU PVE VM via serial socket
#
# Usage: ./test-plugin.sh [socket-path]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOCKET="${1:-${SCRIPT_DIR}/pve-serial.sock}"
SERIAL="${SCRIPT_DIR}/serial-cmd.sh"
PASS=0
FAIL=0

if [ ! -S "$SOCKET" ]; then
    echo "ERROR: Serial socket not found at $SOCKET"
    echo "Start the VM first: ./run-pve-vm.sh"
    exit 1
fi

scmd() { bash "$SERIAL" "$SOCKET" "$@"; }

run_test() {
    local name="$1"
    shift
    echo -n "  TEST: $name ... "
    if scmd "$@" >/dev/null 2>&1; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
}

run_test_output() {
    local name="$1"
    local expected="$2"
    shift 2
    echo -n "  TEST: $name ... "
    local output
    output=$(scmd "$@" 2>/dev/null) || true
    if echo "$output" | grep -q "$expected"; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (expected '$expected' in output)"
        echo "  Got: $output"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== PVE GPU Plugin Smoke Tests (via serial) ==="
echo ""

# Get hostname for API calls
HOSTNAME=$(scmd "hostname" 2>/dev/null | tr -d '[:space:]')
echo "VM hostname: $HOSTNAME"
echo ""

echo "--- Installation checks ---"
run_test "Perl module exists" "test -f /usr/share/perl5/PVE/API2/Hardware/GPU.pm"
run_test "JS plugin exists" "test -f /usr/share/pve-manager/js/pve-gpu-plugin.js"
run_test "Apply script exists" "test -x /usr/lib/pve-gpu/apply-sriov-config.sh"
run_test "Power-limit restore script exists" "test -x /usr/lib/pve-gpu/apply-power-limit.sh"
run_test "JS patch applied" "grep -q pve-gpu-plugin /usr/share/pve-manager/index.html.tpl"
run_test "Nodes.pm patch applied" "grep -q GPU /usr/share/perl5/PVE/API2/Nodes.pm"
run_test "Systemd service enabled" "systemctl is-enabled pve-gpu-sriov.service"
run_test "Perl module loads" "perl -I/usr/share/perl5 -MPVE::API2::Hardware::GPU -e 1"

echo ""
echo "--- API endpoint tests ---"
run_test_output "List supported BMG device" "0000:04:00.0" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu --output-format json"
run_test "Unsupported Flex is not enumerated" \
    "! pvesh get /nodes/$HOSTNAME/hardware/gpu --output-format json | grep -q '0000:03:00.0'"
run_test_output "BMG device detail" "e211" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0 --output-format json"
run_test_output "BMG telemetry temp" "43" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0 --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['telemetry']['temperature_c'])\""
run_test_output "BMG PF resident VRAM" "1024" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0 --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['telemetry']['lmem_pf_resident_mb'])\""
run_test_output "BMG Card PL2" "60" \
    "pvesh get /nodes/$HOSTNAME/hardware/gpu/0000:04:00.0/power-limit --output-format json | python3 -c \"import sys,json; print(json.load(sys.stdin)['current_w'])\""
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
echo "--- Uninstall test ---"
run_test "Uninstall plugin" "dpkg -r pve-gpu-manager"
run_test "Perl module removed" "test ! -f /usr/share/perl5/PVE/API2/Hardware/GPU.pm"
run_test "JS patch reverted" "! grep -q pve-gpu-plugin /usr/share/pve-manager/index.html.tpl"
run_test "Nodes.pm patch reverted" "! grep -q GPU /usr/share/perl5/PVE/API2/Nodes.pm"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
