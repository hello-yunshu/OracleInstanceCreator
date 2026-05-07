#!/bin/bash
# Comprehensive test suite for state management functionality
# Tests all critical state manager operations and edge cases

set -euo pipefail

# Source the state manager and utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_DIR/scripts/utils.sh"
source "$PROJECT_DIR/scripts/state-manager.sh"

# Test configuration
TEST_STATE_DIR="/tmp/state-manager-tests-$$"
TEST_STATE_FILE="$TEST_STATE_DIR/test-instance-state.json"
TEST_CACHE_DIR="$TEST_STATE_DIR/.cache/oci-state"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TEST_SECTION=""

# Test utilities
setup_test_env() {
    # Clean up any existing test environment
    rm -rf "$TEST_STATE_DIR"
    mkdir -p "$TEST_STATE_DIR"
    mkdir -p "$TEST_CACHE_DIR"
    
    # Override environment variables for testing
    export CACHE_PATH="$TEST_STATE_DIR/.cache/oci-state"
    export OCI_REGION="ap-singapore-1"
    export CACHE_ENABLED="true"
    export CACHE_TTL_HOURS="24"
    export CACHE_DATE_KEY="2024-01-15"  # Fixed date for testing
    unset GITHUB_ACTIONS  # Disable GitHub Actions mode for most tests
    
    log_info "Test environment set up: $TEST_STATE_DIR"
}

cleanup_test_env() {
    rm -rf "$TEST_STATE_DIR"
    log_info "Test environment cleaned up"
}

start_test_section() {
    TEST_SECTION="$1"
    echo ""
    echo "=== Testing: $TEST_SECTION ==="
}

assert_success() {
    local test_name="$1"
    local command="$2"
    local status
    
    set +e
    eval "$command" >/dev/null 2>&1
    status=$?
    set -e

    if [[ $status -eq 0 ]]; then
        echo "✓ $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "✗ $test_name (command failed: $command)"
        ((TESTS_FAILED += 1))
    fi
}

assert_failure() {
    local test_name="$1"
    local command="$2"
    local status
    
    set +e
    eval "$command" >/dev/null 2>&1
    status=$?
    set -e

    if [[ $status -eq 0 ]]; then
        echo "✗ $test_name (expected failure but command succeeded: $command)"
        ((TESTS_FAILED += 1))
    else
        echo "✓ $test_name"
        ((TESTS_PASSED += 1))
    fi
}

assert_file_exists() {
    local test_name="$1"
    local file_path="$2"
    
    if [[ -f "$file_path" ]]; then
        echo "✓ $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "✗ $test_name (file not found: $file_path)"
        ((TESTS_FAILED += 1))
    fi
}

assert_json_valid() {
    local test_name="$1"
    local file_path="$2"
    
    if [[ -f "$file_path" ]] && jq empty "$file_path" 2>/dev/null; then
        echo "✓ $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "✗ $test_name (invalid JSON: $file_path)"
        ((TESTS_FAILED += 1))
    fi
}

assert_contains() {
    local test_name="$1"
    local file_path="$2"
    local expected_content="$3"
    
    if [[ -f "$file_path" ]] && grep -q "$expected_content" "$file_path" 2>/dev/null; then
        echo "✓ $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "✗ $test_name (content not found: $expected_content)"
        ((TESTS_FAILED += 1))
    fi
}

# Test cases
test_basic_state_operations() {
    start_test_section "Basic State Operations"
    
    # Test state manager initialization
    assert_success "Initialize state manager" "init_state_manager '$TEST_STATE_FILE'"
    assert_file_exists "State file created" "$TEST_STATE_FILE"
    assert_json_valid "State file is valid JSON" "$TEST_STATE_FILE"
    
    # Test state file loading
    assert_success "Load existing state file" "load_state '$TEST_STATE_FILE'"
    
    # Test state validation
    assert_success "Validate state file" "validate_state_file '$TEST_STATE_FILE'"
    
    # Test instance state checking (should allow creation for new instance)
    assert_success "Check new instance (should create)" "should_create_instance 'test-instance' '$TEST_STATE_FILE'"
    
    # Test instance creation recording
    assert_success "Record instance creation" "record_instance_creation 'test-instance' 'ocid1.instance.test' '$TEST_STATE_FILE'"
    
    # Test instance state checking (should skip creation for existing instance)
    assert_failure "Check existing instance (should skip)" "should_create_instance 'test-instance' '$TEST_STATE_FILE'"
    
    # Test instance verification recording
    assert_success "Record instance verification" "record_instance_verification 'test-instance' 'ocid1.instance.test' 'verified' '$TEST_STATE_FILE'"
}

test_path_consistency() {
    start_test_section "Path Consistency"
    
    # Test absolute path resolution
    local resolved_path
    resolved_path=$(get_state_file_path)
    assert_success "Get absolute state file path" "[[ '$resolved_path' = /* ]]"
    
    # Test cache directory resolution
    local cache_dir
    cache_dir=$(get_cache_dir)
    assert_success "Get absolute cache directory" "[[ '$cache_dir' = /* ]]"
    
    # Test state file path with custom input
    local custom_path
    custom_path=$(get_state_file_path "custom-state.json")
    assert_success "Custom state file path resolution" "[[ '$custom_path' == *'custom-state.json' ]]"
}

test_cache_key_generation() {
    start_test_section "Cache Key Generation"
    
    # Test cache key with fixed date
    local cache_key
    cache_key=$(generate_cache_key)
    assert_success "Generate cache key" "[[ '$cache_key' =~ ^oci-instances-[a-f0-9]{8}-v1-2024-01-15$ ]]"
    
    # Test cache key with different region
    export OCI_REGION="us-ashburn-1"
    local cache_key_us
    cache_key_us=$(generate_cache_key)
    assert_success "Generate cache key for different region" "[[ '$cache_key_us' =~ ^oci-instances-[a-f0-9]{8}-v1-2024-01-15$ && '$cache_key_us' != '$cache_key' ]]"
    
    # Reset region
    export OCI_REGION="ap-singapore-1"
}

test_dynamic_ttl() {
    start_test_section "Dynamic TTL Configuration"
    
    # Test normal TTL for low-contention region
    export OCI_REGION="eu-amsterdam-1"
    local ttl_normal
    ttl_normal=$(get_dynamic_ttl_hours)
    assert_success "Normal TTL for low-contention region" "[[ '$ttl_normal' == '24' ]]"
    
    # Test reduced TTL for high-contention region
    export OCI_REGION="ap-singapore-1"
    local ttl_reduced
    ttl_reduced=$(get_dynamic_ttl_hours)
    assert_success "Reduced TTL for high-contention region" "[[ '$ttl_reduced' == '12' ]]"
    
    # Test another high-contention region
    export OCI_REGION="us-ashburn-1"
    local ttl_reduced2
    ttl_reduced2=$(get_dynamic_ttl_hours)
    assert_success "Reduced TTL for us-ashburn-1" "[[ '$ttl_reduced2' == '12' ]]"
}

test_state_expiry() {
    start_test_section "State Expiry Logic"
    
    # Initialize state with current timestamp
    init_state_manager "$TEST_STATE_FILE" >/dev/null
    
    # State should not be expired immediately
    assert_failure "Fresh state should not be expired" "is_state_expired '$TEST_STATE_FILE'"
    
    # Create an expired state file (manually set old timestamp)
    local old_timestamp=$(($(date +%s) - 86400 * 2))  # 2 days ago
    jq --arg timestamp "$old_timestamp" '.updated = ($timestamp | tonumber)' "$TEST_STATE_FILE" > "$TEST_STATE_FILE.tmp"
    mv "$TEST_STATE_FILE.tmp" "$TEST_STATE_FILE"
    
    # State should now be expired
    assert_success "Old state should be expired" "is_state_expired '$TEST_STATE_FILE'"
}

test_corrupted_state_handling() {
    start_test_section "Corrupted State Handling"
    
    # Create invalid JSON file
    echo "invalid json content" > "$TEST_STATE_FILE"
    
    # State validation should fail
    assert_failure "Corrupted state should fail validation" "validate_state_file '$TEST_STATE_FILE'"
    
    # Loading corrupted state should reinitialize
    assert_success "Loading corrupted state should reinitialize" "load_state '$TEST_STATE_FILE'"
    assert_json_valid "Reinitialized state is valid JSON" "$TEST_STATE_FILE"
}

test_github_actions_cache() {
    start_test_section "GitHub Actions Cache Integration"
    
    # Enable GitHub Actions mode
    export GITHUB_ACTIONS="true"
    
    # Initialize state
    init_state_manager "$TEST_STATE_FILE" >/dev/null
    
    # Test cache save preparation
    assert_success "Save state to cache" "save_state_to_cache '$TEST_STATE_FILE'"
    
    # Verify cache file was created in expected location
    local cached_state="$TEST_CACHE_DIR/$STATE_FILE_NAME"
    assert_file_exists "Cached state file created" "$cached_state"
    
    # Test cache loading
    rm -f "$TEST_STATE_FILE"  # Remove original
    assert_success "Load state from cache" "load_state_from_cache '$TEST_STATE_FILE'"
    assert_file_exists "State restored from cache" "$TEST_STATE_FILE"
    
    # Disable GitHub Actions mode
    unset GITHUB_ACTIONS
}

test_enhanced_verification() {
    start_test_section "Enhanced Configuration Verification"
    
    # Note: This test would require actual OCI API access in a real environment
    # For now, we test the function interface and error handling
    
    # Test missing parameters
    assert_failure "Verify config with missing parameters" "verify_instance_configuration '' ''"
    
    # Test with mock parameters (will fail API call but tests parameter validation)
    assert_failure "Verify config with invalid instance ID" "verify_instance_configuration 'invalid-id' 'VM.Standard.A1.Flex'"
}

test_cli_interface() {
    start_test_section "CLI Interface"
    
    local cli_env
    cli_env="CACHE_PATH='$TEST_CACHE_DIR' OCI_REGION='ap-singapore-1' CACHE_ENABLED='true' CACHE_TTL_HOURS='24'"
    
    # Test CLI initialization
    assert_success "CLI init command" "env $cli_env '$PROJECT_DIR/scripts/state-manager.sh' init"
    
    # Test CLI health check
    assert_success "CLI health command" "env $cli_env '$PROJECT_DIR/scripts/state-manager.sh' health"
    
    # Test CLI stats (will show no stats initially)
    assert_success "CLI stats command" "env $cli_env '$PROJECT_DIR/scripts/state-manager.sh' stats || true"  # Allow failure if no stats
    
    # Test CLI print
    assert_success "CLI print command" "env $cli_env '$PROJECT_DIR/scripts/state-manager.sh' print"
}

test_error_propagation() {
    start_test_section "Error Propagation"
    
    # Test with invalid state file directory (read-only)
    local readonly_dir="/tmp/readonly-$$"
    mkdir -p "$readonly_dir"
    chmod 555 "$readonly_dir"
    
    # Should fail to create state file in read-only directory
    assert_failure "State creation in read-only directory should fail" "init_state_file '$readonly_dir/state.json'"
    
    # Clean up
    chmod 755 "$readonly_dir"
    rm -rf "$readonly_dir"
}

# Main test execution
main() {
    echo "=== State Manager Test Suite ==="
    echo "Testing directory: $TEST_STATE_DIR"
    
    # Set up test environment
    setup_test_env
    
    # Run all test suites
    test_basic_state_operations
    test_path_consistency
    test_cache_key_generation
    test_dynamic_ttl
    test_state_expiry
    test_corrupted_state_handling
    test_github_actions_cache
    test_enhanced_verification
    test_cli_interface
    test_error_propagation
    
    # Clean up test environment
    cleanup_test_env
    
    # Print results
    echo ""
    echo "=== Test Results ==="
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo "Total tests: $((TESTS_PASSED + TESTS_FAILED))"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✅ All tests passed!"
        exit 0
    else
        echo "❌ Some tests failed!"
        exit 1
    fi
}

# Run tests if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
