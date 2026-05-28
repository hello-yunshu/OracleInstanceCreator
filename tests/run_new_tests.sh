#!/bin/bash

# Test runner for new improvements: circuit breaker and exponential backoff

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
cd "$SCRIPT_DIR"

echo "=== Running Enhanced Feature Tests ==="
echo

# Track overall results
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_test_suite() {
    local suite_name="$1"
    local test_script="$2"
    
    echo "Running $suite_name..."
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    
    if "./$test_script"; then
        echo "✅ $suite_name: PASSED"
        PASSED_SUITES=$((PASSED_SUITES + 1))
    else
        echo "❌ $suite_name: FAILED"
        FAILED_SUITES=$((FAILED_SUITES + 1))
    fi
    echo
}

# Run test suites
run_test_suite "Circuit Breaker Tests" "test_circuit_breaker.sh"
run_test_suite "Exponential Backoff Tests" "test_exponential_backoff.sh"
run_test_suite "State Manager Tests" "test_state_manager.sh"
run_test_suite "Image Cache Tests" "test_image_cache.sh"

# Summary
echo "=== Test Suite Summary ==="
echo "Test suites run: $TOTAL_SUITES"
echo "Passed: $PASSED_SUITES"
echo "Failed: $FAILED_SUITES"
echo

if [[ $FAILED_SUITES -eq 0 ]]; then
    echo "🎉 All enhanced feature tests passed!"
    exit 0
else
    echo "💥 Some test suites failed!"
    exit 1
fi
