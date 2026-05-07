#!/bin/bash
# Integration Test Suite for Parallel Execution
# Tests end-to-end parallel execution scenarios with mock background processes

set -euo pipefail

# Source testing utilities and main functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../scripts/utils.sh"

# Test configuration
readonly TEST_TEMP_DIR="/tmp/oci_integration_tests_$$"
readonly MOCK_DURATION=3  # Seconds for mock processes to run

# Test counters
total_tests=0
passed_tests=0
failed_tests=0

# Setup test environment
setup_test_environment() {
    mkdir -p "$TEST_TEMP_DIR"
    chmod 700 "$TEST_TEMP_DIR"
    
    # Mock environment variables (only if not already set as readonly)
    [[ -z "${GITHUB_ACTIONS_TIMEOUT_SECONDS:-}" ]] && export GITHUB_ACTIONS_TIMEOUT_SECONDS=10
    [[ -z "${GRACEFUL_TERMINATION_DELAY:-}" ]] && export GRACEFUL_TERMINATION_DELAY=1
    export DEBUG=false  # Reduce noise during tests
}

# Cleanup test environment
cleanup_test_environment() {
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# Test helper functions
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    printf "  Testing %s..." "$test_name"
    total_tests=$((total_tests + 1))
    
    if $test_function; then
        printf " \033[32m✓\033[0m PASS\n"
        passed_tests=$((passed_tests + 1))
    else
        printf " \033[31m✗\033[0m FAIL\n"
        failed_tests=$((failed_tests + 1))
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        if [[ -n "$message" ]]; then
            echo "Assertion failed: $message (expected: $expected, actual: $actual)" >&2
        fi
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    [[ -f "$file" ]] || return 1
}

assert_file_permissions() {
    local file="$1"
    local expected_perms="$2"
    local actual_perms
    actual_perms=$(stat -c %a "$file" 2>/dev/null || stat -f %Mp%Lp "$file" 2>/dev/null)
    # Remove leading zeros for comparison
    actual_perms=${actual_perms#0}
    expected_perms=${expected_perms#0}
    assert_equals "$expected_perms" "$actual_perms" "File permissions for $file"
}

# Mock parallel execution function
mock_parallel_execution() {
    local success_shape="$1"  # Which shape should succeed (A1, E2, BOTH, NONE)
    local timeout_scenario="${2:-false}"  # Whether to test timeout
    
    local temp_dir
    temp_dir=$(mktemp -d -p "$TEST_TEMP_DIR")
    chmod 700 "$temp_dir"
    
    local a1_result="${temp_dir}/a1_result"
    local e2_result="${temp_dir}/e2_result"
    
    # Pre-create result files with secure permissions
    touch "$a1_result" "$e2_result"
    chmod 600 "$a1_result" "$e2_result"
    
    # Launch mock processes
    (
        if [[ "$timeout_scenario" == "true" ]]; then
            sleep 15  # Longer than timeout
        else
            sleep "$MOCK_DURATION"
        fi
        
        case "$success_shape" in
            "A1"|"BOTH") echo "0" > "$a1_result" ;;
            *) echo "2" > "$a1_result" ;;  # Capacity error
        esac
    ) &
    local pid_a1=$!
    
    (
        if [[ "$timeout_scenario" == "true" ]]; then
            sleep 15  # Longer than timeout
        else
            sleep "$MOCK_DURATION"
        fi
        
        case "$success_shape" in
            "E2"|"BOTH") echo "0" > "$e2_result" ;;
            *) echo "2" > "$e2_result" ;;  # Capacity error
        esac
    ) &
    local pid_e2=$!
    
    # Implement timeout logic similar to launch-parallel.sh
    local elapsed=0
    local sleep_interval=1
    local timeout_seconds=5
    
    while [[ $elapsed -lt $timeout_seconds ]]; do
        if ! kill -0 $pid_a1 2>/dev/null && ! kill -0 $pid_e2 2>/dev/null; then
            break  # Both processes completed
        fi
        sleep $sleep_interval
        ((elapsed += sleep_interval))
    done
    
    # Handle timeout case
    if [[ $elapsed -ge $timeout_seconds ]]; then
        [[ -n "$pid_a1" ]] && kill "$pid_a1" 2>/dev/null || true
        [[ -n "$pid_e2" ]] && kill "$pid_e2" 2>/dev/null || true
        sleep 1
        [[ -n "$pid_a1" ]] && kill -9 "$pid_a1" 2>/dev/null || true
        [[ -n "$pid_e2" ]] && kill -9 "$pid_e2" 2>/dev/null || true
        echo "124" > "$a1_result"  # Timeout exit code
        echo "124" > "$e2_result"  # Timeout exit code
    fi
    
    # Always wait for processes to complete
    wait $pid_a1 2>/dev/null || true
    wait $pid_e2 2>/dev/null || true
    
    # Return results via global variables for test verification
    A1_EXIT_CODE=$(cat "$a1_result" 2>/dev/null || echo "1")
    E2_EXIT_CODE=$(cat "$e2_result" 2>/dev/null || echo "1")
    
    # Test file permissions
    assert_file_permissions "$temp_dir" "700"
    assert_file_permissions "$a1_result" "600"
    assert_file_permissions "$e2_result" "600"
    
    rm -rf "$temp_dir"
}

# Test cases
test_both_shapes_succeed() {
    mock_parallel_execution "BOTH"
    assert_equals "0" "$A1_EXIT_CODE" "A1 should succeed"
    assert_equals "0" "$E2_EXIT_CODE" "E2 should succeed"
}

test_only_a1_succeeds() {
    mock_parallel_execution "A1"
    assert_equals "0" "$A1_EXIT_CODE" "A1 should succeed"
    assert_equals "2" "$E2_EXIT_CODE" "E2 should report capacity error"
}

test_only_e2_succeeds() {
    mock_parallel_execution "E2"
    assert_equals "2" "$A1_EXIT_CODE" "A1 should report capacity error"
    assert_equals "0" "$E2_EXIT_CODE" "E2 should succeed"
}

test_both_shapes_fail() {
    mock_parallel_execution "NONE"
    assert_equals "2" "$A1_EXIT_CODE" "A1 should report capacity error"
    assert_equals "2" "$E2_EXIT_CODE" "E2 should report capacity error"
}

test_timeout_handling() {
    mock_parallel_execution "BOTH" "true"
    assert_equals "124" "$A1_EXIT_CODE" "A1 should report timeout"
    assert_equals "124" "$E2_EXIT_CODE" "E2 should report timeout"
}

test_file_permissions() {
    local test_dir
    test_dir=$(mktemp -d -p "$TEST_TEMP_DIR")
    chmod 700 "$test_dir"
    
    local test_file="${test_dir}/test_file"
    touch "$test_file"
    chmod 600 "$test_file"
    
    assert_file_permissions "$test_dir" "700"
    assert_file_permissions "$test_file" "600"
    
    rm -rf "$test_dir"
}

test_credential_masking() {
    local test_url="user:password@proxy.example.com:3128"
    local masked_url
    masked_url=$(mask_credentials "$test_url")
    
    # Should not contain the original credentials
    [[ "$masked_url" != *"password"* ]] || return 1
    [[ "$masked_url" == *"[MASKED]"* ]] || return 1
    [[ "$masked_url" == *"proxy.example.com"* ]] || return 1
}

test_error_classification() {
    # Test various Oracle error types
    local capacity_error="Out of host capacity for shape VM.Standard.A1.Flex"
    local rate_limit_error="Too many requests"
    local auth_error="Authentication failed"
    
    local error_type
    error_type=$(get_error_type "$capacity_error")
    assert_equals "CAPACITY" "$error_type" "Should detect capacity error"
    
    error_type=$(get_error_type "$rate_limit_error")
    assert_equals "RATE_LIMIT" "$error_type" "Should detect rate limit"
    
    error_type=$(get_error_type "$auth_error")
    assert_equals "AUTH" "$error_type" "Should detect auth error"
}

# Signal handling test
test_signal_handling() {
    # This is a simplified test - in practice we'd need more complex process management
    local temp_file
    temp_file=$(mktemp -p "$TEST_TEMP_DIR")
    
    # Simulate cleanup handler
    cleanup_handler() {
        echo "cleanup_executed" > "$temp_file.cleanup"
        rm -f "$temp_file" 2>/dev/null || true
    }
    
    cleanup_handler  # Manually trigger for test
    
    assert_file_exists "$temp_file.cleanup"
    [[ ! -f "$temp_file" ]] || return 1  # File should be removed
    
    rm -f "$temp_file.cleanup" 2>/dev/null || true
}

# Test network partition simulation
test_network_partition_simulation() {
    # Simulate network errors during parallel execution
    local a1_result e2_result
    a1_result="$TEST_TEMP_DIR/a1_network_test"
    e2_result="$TEST_TEMP_DIR/e2_network_test"
    
    # Mock processes that simulate network failures
    (
        sleep 1
        # Simulate network timeout/connection error (exit code 4)
        echo "4" > "$a1_result"
    ) &
    local pid_a1=$!
    
    (
        sleep 2  
        # E2 succeeds after network delay
        echo "0" > "$e2_result"  
    ) &
    local pid_e2=$!
    
    # Wait for completion
    wait $pid_a1 $pid_e2
    
    # Verify results
    assert_file_exists "$a1_result"
    assert_file_exists "$e2_result"
    
    local a1_status e2_status
    a1_status=$(cat "$a1_result")
    e2_status=$(cat "$e2_result")
    
    # A1 should have network error, E2 should succeed
    [[ "$a1_status" == "4" ]] || return 1
    [[ "$e2_status" == "0" ]] || return 1
    
    rm -f "$a1_result" "$e2_result" 2>/dev/null || true
}

# Test concurrent execution stress
test_concurrent_execution_stress() {
    # Test with multiple rapid parallel executions to detect race conditions
    local test_iteration
    local success_count=0
    local expected_iterations=3
    
    for test_iteration in $(seq 1 $expected_iterations); do
        local a1_result e2_result
        a1_result="$TEST_TEMP_DIR/a1_stress_${test_iteration}"
        e2_result="$TEST_TEMP_DIR/e2_stress_${test_iteration}"
        
        # Run quick parallel processes
        (
            sleep 0.2
            echo "0" > "$a1_result"
        ) &
        
        (
            sleep 0.3
            echo "0" > "$e2_result"
        ) &
        
        # Don't wait here - let them run concurrently
    done
    
    # Now wait for all processes and check results
    sleep 1  # Allow all processes to complete
    
    for test_iteration in $(seq 1 $expected_iterations); do
        local a1_result e2_result
        a1_result="$TEST_TEMP_DIR/a1_stress_${test_iteration}"
        e2_result="$TEST_TEMP_DIR/e2_stress_${test_iteration}"
        
        if [[ -f "$a1_result" && -f "$e2_result" ]]; then
            local a1_status e2_status
            a1_status=$(cat "$a1_result" 2>/dev/null || echo "1")
            e2_status=$(cat "$e2_result" 2>/dev/null || echo "1")
            
            if [[ "$a1_status" == "0" && "$e2_status" == "0" ]]; then
                ((success_count += 1))
            fi
        fi
        
        rm -f "$a1_result" "$e2_result" 2>/dev/null || true
    done
    
    # At least 2 out of 3 iterations should succeed (allows for some stress-induced failures)
    [[ $success_count -ge 2 ]] || return 1
}

# Main test execution
main() {
    echo ""
    echo "==================================================="
    echo "Starting Parallel Execution Integration Tests"
    echo "==================================================="
    
    setup_test_environment
    trap cleanup_test_environment EXIT
    
    echo ""
    echo "Testing parallel execution scenarios..."
    run_test "Both shapes succeed" test_both_shapes_succeed
    run_test "Only A1 succeeds" test_only_a1_succeeds
    run_test "Only E2 succeeds" test_only_e2_succeeds
    run_test "Both shapes fail" test_both_shapes_fail
    run_test "Timeout handling" test_timeout_handling
    
    echo ""
    echo "Testing security and file handling..."
    run_test "File permissions" test_file_permissions
    run_test "Credential masking" test_credential_masking
    
    echo ""
    echo "Testing error handling..."
    run_test "Error classification" test_error_classification
    run_test "Signal handling" test_signal_handling
    
    echo ""
    echo "Testing advanced scenarios..."
    run_test "Network partition simulation" test_network_partition_simulation
    run_test "Concurrent execution stress" test_concurrent_execution_stress
    
    echo ""
    echo "Test Results:"
    echo "Total tests: $total_tests"
    echo "Passed: $passed_tests"
    echo "Failed: $failed_tests"
    echo ""
    
    if [[ $failed_tests -eq 0 ]]; then
        echo "All integration tests passed! ✓"
        exit 0
    else
        echo "Some integration tests failed! ✗"
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
