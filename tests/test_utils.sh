#!/bin/bash

# Test suite for utility functions
# Simple test framework for shell scripts

set -euo pipefail

# Test framework variables
TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test framework functions
assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="${3:-}"
    
    ((TEST_COUNT += 1))
    
    if [[ "$expected" == "$actual" ]]; then
        ((PASSED_COUNT += 1))
        echo -e "${GREEN}✓${NC} PASS: $description"
        return 0
    else
        ((FAILED_COUNT += 1))
        echo -e "${RED}✗${NC} FAIL: $description"
        echo -e "  Expected: '$expected'"
        echo -e "  Actual:   '$actual'"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="${3:-}"
    
    ((TEST_COUNT += 1))
    
    if [[ "$haystack" == *"$needle"* ]]; then
        ((PASSED_COUNT += 1))
        echo -e "${GREEN}✓${NC} PASS: $description"
        return 0
    else
        ((FAILED_COUNT += 1))
        echo -e "${RED}✗${NC} FAIL: $description"
        echo -e "  Expected '$haystack' to contain '$needle'"
        return 1
    fi
}

assert_success() {
    local command="$1"
    local description="${2:-}"
    
    ((TEST_COUNT += 1))
    
    if eval "$command" >/dev/null 2>&1; then
        ((PASSED_COUNT += 1))
        echo -e "${GREEN}✓${NC} PASS: $description"
        return 0
    else
        ((FAILED_COUNT += 1))
        echo -e "${RED}✗${NC} FAIL: $description"
        echo -e "  Command failed: $command"
        return 1
    fi
}

assert_failure() {
    local command="$1"
    local description="${2:-}"
    
    ((TEST_COUNT += 1))
    
    if ! eval "$command" >/dev/null 2>&1; then
        ((PASSED_COUNT += 1))
        echo -e "${GREEN}✓${NC} PASS: $description"
        return 0
    else
        ((FAILED_COUNT += 1))
        echo -e "${RED}✗${NC} FAIL: $description"
        echo -e "  Expected command to fail: $command"
        return 1
    fi
}

# Test setup
setup() {
    # Source the utils script
    source "$(dirname "${BASH_SOURCE[0]:-$0}")/../scripts/utils.sh"
    
    # Redirect log output to suppress during tests
    exec 3>&2 2>/dev/null
}

# Test teardown
teardown() {
    # Restore stderr
    exec 2>&3
}

# Individual test functions
test_get_error_type_capacity() {
    local result
    result=$(get_error_type "Out of host capacity for shape VM.Standard.A1.Flex")
    assert_equal "CAPACITY" "$result" "Should detect capacity error"
}

test_get_error_type_rate_limit() {
    local result
    result=$(get_error_type "Too many requests for the user")
    assert_equal "RATE_LIMIT" "$result" "Should detect rate limit error"
    
    result=$(get_error_type '{"code": "TooManyRequests", "message": "Rate limit exceeded"}')
    assert_equal "RATE_LIMIT" "$result" "Should detect rate limit in JSON"
}

test_get_error_type_limit_exceeded() {
    local result
    result=$(get_error_type "LimitExceeded: The service limit for this resource has been exceeded")
    assert_equal "LIMIT_EXCEEDED" "$result" "Should detect limit exceeded error"
}

test_get_error_type_internal_error() {
    local result
    result=$(get_error_type "InternalError: An internal server error occurred")
    assert_equal "INTERNAL_ERROR" "$result" "Should detect internal error"
    
    result=$(get_error_type "Bad Gateway (502)")
    assert_equal "INTERNAL_ERROR" "$result" "Should detect gateway error"
}

test_get_error_type_duplicate() {
    local result
    result=$(get_error_type "Display name already exists in the compartment")
    assert_equal "DUPLICATE" "$result" "Should detect duplicate error"
}

test_get_error_type_auth() {
    local result
    result=$(get_error_type "Authentication failed: Invalid user OCID")
    assert_equal "AUTH" "$result" "Should detect auth error"
}

test_get_error_type_config() {
    local result
    result=$(get_error_type "NotFound: The specified resource does not exist")
    assert_equal "CONFIG" "$result" "Should detect config error"
}

test_get_error_type_network() {
    local result
    result=$(get_error_type "Connection timeout occurred")
    assert_equal "NETWORK" "$result" "Should detect network error"
}

test_get_error_type_unknown() {
    local result
    result=$(get_error_type "Some completely unexpected error message")
    assert_equal "UNKNOWN" "$result" "Should return UNKNOWN for unrecognized errors"
}

test_validate_no_spaces() {
    assert_success 'validate_no_spaces "TEST_VAR" "no-spaces-here"' "Should pass validation without spaces"
    assert_failure 'validate_no_spaces "TEST_VAR" "has spaces here"' "Should fail validation with spaces"
    assert_success 'validate_no_spaces "TEST_VAR" ""' "Should pass validation with empty string"
}

test_validate_boot_volume_size() {
    assert_success 'validate_boot_volume_size "50"' "Should accept minimum size 50"
    assert_success 'validate_boot_volume_size "100"' "Should accept valid size 100"
    assert_failure 'validate_boot_volume_size "49"' "Should reject size below minimum"
    assert_failure 'validate_boot_volume_size "not-a-number"' "Should reject non-numeric values"
    assert_failure 'validate_boot_volume_size ""' "Should reject empty string"
}

test_validate_availability_domain() {
    assert_success 'validate_availability_domain "fgaj:AP-SINGAPORE-1-AD-1"' "Should accept valid single AD"
    assert_success 'validate_availability_domain "fgaj:AP-SINGAPORE-1-AD-1,fgaj:AP-SINGAPORE-1-AD-2"' "Should accept multiple ADs"
    assert_failure 'validate_availability_domain "invalid-format"' "Should reject invalid format"
    assert_failure 'validate_availability_domain ""' "Should reject empty string"
}

test_is_valid_ocid() {
    assert_success 'is_valid_ocid "ocid1.instance.oc1.ap-singapore-1.test123"' "Should accept valid instance OCID"
    assert_success 'is_valid_ocid "ocid1.compartment.oc1..test123"' "Should accept valid compartment OCID"
    assert_failure 'is_valid_ocid "invalid-ocid"' "Should reject invalid OCID"
    assert_failure 'is_valid_ocid ""' "Should reject empty string"
}

test_has_jq() {
    # This test depends on whether jq is actually installed
    if command -v jq >/dev/null 2>&1; then
        assert_success 'has_jq' "Should detect jq when available"
    else
        assert_failure 'has_jq' "Should return false when jq not available"
    fi
}

test_extract_instance_ocid() {
    local json_output='{"data": {"id": "ocid1.instance.oc1.ap-singapore-1.test123", "display-name": "test"}}'
    local result
    result=$(extract_instance_ocid "$json_output")
    
    if command -v jq >/dev/null 2>&1; then
        assert_equal "ocid1.instance.oc1.ap-singapore-1.test123" "$result" "Should extract OCID from JSON with jq"
    else
        # Without jq, it should fall back to regex
        local regex_output='Launch Instance succeeded: ocid1.instance.oc1.ap-singapore-1.test123'
        result=$(extract_instance_ocid "$regex_output")
        assert_equal "ocid1.instance.oc1.ap-singapore-1.test123" "$result" "Should extract OCID with regex fallback"
    fi
}

test_redact_sensitive_params() {
    local result
    result=$(redact_sensitive_params "compute" "instance" "launch" "--metadata" "ssh-authorized-keys=ssh-rsa AAAAB3...")
    assert_contains "$result" "[SSH_KEY_REDACTED]" "Should redact SSH keys"
    
    result=$(redact_sensitive_params "iam" "user" "get" "--user-id" "ocid1.user.oc1..test123456789")
    assert_contains "$result" "ocid...6789" "Should redact OCID showing first and last 4 chars"
}

# Main test runner
run_tests() {
    echo -e "${YELLOW}Running utility function tests...${NC}\n"
    
    setup
    
    # Run all test functions
    test_get_error_type_capacity
    test_get_error_type_rate_limit
    test_get_error_type_limit_exceeded
    test_get_error_type_internal_error
    test_get_error_type_duplicate
    test_get_error_type_auth
    test_get_error_type_config
    test_get_error_type_network
    test_get_error_type_unknown
    test_validate_no_spaces
    test_validate_boot_volume_size
    test_validate_availability_domain
    test_is_valid_ocid
    test_has_jq
    test_extract_instance_ocid
    test_redact_sensitive_params
    
    teardown
    
    # Print summary
    echo
    echo -e "${YELLOW}Test Results:${NC}"
    echo -e "Total tests: $TEST_COUNT"
    echo -e "${GREEN}Passed: $PASSED_COUNT${NC}"
    echo -e "${RED}Failed: $FAILED_COUNT${NC}"
    
    if [[ $FAILED_COUNT -eq 0 ]]; then
        echo -e "\n${GREEN}All tests passed! ✓${NC}"
        return 0
    else
        echo -e "\n${RED}Some tests failed! ✗${NC}"
        return 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi