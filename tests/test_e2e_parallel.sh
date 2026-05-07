#!/bin/bash

# End-to-end integration tests for parallel execution
# Tests actual parallel process execution with mock OCI responses

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source test utilities and scripts
source "$PROJECT_ROOT/scripts/utils.sh"
source "$PROJECT_ROOT/scripts/constants.sh"
source "$SCRIPT_DIR/test_utils.sh"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Mock OCI responses for testing
create_mock_oci_responses() {
    local test_case="$1"
    local temp_dir="$2"
    
    case "$test_case" in
        "both_success")
            # Mock successful responses for both shapes
            cat > "$temp_dir/mock_oci_success.json" << 'EOF'
{
    "data": {
        "id": "ocid1.instance.oc1.ap-singapore-1.test123456789012345678901234567890",
        "display-name": "test-instance",
        "lifecycle-state": "RUNNING",
        "shape": "VM.Standard.A1.Flex",
        "availability-domain": "fgaj:AP-SINGAPORE-1-AD-1"
    }
}
EOF
            ;;
        "capacity_error")
            # Mock capacity error response
            cat > "$temp_dir/mock_oci_capacity_error.json" << 'EOF'
{
    "code": "OutOfCapacity",
    "message": "Out of host capacity"
}
EOF
            ;;
        "network_error")
            # Mock network error response
            cat > "$temp_dir/mock_oci_network_error.json" << 'EOF'
{
    "code": "InternalError", 
    "message": "Internal server error occurred"
}
EOF
            ;;
        "timeout_scenario")
            # No response file - simulates timeout
            ;;
    esac
}

# Mock OCI CLI for testing
create_mock_oci_cli() {
    local temp_dir="$1"
    local test_case="$2"
    
    cat > "$temp_dir/mock_oci" << EOF
#!/bin/bash
# Mock OCI CLI for testing

case "\$test_case" in
    "both_success")
        if [[ "\$*" == *"VM.Standard.A1.Flex"* ]]; then
            cat "$temp_dir/mock_oci_success.json"
            exit 0
        elif [[ "\$*" == *"VM.Standard.E2.1.Micro"* ]]; then
            # Simulate slight delay for E2
            sleep 0.5
            sed 's/A1.Flex/E2.1.Micro/' "$temp_dir/mock_oci_success.json"
            exit 0
        fi
        ;;
    "capacity_error")
        cat "$temp_dir/mock_oci_capacity_error.json" >&2
        exit 1
        ;;
    "network_error")
        cat "$temp_dir/mock_oci_network_error.json" >&2
        exit 1
        ;;
    "timeout_scenario")
        # Simulate long-running process that will timeout
        sleep 30
        exit 0
        ;;
esac

# Default success
cat "$temp_dir/mock_oci_success.json"
exit 0
EOF
    
    chmod +x "$temp_dir/mock_oci"
}

# Test parallel execution with both shapes succeeding
test_parallel_both_success() {
    local test_name="E2E Parallel Both Success"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Setup mock environment
    create_mock_oci_responses "both_success" "$temp_dir"
    create_mock_oci_cli "$temp_dir" "both_success"
    
    # Mock environment variables
    export OCI_SHAPE_A1="VM.Standard.A1.Flex"
    export OCI_SHAPE_E2="VM.Standard.E2.1.Micro" 
    export OCI_OCPUS_A1="4"
    export OCI_OCPUS_E2=""
    export PATH="$temp_dir:$PATH"
    export test_case="both_success"
    
    # Create mock launch-instance.sh that simulates success
    cat > "$temp_dir/mock_launch_instance.sh" << EOF
#!/bin/bash

# Determine result file based on shape
if [[ "\$OCI_SHAPE" == "VM.Standard.A1.Flex" ]]; then
    result_file="\$1/a1_result"
elif [[ "\$OCI_SHAPE" == "VM.Standard.E2.1.Micro" ]]; then
    result_file="\$1/e2_result"
fi

# Simulate instance creation time
sleep 2

# Write success result
echo "SUCCESS:ocid1.instance.test" > "\$result_file"
exit 0
EOF
    
    chmod +x "$temp_dir/mock_launch_instance.sh"
    
    # Test parallel execution logic (simplified version)
    local start_time
    start_time=$(date +%s)
    
    # Launch both processes in parallel with environment variables
    (export OCI_SHAPE="VM.Standard.A1.Flex"; "$temp_dir/mock_launch_instance.sh" "$temp_dir") &
    local pid_a1=$!
    
    (export OCI_SHAPE="VM.Standard.E2.1.Micro"; "$temp_dir/mock_launch_instance.sh" "$temp_dir") &
    local pid_e2=$!
    
    # Wait for completion with timeout
    local timeout_seconds=10
    local elapsed=0
    while [[ $elapsed -lt $timeout_seconds ]]; do
        if ! kill -0 $pid_a1 2>/dev/null && ! kill -0 $pid_e2 2>/dev/null; then
            break
        fi
        sleep 1
        ((elapsed += 1))
    done
    
    # Check results
    local end_time
    end_time=$(date +%s)
    local execution_time=$((end_time - start_time))
    
    if [[ -f "$temp_dir/a1_result" ]] && [[ -f "$temp_dir/e2_result" ]]; then
        if [[ $execution_time -le 5 ]]; then
            echo "✅ PASS: $test_name (${execution_time}s)"
            ((TESTS_PASSED += 1))
        else
            echo "❌ FAIL: $test_name - Too slow (${execution_time}s > 5s)"
            ((TESTS_FAILED += 1))
        fi
    else
        echo "❌ FAIL: $test_name - Missing result files"
        ((TESTS_FAILED += 1))
    fi
    
    # Cleanup
    kill $pid_a1 $pid_e2 2>/dev/null || true
    rm -rf "$temp_dir"
    trap - EXIT
}

# Test timeout handling
test_parallel_timeout_handling() {
    local test_name="E2E Parallel Timeout Handling"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Create long-running mock script
    cat > "$temp_dir/mock_slow_instance.sh" << 'EOF'
#!/bin/bash
# Simulate slow instance creation that will timeout
sleep 20  # Longer than our timeout
echo "SUCCESS:ocid1.instance.test" > "$1/result"
exit 0
EOF
    
    chmod +x "$temp_dir/mock_slow_instance.sh"
    
    local start_time
    start_time=$(date +%s)
    
    # Launch process that will timeout
    ("$temp_dir/mock_slow_instance.sh" "$temp_dir") &
    local pid=$!
    
    # Implement timeout logic
    local timeout_seconds=3  # Short timeout for testing
    local elapsed=0
    
    while [[ $elapsed -lt $timeout_seconds ]]; do
        if ! kill -0 $pid 2>/dev/null; then
            break
        fi
        sleep 1
        ((elapsed += 1))
    done
    
    # Handle timeout
    local timed_out=false
    if [[ $elapsed -ge $timeout_seconds ]]; then
        kill $pid 2>/dev/null || true
        sleep 2
        kill -9 $pid 2>/dev/null || true
        timed_out=true
    fi
    
    local end_time
    end_time=$(date +%s)
    local execution_time=$((end_time - start_time))
    
    if [[ "$timed_out" == "true" ]] && [[ $execution_time -le 6 ]]; then
        echo "✅ PASS: $test_name (${execution_time}s)"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - Timeout not properly handled"
        ((TESTS_FAILED += 1))
    fi
    
    rm -rf "$temp_dir"
    trap - EXIT
}

# Test signal handling during parallel execution
test_parallel_signal_handling() {
    local test_name="E2E Parallel Signal Handling"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Create script that handles signals
cat > "$temp_dir/mock_signal_instance.sh" << EOF
#!/bin/bash

result_dir="\$1"

cleanup() {
    echo "CLEANUP_CALLED" > "\$result_dir/cleanup_marker"
    exit 130
}

trap cleanup SIGTERM SIGINT

# Simulate work
sleep 10 &
wait \$!

echo "SUCCESS:ocid1.instance.test" > "\$result_dir/result"
exit 0
EOF
    
    chmod +x "$temp_dir/mock_signal_instance.sh"
    
    # Launch process
    ("$temp_dir/mock_signal_instance.sh" "$temp_dir") &
    local pid=$!
    
    # Send SIGTERM after short delay
    sleep 1
    kill -TERM $pid 2>/dev/null
    
    # Wait for cleanup
    sleep 2
    
    if [[ -f "$temp_dir/cleanup_marker" ]]; then
        echo "✅ PASS: $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - Signal not properly handled"
        ((TESTS_FAILED += 1))
    fi
    
    kill -9 $pid 2>/dev/null || true
    rm -rf "$temp_dir"
    trap - EXIT
}

# Test concurrent file operations
test_parallel_file_operations() {
    local test_name="E2E Parallel File Operations"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    # Create script that writes to separate files
    cat > "$temp_dir/mock_file_writer.sh" << 'EOF'
#!/bin/bash
shape="$1"
result_dir="$2"

# Write unique content based on shape
if [[ "$shape" == "A1" ]]; then
    echo "A1_SUCCESS:$(date +%s.%N)" > "$result_dir/a1_result"
elif [[ "$shape" == "E2" ]]; then
    echo "E2_SUCCESS:$(date +%s.%N)" > "$result_dir/e2_result"
fi

# Simulate some processing time
sleep 1
exit 0
EOF
    
    chmod +x "$temp_dir/mock_file_writer.sh"
    
    # Launch both writers in parallel
    ("$temp_dir/mock_file_writer.sh" "A1" "$temp_dir") &
    local pid_a1=$!
    
    ("$temp_dir/mock_file_writer.sh" "E2" "$temp_dir") &
    local pid_e2=$!
    
    # Wait for completion
    wait $pid_a1
    wait $pid_e2
    
    # Verify both files were created with correct content
    if [[ -f "$temp_dir/a1_result" ]] && [[ -f "$temp_dir/e2_result" ]]; then
        local a1_content
        local e2_content
        a1_content=$(cat "$temp_dir/a1_result")
        e2_content=$(cat "$temp_dir/e2_result")
        
        if [[ "$a1_content" == A1_SUCCESS:* ]] && [[ "$e2_content" == E2_SUCCESS:* ]]; then
            echo "✅ PASS: $test_name"
            ((TESTS_PASSED += 1))
        else
            echo "❌ FAIL: $test_name - Incorrect file content"
            ((TESTS_FAILED += 1))
        fi
    else
        echo "❌ FAIL: $test_name - Missing result files"
        ((TESTS_FAILED += 1))
    fi
    
    rm -rf "$temp_dir"
    trap - EXIT
}

# Test resource cleanup on various scenarios
test_parallel_resource_cleanup() {
    local test_name="E2E Parallel Resource Cleanup"
    echo "Running: $test_name"
    
    local temp_dir
    temp_dir=$(mktemp -d)
    local initial_files
    initial_files=$(find /tmp -name "tmp.*" | wc -l)
    
    # Create script that creates temporary resources
    cat > "$temp_dir/mock_resource_creator.sh" << 'EOF'
#!/bin/bash
# Create some temporary resources
temp_file=$(mktemp)
temp_dir_nested=$(mktemp -d)

cleanup_resources() {
    rm -f "$temp_file" 2>/dev/null
    rm -rf "$temp_dir_nested" 2>/dev/null
    exit $1
}

trap 'cleanup_resources 130' SIGTERM SIGINT
trap 'cleanup_resources 0' EXIT

# Simulate work
sleep 2

echo "SUCCESS" > "$1/result"
cleanup_resources 0
EOF
    
    chmod +x "$temp_dir/mock_resource_creator.sh"
    
    # Launch and then kill process to test cleanup
    ("$temp_dir/mock_resource_creator.sh" "$temp_dir") &
    local pid=$!
    
    sleep 1
    kill -TERM $pid 2>/dev/null
    
    # Wait for cleanup
    sleep 3
    
    # Check if temporary files were cleaned up
    local final_files
    final_files=$(find /tmp -name "tmp.*" | wc -l)
    
    if [[ $final_files -le $initial_files ]]; then
        echo "✅ PASS: $test_name"
        ((TESTS_PASSED += 1))
    else
        echo "❌ FAIL: $test_name - Resource cleanup failed"
        ((TESTS_FAILED += 1))
    fi
    
    kill -9 $pid 2>/dev/null || true
    rm -rf "$temp_dir"
}

# Main test runner
run_e2e_tests() {
    echo "=== End-to-End Parallel Execution Tests ==="
    echo "Testing parallel execution behavior with mock scenarios"
    echo
    
    # Run all test cases
    test_parallel_both_success
    test_parallel_timeout_handling
    test_parallel_signal_handling
    test_parallel_file_operations
    test_parallel_resource_cleanup
    
    echo
    echo "=== Test Results ==="
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo "Total:  $((TESTS_PASSED + TESTS_FAILED))"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo "✅ All end-to-end tests passed!"
        return 0
    else
        echo "❌ Some tests failed!"
        return 1
    fi
}

# Run tests if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_e2e_tests
fi
