#!/bin/bash

# Test image cache selection in launch-instance.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_ROOT/scripts/launch-instance.sh"

TESTS_PASSED=0
TESTS_FAILED=0
OCI_CMD_LOG="$(mktemp)"
trap 'rm -f "$OCI_CMD_LOG"' EXIT

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $description"
        ((TESTS_PASSED += 1))
    else
        echo "FAIL: $description" >&2
        echo "  Expected: $expected" >&2
        echo "  Actual:   $actual" >&2
        ((TESTS_FAILED += 1))
    fi
}

reset_image_env() {
    unset OCI_IMAGE_ID
    unset OCI_CACHED_UBUNTU_2404_ARM_IMAGE
    unset OCI_CACHED_UBUNTU_2404_AMD_IMAGE
    unset OCI_CACHED_OL10_ARM_IMAGE
    unset OCI_CACHED_OL10_AMD_IMAGE
    unset OPERATING_SYSTEM
    unset OS_VERSION
    unset OCI_SHAPE
    : >"$OCI_CMD_LOG"
}

oci_cmd() {
    echo "call" >>"$OCI_CMD_LOG"
    echo "ocid1.image.oc1.us-sanjose-1.fallback"
}

oci_cmd_call_count() {
    wc -l <"$OCI_CMD_LOG" | tr -d '[:space:]'
}

test_ubuntu_arm_cache() {
    reset_image_env
    export OPERATING_SYSTEM="Canonical Ubuntu"
    export OS_VERSION="24.04"
    export OCI_SHAPE="VM.Standard.A1.Flex"
    export OCI_CACHED_UBUNTU_2404_ARM_IMAGE="ocid1.image.oc1.us-sanjose-1.armcached"

    local result
    result=$(lookup_image_id "ocid1.tenancy.oc1..test")

    assert_equal "$OCI_CACHED_UBUNTU_2404_ARM_IMAGE" "$result" "Ubuntu 24.04 ARM cache should be used"
    assert_equal "0" "$(oci_cmd_call_count)" "Ubuntu 24.04 ARM cache should skip API lookup"
}

test_ubuntu_amd_cache() {
    reset_image_env
    export OPERATING_SYSTEM="Canonical Ubuntu"
    export OS_VERSION="24.04"
    export OCI_SHAPE="VM.Standard.E2.1.Micro"
    export OCI_CACHED_UBUNTU_2404_AMD_IMAGE="ocid1.image.oc1.us-sanjose-1.amdcached"

    local result
    result=$(lookup_image_id "ocid1.tenancy.oc1..test")

    assert_equal "$OCI_CACHED_UBUNTU_2404_AMD_IMAGE" "$result" "Ubuntu 24.04 AMD cache should be used"
    assert_equal "0" "$(oci_cmd_call_count)" "Ubuntu 24.04 AMD cache should skip API lookup"
}

test_ubuntu_fallback_lookup() {
    reset_image_env
    export OPERATING_SYSTEM="Canonical Ubuntu"
    export OS_VERSION="24.04"
    export OCI_SHAPE="VM.Standard.A1.Flex"

    local result
    result=$(lookup_image_id "ocid1.tenancy.oc1..test")

    assert_equal "ocid1.image.oc1.us-sanjose-1.fallback" "$result" "Ubuntu 24.04 should fall back to API lookup without cache"
    assert_equal "1" "$(oci_cmd_call_count)" "Ubuntu 24.04 fallback should call API once"
}

main() {
    echo "Running image cache tests..."
    test_ubuntu_arm_cache
    test_ubuntu_amd_cache
    test_ubuntu_fallback_lookup

    echo
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"

    [[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
