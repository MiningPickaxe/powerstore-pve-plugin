#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# powerstore-plugin-test-suite.sh
# Basic end-to-end validation of the PowerStore PVE plugin.
#
# Usage:  bash tools/powerstore-plugin-test-suite.sh <storage-id>
# Example: bash tools/powerstore-plugin-test-suite.sh ps-prod
#
# Requires: a running Proxmox VE node with the plugin installed and
#           a valid storage entry for <storage-id> in storage.cfg.

set -euo pipefail

STORAGE="${1:-}"
if [[ -z "$STORAGE" ]]; then
    echo "Usage: $0 <storage-id>"
    echo "Example: $0 ps-prod"
    exit 1
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
PASS=0; FAIL=0

_result() {
    local label="$1" status="$2" detail="${3:-}"
    printf "  %-50s" "${label}"
    if [[ "$status" == "PASS" ]]; then
        printf "\033[0;32m✓ PASS\033[0m\n"
        (( PASS++ )) || true
    else
        printf "\033[0;31m✗ FAIL\033[0m  %s\n" "$detail"
        (( FAIL++ )) || true
    fi
}

run_test() {
    local label="$1"; shift
    local output
    if output=$("$@" 2>&1); then
        _result "$label" "PASS"
        echo "$output"
    else
        _result "$label" "FAIL" "$output"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        _result "$label" "PASS"
    else
        _result "$label" "FAIL" "Expected '$needle' in output"
    fi
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
echo
echo "========================================================================"
echo "  PowerStore PVE Plugin — Test Suite"
echo "  Storage: ${STORAGE}"
echo "  Date:    $(date)"
echo "========================================================================"
echo

TEST_VMID="99901"          # Unlikely to collide with real VMs
DISK_SIZE_KIB=$((8 * 1024 * 1024))  # 8 GiB in KiB
SNAP_NAME="test-snap-001"
CLONE_VMID="99902"
VOLNAME=""
CLONE_VOLNAME=""

# ---------------------------------------------------------------------------
# Test 1: API connectivity (pvesm status)
# ---------------------------------------------------------------------------
echo "--- Phase 1: API connectivity ---"
output=$(pvesm status --storage "${STORAGE}" 2>&1) || true
assert_contains "pvesm status returns active" "$output" "active"

# ---------------------------------------------------------------------------
# Test 2: Volume creation
# ---------------------------------------------------------------------------
echo
echo "--- Phase 2: Volume creation ---"
VOLNAME=$(pvesm alloc "${STORAGE}" "${TEST_VMID}" "" "${DISK_SIZE_KIB}" \
    --format raw 2>&1 | tail -1)
_result "Allocate 8 GiB volume for vmid ${TEST_VMID}" \
    "$( [[ -n "$VOLNAME" ]] && echo PASS || echo FAIL )" \
    "pvesm alloc returned empty"
echo "  Created: ${VOLNAME}"

# ---------------------------------------------------------------------------
# Test 3: Volume listing
# ---------------------------------------------------------------------------
echo
echo "--- Phase 3: Volume listing ---"
list_output=$(pvesm list "${STORAGE}" --vmid "${TEST_VMID}" 2>&1)
assert_contains "Volume appears in list" "$list_output" "${VOLNAME##*:}"

# ---------------------------------------------------------------------------
# Test 4: Snapshot creation
# ---------------------------------------------------------------------------
echo
echo "--- Phase 4: Snapshot operations ---"
run_test "Create snapshot '${SNAP_NAME}'" \
    pvesm snapshot "${STORAGE}:${VOLNAME##*:}" "${SNAP_NAME}"

snap_info=$(pvesm snapinfo "${STORAGE}:${VOLNAME##*:}" 2>&1)
assert_contains "Snapshot appears in info" "$snap_info" "${SNAP_NAME}"

# ---------------------------------------------------------------------------
# Test 5: Volume clone from snapshot
# ---------------------------------------------------------------------------
echo
echo "--- Phase 5: Clone from snapshot ---"
CLONE_VOLNAME=$(pvesm clone "${STORAGE}:${VOLNAME##*:}" "${CLONE_VMID}" \
    --snapname "${SNAP_NAME}" --format raw 2>&1 | tail -1)
_result "Clone volume for vmid ${CLONE_VMID}" \
    "$( [[ -n "$CLONE_VOLNAME" ]] && echo PASS || echo FAIL )"
echo "  Created clone: ${CLONE_VOLNAME}"

# ---------------------------------------------------------------------------
# Test 6: Volume resize
# ---------------------------------------------------------------------------
echo
echo "--- Phase 6: Volume resize ---"
NEW_SIZE_BYTES=$(( (DISK_SIZE_KIB + 2 * 1024 * 1024) * 1024 ))  # +2 GiB
run_test "Resize volume by +2 GiB" \
    pvesm resize "${STORAGE}:${VOLNAME##*:}" "${NEW_SIZE_BYTES}"

# ---------------------------------------------------------------------------
# Test 7: Snapshot rollback
# ---------------------------------------------------------------------------
echo
echo "--- Phase 7: Snapshot rollback ---"
run_test "Rollback volume to snapshot '${SNAP_NAME}'" \
    pvesm rollback "${STORAGE}:${VOLNAME##*:}" "${SNAP_NAME}"

# ---------------------------------------------------------------------------
# Test 8: Cleanup
# ---------------------------------------------------------------------------
echo
echo "--- Phase 8: Cleanup ---"

if [[ -n "$CLONE_VOLNAME" ]]; then
    run_test "Delete clone" \
        pvesm free "${STORAGE}:${CLONE_VOLNAME##*:}"
fi

run_test "Delete snapshot '${SNAP_NAME}'" \
    pvesm delsnapshot "${STORAGE}:${VOLNAME##*:}" "${SNAP_NAME}"

run_test "Delete volume" \
    pvesm free "${STORAGE}:${VOLNAME##*:}"

# Verify deletion
list_after=$(pvesm list "${STORAGE}" --vmid "${TEST_VMID}" 2>&1)
_result "Volume absent from list after delete" \
    "$( echo "$list_after" | grep -q "${VOLNAME##*:}" && echo FAIL || echo PASS )"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "========================================================================"
printf "  Results: \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m\n" \
    "$PASS" "$FAIL"
echo "========================================================================"
echo

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
