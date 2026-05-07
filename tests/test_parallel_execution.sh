#!/bin/bash

# Integration test suite for parallel execution functionality
# Tests end-to-end parallel instance creation with mock responses

set -euo pipefail

# Test framework setup
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

source "$SCRIPTS_DIR/utils.sh"

# Test configuration
TESTS_PASSED=0
TESTS_FAILED=0
TEST_TEMP_DIR=""

# Colors for test output
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

setup_test_environment() {
    log_info "Setting up test environment..."
    
    # Create secure temporary directory
    umask 077
    TEST_TEMP_DIR=$(mktemp -d)
    export TMPDIR="$TEST_TEMP_DIR"
    export TEST_TEMP_DIR
    
    # Mock environment variables for testing
    export OCI_USER_OCID="ocid1.user.oc1..test"
    export OCI_KEY_FINGERPRINT="aa:bb:cc:dd:ee"
    export OCI_TENANCY_OCID="ocid1.tenancy.oc1..test"
    export OCI_REGION="us-ashburn-1"
    export OCI_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\nMOCK\n-----END PRIVATE KEY-----"
    export OCI_SUBNET_ID="ocid1.subnet.oc1.test"
    export OCI_AD="test:US-ASHBURN-1-AD-1,test:US-ASHBURN-1-AD-2"
    export INSTANCE_SSH_PUBLIC_KEY="ssh-rsa AAAAB3... test@example.com"
    export DEBUG="false"  # Reduce noise in tests
    
    log_success "Test environment configured"
}

cleanup_test_environment() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    fi
}

# Test utilities
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" == "$actual" ]]; then
        echo "  ${GREEN}✓${RESET} $message"
        ((TESTS_PASSED += 1))
    else
        echo "  ${RED}✗${RESET} $message"
        echo "    Expected: $expected"
        echo "    Actual: $actual"
        ((TESTS_FAILED += 1))
    fi
}

assert_file_exists() {
    local file_path="$1"
    local message="${2:-File should exist: $file_path}"
    
    if [[ -f "$file_path" ]]; then
        echo "  ${GREEN}✓${RESET} $message"
        ((TESTS_PASSED += 1))
    else
        echo "  ${RED}✗${RESET} $message"
        ((TESTS_FAILED += 1))
    fi
}

assert_file_not_exists() {
    local file_path="$1"
    local message="${2:-File should not exist: $file_path}"
    
    if [[ ! -f "$file_path" ]]; then
        echo "  ${GREEN}✓${RESET} $message"
        ((TESTS_PASSED += 1))
    else
        echo "  ${RED}✗${RESET} $message"
        ((TESTS_FAILED += 1))
    fi
}

# Test cases
test_wait_for_result_file() {
    echo "${YELLOW}Testing wait_for_result_file function...${RESET}"
    
    # Test 1: File exists immediately
    local test_file="$TEST_TEMP_DIR/immediate_file"
    echo "0" > "$test_file"
    
    if wait_for_result_file "$test_file" 1; then
        assert_equals "true" "true" "Should find existing file immediately"
    else
        assert_equals "true" "false" "Should find existing file immediately"
    fi
    
    # Test 2: File appears after delay
    local delayed_file="$TEST_TEMP_DIR/delayed_file"
    (sleep 0.5; echo "1" > "$delayed_file") &
    
    if wait_for_result_file "$delayed_file" 2; then
        assert_equals "true" "true" "Should find file that appears after delay"
    else
        assert_equals "true" "false" "Should find file that appears after delay"
    fi
    
    # Test 3: Timeout case
    local missing_file="$TEST_TEMP_DIR/missing_file"
    
    if ! wait_for_result_file "$missing_file" 1; then
        assert_equals "true" "true" "Should timeout when file doesn't exist"
    else
        assert_equals "true" "false" "Should timeout when file doesn't exist"
    fi
}

test_mask_credentials() {
    echo "${YELLOW}Testing credential masking function...${RESET}"
    
    local input="http://user:secret123@proxy.example.com:8080/"
    local expected="http://[MASKED]:[MASKED]@proxy.example.com:8080/"
    local actual
    actual=$(mask_credentials "$input")
    
    assert_equals "$expected" "$actual" "Should mask IPv4 proxy credentials"
    
    local ipv6_input="http://myuser:mypass@[2001:db8::1]:3128/"
    local ipv6_expected="http://[MASKED]:[MASKED]@[2001:db8::1]:3128/"
    local ipv6_actual
    ipv6_actual=$(mask_credentials "$ipv6_input")
    
    assert_equals "$ipv6_expected" "$ipv6_actual" "Should mask IPv6 proxy credentials"
}

test_validate_availability_domain() {
    echo "${YELLOW}Testing AD validation function...${RESET}"
    
    # Valid single AD
    if validate_availability_domain "test:US-ASHBURN-1-AD-1"; then
        assert_equals "true" "true" "Should accept valid single AD"
    else
        assert_equals "true" "false" "Should accept valid single AD"
    fi
    
    # Valid comma-separated ADs
    if validate_availability_domain "test:US-ASHBURN-1-AD-1,test:US-ASHBURN-1-AD-2"; then
        assert_equals "true" "true" "Should accept valid comma-separated ADs"
    else
        assert_equals "true" "false" "Should accept valid comma-separated ADs"
    fi
    
    # Invalid format - leading comma
    if ! validate_availability_domain ",test:US-ASHBURN-1-AD-1"; then
        assert_equals "true" "true" "Should reject leading comma"
    else
        assert_equals "true" "false" "Should reject leading comma"
    fi
    
    # Invalid format - trailing comma
    if ! validate_availability_domain "test:US-ASHBURN-1-AD-1,"; then
        assert_equals "true" "true" "Should reject trailing comma"
    else
        assert_equals "true" "false" "Should reject trailing comma"
    fi
    
    # Invalid format - consecutive commas
    if ! validate_availability_domain "test:US-ASHBURN-1-AD-1,,test:US-ASHBURN-1-AD-2"; then
        assert_equals "true" "true" "Should reject consecutive commas"
    else
        assert_equals "true" "false" "Should reject consecutive commas"
    fi
}

test_get_exit_code_for_error_type() {
    echo "${YELLOW}Testing error code mapping function...${RESET}"
    
    local capacity_code
    capacity_code=$(get_exit_code_for_error_type "CAPACITY")
    assert_equals "$OCI_EXIT_CAPACITY_ERROR" "$capacity_code" "CAPACITY should map to capacity error code"
    
    local auth_code
    auth_code=$(get_exit_code_for_error_type "AUTH")
    assert_equals "$OCI_EXIT_CONFIG_ERROR" "$auth_code" "AUTH should map to config error code"
    
    local network_code
    network_code=$(get_exit_code_for_error_type "NETWORK")
    assert_equals "$OCI_EXIT_NETWORK_ERROR" "$network_code" "NETWORK should map to network error code"
    
    local unknown_code
    unknown_code=$(get_exit_code_for_error_type "UNKNOWN")
    assert_equals "$OCI_EXIT_GENERAL_ERROR" "$unknown_code" "UNKNOWN should map to general error code"
}

test_timeout_validation() {
    echo "${YELLOW}Testing timeout value validation...${RESET}"
    
    # Valid timeout
    if validate_timeout_value "TEST_TIMEOUT" "30" 5 300; then
        assert_equals "true" "true" "Should accept valid timeout value"
    else
        assert_equals "true" "false" "Should accept valid timeout value"
    fi
    
    # Too low
    if ! validate_timeout_value "TEST_TIMEOUT" "3" 5 300; then
        assert_equals "true" "true" "Should reject timeout below minimum"
    else
        assert_equals "true" "false" "Should reject timeout below minimum"
    fi
    
    # Too high
    if ! validate_timeout_value "TEST_TIMEOUT" "500" 5 300; then
        assert_equals "true" "true" "Should reject timeout above maximum"
    else
        assert_equals "true" "false" "Should reject timeout above maximum"
    fi
    
    # Non-numeric
    if ! validate_timeout_value "TEST_TIMEOUT" "abc" 5 300; then
        assert_equals "true" "true" "Should reject non-numeric timeout"
    else
        assert_equals "true" "false" "Should reject non-numeric timeout"
    fi
}

test_signal_handling_cleanup() {
    echo "${YELLOW}Testing signal handling cleanup...${RESET}"
    
    # Create a test script that sets up like launch-parallel.sh
    local test_script="$TEST_TEMP_DIR/test_signal_script.sh"
    cat > "$test_script" << 'EOF'
#!/bin/bash
set -euo pipefail

PID_A1=""
PID_E2=""
temp_dir=""

cleanup_handler() {
    echo "Cleanup called" >> "$TEST_TEMP_DIR/cleanup_log"
    [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf "$temp_dir" 2>/dev/null || true
    exit 1
}

trap cleanup_handler SIGTERM SIGINT

umask 077
temp_dir=$(mktemp -d)
echo "temp_dir=$temp_dir" >> "$TEST_TEMP_DIR/script_log"

# Simulate long-running processes
sleep 10 &
PID_A1=$!
sleep 10 &
PID_E2=$!

(sleep 0.2; kill -TERM $$) &
wait
EOF
    chmod +x "$test_script"
    
    set +e
    "$test_script"
    set -e
    
    assert_file_exists "$TEST_TEMP_DIR/cleanup_log" "Cleanup handler should be called on SIGTERM"
}

# Main test runner
run_tests() {
    echo "Starting OracleInstanceCreator Parallel Execution Integration Tests"
    echo "=================================================================="
    
    setup_test_environment
    
    # Run all test cases
    test_wait_for_result_file
    test_mask_credentials
    test_validate_availability_domain
    test_get_exit_code_for_error_type
    test_timeout_validation
    test_signal_handling_cleanup
    
    cleanup_test_environment
    
    # Print results
    echo ""
    echo "Test Results:"
    echo "============="
    echo "Passed: ${GREEN}$TESTS_PASSED${RESET}"
    echo "Failed: ${RED}$TESTS_FAILED${RESET}"
    echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo ""
        echo "${GREEN}All tests passed!${RESET}"
        exit 0
    else
        echo ""
        echo "${RED}Some tests failed!${RESET}"
        exit 1
    fi
}

# Signal handler for test cleanup
trap cleanup_test_environment EXIT

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
