#!/bin/sh
# Verify the persisted PCI binders before pve-guests starts.

set -eu

VFIO_CONF=${PVE_GPU_VFIO_CONF:-/etc/pve-gpu-vfio.conf}

fail() {
    echo "pve-gpu-binders: ERROR: $*" >&2
    exit 1
}

command -v systemctl >/dev/null 2>&1 \
    || fail "systemctl is unavailable; cannot verify PCI binder state"

# VFIO is intentionally conditional: no persisted VFIO configuration means
# its ConditionPathExists skips the unit and there is no binder to require.
if [ -e "$VFIO_CONF" ] &&
    ! systemctl is-active --quiet pve-gpu-vfio.service; then
    fail "pve-gpu-vfio.service is not active"
fi

# SR-IOV's oneshot uses RemainAfterExit, including the no-configuration case;
# an inactive or failed unit therefore always means the restore transaction did
# not complete successfully.
systemctl is-active --quiet pve-gpu-sriov.service \
    || fail "pve-gpu-sriov.service is not active"

exit 0
