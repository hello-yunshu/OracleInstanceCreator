#!/bin/bash

# Test suite for circuit breaker pattern functionality
# Tests AD failure tracking, circuit breaker logic, and reset mechanisms

set -euo pipefail

# Setup test environment
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
export PATH="$PROJECT_ROOT/scripts:$PATH"

# Source the modules to test
source "$PROJECT_ROOT/scripts/utils.sh"
source "$PROJECT_ROOT/scripts/circuit-breaker.sh"

# Test configuration
readonly TEST_AD_1="test:AP-SINGAPORE-1-AD-1"
readonly TEST_AD_2="test:AP-SINGAPORE-1-AD-2"
readonly TEST_AD_3="test:AP-SINGAPORE-1-AD-3"

# Test results tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_ASSERTION_FAILED=0

TEST_STATE_DIR="${TMPDIR:-/tmp}/circuit-breaker-tests-$$"
export STATE_DIR="$TEST_STATE_DIR"

# Test utilities
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    echo -n "Testing $test_name... "
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if $test_function; then
        echo "PASSED"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "FAILED"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        TEST_ASSERTION_FAILED=1
        if [[ -n "$message" ]]; then
            echo "ASSERTION FAILED: $message"
        fi
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        return 1
    fi
}

assert_not_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    if [[ "$expected" != "$actual" ]]; then
        return 0
    else
        if [[ -n "$message" ]]; then
            echo "ASSERTION FAILED: $message"
        fi
        echo "  Expected NOT: '$expected'"
        echo "  Actual:       '$actual'"
        return 1
    fi
}

# Setup and cleanup functions
setup_test() {
    TEST_ASSERTION_FAILED=0
    mkdir -p "$TEST_STATE_DIR"

    # Reset all AD failures before each test
    reset_all_ad_failures >/dev/null 2>&1 || true
}

cleanup_test() {
    # Clean up after each test
    reset_all_ad_failures >/dev/null 2>&1 || true
    [[ "$TEST_ASSERTION_FAILED" -eq 0 ]]
}

# Test functions

test_initial_state() {
    setup_test
    
    # Initially, no AD should be skipped
    if should_skip_ad "$TEST_AD_1"; then
        return 1
    fi
    
    # Failure count should be 0
    local count
    count=$(get_ad_failure_count "$TEST_AD_1")
    assert_equals "0" "$count" "Initial failure count should be 0"
    
    cleanup_test
}

test_increment_failure() {
    setup_test
    
    # Increment failure for AD
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    
    # Check failure count
    local count
    count=$(get_ad_failure_count "$TEST_AD_1")
    assert_equals "1" "$count" "Failure count should be 1 after increment"
    
    cleanup_test
}

test_multiple_failures() {
    setup_test
    
    # Add multiple failures
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    
    # Check failure count
    local count
    count=$(get_ad_failure_count "$TEST_AD_1")
    assert_equals "3" "$count" "Failure count should be 3 after three increments"
    
    cleanup_test
}

test_circuit_breaker_threshold() {
    setup_test
    
    # Add failures up to threshold (3)
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    
    # Should trigger circuit breaker
    if ! should_skip_ad "$TEST_AD_1"; then
        echo "AD should be skipped after reaching failure threshold"
        cleanup_test
        return 1
    fi
    
    cleanup_test
}

test_circuit_breaker_below_threshold() {
    setup_test
    
    # Add failures below threshold (2 < 3)
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    
    # Should not trigger circuit breaker
    if should_skip_ad "$TEST_AD_1"; then
        echo "AD should not be skipped below failure threshold"
        cleanup_test
        return 1
    fi
    
    cleanup_test
}

test_success_reset() {
    setup_test
    
    # Add failures up to threshold
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    
    # Circuit breaker should be active
    if ! should_skip_ad "$TEST_AD_1"; then
        echo "Circuit breaker should be active"
        cleanup_test
        return 1
    fi
    
    # Mark success to reset
    mark_ad_success "$TEST_AD_1" >/dev/null 2>&1
    
    # Circuit breaker should be reset
    if should_skip_ad "$TEST_AD_1"; then
        echo "Circuit breaker should be reset after success"
        cleanup_test
        return 1
    fi
    
    cleanup_test
}

test_multiple_ads() {
    setup_test
    
    # Add failures to different ADs
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1  # AD1 should be skipped
    
    increment_ad_failure "$TEST_AD_2" >/dev/null 2>&1  # AD2 should not be skipped
    
    # Check circuit breaker status
    if ! should_skip_ad "$TEST_AD_1"; then
        echo "AD1 should be skipped"
        cleanup_test
        return 1
    fi
    
    if should_skip_ad "$TEST_AD_2"; then
        echo "AD2 should not be skipped"
        cleanup_test
        return 1
    fi
    
    cleanup_test
}

test_get_available_ads() {
    setup_test
    
    local input_ads="$TEST_AD_1,$TEST_AD_2,$TEST_AD_3"
    
    # Initially all ADs should be available
    local available_ads
    available_ads=$(get_available_ads "$input_ads")
    assert_equals "$input_ads" "$available_ads" "All ADs should be available initially"
    
    # Add failures to first AD
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    increment_ad_failure "$TEST_AD_1" >/dev/null 2>&1
    
    # First AD should be filtered out
    available_ads=$(get_available_ads "$input_ads")
    local expected="$TEST_AD_2,$TEST_AD_3"
    assert_equals "$expected" "$available_ads" "Failed AD should be filtered out"
    
    cleanup_test
}

test_all_ads_filtered() {
    setup_test
    
    local input_ads="$TEST_AD_1,$TEST_AD_2"
    
    # Add failures to all ADs
    for ad in $TEST_AD_1 $TEST_AD_2; do
        increment_ad_failure "$ad" >/dev/null 2>&1
        increment_ad_failure "$ad" >/dev/null 2>&1
        increment_ad_failure "$ad" >/dev/null 2>&1
    done
    
    # No ADs should be available
    local available_ads
    available_ads=$(get_available_ads "$input_ads")
    assert_equals "" "$available_ads" "No ADs should be available when all have failed"
    
    cleanup_test
}

# Mock GitHub CLI for testing (if not available)
if ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: GitHub CLI not available - some persistence tests will be skipped"
    
    # Create a mock gh function for basic testing
    gh() {
        case "${1:-} ${2:-}" in
            "variable get")
                echo "[]"  # Return empty array
                return 0
                ;;
            "variable set")
                return 0  # Pretend to succeed
                ;;
            *)
                return 1
                ;;
        esac
    }
    export -f gh
fi

# Run all tests
echo "=== Circuit Breaker Test Suite ==="
echo

run_test "initial state" test_initial_state
run_test "increment failure" test_increment_failure
run_test "multiple failures" test_multiple_failures
run_test "circuit breaker threshold" test_circuit_breaker_threshold
run_test "circuit breaker below threshold" test_circuit_breaker_below_threshold
run_test "success reset" test_success_reset
run_test "multiple ADs" test_multiple_ads
run_test "get available ADs" test_get_available_ads
run_test "all ADs filtered" test_all_ads_filtered

# Test summary
echo
echo "=== Test Results ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✅ All circuit breaker tests passed!"
    rm -rf "$TEST_STATE_DIR"
    exit 0
else
    echo "❌ Some circuit breaker tests failed!"
    rm -rf "$TEST_STATE_DIR"
    exit 1
fi
